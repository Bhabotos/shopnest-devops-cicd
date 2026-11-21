#!/usr/bin/env bash
# Offline tests for the blue/green deploy and rollback scripts. They drive the REAL scripts and
# library against a fake `docker` (deploy/tests/fake-docker.sh), so the decisions are tested
# (which colour, when traffic moves, what happens on failure) without a Docker engine.
# This does NOT prove the containers, nginx or Docker Compose behave; that needs a real engine.
#   bash deploy/tests/bluegreen-logic.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "$HERE/.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
ORIG_PATH="$PATH"
PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); echo "PASS  $*"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL  $*"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: got [$2] expected [$3]"; fi; }
contains() { if grep -q -- "$3" "$2" 2> /dev/null; then ok "$1"; else bad "$1: '$3' not found in $2"; fi; }

# Fixed fake release SHAs: forty copies of one hex letter.
sha() { printf '%040d' 0 | tr 0 "$1"; }
A="$(sha a)"; B="$(sha b)"; C="$(sha c)"; D="$(sha d)"; E="$(sha e)"
CARRIER_SHA="$(sha f)"   # the bundle a rollback runs from

new_world() {
  W="$(mktemp -d "$T/w.XXXXXX")"
  mkdir -p "$W/home/staging" "$W/home/production" "$W/fake" "$W/bin" "$W/bundles"
  cp "$HERE/fake-docker.sh" "$W/bin/docker"
  chmod +x "$W/bin/docker"
  local env_name
  for env_name in staging production; do
    printf 'POSTGRES_PASSWORD=aaaaaaaaaaaaaaaa11\nDB_OWNER_PASSWORD=bbbbbbbbbbbbbbbb22\nDB_APP_PASSWORD=cccccccccccccccc33\n' > "$W/home/$env_name/secrets.env"
  done
  # The loose-secrets bypass is accepted only with a non-default prefix and a loopback bind (section 14).
  export SHOPNEST_HOME="$W/home" FAKE="$W/fake" PATH="$W/bin:$ORIG_PATH" BG_ALLOW_LOOSE_SECRETS=1 BG_SKIP_PUBLIC_CHECK=1
  export SHOPNEST_PROJECT_PREFIX=shopnest-test HTTP_BIND=127.0.0.1
  # Sections 1 to 16 exercise the blue/green logic against the throwaway database CONTAINER (local rehearsal mode).
  # The AWS mode (private RDS, ECR) has its own sections, 17 onwards, which call new_rds_world.
  export BG_LOCAL_DB=1
}

make_bundle() { # <sha>
  local b="$W/bundles/$1" env_name
  rm -rf "$b"
  mkdir -p "$b/deploy/scripts/lib" "$b/deploy/env" "$b/frontend-dist"
  cp "$DEPLOY_DIR/scripts/"*.sh "$b/deploy/scripts/"
  cp "$DEPLOY_DIR/scripts/lib/"*.sh "$b/deploy/scripts/lib/"
  : > "$b/deploy/docker-compose.prod.yml"
  mkdir -p "$b/deploy/host"
  cp "$DEPLOY_DIR/host/install-host-guards.sh" "$DEPLOY_DIR/host/"*.service "$DEPLOY_DIR/host/"*.timer "$b/deploy/host/"
  cat > "$b/deploy/host/imds-guard.sh" << 'STUB'
#!/usr/bin/env bash
# TEST STUB of deploy/host/imds-guard.sh: records its calls and honours failure switches. The real rules, their order and
# their fail-closed behaviour are tested in deploy/tests/imds-guard.test.sh; this suite tests how the DEPLOY uses it.
cmd="${1:-}"; file="${2:-}"
echo "guard $cmd" >> "$FAKE/calls.log"
case "$cmd" in
  validate) [ -f "$FAKE/guard_fail_validate" ] && { echo "stub: invalid settings" >&2; exit 1; }; exit 0 ;;
  export-edge) grep -E '^(EDGE_NETWORK|EDGE_SUBNET|EDGE_IP_RANGE|EDGE_GATEWAY|NGINX_IP|BACKEND_BLUE_IP|BACKEND_GREEN_IP)=' "$file" ;;
  ensure-network) [ -f "$FAKE/guard_fail_network" ] && exit 1; exit 0 ;;
  apply) [ -f "$FAKE/guard_fail_apply" ] && exit 1; exit 0 ;;
  verify) echo "verify image=${3:-} nginx=${4:-}" >> "$FAKE/calls.log"; [ -f "$FAKE/guard_fail_verify" ] && exit 1; exit 0 ;;
esac
STUB
  : > "$b/deploy/docker-compose.local-db.yml"
  mkdir -p "$b/deploy/db/init" "$b/deploy/nginx"
  echo '#!/bin/sh' > "$b/deploy/db/init/01-roles.sh"
  echo 'server { listen 8080; }' > "$b/deploy/nginx/nginx.conf"
  for env_name in staging production; do
    printf 'HTTP_PORT=1\nREADY_ATTEMPTS=3\nREADY_INTERVAL=0\nLIVE_ATTEMPTS=2\nLIVE_INTERVAL=0\nDRAIN_SECONDS=0\nDB_WAIT_ATTEMPTS=2\nDB_WAIT_INTERVAL=0\n' > "$b/deploy/env/$env_name.env"
    grep -E '^(EDGE_|NGINX_IP|BACKEND_)' "$DEPLOY_DIR/env/$env_name.env" >> "$b/deploy/env/$env_name.env"
  done
  echo "release $1" > "$b/frontend-dist/index.html"
  echo image > "$b/backend-image.tar.gz"
  echo "$1" > "$b/RELEASE_SHA"
  (cd "$b" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)
}

