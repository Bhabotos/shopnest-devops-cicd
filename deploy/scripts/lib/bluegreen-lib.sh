#!/usr/bin/env bash
# Shared functions for bluegreen-deploy.sh and rollback.sh. Source it; do not execute it.
# Design: docs/ARCHITECTURE.md, "Deployment & rollback".
#
# Layout on the server (per environment, under $SHOPNEST_HOME, default ~/shopnest):
#   <env>/runtime.env           NON-secret settings (database host, name, region, the db-app secret id, the ECR repository
#                               and the artifact bucket), written by the operator, never in git. The backend reads its
#                               user and password (db-app ONLY) from AWS Secrets Manager; no password exists on the
#                               server, and the owner and master secret ids are deliberately not accepted here.
#   <env>/secrets.env           LOCAL REHEARSAL ONLY (BG_LOCAL_DB=1): passwords of the throwaway database container
#   <env>/state/active          blue or green: the colour that receives traffic
#   <env>/state/tag-blue|green  release SHA running (or last run) on that colour
#   <env>/state/last_good       SHA of the last release that passed live verification
#   <env>/state/history.log     "<utc> <env> <sha> <status> <detail>", appended, never rewritten
#   <env>/nginx/upstream/       active.conf (backend colour + frontend release), swapped atomically
#   <env>/frontend/releases/    one directory of static files per release SHA
#   logs/<env>-<sha>.log        deployment log (the CD workflow uploads it as an artifact)

bg_log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
bg_die() { bg_log "ERROR: $*" >&2; exit 1; }

bg_require_sha() { [[ "${1:-}" =~ ^[0-9a-f]{40}$ ]] || bg_die "release must be a full 40-character commit SHA"; }

# bg_init <staging|production> <bundle dir that contains deploy/>
# Three modes:
#   rds   (default): the database is the private RDS instance (infra/terraform design). Needs <env>/runtime.env. No password
#         is read, stored or checked here.
#   lab   (BG_LAB=1, set by the lab SSM documents in infra/lab): ONE small instance runs both environments, each as its own
#         Compose project with its own PostgreSQL CONTAINER on an internal network (no published port). Images come from GHCR
#         by digest and the release is a git checkout of the exact commit. The passwords are GENERATED on the host at the first
#         deploy into <env>/secrets.env (mode 600, never printed, never in git). Staging is bound to the loopback address only.
#   local (BG_LOCAL_DB=1): the same containers, for rehearsing the blue/green logic on a laptop. Needs <env>/secrets.env.
#         Refused unless the stack is plainly not a real environment (see below).
bg_init() {
  BG_ENV="${1:-}"
  BG_RELEASE_DIR="${2:-}"
  case "$BG_ENV" in staging | production) ;; *) bg_die "environment must be staging or production" ;; esac
  [ -f "$BG_RELEASE_DIR/deploy/docker-compose.prod.yml" ] || bg_die "no deploy/docker-compose.prod.yml in $BG_RELEASE_DIR"

  BG_BASE_DIR="${SHOPNEST_HOME:-$HOME/shopnest}"
  BG_ENV_DIR="$BG_BASE_DIR/$BG_ENV"
  BG_STATE_DIR="$BG_ENV_DIR/state"
  BG_UPSTREAM_DIR="$BG_ENV_DIR/nginx/upstream"
  BG_FRONTEND_DIR="$BG_ENV_DIR/frontend"
  BG_LOG_DIR="$BG_BASE_DIR/logs"
  # The prefix and the port can be overridden so a local rehearsal never touches a real environment.
  BG_PROJECT="${SHOPNEST_PROJECT_PREFIX:-shopnest}-$BG_ENV"
  BG_COMPOSE_FILE="$BG_RELEASE_DIR/deploy/docker-compose.prod.yml"
  BG_COMPOSE_FILES=(-f "$BG_COMPOSE_FILE")
  mkdir -p "$BG_STATE_DIR" "$BG_UPSTREAM_DIR" "$BG_FRONTEND_DIR/releases" "$BG_LOG_DIR"

  if [ "${BG_LAB:-}" = "1" ]; then
    [ "${BG_LOCAL_DB:-}" != "1" ] || bg_die "BG_LAB=1 and BG_LOCAL_DB=1 are mutually exclusive"
    BG_DB_MODE=lab
    # The lab reuses the local-database file: a PostgreSQL container, one ordinary bridge network, no fixed addresses.
    [ -f "$BG_RELEASE_DIR/deploy/docker-compose.local-db.yml" ] || bg_die "no deploy/docker-compose.local-db.yml in $BG_RELEASE_DIR"
    BG_COMPOSE_FILES+=(-f "$BG_RELEASE_DIR/deploy/docker-compose.local-db.yml")
  elif [ "${BG_LOCAL_DB:-}" = "1" ]; then
    BG_DB_MODE=local
    bg_require_rehearsal_stack "BG_LOCAL_DB=1"
    [ -f "$BG_RELEASE_DIR/deploy/docker-compose.local-db.yml" ] || bg_die "no deploy/docker-compose.local-db.yml in $BG_RELEASE_DIR"
    BG_COMPOSE_FILES+=(-f "$BG_RELEASE_DIR/deploy/docker-compose.local-db.yml")
  else
    BG_DB_MODE=rds
  fi

  [ -f "$BG_RELEASE_DIR/deploy/env/$BG_ENV.env" ] || bg_die "missing deploy/env/$BG_ENV.env in the bundle"
  set -a
  # shellcheck disable=SC1090
  . "$BG_RELEASE_DIR/deploy/env/$BG_ENV.env"
  set +a
  if [ "$BG_DB_MODE" = lab ]; then
    bg_load_lab_secrets
    # Only the production environment is public (the security group admits port 80 only); staging listens on loopback.
    if [ "$BG_ENV" = production ]; then HTTP_BIND=0.0.0.0; else HTTP_BIND=127.0.0.1; fi
    export HTTP_BIND
  elif [ "$BG_DB_MODE" = local ]; then
    bg_load_local_secrets
  else
    bg_load_runtime
    # The container network and the metadata-service rules come from one set of EDGE_* settings: refuse inconsistent ones
    # before anything is started (the real checks are in deploy/host/imds-guard.sh and its own tests).
    bash "$BG_RELEASE_DIR/deploy/host/imds-guard.sh" validate "$BG_RELEASE_DIR/deploy/env/$BG_ENV.env" > /dev/null \
      || bg_die "the EDGE_* settings in deploy/env/$BG_ENV.env are not consistent (run: bash deploy/host/imds-guard.sh validate deploy/env/$BG_ENV.env)"
  fi
  if [ -n "${SHOPNEST_HTTP_PORT:-}" ]; then HTTP_PORT="$SHOPNEST_HTTP_PORT"; export HTTP_PORT; fi
  export ENV_DIR="$BG_ENV_DIR"
  bg_stage_config
  bg_export_tags
}

