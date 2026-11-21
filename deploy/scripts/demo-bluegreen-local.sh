#!/usr/bin/env bash
# Local rehearsal of Part F and G against a REAL Docker engine, in a throwaway Compose project
# ("shopnest-demo"), on a loopback-only port, with a throwaway home directory and random database
# passwords. It runs the real deploy and rollback scripts. Steps:
#   1. deploy release A (good), with the demo catalogue
#   2. deploy release B (good) while a request loop runs   -> expect 0 failed requests
#   3. deploy release C (deliberately broken backend)       -> expect exit 1, B still live, 0 failed requests
#   4. manual rollback to A                                 -> expect A live, 0 failed requests
#   5. deploy release D, whose frontend files have no index.html (the defect found by attempt 4 of the
#      first rehearsal: 83 of 181 requests failed while such a release was live)
#                                                           -> expect exit 1, refused BEFORE anything changes, A live, 0 failed requests
#   6. deploy release E (good) and, right after the script says it is switching traffic, delete E's index.html
#      from the host (an external fault, injected by this harness, not by the scripts) so the live check fails
#      AFTER the switch                                     -> expect exit 1 (rollback restored A), E stopped, database untouched;
#      requests to "/" fail while E is live: that window is measured and reported, not hidden
# Scenarios: full = 1-4 | frontend-missing = 1,5 | post-switch = 1,6 | all = 1-6.
# It is a rehearsal for the staging demonstration (docs/ARCHITECTURE.md); it is not evidence from AWS.
# Needs: docker with compose, curl, a local Docker engine. Never touches the "shopnest-staging" or
# "shopnest-production" projects: its project name, port and files are its own.
#   bash deploy/scripts/demo-bluegreen-local.sh [--out DIR] [--keep] [--scenario full|frontend-missing|post-switch|all]
# On a filesystem that cannot hold mode 600 (Windows) run it with the BG_ALLOW_LOOSE_SECRETS override set to 1; the
# library accepts that only because this script sets a non-default project prefix and a loopback bind.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="$ROOT/demo-bluegreen-output"
KEEP=0
SCENARIO=full
while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT="${2:?}"; shift 2 ;;
    --keep) KEEP=1; shift ;;
    --scenario) SCENARIO="${2:?}"; shift 2 ;;
    *) echo "usage: demo-bluegreen-local.sh [--out DIR] [--keep] [--scenario full|frontend-missing|post-switch|all]" >&2; exit 2 ;;
  esac
done

PREFIX="shopnest-demo"
PORT=18081
sha() { printf '%040d' 0 | tr 0 "$1"; }
A="$(sha a)"; B="$(sha b)"; C="$(sha c)"; D="$(sha d)"; E="$(sha e)"
case "$SCENARIO" in full | frontend-missing | post-switch | all) ;; *) echo "scenario must be full, frontend-missing, post-switch or all" >&2; exit 2 ;; esac
want() { # want <step>
  case "$SCENARIO:$1" in
    full:[1-4] | frontend-missing:[15] | post-switch:[16] | all:[1-6]) return 0 ;;
    *) return 1 ;;
  esac
}
PASSED=0
pass() { PASSED=$((PASSED + 1)); echo "PASS  $*"; }
fail() { echo "FAIL  $*" >&2; exit 1; }
step() { echo; echo "== $*"; }

# Refuse anything but a local engine (same rule as verify-stack.sh).
if [[ -n "${DOCKER_HOST:-}" ]]; then fail "refusing: DOCKER_HOST is set"; fi
endpoint="$(docker context inspect "$(docker context show)" --format '{{.Endpoints.docker.Host}}')"
case "$endpoint" in unix://* | npipe:////./pipe/*) ;; *) fail "refusing: the Docker endpoint is not local" ;; esac

WORK="$(mktemp -d)"
WORK_NATIVE="$(cygpath -m "$WORK" 2> /dev/null || echo "$WORK")"   # a path Docker Compose understands on Windows too
export SHOPNEST_HOME="$WORK_NATIVE/home" SHOPNEST_PROJECT_PREFIX="$PREFIX" SHOPNEST_HTTP_PORT="$PORT" HTTP_BIND=127.0.0.1
# This rehearsal has no RDS: it uses the throwaway database container (docker-compose.local-db.yml). The scripts accept
# this only for a project prefix other than "shopnest" and a loopback bind, both set above.
export BG_LOCAL_DB=1
mkdir -p "$OUT" "$SHOPNEST_HOME/staging"
OUT="$(cd "$OUT" && pwd)"