deploy() { # <env> <sha> [more args]; output in $W/out
  [ -d "$W/bundles/$2" ] || make_bundle "$2"
  echo "$2" > "$FAKE/load-tag"
  bash "$W/bundles/$2/deploy/scripts/bluegreen-deploy.sh" --env "$1" --sha "$2" "${@:3}" > "$W/out" 2>&1
}
rollback() { # <env> <sha>
  local carrier="$W/bundles/$CARRIER_SHA"
  [ -d "$carrier" ] || make_bundle "$CARRIER_SHA"
  bash "$carrier/deploy/scripts/rollback.sh" --env "$1" --sha "$2" > "$W/out" 2>&1
}
state() { cat "$SHOPNEST_HOME/staging/state/$1" 2> /dev/null || true; }
served() { cat "$FAKE/served" 2> /dev/null || true; }
running() { (cd "$FAKE/running" && ls | tr '\n' ' ' | sed 's/ $//'); }
reloads() { grep -c '^reload' "$FAKE/calls.log" 2> /dev/null || true; }
history_count() { grep -c " $2 $1 " "$SHOPNEST_HOME/staging/state/history.log" 2> /dev/null || true; }

echo "== 1. first deploy of release A goes to blue"
new_world
deploy staging "$A"; check "deploy A exit code" $? 0
check "live colour" "$(state active)" blue
check "blue runs A" "$(state tag-blue)" "$A"
check "nginx serves blue with A's frontend" "$(served)" "blue $A"
check "last good" "$(state last_good)" "$A"
check "green was never started" "$(running)" "backend-blue db nginx"
check "A recorded as deployed" "$(history_count deployed "$A")" 1
contains "deployment log written under logs/" "$SHOPNEST_HOME/logs/staging-$A.log" "DEPLOY SUCCEEDED"
contains "frontend files kept per release" "$SHOPNEST_HOME/staging/frontend/releases/$A/index.html" "release $A"

echo "== 2. release B goes to the idle colour, then traffic switches"
deploy staging "$B"; check "deploy B exit code" $? 0
check "live colour is now green" "$(state active)" green
check "green runs B" "$(state tag-green)" "$B"
check "nginx serves green with B's frontend" "$(served)" "green $B"
check "last good is B" "$(state last_good)" "$B"
check "old colour stopped after the drain" "$(running)" "backend-green db nginx"
check "nginx reloaded once for the switch" "$(reloads)" 1

echo "== 3. release C fails validation: traffic never moves"
reloads_before="$(reloads)"
touch "$FAKE/dummy"; mkdir -p "$FAKE/bad_health"; touch "$FAKE/bad_health/$C"
deploy staging "$C"; check "deploy C exit code" $? 1
check "live colour unchanged" "$(state active)" green
check "still serving B" "$(served)" "green $B"
check "last good still B" "$(state last_good)" "$B"
check "failed colour removed, live colour up" "$(running)" "backend-green db nginx"
check "idle colour tag restored" "$(state tag-blue)" "$A"
check "no extra nginx reload" "$(reloads)" "$reloads_before"
check "C recorded as failed" "$(history_count failed "$C")" 1
contains "log says traffic was not moved" "$W/out" "traffic was NOT moved"

echo "== 4. release D passes validation but fails after the switch: automatic rollback"
mkdir -p "$FAKE/postswitch_bad"; touch "$FAKE/postswitch_bad/$D"
deploy staging "$D"; check "deploy D exit code" $? 1
check "live colour restored" "$(state active)" green
check "nginx serves B again" "$(served)" "green $B"
check "last good still B" "$(state last_good)" "$B"
check "failed colour stopped" "$(running)" "backend-green db nginx"
check "D recorded as failed" "$(history_count failed "$D")" 1
contains "log shows the automatic rollback" "$W/out" "automatic rollback complete"

echo "== 5. manual rollback to release A through the same validation path"
rollback staging "$A"; check "rollback exit code" $? 0
check "live colour is blue again" "$(state active)" blue
check "blue runs A" "$(state tag-blue)" "$A"
check "nginx serves A's frontend" "$(served)" "blue $A"
check "last good is A" "$(state last_good)" "$A"
check "manual rollback recorded" "$(grep -c 'manual rollback' "$SHOPNEST_HOME/staging/state/history.log")" 1
check "migrations not run during rollback" "$(grep -c '^run migrate' "$FAKE/calls.log")" 4
contains "rollback log written" "$SHOPNEST_HOME/logs/rollback-staging-$A.log" "ROLLBACK SUCCEEDED"

echo "== 6. rollback guards"
rollback staging "$A"; check "rolling back to the live release is a no-op" $? 0
contains "says already live" "$W/out" "already the live release"
rollback staging "$E"; check "unknown release is refused" $? 1
contains "refusal explains why" "$W/out" "not in the release history"
check "live colour untouched" "$(state active)" blue

echo "== 7. failures before any release exists"
new_world
mkdir -p "$FAKE/bad_health"; touch "$FAKE/bad_health/$A"
deploy staging "$A"; check "first deploy that fails validation exits 1" $? 1
check "nothing is live" "$(state active)" ""
check "recorded as failed" "$(history_count failed "$A")" 1

echo "== 8. migration failure stops before any container starts"
new_world
touch "$FAKE/migrate_fail"
deploy staging "$A"; check "exit code" $? 1
check "no backend started" "$(running)" "db"
contains "reported" "$W/out" "migration failed"
check "recorded as failed" "$(history_count failed "$A")" 1

echo "== 9. nginx rejects the new configuration: previous config restored"
new_world
deploy staging "$A" > /dev/null; deploy staging "$B" > /dev/null
touch "$FAKE/nginx_t_fail"
deploy staging "$C"; check "exit code" $? 1
check "live colour unchanged" "$(state active)" green
check "active.conf restored to B" "$(grep -c "releases/$B" "$SHOPNEST_HOME/staging/nginx/upstream/active.conf")" 1
check "idle colour removed" "$(running)" "backend-green db nginx"
contains "reported" "$W/out" "switch FAILED"