# A local rehearsal (loose secrets file, throwaway database container) is accepted only when the stack is plainly
# not a real environment: a project prefix other than "shopnest" (so it can never be shopnest-staging or
# shopnest-production) and a loopback-only bind. $1 names the setting being refused, for the message.
bg_require_rehearsal_stack() {
  if [ -z "${SHOPNEST_PROJECT_PREFIX:-}" ] || [ "$SHOPNEST_PROJECT_PREFIX" = "shopnest" ] || [ "${HTTP_BIND:-}" != "127.0.0.1" ]; then
    bg_die "$1 is for local rehearsals only: it needs SHOPNEST_PROJECT_PREFIX set to something other than 'shopnest' and HTTP_BIND=127.0.0.1; it is never allowed for $BG_PROJECT"
  fi
}

# ---- the host guard for the EC2 metadata service (AWS mode only) ------------------------------------------------
# Installed and applied BEFORE any container starts, and PROVEN before a release starts: a probe container and nginx must
# fail to reach the metadata service. If that cannot be shown the deploy stops (fail closed). GUARD_ROOT is empty on a real
# host; the offline tests set it. The rules themselves and their tests live in deploy/host/ and deploy/tests/imds-guard.test.sh.
bg_guard_bin() { echo "${GUARD_ROOT:-}/usr/local/sbin/shopnest-imds-guard"; }
bg_guard_env() { echo "${GUARD_ROOT:-}/etc/shopnest/edge.env"; }

bg_host_guard() {
  [ "$BG_DB_MODE" = rds ] || return 0
  bash "$BG_RELEASE_DIR/deploy/host/install-host-guards.sh" "$BG_RELEASE_DIR/deploy/env/$BG_ENV.env" || bg_die "could not install the metadata-service guard"
  "$(bg_guard_bin)" ensure-network "$(bg_guard_env)" || bg_die "could not create the container network"
  "$(bg_guard_bin)" apply "$(bg_guard_env)" || bg_die "could not apply the metadata-service rules; nothing was started"
}

# bg_host_guard_verify <release sha>: the image of that release runs the probe. nginx is checked too when it is running.
bg_host_guard_verify() {
  [ "$BG_DB_MODE" = rds ] || return 0
  local nginx_container
  nginx_container="$(bg_compose ps -q nginx 2> /dev/null | head -n 1 || true)"
  "$(bg_guard_bin)" verify "$(bg_guard_env)" "shopnest-backend:$1" "$nginx_container" \
    || bg_die "FAIL CLOSED: the metadata-service isolation could not be confirmed; no release was started"
}