cleanup() {
  step "cleanup (throwaway project $PREFIX-staging only)"
  # Dummy values only so Compose can parse the file's required variables; nothing is started.
  POSTGRES_PASSWORD=x DB_OWNER_PASSWORD=x DB_APP_PASSWORD=x ENV_DIR="$WORK_NATIVE" HTTP_PORT=1 \
    docker compose -p "$PREFIX-staging" -f "$WORK/bundles/$A/deploy/docker-compose.prod.yml" -f "$WORK/bundles/$A/deploy/docker-compose.local-db.yml" down -v --remove-orphans > /dev/null 2>&1 || true
  for s in "$A" "$B" "$C" "$D" "$E"; do docker rmi -f "shopnest-backend:$s" > /dev/null 2>&1 || true; done
  [ "$KEEP" = 1 ] || rm -rf "$WORK"
}
trap cleanup EXIT

printf 'POSTGRES_PASSWORD=%s\nDB_OWNER_PASSWORD=%s\nDB_APP_PASSWORD=%s\n' "$(openssl rand -hex 12)" "$(openssl rand -hex 12)" "$(openssl rand -hex 12)" > "$SHOPNEST_HOME/staging/secrets.env"
chmod 600 "$SHOPNEST_HOME/staging/secrets.env"

build() { docker build -q --label "org.opencontainers.image.revision=$1" -t "shopnest-backend:$1" "$ROOT/backend" > /dev/null; }

step "build the releases (all from the same backend source; C is built to exit at once)"
build "$A"
if want 2; then build "$B"; fi
if want 3; then printf 'FROM shopnest-backend:%s\nCMD ["node","-e","process.exit(1)"]\n' "$A" | docker build -q --label "org.opencontainers.image.revision=$C" -t "shopnest-backend:$C" - > /dev/null; fi
if want 5; then build "$D"; fi
if want 6; then build "$E"; fi
pass "images built"

make_bundle() { # <sha> <label>
  local d="$WORK/bundles/$1"
  mkdir -p "$d/frontend-dist"
  cp -r "$ROOT/deploy" "$d/deploy"
  rm -rf "$d/deploy/tests"
  printf '<!doctype html><title>ShopNest demo %s</title><p>release %s</p>\n' "$2" "$1" > "$d/frontend-dist/index.html"
  docker save "shopnest-backend:$1" | gzip -1 > "$d/backend-image.tar.gz"
  printf '%s\n' "$1" > "$d/RELEASE_SHA"
  (cd "$d" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)
}
make_bundle "$A" A
if want 2; then make_bundle "$B" B; fi
if want 3; then make_bundle "$C" C; fi
if want 5; then
  make_bundle "$D" D
  rm -f "$WORK/bundles/$D/frontend-dist/index.html"
  printf 'release D has no index.html on purpose\n' > "$WORK/bundles/$D/frontend-dist/NOTE.txt"
  # The checksum list was made before the file was removed; rebuild it so the bundle still verifies.
  (cd "$WORK/bundles/$D" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)
fi
if want 6; then make_bundle "$E" E; fi
# The rehearsal compresses the images only lightly and reuses the images already built above; the
# deploy script still loads them from the bundle exactly as it would on a server.
for s in "$A" "$B" "$C" "$D" "$E"; do docker rmi -f "shopnest-backend:$s" > /dev/null 2>&1 || true; done