echo "== 10. input and safety checks"
new_world
make_bundle "$A"
echo "$B" > "$W/bundles/$A/RELEASE_SHA"
(cd "$W/bundles/$A" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)
echo "$A" > "$FAKE/load-tag"
bash "$W/bundles/$A/deploy/scripts/bluegreen-deploy.sh" --env staging --sha "$A" > "$W/out" 2>&1; check "bundle for another commit is refused" $? 1
contains "explains" "$W/out" "different commit"
make_bundle "$A"
echo tamper >> "$W/bundles/$A/frontend-dist/index.html"
bash "$W/bundles/$A/deploy/scripts/bluegreen-deploy.sh" --env staging --sha "$A" > "$W/out" 2>&1; check "tampered bundle is refused" $? 1
contains "checksum failure reported" "$W/out" "checksum"
bash "$W/bundles/$A/deploy/scripts/bluegreen-deploy.sh" --env staging --sha "not-a-sha" > "$W/out" 2>&1; check "malformed SHA is refused" $? 1
bash "$W/bundles/$A/deploy/scripts/bluegreen-deploy.sh" --env qa --sha "$A" > "$W/out" 2>&1; check "unknown environment is refused" $? 1
make_bundle "$B"
mkdir -p "$SHOPNEST_HOME/staging/.lock"
deploy staging "$B"; check "a second deploy cannot run at the same time" $? 1
contains "lock reported" "$W/out" "another deploy or rollback is running"
rmdir "$SHOPNEST_HOME/staging/.lock"
unset BG_ALLOW_LOOSE_SECRETS
deploy staging "$B"; rc=$?
if [ "$(stat -c '%a' "$SHOPNEST_HOME/staging/secrets.env")" != "600" ]; then check "loose secrets file is refused" "$rc" 1; else ok "secrets file mode check skipped (filesystem reports 600)"; fi
export BG_ALLOW_LOOSE_SECRETS=1
printf 'POSTGRES_PASSWORD=short\nDB_OWNER_PASSWORD=bbbbbbbbbbbbbbbb22\nDB_APP_PASSWORD=cccccccccccccccc33\n' > "$SHOPNEST_HOME/staging/secrets.env"
deploy staging "$B"; check "weak or malformed password is refused" $? 1
contains "names the key, never the value" "$W/out" "POSTGRES_PASSWORD in secrets.env"

echo "== 11. production seeding needs an explicit opt-in"
new_world
deploy production "$A" --seed; check "seeding production without the opt-in is refused" $? 1
contains "explains" "$W/out" "ALLOW_PRODUCTION_SEED"
ALLOW_PRODUCTION_SEED=true deploy production "$A" --seed; check "with the opt-in it is allowed" $? 0

echo "== 13. the database is never recreated by a deploy or a rollback (found by the first real-Docker rehearsal)"
new_world
deploy staging "$A" > /dev/null; deploy staging "$B" > /dev/null; rollback staging "$A" > /dev/null
db_calls="$(grep '^upcall' "$FAKE/calls.log" | grep -cE '(^| )db( |$)')"
db_calls_unsafe="$(grep '^upcall' "$FAKE/calls.log" | grep -E '(^| )db( |$)' | grep -vc -- '--no-recreate')"
if [ "$db_calls" -ge 3 ]; then ok "the database was brought up in all three operations ($db_calls calls)"; else bad "expected at least 3 db up calls, saw $db_calls"; fi
check "every db up call uses --no-recreate" "$db_calls_unsafe" 0
check "no other service is ever started with a plain recreate except the colour being deployed" \
  "$(grep '^upcall' "$FAKE/calls.log" | grep -c -- '--force-recreate' | tr -d ' ')" "$(grep -c '^upcall .*backend-\(blue\|green\)' "$FAKE/calls.log" | tr -d ' ')"
check "init scripts are staged at a stable path" "$([ -f "$SHOPNEST_HOME/staging/db-init/01-roles.sh" ] && echo yes || echo no)" yes
check "nginx config is staged at a stable path" "$([ -f "$SHOPNEST_HOME/staging/nginx/conf/default.conf" ] && echo yes || echo no)" yes
check "compose has no bundle-relative bind mounts" "$(cat "$DEPLOY_DIR/docker-compose.prod.yml" "$DEPLOY_DIR/docker-compose.local-db.yml" | grep -cE '^[[:space:]]+- \./')" 0
contains "the local-database compose file mounts the stable db-init path" "$DEPLOY_DIR/docker-compose.local-db.yml" 'ENV_DIR:?ENV_DIR is required}/db-init'
contains "compose mounts the stable nginx conf path" "$DEPLOY_DIR/docker-compose.prod.yml" 'ENV_DIR:?ENV_DIR is required}/nginx/conf:/etc/nginx/conf.d'

echo "== 14. the loose-secrets bypass can never apply to a real environment"
new_world
for env_name in staging production; do
  ( unset SHOPNEST_PROJECT_PREFIX; deploy "$env_name" "$A" ); check "$env_name: bypass without a project prefix is refused" $? 1
  contains "$env_name: explains it is for local rehearsals" "$W/out" "local rehearsals only"
  ( SHOPNEST_PROJECT_PREFIX=shopnest deploy "$env_name" "$A" ); check "$env_name: bypass with the default prefix is refused" $? 1
  ( unset HTTP_BIND; deploy "$env_name" "$A" ); check "$env_name: bypass without a loopback bind is refused" $? 1
  ( HTTP_BIND=0.0.0.0 deploy "$env_name" "$A" ); check "$env_name: bypass with a public bind is refused" $? 1
  ( unset SHOPNEST_PROJECT_PREFIX; rollback "$env_name" "$A" ); check "$env_name: a rollback is refused too" $? 1
  contains "$env_name: the rollback is refused for the bypass, not for another reason" "$W/out" "local rehearsals only"
done
check "no container was started by any refused attempt" "$(grep -c '^upcall' "$FAKE/calls.log" 2> /dev/null || echo 0)" 0
deploy staging "$A"; check "bypass with a non-default prefix and loopback bind is accepted (local rehearsal)" $? 0
contains "the rehearsal warning is logged" "$W/out" "WARNING: BG_ALLOW_LOOSE_SECRETS=1"
chmod 644 "$SHOPNEST_HOME/staging/secrets.env" 2> /dev/null || true
( BG_ALLOW_LOOSE_SECRETS=0 deploy staging "$B" ) > /dev/null 2>&1; rc=$?
if [ "$(stat -c '%a' "$SHOPNEST_HOME/staging/secrets.env")" != "600" ]; then check "only the exact value 1 enables the bypass (0 does not)" "$rc" 1; else ok "bypass value check skipped (filesystem reports 600)"; fi