# bg_read_env_file <file> <allowed key>...: read KEY=VALUE lines and export them. The file is PARSED, never sourced, so
# nothing in it can run as a command: only the listed keys are accepted, and a value may contain only letters, digits and
# . _ / @ + = : - (no quotes, spaces, $ or ;). Blank lines and lines starting with # are ignored.
bg_read_env_file() {
  local file="$1" line key value allowed n=0
  shift
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    line="${line%$'\r'}"
    [[ -z "$line" || "$line" == \#* ]] && continue
    [[ "$line" =~ ^([A-Z][A-Z0-9_]*)=(.*)$ ]] || bg_die "$file line $n is not KEY=VALUE"
    key="${BASH_REMATCH[1]}"
    value="${BASH_REMATCH[2]}"
    allowed=0
    for a in "$@"; do [ "$a" = "$key" ] && allowed=1; done
    [ "$allowed" = 1 ] || bg_die "$file line $n: $key is not an allowed setting"
    [[ "$value" =~ ^[A-Za-z0-9._/@+=:-]*$ ]] || bg_die "$file line $n: the value of $key is not a plain value (letters, digits and . _ / @ + = : - only)"
    export "$key=$value"
  done < "$file"
}

# RDS mode: <env>/runtime.env holds the non-secret settings. Nothing here is a credential.
bg_load_runtime() {
  local runtime="$BG_ENV_DIR/runtime.env" key
  [ -f "$runtime" ] || bg_die "missing $runtime (create it on the server; see docs/AWS_STAGING_INTEGRATION.md)"
  # DB_OWNER_SECRET_ID and any master-secret setting are NOT allowed keys: this host must never learn where the owner or
  # master credentials are, because migrations and the role bootstrap run in CodeBuild, not here.
  bg_read_env_file "$runtime" DB_HOST DB_PORT DB_NAME AWS_REGION DB_APP_SECRET_ID ECR_REPOSITORY ARTIFACT_BUCKET
  for key in DB_HOST DB_NAME AWS_REGION DB_APP_SECRET_ID ECR_REPOSITORY ARTIFACT_BUCKET; do
    [ -n "${!key:-}" ] || bg_die "$key is not set in $runtime"
  done
  DB_PORT="${DB_PORT:-5432}"
  { [[ "$DB_PORT" =~ ^[0-9]{1,5}$ ]] && [ "$DB_PORT" -ge 1 ] && [ "$DB_PORT" -le 65535 ]; } || bg_die "DB_PORT in $runtime must be a port number"
  [[ "$DB_HOST" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || bg_die "DB_HOST in $runtime is not a host name"
  [[ "$DB_NAME" =~ ^[a-z_][a-z0-9_]*$ ]] || bg_die "DB_NAME in $runtime is not a plain database name"
  [[ "$AWS_REGION" =~ ^[a-z]{2}-[a-z]+-[0-9]$ ]] || bg_die "AWS_REGION in $runtime is not a region"
  [[ "$DB_APP_SECRET_ID" =~ ^[A-Za-z0-9/_+=.@-]+$ ]] || bg_die "DB_APP_SECRET_ID in $runtime is not a plain secret name"
  [[ "$ARTIFACT_BUCKET" =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]] || bg_die "ARTIFACT_BUCKET in $runtime is not a bucket name"
  [[ "$ECR_REPOSITORY" =~ ^[a-z0-9][a-z0-9._/-]*$ ]] || bg_die "ECR_REPOSITORY in $runtime is not a plain repository name"
  export DB_HOST DB_PORT DB_NAME AWS_REGION DB_APP_SECRET_ID ECR_REPOSITORY ARTIFACT_BUCKET
}

# Local mode: the passwords of the throwaway database container.
bg_load_local_secrets() {
  local secrets="$BG_ENV_DIR/secrets.env" key value
  [ -f "$secrets" ] || bg_die "missing $secrets (create it on the server; see docs/ARCHITECTURE.md)"
  if [ "${BG_ALLOW_LOOSE_SECRETS:-}" = "1" ]; then
    # Only for a local rehearsal on a filesystem that cannot hold mode 600 (Windows).
    bg_require_rehearsal_stack "BG_ALLOW_LOOSE_SECRETS=1"
    bg_log "WARNING: BG_ALLOW_LOOSE_SECRETS=1, the secrets file mode is not checked (local rehearsal $BG_PROJECT)"
  elif [ "$(stat -c '%a' "$secrets")" != "600" ]; then
    bg_die "$secrets must have mode 600"
  fi
  set -a
  # shellcheck disable=SC1090
  . "$secrets"
  set +a
  for key in POSTGRES_PASSWORD DB_OWNER_PASSWORD DB_APP_PASSWORD; do
    value="${!key:-}"
    [[ "$value" =~ ^[A-Za-z0-9]{16,}$ ]] || bg_die "$key in secrets.env must be 16 or more letters and digits"
  done
}

# Lab mode: the passwords of this environment's database container are generated on the host at the first deploy and kept in
# <env>/secrets.env (mode 600, readable by root only). They are never printed, never passed through GitHub or Systems Manager and
# never committed. A later deploy reuses the file; the database roles are created only on an EMPTY data volume, from these values.
bg_random_password() { head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n'; }
bg_load_lab_secrets() {
  local secrets="$BG_ENV_DIR/secrets.env" key
  if [ ! -f "$secrets" ]; then
    bg_log "first deploy of $BG_ENV: generating its database passwords into $secrets (mode 600; the values are never printed)"
    (
      umask 077
      for key in POSTGRES_PASSWORD DB_OWNER_PASSWORD DB_APP_PASSWORD; do printf '%s=%s\n' "$key" "$(bg_random_password)"; done > "$secrets.tmp"
    ) || bg_die "could not generate the database passwords"
    mv "$secrets.tmp" "$secrets" || bg_die "could not store the database passwords"
  fi
  bg_load_local_secrets
}

# Everything a container mounts from the host lives at a STABLE path under the environment directory.
# If a service mounted a path inside the release bundle, its definition would change with every
# release and Compose would recreate it; for the database that is a restart in the middle of a live
# deploy (found by the first real-Docker rehearsal: one failed request and a 2.5 s stall).
bg_stage_config() {
  [ -f "$BG_RELEASE_DIR/deploy/nginx/nginx.conf" ] || bg_die "missing deploy/nginx/nginx.conf in the bundle"
  mkdir -p "$BG_ENV_DIR/nginx/conf" || bg_die "could not create the config directories"
  if [ "$BG_DB_MODE" = local ] || [ "$BG_DB_MODE" = lab ]; then
    [ -d "$BG_RELEASE_DIR/deploy/db/init" ] || bg_die "missing deploy/db/init in the bundle"
    mkdir -p "$BG_ENV_DIR/db-init" || bg_die "could not create the config directories"
    cp -a "$BG_RELEASE_DIR/deploy/db/init/." "$BG_ENV_DIR/db-init/" || bg_die "could not stage the database init scripts"
  fi
  # Copied over the existing file (same inode); a running nginx picks it up at the next reload.
  cp "$BG_RELEASE_DIR/deploy/nginx/nginx.conf" "$BG_ENV_DIR/nginx/conf/default.conf" || bg_die "could not stage the nginx config"
}

# The database must be reachable before a release is started.
#   rds:   the RDS endpoint accepts a TCP connection from this host. This proves the network path only; the
#          credentials, TLS and the roles are proven by the migration step that follows, and by the backend's own
#          /health (which runs SELECT 1). There is no database container to start, restart or recreate.
#   local: start the database container if it is not running, and NEVER recreate or restart it:
#          --no-recreate leaves a running container alone even if Compose thinks its definition changed.
bg_db_up() {
  if [ "$BG_DB_MODE" = local ] || [ "$BG_DB_MODE" = lab ]; then
    bg_compose up -d --no-recreate db || return 1
    bg_retry 60 2 bg_compose exec -T db pg_isready -h 127.0.0.1 -U shopnest_admin -d shopnest
  else
    bg_retry "${DB_WAIT_ATTEMPTS:-30}" "${DB_WAIT_INTERVAL:-2}" bg_db_tcp_open
  fi
}
bg_db_tcp_open() { timeout 3 bash -c 'exec 3<> "/dev/tcp/$1/$2"' _ "$DB_HOST" "$DB_PORT"; }

bg_export_tags() {
  BLUE_TAG="$(cat "$BG_STATE_DIR/tag-blue" 2>/dev/null || echo none)"
  GREEN_TAG="$(cat "$BG_STATE_DIR/tag-green" 2>/dev/null || echo none)"
  export BLUE_TAG GREEN_TAG
}

bg_compose() { docker compose -p "$BG_PROJECT" "${BG_COMPOSE_FILES[@]}" "$@"; }

bg_active() { cat "$BG_STATE_DIR/active" 2>/dev/null || true; }
bg_other() { if [ "$1" = blue ]; then echo green; else echo blue; fi; }
bg_idle() {
  local current
  current="$(bg_active)"
  if [ -z "$current" ]; then echo blue; else bg_other "$current"; fi
}

# bg_retry <attempts> <interval seconds> <command...>
bg_retry() {
  local attempts="$1" interval="$2" n
  shift 2
  for ((n = 1; n <= attempts; n++)); do
    if "$@" > /dev/null 2>&1; then return 0; fi
    sleep "$interval"
  done
  return 1
}

# ---- history -----------------------------------------------------------------------------------
# bg_history <status> <sha> <detail>
bg_history() { printf '%s %s %s %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$BG_ENV" "$2" "$1" "$3" >> "$BG_STATE_DIR/history.log"; }
bg_history_has_deployed() {
  [ -f "$BG_STATE_DIR/history.log" ] && awk -v s="$1" '$3 == s && $4 == "deployed" { found = 1 } END { exit !found }' "$BG_STATE_DIR/history.log"
}

# ---- images and frontend files -------------------------------------------------------------------
bg_image_revision() { docker image inspect "shopnest-backend:$1" --format '{{ index .Config.Labels "org.opencontainers.image.revision" }}' 2> /dev/null; }

# A frontend release is usable only if it has a non-empty index.html. Without it nginx answers every page
# with HTTP 500 (an internal redirection cycle through try_files), which no health endpoint would show:
# found by attempt 4 of the local rehearsal (83 of 181 requests failed while such a release was live).
bg_frontend_ok() { [ -f "$1/index.html" ] && [ -s "$1/index.html" ]; }

# bg_frontend_install <sha> <dist dir>: one directory of static files per release, kept for rollback.
bg_frontend_install() {
  local dest="$BG_FRONTEND_DIR/releases/$1"
  [ -d "$2" ] || return 1
  if [ ! -d "$dest" ]; then
    rm -rf "$dest.tmp"
    mkdir -p "$dest.tmp" && cp -a "$2/." "$dest.tmp/" && mv "$dest.tmp" "$dest" || return 1
  fi
}

# ---- nginx switching -----------------------------------------------------------------------------
bg_active_conf_text() { # <colour> <sha>
  printf 'upstream backend_active {\n  server backend-%s:3000;\n}\nmap $host $frontend_root {\n  default /srv/frontend/releases/%s;\n}\n' "$1" "$2"
}
bg_write_active_conf() { # atomic: write a hidden temp file in the same directory, then rename over active.conf
  local tmp="$BG_UPSTREAM_DIR/.active.conf.tmp"
  printf '%s' "$1" > "$tmp" && mv -f "$tmp" "$BG_UPSTREAM_DIR/active.conf"
}
bg_nginx_running() { [ -n "$(bg_compose ps --status running -q nginx 2> /dev/null)" ]; }

# bg_switch <colour> <sha>: point nginx at that colour and that release's frontend. On any failure the
# previous active.conf is restored (and reloaded when nginx was running), so traffic never lands on a
# configuration that failed `nginx -t`.
bg_switch() {
  local colour="$1" sha="$2" previous="" had_previous=0
  if [ -f "$BG_UPSTREAM_DIR/active.conf" ]; then
    previous="$(cat "$BG_UPSTREAM_DIR/active.conf")"
    had_previous=1
  fi
  [ -d "$BG_FRONTEND_DIR/releases/$sha" ] || { bg_log "frontend release $sha is not installed"; return 1; }
  bg_write_active_conf "$(bg_active_conf_text "$colour" "$sha")" || return 1
  if bg_nginx_running; then
    if bg_compose exec -T nginx nginx -t && bg_compose exec -T nginx nginx -s reload; then
      return 0
    fi
    if [ "$had_previous" = 1 ]; then bg_write_active_conf "$previous"; fi
    return 1
  fi
  if bg_compose up -d nginx; then return 0; fi
  if [ "$had_previous" = 1 ]; then bg_write_active_conf "$previous"; fi
  return 1
}

# ---- health and version checks -----------------------------------------------------------------
# A colour is ready when its own /health is OK and its /version reports the expected commit.
bg_color_ready() { # <colour> <sha>
  local commit
  bg_compose exec -T "backend-$1" node -e "fetch('http://127.0.0.1:3000/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))" || return 1
  commit="$(bg_compose exec -T "backend-$1" node -e "fetch('http://127.0.0.1:3000/version').then(r=>r.json()).then(j=>console.log(j.commit)).catch(()=>process.exit(1))")" || return 1
  [ "$commit" = "$2" ]
}

bg_nginx_get() { bg_compose exec -T nginx wget -q -O - "http://127.0.0.1:8081$1"; }

# ---- staging-only, one-shot fault injection (the Part G demonstration of the AUTOMATIC rollback) -----------------------------------
# The owner arms it with a Session Manager session on the instance: a file /opt/shopnest/staging/fault.env that is owned by root, not
# writable by group or others, and holds exactly the line  FAULT=post-switch-unhealthy.  The NEXT staging DEPLOY consumes it: the file is
# deleted first, and the post-switch verification of THAT release (and only that release) is reported as failed, so the real automatic
# rollback runs: traffic is returned to the previous release, which is verified again. Nothing is actually broken and real traffic never
# sees a broken backend. The rules, each tested in deploy/tests/lab-mode.test.sh:
#   * production never reads the file (the function returns before it looks): only BG_ENV=staging in lab mode;
#   * only a deploy arms it: a rollback never does, and the file is left untouched;
#   * only when a previous release exists to fall back to (the very first deploy is never sabotaged);
#   * only a plain root-owned file with the exact content; anything else is ignored, logged and left in place;
#   * it is consumed (removed) when armed; if it cannot be removed it is NOT armed.
# BG_FAULT_OWNER_UID (default 0) exists for the offline tests, which do not run as root; on the instance the deploy runs through sudo, which
# discards the caller's environment, so it cannot be set there.
BG_FAULT_SHA=""
bg_fault_arm() { # <sha> <note> <previous colour>
  local f="$BG_ENV_DIR/fault.env" owner="${BG_FAULT_OWNER_UID:-0}" mode near
  BG_FAULT_SHA=""
  [ "$BG_ENV" = staging ] && [ "$BG_DB_MODE" = lab ] || return 0
  if ! { [ -e "$f" ] || [ -L "$f" ]; }; then
    # A silent "nothing armed" cannot be told apart from a hook that did not run (found on the first real attempt). Staging deploys therefore
    # say what they looked for, and list the names, owners and modes (never the content) of anything under the base directory called *fault*,
    # which shows a file created in the wrong place or under the wrong name. Production never reaches this code.
    near="$(find "$BG_BASE_DIR" -maxdepth 3 -iname '*fault*' -printf '%u:%g %m %p\n' 2> /dev/null | head -n 5 | tr '\n' ';')"
    bg_log "fault injection: no fault file at $f, not armed${near:+; found instead (NOT used): $near}"
    return 0
  fi
  if [ "$2" != deploy ]; then bg_log "fault file present, but this is a $2 and not a deploy: left untouched, not armed"; return 0; fi
  if [ -z "$3" ]; then bg_log "fault file present, but there is no previous release to fall back to: left untouched, not armed"; return 0; fi
  if [ -L "$f" ] || [ ! -f "$f" ]; then bg_log "fault file ignored: it is not a plain file"; return 0; fi
  if [ "$(stat -c %u "$f" 2> /dev/null)" != "$owner" ]; then bg_log "fault file ignored: it is not owned by root"; return 0; fi
  mode="$(stat -c %a "$f" 2> /dev/null)"
  if [ $((8#${mode:-777} & 8#022)) -ne 0 ]; then bg_log "fault file ignored: it is writable by group or others"; return 0; fi
  if [ "$(head -c 64 "$f" | tr -d '\r')" != "FAULT=post-switch-unhealthy" ] || [ "$(wc -l < "$f" | tr -d ' ')" -gt 1 ]; then
    bg_log "fault file ignored: its content is not exactly FAULT=post-switch-unhealthy"
    return 0
  fi
  if ! rm -f "$f" || [ -e "$f" ]; then bg_log "fault file could not be removed: NOT armed"; return 0; fi
  BG_FAULT_SHA="$1"
  bg_log "FAULT INJECTION (staging test): armed for release $1; the fault file is consumed and removed; its post-switch verification will be reported as FAILED"
}

# Live check, as traffic sees it: through nginx (health and commit), and through the published port
# when curl is available on the host (health and the frontend index).
bg_live_check() { # <sha>
  local body
  # The injected fault applies to the release it was armed for, never to the previous release that traffic is returned to.
  if [ -n "${BG_FAULT_SHA:-}" ] && [ "$BG_FAULT_SHA" = "$1" ]; then return 1; fi
  body="$(bg_nginx_get /health)" || return 1
  [[ "$body" == *'"status":"ok"'* ]] || return 1
  body="$(bg_nginx_get /version)" || return 1
  [[ "$body" == *"\"commit\":\"$1\""* ]] || return 1
  if command -v curl > /dev/null 2>&1 && [ -z "${BG_SKIP_PUBLIC_CHECK:-}" ]; then
    curl -fsS --max-time 5 "http://127.0.0.1:${HTTP_PORT}/health" | grep -q '"status":"ok"' || return 1
    curl -fsS --max-time 5 -o /dev/null "http://127.0.0.1:${HTTP_PORT}/" || return 1
  fi
}

# ---- the release step shared by deploy and rollback ----------------------------------------------
bg_abort_idle() { # <colour> <previous tag value>: remove a colour that must not stay up
  bg_compose stop "backend-$1" > /dev/null 2>&1 || true
  bg_compose rm -f "backend-$1" > /dev/null 2>&1 || true
  printf '%s\n' "$2" > "$BG_STATE_DIR/tag-$1"
  bg_export_tags
}

# bg_release <sha> [note]: put <sha> on the idle colour, validate it, move traffic, verify, then drain
# and stop the old colour. Anything that fails before the switch leaves the live release untouched;
# anything that fails after it returns traffic to the previous release.
# Return codes (the CD workflows rely on them):
#   0  the release is live
#   1  the release failed and the previous release is serving: it was never replaced (failure before the
#      switch) or traffic was returned to it and verified (automatic rollback complete)
#   3  the release failed AND the recovery failed: traffic may be on a release that did not verify, or
#      there was no previous release to return to. Needs an operator now.
bg_release() {
  local sha="$1" note="${2:-deploy}" prev prev_sha="" idle old_idle_tag restored=1 rc=1
  prev="$(bg_active)"
  if [ -n "$prev" ]; then prev_sha="$(cat "$BG_STATE_DIR/tag-$prev")"; fi
  idle="$(bg_idle)"
  old_idle_tag="$(cat "$BG_STATE_DIR/tag-$idle" 2> /dev/null || echo none)"
  bg_log "release $sha ($note): live=${prev:-none} (${prev_sha:-none}), target colour=$idle"

  printf '%s\n' "$sha" > "$BG_STATE_DIR/tag-$idle" || return 1
  bg_export_tags
  if ! bg_compose up -d --force-recreate --no-deps "backend-$idle"; then
    bg_log "could not start backend-$idle"
    bg_abort_idle "$idle" "$old_idle_tag"
    bg_history failed "$sha" "could not start backend-$idle; live release unchanged"
    return 1
  fi

  bg_log "waiting for backend-$idle to report healthy and commit $sha"
  if ! bg_retry "${READY_ATTEMPTS:-30}" "${READY_INTERVAL:-2}" bg_color_ready "$idle" "$sha"; then
    bg_log "validation FAILED for backend-$idle; traffic was NOT moved"
    bg_compose logs --no-color --tail 40 "backend-$idle" || true
    bg_abort_idle "$idle" "$old_idle_tag"
    bg_history failed "$sha" "pre-switch validation failed; live release unchanged"
    return 1
  fi

  # Everything that can be checked without sending traffic is checked before the switch.
  if ! bg_frontend_ok "$BG_FRONTEND_DIR/releases/$sha"; then
    bg_log "validation FAILED: the frontend files for $sha have no non-empty index.html; traffic was NOT moved"
    bg_abort_idle "$idle" "$old_idle_tag"
    bg_history failed "$sha" "pre-switch validation failed (frontend has no index.html); live release unchanged"
    return 1
  fi

  bg_log "backend-$idle validated; switching traffic"
  if ! bg_switch "$idle" "$sha"; then
    bg_log "switch FAILED; the previous nginx configuration was restored"
    bg_abort_idle "$idle" "$old_idle_tag"
    bg_history failed "$sha" "nginx switch failed; live release unchanged"
    return 1
  fi
  printf '%s\n' "$idle" > "$BG_STATE_DIR/active"

  bg_fault_arm "$sha" "$note" "$prev"
  if ! bg_retry "${LIVE_ATTEMPTS:-10}" "${LIVE_INTERVAL:-1}" bg_live_check "$sha"; then
    bg_log "post-switch verification FAILED; returning traffic to the previous release"
    if [ -n "$BG_FAULT_SHA" ]; then bg_log "this failure was INJECTED by the staging fault file (a test); the automatic rollback below is the real one"; fi
    if [ -n "$prev" ]; then
      restored=0
      if bg_switch "$prev" "$prev_sha"; then
        printf '%s\n' "$prev" > "$BG_STATE_DIR/active"
        if bg_retry "${LIVE_ATTEMPTS:-10}" "${LIVE_INTERVAL:-1}" bg_live_check "$prev_sha"; then
          restored=1
          bg_log "previous release $prev_sha is live again (automatic rollback complete)"
        else
          bg_log "CRITICAL: traffic moved back to $prev but release $prev_sha did not verify"
        fi
      else
        bg_log "CRITICAL: could not move traffic back to $prev"
      fi
    else
      : > "$BG_STATE_DIR/active"
      restored=0
      bg_log "CRITICAL: no previous release exists, so there is nothing to return to; the failed release is still receiving traffic"
    fi
    if [ "$restored" = 0 ]; then rc=3; fi
    # Stop the failed colour only when traffic is safely elsewhere.
    if [ "$restored" = 1 ] && [ -n "$prev" ]; then bg_abort_idle "$idle" "$old_idle_tag"; fi
    bg_history failed "$sha" "post-switch verification failed; automatic rollback to ${prev_sha:-nothing} (restored=$restored)"
    return "$rc"
  fi

  printf '%s\n' "$sha" > "$BG_STATE_DIR/last_good"
  bg_history deployed "$sha" "$note; live on $idle; replaced ${prev_sha:-nothing}"
  if [ -n "$prev" ]; then
    bg_log "draining backend-$prev for ${DRAIN_SECONDS:-10}s before stopping it"
    sleep "${DRAIN_SECONDS:-10}"
    bg_compose stop "backend-$prev" > /dev/null 2>&1 || bg_log "warning: could not stop backend-$prev"
  fi
  bg_log "release $sha is live on $idle"
}

# One deploy or rollback per environment at a time. mkdir is atomic, so it works as a lock.
bg_lock() {
  BG_LOCK_DIR="$BG_ENV_DIR/.lock"
  mkdir "$BG_LOCK_DIR" 2> /dev/null || bg_die "another deploy or rollback is running for $BG_ENV (remove $BG_LOCK_DIR only if you are sure none is)"
}
bg_unlock() { rmdir "$BG_LOCK_DIR" 2> /dev/null || true; }

# ---- release image from ECR (the delivery path on AWS) --------------------------------------------
# The image is identified by its DIGEST, never by a tag, so what runs is exactly what CI pushed and the SSM caller
# cannot swap it by moving a tag. The registry login uses the instance role (no stored credentials: a throwaway
# Docker config directory is used and removed again).
bg_image_ref_ok() { [[ "$1" =~ ^[0-9]{12}\.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com/[a-z0-9][a-z0-9._/-]*@sha256:[0-9a-f]{64}$ ]]; }

# bg_validate_bundle_ref <s3 key> <sha-256>: PURE (it changes nothing), so the deploy can refuse a bad reference before it
# installs a guard, creates a network, pulls an image or starts anything.
bg_validate_bundle_ref() {
  [[ "$1" =~ ^deploy/(staging|production)/[0-9a-f]{40}/bundle\.tar\.gz$ ]] || bg_die "the bundle key must be deploy/<environment>/<40-hex sha>/bundle.tar.gz"
  [[ "$2" =~ ^[0-9a-f]{64}$ ]] || bg_die "the bundle SHA-256 must be 64 hex digits"
}

# bg_record_bundle <sha> <s3 key> <sha-256>: remember WHICH artifact this release came from, so a later rollback can
# fetch the same frontend files again (and verify them) if the host no longer has them.
bg_record_bundle() {
  bg_validate_bundle_ref "$2" "$3"
  printf '%s %s\n' "$2" "$3" > "$BG_STATE_DIR/bundle-$1"
}

# bg_refetch_frontend <sha>: download the recorded bundle from S3, verify its SHA-256 BEFORE extracting anything, and
# install only its frontend files. Returns 1 (changing nothing) if there is no record, no bucket, or any check fails.
bg_refetch_frontend() {
  local sha="$1" key hash tmp
  if [ "$BG_DB_MODE" = lab ]; then
    # Lab mode: the frontend of every release is a GHCR image, recorded by digest at deploy time; pull it again and unpack it.
    [ -f "$BG_STATE_DIR/frontend-ref-$sha" ] || return 1
    bg_pull_lab_image "$(cat "$BG_STATE_DIR/frontend-ref-$sha")" "$sha" frontend || return 1
    bg_frontend_from_image "$sha"
    return
  fi
  [ -f "$BG_STATE_DIR/bundle-$sha" ] || return 1
  [ -n "${ARTIFACT_BUCKET:-}" ] || return 1
  read -r key hash < "$BG_STATE_DIR/bundle-$sha"
  tmp="$(mktemp -d)"
  if ! aws s3 cp "s3://$ARTIFACT_BUCKET/$key" "$tmp/bundle.tar.gz" --region "$AWS_REGION" --only-show-errors; then
    rm -rf "$tmp"; bg_log "could not download the recorded bundle for $sha"; return 1
  fi
  if ! printf '%s  %s\n' "$hash" "$tmp/bundle.tar.gz" | sha256sum --check --strict > /dev/null 2>&1; then
    rm -rf "$tmp"; bg_log "the recorded bundle for $sha does not match its recorded SHA-256; refusing it"; return 1
  fi
  mkdir "$tmp/x"
  if ! tar -xzf "$tmp/bundle.tar.gz" -C "$tmp/x" frontend-dist 2> /dev/null || ! bg_frontend_ok "$tmp/x/frontend-dist"; then
    rm -rf "$tmp"; bg_log "the recorded bundle for $sha has no usable frontend files"; return 1
  fi
  bg_frontend_install "$sha" "$tmp/x/frontend-dist" || { rm -rf "$tmp"; return 1; }
  rm -rf "$tmp"
}

# bg_validate_image_ref <image ref>: PURE. A digest (never a tag), from THIS environment's region and repository.
bg_validate_image_ref() {
  local ref="$1" registry region repository
  bg_image_ref_ok "$ref" || bg_die "the image reference must be <registry>/<repository>@sha256:<64 hex digits> (a digest, never a tag)"
  registry="${ref%%/*}"
  region="${registry#*.dkr.ecr.}"
  region="${region%.amazonaws.com}"
  [ "$region" = "${AWS_REGION:-}" ] || bg_die "the image registry region ($region) is not this environment's region"
  repository="${ref#*/}"
  repository="${repository%@*}"
  [ "$repository" = "${ECR_REPOSITORY:-}" ] || bg_die "the image repository ($repository) is not this environment's repository (${ECR_REPOSITORY:-unset})"
}

# bg_pull_image <image ref> <release sha>: pull by digest, tag it as shopnest-backend:<sha> for Compose, and require its
# revision label to be <sha>. The reference is remembered per release so a later rollback can pull it again.
bg_pull_image() {
  local ref="$1" sha="$2" registry region cfg revision
  bg_validate_image_ref "$ref"
  registry="${ref%%/*}"
  region="${registry#*.dkr.ecr.}"
  region="${region%.amazonaws.com}"
  cfg="$(mktemp -d)"
  if ! { aws ecr get-login-password --region "$region" | DOCKER_CONFIG="$cfg" docker login --username AWS --password-stdin "$registry" > /dev/null; }; then
    rm -rf "$cfg"
    bg_die "could not log in to ECR with the instance role"
  fi
  if ! DOCKER_CONFIG="$cfg" docker pull "$ref" > /dev/null; then
    rm -rf "$cfg"
    bg_die "could not pull $ref"
  fi
  rm -rf "$cfg"
  docker tag "$ref" "shopnest-backend:$sha" || bg_die "could not tag the pulled image"
  revision="$(bg_image_revision "$sha" || true)"
  [ "$revision" = "$sha" ] || bg_die "image revision label '$revision' does not match $sha"
  printf '%s\n' "$ref" > "$BG_STATE_DIR/image-ref-$sha"
}

# ---- release images from GHCR (the delivery path in lab mode) -------------------------------------
# Both images (the backend, and the frontend that carries the built static files) are identified by DIGEST, never by a tag, so
# what runs is exactly what CI pushed and the SSM caller cannot swap an image by moving a tag. The packages are PUBLIC, so the
# host pulls without any credential. Each image must carry the revision label of the release it is deployed as.
bg_lab_image_ref_ok() { # <ref> <backend|frontend>
  case "${2:-}" in backend | frontend) ;; *) return 1 ;; esac
  [[ "${1:-}" =~ ^ghcr\.io/[a-z0-9][a-z0-9-]{0,38}/shopnest-$2@sha256:[0-9a-f]{64}$ ]]
}

# bg_validate_lab_image_ref <ref> <backend|frontend>: PURE (it changes nothing).
bg_validate_lab_image_ref() {
  bg_lab_image_ref_ok "$1" "$2" || bg_die "the $2 image reference must be ghcr.io/<owner>/shopnest-$2@sha256:<64 hex digits> (a digest, never a tag)"
}

bg_lab_image_revision() { docker image inspect "$1" --format '{{ index .Config.Labels "org.opencontainers.image.revision" }}' 2> /dev/null; }

# bg_pull_lab_image <ref> <release sha> <backend|frontend>: pull by digest, tag it shopnest-<kind>:<sha> for Compose, require its
# revision label to be <sha>, and remember the reference per release so a later rollback can pull it again.
bg_pull_lab_image() {
  local ref="$1" sha="$2" kind="$3" revision record
  bg_validate_lab_image_ref "$ref" "$kind"
  docker pull "$ref" > /dev/null || bg_die "could not pull $ref (is the GHCR package public, and does the digest exist?)"
  docker tag "$ref" "shopnest-$kind:$sha" || bg_die "could not tag the pulled $kind image"
  revision="$(bg_lab_image_revision "shopnest-$kind:$sha" || true)"
  [ "$revision" = "$sha" ] || bg_die "$kind image revision label '$revision' does not match $sha"
  if [ "$kind" = backend ]; then record="image-ref-$sha"; else record="frontend-ref-$sha"; fi
  printf '%s\n' "$ref" > "$BG_STATE_DIR/$record"
}

# bg_frontend_from_image <sha>: unpack the static files from shopnest-frontend:<sha> (already pulled) into this release's
# directory, kept for rollback. A frontend without a non-empty index.html is refused before anything changes.
bg_frontend_from_image() {
  local sha="$1" tmp cid
  tmp="$(mktemp -d)"
  cid="$(docker create "shopnest-frontend:$sha")" || { rm -rf "$tmp"; bg_log "could not create a container to read the frontend files"; return 1; }
  if ! docker cp "$cid:/usr/share/nginx/html/." "$tmp/"; then
    docker rm "$cid" > /dev/null 2>&1 || true
    rm -rf "$tmp"
    bg_log "could not copy the frontend files out of the image"
    return 1
  fi
  docker rm "$cid" > /dev/null 2>&1 || true
  # The nginx container runs as an unprivileged user: the files and the directories must be readable by it.
  chmod -R a+rX "$tmp"
  if ! bg_frontend_ok "$tmp"; then
    rm -rf "$tmp"
    bg_log "the frontend image has no non-empty index.html"
    return 1
  fi
  bg_frontend_install "$sha" "$tmp" || { rm -rf "$tmp"; return 1; }
  rm -rf "$tmp"
}

# bg_lab_check_checkout <sha> <dir>: the release scripts must run from a git checkout of exactly the commit being deployed.
bg_lab_check_checkout() {
  local head
  head="$(git -C "$2" rev-parse HEAD 2> /dev/null || true)"
  [ "$head" = "$1" ] || bg_die "lab mode must run from a git checkout of $1 (found '${head:-no checkout}')"
}