run() { bash "$WORK/bundles/$1/deploy/scripts/$2" "${@:3}"; }
# Which commit nginx is sending traffic to, read from nginx's internal loopback probe.
version_live() { curl -fsS --max-time 5 "http://127.0.0.1:$PORT/health" > /dev/null && docker exec "$PREFIX-staging-nginx-1" wget -q -O - http://127.0.0.1:8081/version; }

step "1. deploy release A with the demo catalogue"
run "$A" bluegreen-deploy.sh --env staging --sha "$A" --seed > "$OUT/01-deploy-A.log" 2>&1 || { tail -30 "$OUT/01-deploy-A.log"; fail "deploy A failed"; }
[[ "$(version_live)" == *"$A"* ]] || fail "A is not live"
pass "A is live"

# A deploy must never restart the database: record its container id and start time now and compare later.
db_identity() { docker inspect -f '{{.Id}} {{.State.StartedAt}}' "$PREFIX-staging-db-1"; }
DB_AFTER_A="$(db_identity)"
same_db() { [ "$(db_identity)" = "$DB_AFTER_A" ] || fail "the database container was recreated or restarted by the $1 (was: $DB_AFTER_A, now: $(db_identity))"; pass "the database container was not recreated or restarted by the $1"; }

# loop <seconds> <log name> [path]: requests to http://127.0.0.1:PORT<path> every 0.1 s.
loop() { bash "$ROOT/deploy/scripts/request-loop.sh" --url "http://127.0.0.1:$PORT${3:-/api/products}" --seconds "$1" --interval 0.1 --log "$OUT/$2" > /dev/null 2>&1; }
# window <log>: first and last failed request and how many failed (timestamps are UTC from the loop itself).
window() { awk 'NF>=3 && $1 ~ /^20/ && $2!="200" { if(!f) f=$1; l=$1; n++ } END { if(n) printf "first failed %s, last failed %s, %d failed", f, l, n; else printf "no failed request" }' "$1"; }

if want 2; then
  step "2. deploy release B while requests flow"
  loop 60 02-request-loop-deploy-B.log & loop_pid=$!
  sleep 3
  run "$B" bluegreen-deploy.sh --env staging --sha "$B" > "$OUT/02-deploy-B.log" 2>&1 || { tail -30 "$OUT/02-deploy-B.log"; kill "$loop_pid" 2> /dev/null || true; fail "deploy B failed"; }
  [[ "$(version_live)" == *"$B"* ]] || fail "B is not live"
  pass "B is live"
  same_db "B deploy"
  wait "$loop_pid" && pass "request loop during the B deploy: no failed request" || { tail -3 "$OUT/02-request-loop-deploy-B.log"; fail "requests failed during the B deploy"; }
fi

if want 3; then
  step "3. deploy the deliberately broken release C (must fail with exit 1 and leave B live)"
  loop 40 03-request-loop-broken-C.log & loop_pid=$!
  sleep 3
  rc=0; run "$C" bluegreen-deploy.sh --env staging --sha "$C" > "$OUT/03-deploy-C-broken.log" 2>&1 || rc=$?
  if [ "$rc" = 0 ]; then kill "$loop_pid" 2> /dev/null || true; fail "the broken release was deployed"; fi
  [ "$rc" = 1 ] || fail "the broken release exited $rc, expected 1"
  pass "broken release C was rejected (exit 1)"
  [[ "$(version_live)" == *"$B"* ]] || fail "B is no longer live after the failed C deploy"
  pass "B is still live"
  same_db "failed C attempt"
  grep -q "traffic was NOT moved" "$OUT/03-deploy-C-broken.log" || fail "the log does not show that traffic stayed put"
  wait "$loop_pid" && pass "request loop during the failed C deploy: no failed request" || { tail -3 "$OUT/03-request-loop-broken-C.log"; fail "requests failed during the C attempt"; }

  step "4. manual rollback to release A"
  loop 40 04-request-loop-rollback-A.log & loop_pid=$!
  sleep 3
  run "$C" rollback.sh --env staging --sha "$A" > "$OUT/04-rollback-A.log" 2>&1 || { tail -30 "$OUT/04-rollback-A.log"; kill "$loop_pid" 2> /dev/null || true; fail "rollback failed"; }
  [[ "$(version_live)" == *"$A"* ]] || fail "A is not live after the rollback"
  pass "A is live again"
  same_db "rollback"
  wait "$loop_pid" && pass "request loop during the rollback: no failed request" || { tail -3 "$OUT/04-request-loop-rollback-A.log"; fail "requests failed during the rollback"; }
fi

if want 5; then
  step "5. deploy release D, whose frontend files have no index.html (must be refused before anything changes)"
  loop 25 05-request-loop-frontend-missing-root.log / & loop_root=$!
  loop 25 05-request-loop-frontend-missing-api.log /api/products & loop_api=$!
  sleep 3
  rc=0; run "$D" bluegreen-deploy.sh --env staging --sha "$D" > "$OUT/05-deploy-D-frontend-missing.log" 2>&1 || rc=$?
  [ "$rc" = 1 ] || { kill "$loop_root" "$loop_api" 2> /dev/null || true; fail "release D exited $rc, expected 1"; }
  pass "release D was refused (exit 1)"
  grep -q "no non-empty index.html" "$OUT/05-deploy-D-frontend-missing.log" || fail "the log does not say why D was refused"
  grep -q "frontend-dist has no non-empty index.html; refusing before anything is changed" "$OUT/05-deploy-D-frontend-missing.log" || fail "D was not refused before anything was changed"
  pass "D was refused before anything was changed (no container started, traffic never moved)"
  [[ "$(version_live)" == *"$A"* ]] || fail "A is no longer live after the refused D deploy"
  pass "A is still live"
  same_db "refused D deploy"
  wait "$loop_root" && pass "request loop on / during the D attempt: no failed request" || { tail -3 "$OUT/05-request-loop-frontend-missing-root.log"; wait "$loop_api" || true; fail "requests to / failed during the D attempt"; }
  wait "$loop_api" && pass "request loop on /api/products during the D attempt: no failed request" || { tail -3 "$OUT/05-request-loop-frontend-missing-api.log"; fail "requests to /api/products failed during the D attempt"; }
fi

if want 6; then
  step "6. deploy release E (good), then delete its index.html right after the switch (external fault): the live check must fail and the automatic rollback must restore A"
  E_LOG="$OUT/06-deploy-E-post-switch-failure.log"
  loop 45 06-request-loop-post-switch-E.log / & loop_pid=$!
  # The fault injector: waits for the script's own "switching traffic" line, then removes E's index.html on the host.
  ( for _ in $(seq 1 1200); do
      if grep -q "validated; switching traffic" "$E_LOG" 2> /dev/null; then
        date -u +%Y-%m-%dT%H:%M:%S.%3NZ > "$OUT/06-fault-injected-utc.txt"
        rm -f "$SHOPNEST_HOME/staging/frontend/releases/$E/index.html"
        exit 0
      fi
      sleep 0.05
    done ) &
  injector_pid=$!
  sleep 3
  rc=0; run "$E" bluegreen-deploy.sh --env staging --sha "$E" > "$E_LOG" 2>&1 || rc=$?
  wait "$injector_pid" || true
  [ -s "$OUT/06-fault-injected-utc.txt" ] || { kill "$loop_pid" 2> /dev/null || true; fail "the fault was never injected"; }
  [ "$rc" = 1 ] || { kill "$loop_pid" 2> /dev/null || true; fail "release E exited $rc, expected 1 (failed, recovery succeeded)"; }
  pass "release E failed with exit 1 (failed, previous release restored)"
  grep -q "validated; switching traffic" "$E_LOG" || fail "the log does not show that E passed the pre-switch validation"
  grep -q "post-switch verification FAILED" "$E_LOG" || fail "the log does not show the post-switch failure"
  grep -q "automatic rollback complete" "$E_LOG" || fail "the log does not show a completed automatic rollback"
  pass "the post-switch check failed and the automatic rollback completed"
  [[ "$(version_live)" == *"$A"* ]] || fail "A is not live after the automatic rollback"
  pass "A is live again after the automatic rollback"
  same_db "automatic rollback"
  if [ -n "$(docker ps -q --filter "name=$PREFIX-staging-backend-green")" ]; then fail "the failed colour (green, E) is still running"; fi
  pass "the failed colour was stopped"
  tail -n 2 "$SHOPNEST_HOME/staging/state/history.log" | grep -q "$E failed post-switch verification failed; automatic rollback to $A (restored=1)" || fail "the history does not record the automatic rollback"
  pass "the release history records the failure and restored=1"
  docker logs "$PREFIX-staging-nginx-1" 2>&1 | grep -E 'error|\[crit\]|\[emerg\]' | cut -c1-220 | head -5 > "$OUT/06-nginx-errors-excerpt.txt" || true
  # Informational, not a pass condition: requests to "/" fail while E is briefly live.
  wait "$loop_pid" || true
  echo "INFO  $(grep SUMMARY "$OUT/06-request-loop-post-switch-E.log")"
  echo "INFO  fault injected at $(cat "$OUT/06-fault-injected-utc.txt"); $(window "$OUT/06-request-loop-post-switch-E.log")"
fi

step "release history"
bash "$ROOT/deploy/scripts/release-status.sh" --env staging | tee "$OUT/07-release-status.txt"
cp "$SHOPNEST_HOME/staging/state/history.log" "$OUT/07-history.log"

step "result"
echo "ALL CHECKS PASSED ($PASSED). Output saved under $OUT"