echo "== 15. exit codes: failed with recovery (1) versus failed WITHOUT recovery (3)"
new_world
deploy staging "$A" > /dev/null; deploy staging "$B" > /dev/null
mkdir -p "$FAKE/postswitch_bad"; touch "$FAKE/postswitch_bad/$D"
deploy staging "$D"; check "deploy fails after the switch and the rollback works: exit 1" $? 1
contains "the log says the previous release is serving" "$W/out" "DEPLOY FAILED (exit 1): the previous release is serving"
contains "the history says restored=1" "$SHOPNEST_HOME/staging/state/history.log" "automatic rollback to $B (restored=1)"
new_world
deploy staging "$A" > /dev/null; deploy staging "$B" > /dev/null
mkdir -p "$FAKE/postswitch_bad"; touch "$FAKE/postswitch_bad/$D" "$FAKE/postswitch_bad/$B"
deploy staging "$D"; check "deploy fails after the switch AND the previous release does not verify: exit 3" $? 3
contains "the log says recovery failed" "$W/out" "DEPLOY FAILED AND RECOVERY FAILED (exit 3)"
contains "the rollback error is not hidden" "$W/out" "CRITICAL: traffic moved back to green but release $B did not verify"
contains "the history says restored=0" "$SHOPNEST_HOME/staging/state/history.log" "(restored=0)"
new_world
mkdir -p "$FAKE/postswitch_bad"; touch "$FAKE/postswitch_bad/$A"
deploy staging "$A"; check "first deploy fails after the switch, nothing to return to: exit 3" $? 3
contains "says there is nothing to return to" "$W/out" "CRITICAL: no previous release exists"
new_world
deploy staging "$A" > /dev/null; deploy staging "$B" > /dev/null
mkdir -p "$FAKE/postswitch_bad"; touch "$FAKE/postswitch_bad/$A"
rollback staging "$A"; check "manual rollback fails after the switch, B restored: exit 1" $? 1
contains "rollback log: previous release serving" "$W/out" "ROLLBACK FAILED (exit 1)"
check "B is serving again" "$(served)" "green $B"
touch "$FAKE/postswitch_bad/$B"
rollback staging "$A"; check "manual rollback fails and B does not verify either: exit 3" $? 3
contains "rollback log: recovery failed" "$W/out" "ROLLBACK FAILED AND RECOVERY FAILED (exit 3)"
new_world
mkdir -p "$FAKE/bad_health"; touch "$FAKE/bad_health/$A"
deploy staging "$A"; check "a failure before the switch stays exit 1" $? 1
new_world
touch "$FAKE/migrate_fail"
deploy staging "$A"; check "a migration failure stays exit 1" $? 1

echo "== 16. a frontend release without index.html is refused BEFORE traffic can reach it (attempt 4: 83 of 181 requests failed)"
new_world
make_bundle "$A"
rm -f "$W/bundles/$A/frontend-dist/index.html"
(cd "$W/bundles/$A" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)
deploy staging "$A"; check "a bundle whose frontend has no index.html is refused" $? 1
contains "explains" "$W/out" "no non-empty index.html"
check "nothing was started or migrated" "$(grep -c '^run \|^up ' "$FAKE/calls.log" 2> /dev/null || echo 0)" 0
new_world
make_bundle "$A"
: > "$W/bundles/$A/frontend-dist/index.html"
(cd "$W/bundles/$A" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)
deploy staging "$A"; check "an empty index.html is refused too" $? 1
new_world
deploy staging "$A" > /dev/null
reloads_before="$(reloads)"
mkdir -p "$SHOPNEST_HOME/staging/frontend/releases/$B"   # an installed release that has no index.html
deploy staging "$B"; check "an installed release without index.html is rejected before the switch" $? 1
contains "traffic was not moved" "$W/out" "no non-empty index.html; traffic was NOT moved"
check "A is still live" "$(served)" "blue $A"
check "no nginx reload happened" "$(reloads)" "$reloads_before"
check "B recorded as failed" "$(history_count failed "$B")" 1
new_world
deploy staging "$A" > /dev/null; deploy staging "$B" > /dev/null
rm -f "$SHOPNEST_HOME/staging/frontend/releases/$A/index.html"
rollback staging "$A"; check "a manual rollback to a release whose frontend lost its index.html is refused" $? 1
contains "explains" "$W/out" "no non-empty index.html"

echo "== 17. AWS mode: private RDS, image from ECR by digest, no database container, no migration on the instance, guarded network"
REGISTRY="111122223333.dkr.ecr.ap-south-1.amazonaws.com"
BUNDLE_SHA="$(printf '%064d' 0 | tr 0 b)"
ref_for() { printf '%s/shopnest/staging/backend@sha256:%s' "$REGISTRY" "$(printf '%064d' 0 | tr 0 "${1:0:1}")"; }
new_rds_world() {
  new_world
  unset BG_LOCAL_DB BG_ALLOW_LOOSE_SECRETS
  export GUARD_ROOT="$W/root"
  local env_name
  for env_name in staging production; do
    rm -f "$W/home/$env_name/secrets.env"   # AWS mode needs no password file: there is no password on the server
    cat > "$W/home/$env_name/runtime.env" << EOF
DB_HOST=db.example.internal
DB_NAME=shopnest
AWS_REGION=ap-south-1
DB_APP_SECRET_ID=shopnest/$env_name/db-app
ECR_REPOSITORY=shopnest/$env_name/backend
ARTIFACT_BUCKET=shopnest-$env_name-artifacts-example
EOF
  done
  mkdir -p "$W/fake/s3"
  cat > "$W/bin/aws" << 'EOF'
#!/usr/bin/env bash
# fake aws: `ecr get-login-password` and `s3 cp s3://<bucket>/<key> <destination>`
case "$1 $2" in
  "ecr get-login-password")
    [ -f "$FAKE/aws_fail" ] && exit 1
    echo "aws $*" >> "$FAKE/calls.log"
    echo "fake-registry-token" ;;
  "s3 cp")
    [ -f "$FAKE/s3_fail" ] && exit 1
    key="${3#s3://*/}"
    object="$FAKE/s3/$(printf '%s' "$key" | tr '/' '_')"
    [ -f "$object" ] || exit 1
    echo "aws s3 cp $key" >> "$FAKE/calls.log"
    cp "$object" "$4" ;;
  *) exit 1 ;;
esac
EOF
  cat > "$W/bin/timeout" << 'EOF'
#!/usr/bin/env bash
# fake timeout: stands in for the TCP reachability check of the RDS endpoint
[ -f "$FAKE/db_unreachable" ] && exit 1
echo "tcp-check" >> "$FAKE/calls.log"
exit 0
EOF
  cat > "$W/bin/systemctl" << 'EOF'
#!/usr/bin/env bash
echo "systemctl $*" >> "$FAKE/calls.log"
EOF
  chmod +x "$W/bin/aws" "$W/bin/timeout" "$W/bin/systemctl"
}
deploy_rds() { deploy "$1" "$2" --image-ref "$(ref_for "$2")" --bundle-key "deploy/$1/$2/bundle.tar.gz" --bundle-sha256 "$BUNDLE_SHA" "${@:3}"; }
calls() { if [ -f "$FAKE/calls.log" ]; then grep -c -- "$1" "$FAKE/calls.log" || true; else echo 0; fi; }
first_line() { grep -n -- "$1" "$FAKE/calls.log" 2> /dev/null | head -n 1 | cut -d: -f1; }

new_rds_world
deploy_rds staging "$A"; check "AWS mode: first deploy exit code" $? 0
check "AWS mode: A is live on blue" "$(state active)" blue
check "AWS mode: nginx serves A's frontend" "$(served)" "blue $A"
check "AWS mode: no database container exists or was started" "$(running)" "backend-blue nginx"
check "AWS mode: no 'up db' call" "$(calls '^up db')" 0
check "AWS mode: the image was pulled once, by digest" "$(calls "^pull $(ref_for "$A")$")" 1
check "AWS mode: it was tagged for Compose" "$(calls "^tag $(ref_for "$A") shopnest-backend:$A")" 1
check "AWS mode: the registry login used the instance role (no key was supplied)" "$(calls '^aws ecr get-login-password --region ap-south-1')" 1
check "AWS mode: no tarball was loaded" "$(calls '^load')" 0
check "AWS mode: the RDS endpoint was checked for reachability" "$(calls '^tcp-check')" 1
check "AWS mode: NO migration ran on the instance (CodeBuild applies them before the deploy)" "$(calls '^run migrate')" 0
check "AWS mode: no one-shot job of any kind ran here" "$(calls '^run ')" 0
check "AWS mode: only the base compose file is used" "$(grep -c '^composefiles docker-compose.prod.yml$' "$FAKE/calls.log")" "$(grep -c '^composefiles' "$FAKE/calls.log")"
check "AWS mode: no database init scripts were staged" "$([ -d "$SHOPNEST_HOME/staging/db-init" ] && echo yes || echo no)" no
check "AWS mode: no password file exists" "$([ -e "$SHOPNEST_HOME/staging/secrets.env" ] && echo yes || echo no)" no
check "AWS mode: the digest is recorded for this release" "$(cat "$SHOPNEST_HOME/staging/state/image-ref-$A")" "$(ref_for "$A")"
check "AWS mode: the artifact reference is recorded for this release" "$(cat "$SHOPNEST_HOME/staging/state/bundle-$A")" "deploy/staging/$A/bundle.tar.gz $BUNDLE_SHA"
check "AWS mode: the guard was installed on the host" "$([ -x "$GUARD_ROOT/usr/local/sbin/shopnest-imds-guard" ] && echo yes || echo no)" yes
check "AWS mode: the guard's settings were written for the boot-time unit" "$(grep -c '^BACKEND_BLUE_IP=' "$GUARD_ROOT/etc/shopnest/edge.env")" 1
check "AWS mode: ensure-network, apply and verify each ran once" "$(calls '^guard ensure-network')$(calls '^guard apply')$(calls '^guard verify')" 111
check "AWS mode: the guard order is ensure-network < apply < pull < verify < first container" \
  "$([ "$(first_line '^guard ensure-network')" -lt "$(first_line '^guard apply')" ] && [ "$(first_line '^guard apply')" -lt "$(first_line '^pull ')" ] && [ "$(first_line '^pull ')" -lt "$(first_line '^verify image')" ] && [ "$(first_line '^verify image')" -lt "$(first_line '^up ')" ] && echo ordered || echo wrong)" ordered
contains "AWS mode: the probe image is this release's image" "$FAKE/calls.log" "verify image=shopnest-backend:$A"
deploy_rds staging "$B"; check "AWS mode: second deploy exit code" $? 0
check "AWS mode: green now live" "$(state active)" green
check "AWS mode: the old colour was stopped" "$(running)" "backend-green nginx"
contains "AWS mode: the second verify also checked the running nginx" "$FAKE/calls.log" "nginx=container-nginx"

echo "== 17b. AWS mode: refusals happen before anything is changed"
new_rds_world
deploy staging "$A"; check "a deploy without --image-ref is refused (no tarball path on AWS)" $? 1
contains "explains" "$W/out" "--image-ref is required"
deploy staging "$A" --image-ref "$(ref_for "$A")"; check "a deploy without the artifact reference is refused" $? 1
contains "explains" "$W/out" "--bundle-key and --bundle-sha256 are required"
deploy_rds staging "$A" --seed; check "--seed is refused on AWS (the instance never holds the owner credentials)" $? 1
contains "explains" "$W/out" "--seed is not available on AWS"
deploy staging "$A" --image-ref "$(ref_for "$A")" --bundle-key "deploy/staging/$B/other.tar.gz" --bundle-sha256 "$BUNDLE_SHA"; check "a bundle key outside the expected shape is refused" $? 1
contains "explains" "$W/out" "bundle key must be"
deploy staging "$A" --image-ref "$(ref_for "$A")" --bundle-key "deploy/staging/$A/bundle.tar.gz" --bundle-sha256 "nothex"; check "a malformed bundle hash is refused" $? 1
contains "explains" "$W/out" "64 hex digits"
deploy staging "$A" --image-ref "$REGISTRY/shopnest/staging/backend:latest" --bundle-key "deploy/staging/$A/bundle.tar.gz" --bundle-sha256 "$BUNDLE_SHA"; check "a tag instead of a digest is refused" $? 1
contains "explains" "$W/out" "a digest, never a tag"
deploy staging "$A" --image-ref "111122223333.dkr.ecr.us-east-1.amazonaws.com/shopnest/staging/backend@sha256:$(printf '%064d' 0 | tr 0 a)" --bundle-key "deploy/staging/$A/bundle.tar.gz" --bundle-sha256 "$BUNDLE_SHA"; check "an image from another region is refused" $? 1
contains "explains" "$W/out" "not this environment's region"
deploy staging "$A" --image-ref "evil.example.com/x/y@sha256:$(printf '%064d' 0 | tr 0 a)" --bundle-key "deploy/staging/$A/bundle.tar.gz" --bundle-sha256 "$BUNDLE_SHA"; check "an image from a non-ECR registry is refused" $? 1
deploy staging "$A" --image-ref "$REGISTRY/shopnest/production/backend@sha256:$(printf '%064d' 0 | tr 0 a)" --bundle-key "deploy/staging/$A/bundle.tar.gz" --bundle-sha256 "$BUNDLE_SHA"; check "an image from another environment's repository is refused" $? 1
contains "explains" "$W/out" "is not this environment's repository"
deploy staging "$A" --image-ref "$REGISTRY/someone-else/backend@sha256:$(printf '%064d' 0 | tr 0 a)" --bundle-key "deploy/staging/$A/bundle.tar.gz" --bundle-sha256 "$BUNDLE_SHA"; check "an unrelated repository in the same registry is refused" $? 1
check "none of those started or pulled anything" "$(calls '^run \|^up \|^pull ')" 0
check "and NONE of them applied a rule or created a network (every argument is checked first)" "$(calls '^guard \(ensure-network\|apply\)\|^verify image')" 0
check "and the guard installer never ran" "$([ -e "$GUARD_ROOT/usr/local/sbin" ] && echo yes || echo no)" no
touch "$FAKE/pull_fail"; deploy_rds staging "$A"; check "an image that cannot be pulled is refused" $? 1
contains "explains" "$W/out" "could not pull"
rm "$FAKE/pull_fail"; touch "$FAKE/pull_wrong_revision"; deploy_rds staging "$A"; check "an image whose revision label is wrong is refused" $? 1
contains "explains" "$W/out" "does not match"
rm "$FAKE/pull_wrong_revision"; touch "$FAKE/aws_fail"; deploy_rds staging "$A"; check "a failed registry login is refused" $? 1
contains "explains" "$W/out" "could not log in to ECR"
rm "$FAKE/aws_fail"
check "nothing was started by any refused attempt" "$(calls '^run \|^up ')" 0
check "nothing is live" "$(state active)" ""

new_rds_world
touch "$FAKE/db_unreachable"; deploy_rds staging "$A"; check "an unreachable RDS endpoint is refused" $? 1
contains "explains" "$W/out" "the database did not become ready"
check "nothing was started" "$(calls '^up ')" 0

echo "== 17b2. AWS mode: the metadata-service guard FAILS CLOSED"
new_rds_world
touch "$FAKE/guard_fail_validate"; deploy_rds staging "$A"; check "inconsistent EDGE settings are refused at start-up" $? 1
# (contains is a basic regular expression: a literal asterisk would be a quantifier, so the text after it is matched)
contains "explains" "$W/out" "settings in deploy/env/staging.env are not consistent"
check "nothing was installed, pulled or started" "$(calls '^guard \(apply\|ensure\)\|^pull \|^up ')" 0
new_rds_world
touch "$FAKE/guard_fail_network"; deploy_rds staging "$A"; check "a failed network creation is refused" $? 1
contains "explains" "$W/out" "could not create the container network"
check "nothing was pulled or started" "$(calls '^pull \|^up ')" 0
new_rds_world
touch "$FAKE/guard_fail_apply"; deploy_rds staging "$A"; check "failed rules are refused BEFORE the image is even pulled" $? 1
contains "explains" "$W/out" "nothing was started"
check "nothing was pulled or started" "$(calls '^pull \|^up ')" 0
new_rds_world
touch "$FAKE/guard_fail_verify"; deploy_rds staging "$A"; check "isolation that cannot be confirmed stops the deploy before any container" $? 1
contains "FAIL CLOSED" "$W/out" "FAIL CLOSED"
check "no container was started" "$(calls '^up ')" 0
check "nothing is live" "$(state active)" ""
new_rds_world
deploy_rds staging "$A" > /dev/null; deploy_rds staging "$B" > /dev/null
touch "$FAKE/guard_fail_verify"; deploy_rds staging "$C"; check "a later deploy is also stopped when isolation is not confirmed" $? 1
check "the live release is untouched" "$(served)" "green $B"
rollback staging "$A"; check "a rollback is stopped the same way" $? 1
contains "FAIL CLOSED" "$W/out" "FAIL CLOSED"
check "the live release is still untouched" "$(served)" "green $B"

echo "== 17c. AWS mode: runtime.env is validated, and never tells this host where the owner or master credentials are"
runtime_case() { # <label> <sed expression on runtime.env | "rm"> <text expected in the output>
  new_rds_world
  if [ "$2" = rm ]; then rm "$W/home/staging/runtime.env"; else sed -i "$2" "$W/home/staging/runtime.env"; fi
  deploy_rds staging "$A"; check "$1: refused" $? 1
  contains "$1: explains" "$W/out" "$3"
  check "$1: nothing was started or pulled" "$(calls '^up \|^run \|^pull ')" 0
}
runtime_case "missing runtime.env" rm "missing .*runtime.env (create it"
runtime_case "no DB_HOST" '/^DB_HOST=/d' "DB_HOST is not set"
runtime_case "no DB_NAME" '/^DB_NAME=/d' "DB_NAME is not set"
runtime_case "no AWS_REGION" '/^AWS_REGION=/d' "AWS_REGION is not set"
runtime_case "no app secret id" '/^DB_APP_SECRET_ID=/d' "DB_APP_SECRET_ID is not set"
runtime_case "no ECR repository" '/^ECR_REPOSITORY=/d' "ECR_REPOSITORY is not set"
runtime_case "no artifact bucket" '/^ARTIFACT_BUCKET=/d' "ARTIFACT_BUCKET is not set"
runtime_case "the OWNER secret id (this host must never know it)" '$a\DB_OWNER_SECRET_ID=shopnest/staging/db-owner' "DB_OWNER_SECRET_ID is not an allowed setting"
runtime_case "a MASTER secret id (this host must never know it)" '$a\DB_MASTER_SECRET_ID=rds!db-example' "DB_MASTER_SECRET_ID is not an allowed setting"
runtime_case "a value with a shell metacharacter" 's/^DB_HOST=.*/DB_HOST=db;touch pwned/' "not a plain value"
check "the runtime file ran no command (it is parsed, never sourced)" "$([ -e ./pwned ] && echo yes || echo no)" no
rm -f ./pwned
runtime_case "a command substitution" 's/^DB_HOST=.*/DB_HOST=$(touch pwned2)/' "not a plain value"
check "the substitution was not executed" "$([ -e ./pwned2 ] && echo yes || echo no)" no
rm -f ./pwned2
runtime_case "an unknown key" '$a\SOMETHING_ELSE=1' "is not an allowed setting"
runtime_case "a line that is not KEY=VALUE" '$a\this is not an assignment' "is not KEY=VALUE"
runtime_case "a host name that is not one" 's/^DB_HOST=.*/DB_HOST=-bad-/' "not a host name"
runtime_case "a port that is not a number" 's/^DB_NAME=.*/DB_NAME=shopnest\nDB_PORT=54x32/' "must be a port number"
runtime_case "a database name that is not plain" 's/^DB_NAME=.*/DB_NAME=Shop/' "not a plain database name"
runtime_case "a malformed region" 's/^AWS_REGION=.*/AWS_REGION=mumbai/' "not a region"
runtime_case "a secret id that is not a plain name" 's/^DB_APP_SECRET_ID=.*/DB_APP_SECRET_ID=arn:aws:x/' "not a plain secret name"
runtime_case "an ECR repository that is not a plain name" 's/^ECR_REPOSITORY=.*/ECR_REPOSITORY=Bad:Name/' "not a plain repository name"
runtime_case "a bucket name that is not one" 's/^ARTIFACT_BUCKET=.*/ARTIFACT_BUCKET=A_B/' "not a bucket name"

echo "== 17d. AWS mode: failures keep the rollback safeguards (exit codes 1 and 3, automatic rollback)"
new_rds_world
deploy_rds staging "$A" > /dev/null; deploy_rds staging "$B" > /dev/null
mkdir -p "$FAKE/postswitch_bad"; touch "$FAKE/postswitch_bad/$D"
deploy_rds staging "$D"; check "AWS mode: failure after the switch rolls back automatically: exit 1" $? 1
check "AWS mode: B is serving again" "$(served)" "green $B"
mkdir -p "$FAKE/bad_health"; touch "$FAKE/bad_health/$C"
deploy_rds staging "$C"; check "AWS mode: a release that fails validation never receives traffic: exit 1" $? 1
check "AWS mode: still serving B" "$(served)" "green $B"
touch "$FAKE/postswitch_bad/$E" "$FAKE/postswitch_bad/$B"
deploy_rds staging "$E"; check "AWS mode: failed AND recovery failed: exit 3" $? 3
rm -f "$FAKE/postswitch_bad/$B" "$FAKE/postswitch_bad/$E"
new_rds_world
touch "$FAKE/migrate_fail"; deploy_rds staging "$A"; check "AWS mode: the instance never runs a migration, so a failing migrate job cannot affect it" $? 0
check "AWS mode: and no migrate job was started" "$(calls '^run migrate')" 0

echo "== 17e. AWS mode: rollback pulls the recorded digest again, restores the recorded frontend, and refuses what is gone"
new_rds_world
deploy_rds staging "$A" > /dev/null; deploy_rds staging "$B" > /dev/null
pulls_before="$(calls '^pull ')"
rollback staging "$A"; check "rollback to A while its image is still on the host: exit 0" $? 0
check "AWS mode: no pull was needed" "$(calls '^pull ')" "$pulls_before"
check "AWS mode: a rollback never runs migrations" "$(calls '^run migrate')" 0
deploy_rds staging "$B" > /dev/null
rm -f "$FAKE/images/$A"   # the host cleaned up the old image
echo "$A" > "$FAKE/load-tag"   # what the fake registry will serve for A's digest
rollback staging "$A"; check "rollback to A after the image was removed: exit 0" $? 0
contains "it says it pulled the recorded digest" "$W/out" "pulling the digest recorded for that release"
check "AWS mode: the recorded digest was pulled" "$(calls "^pull $(ref_for "$A")$")" 2
check "AWS mode: A is live again" "$(served)" "blue $A"
deploy_rds staging "$B" > /dev/null
rm -f "$FAKE/images/$A"; touch "$FAKE/pull_fail"
echo "$A" > "$FAKE/load-tag"
rollback staging "$A"; check "rollback when ECR no longer has the image: refused with exit 1" $? 1
check "AWS mode: B stays live" "$(served)" "green $B"
rm -f "$FAKE/pull_fail" "$SHOPNEST_HOME/staging/state/image-ref-$A"
rollback staging "$A"; check "rollback with no recorded digest and no local image: refused" $? 1
contains "explains" "$W/out" "no ECR digest was recorded"
check "AWS mode: still B" "$(served)" "green $B"

echo "== 17e2. AWS mode: the frontend is restored from the recorded artifact, hash-verified BEFORE extraction"
make_artifact() { # <sha> <fake s3 key>: a real bundle.tar.gz with a frontend-dist for <sha>; prints its SHA-256
  local d="$W/art-$1"
  rm -rf "$d"; mkdir -p "$d/frontend-dist"
  echo "restored release $1" > "$d/frontend-dist/index.html"
  echo "$1" > "$d/RELEASE_SHA"
  (cd "$d" && tar -czf bundle.tar.gz frontend-dist RELEASE_SHA)
  cp "$d/bundle.tar.gz" "$FAKE/s3/$(printf '%s' "$2" | tr '/' '_')"
  sha256sum "$d/bundle.tar.gz" | cut -d' ' -f1
}
setup_two() { # deploys A (with a real recorded artifact) and B
  new_rds_world
  KEY_A="deploy/staging/$A/bundle.tar.gz"
  HASH_A="$(make_artifact "$A" "$KEY_A")"
  deploy staging "$A" --image-ref "$(ref_for "$A")" --bundle-key "$KEY_A" --bundle-sha256 "$HASH_A" > /dev/null
  deploy_rds staging "$B" > /dev/null
}
setup_two
rm -rf "$SHOPNEST_HOME/staging/frontend/releases/$A"
rollback staging "$A"; check "the frontend files were lost: the recorded artifact restores them and the rollback succeeds" $? 0
contains "it fetched the recorded artifact" "$W/out" "fetching the recorded artifact"
check "A is live again" "$(served)" "blue $A"
contains "the restored files are the artifact's" "$SHOPNEST_HOME/staging/frontend/releases/$A/index.html" "restored release $A"
setup_two
rm -rf "$SHOPNEST_HOME/staging/frontend/releases/$A"
echo "tampered" >> "$FAKE/s3/$(printf '%s' "$KEY_A" | tr '/' '_')"
rollback staging "$A"; check "an artifact that does not match its recorded SHA-256 is refused" $? 1
contains "explains" "$W/out" "does not match its recorded SHA-256"
check "nothing from it was extracted or installed" "$([ -d "$SHOPNEST_HOME/staging/frontend/releases/$A" ] && echo yes || echo no)" no
check "B is still live" "$(served)" "green $B"
setup_two
rm -rf "$SHOPNEST_HOME/staging/frontend/releases/$A"; touch "$FAKE/s3_fail"
rollback staging "$A"; check "an artifact that cannot be downloaded is refused" $? 1
contains "explains" "$W/out" "could not be restored from the recorded artifact"
check "B is still live" "$(served)" "green $B"
setup_two
rm -rf "$SHOPNEST_HOME/staging/frontend/releases/$A"; rm -f "$SHOPNEST_HOME/staging/state/bundle-$A"
rollback staging "$A"; check "no recorded artifact: refused" $? 1
check "B is still live" "$(served)" "green $B"
setup_two
rm -rf "$SHOPNEST_HOME/staging/frontend/releases/$A"
mkdir -p "$W/art-bad/other"; echo x > "$W/art-bad/other/file"; (cd "$W/art-bad" && tar -czf bundle.tar.gz other)
cp "$W/art-bad/bundle.tar.gz" "$FAKE/s3/$(printf '%s' "$KEY_A" | tr '/' '_')"
printf '%s %s\n' "$KEY_A" "$(sha256sum "$W/art-bad/bundle.tar.gz" | cut -d' ' -f1)" > "$SHOPNEST_HOME/staging/state/bundle-$A"
rollback staging "$A"; check "a hash-correct artifact WITHOUT frontend files is refused" $? 1
contains "explains" "$W/out" "no usable frontend files"

echo "== 17f. the compose files and the local-database mode"
check "the AWS compose file has no database container" "$(grep -v '^[[:space:]]*#' "$DEPLOY_DIR/docker-compose.prod.yml" | grep -ciE 'image: *postgres|pgdata|DATABASE_URL')" 0
check "the AWS compose file passes no password (comments aside)" "$(grep -v '^[[:space:]]*#' "$DEPLOY_DIR/docker-compose.prod.yml" | grep -ciE 'PASSWORD')" 0
contains "the local-database file says it is for local rehearsals only" "$DEPLOY_DIR/docker-compose.local-db.yml" 'LOCAL REHEARSAL ONLY'
new_rds_world
export BG_LOCAL_DB=1 SHOPNEST_PROJECT_PREFIX=shopnest
deploy_rds staging "$A"; check "BG_LOCAL_DB=1 is refused for the real project prefix" $? 1
contains "explains" "$W/out" "BG_LOCAL_DB=1 is for local rehearsals only"
unset BG_LOCAL_DB GUARD_ROOT
export SHOPNEST_PROJECT_PREFIX=shopnest-test
new_world
deploy staging "$A" > /dev/null
check "local mode uses both compose files" "$(grep -c '^composefiles docker-compose.prod.yml docker-compose.local-db.yml$' "$FAKE/calls.log")" "$(grep -c '^composefiles' "$FAKE/calls.log")"
check "local mode never touches the host guard" "$(calls '^guard ')" 0
check "local mode still runs the migration job (the rehearsal has a database container)" "$(calls '^run migrate')" 1

echo "== 12. no secrets in any log"
if grep -rq 'aaaaaaaaaaaaaaaa11\|bbbbbbbbbbbbbbbb22\|cccccccccccccccc33' "$SHOPNEST_HOME/logs" "$W/out" 2> /dev/null; then bad "a password appears in a log"; else ok "no password appears in the deployment logs"; fi

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
