#!/usr/bin/env bash
# Local rehearsal of Part F and G against a REAL Docker engine, in a throwaway Compose project
# ("shopnest-demo"), on a loopback-only port, with a throwaway home directory and random database
# passwords. It runs the real deploy and rollback scripts:
#   1. deploy release A (good), with the demo catalogue
#   2. deploy release B (good) while a request loop runs   -> expect 0 failed requests
#   3. deploy release C (deliberately broken)               -> expect failure, B still live, 0 failed requests
#   4. manual rollback to A                                 -> expect A live, 0 failed requests
# With --scenario post-switch it runs a different rehearsal (only step 1, then):
#   5. deploy release D, which passes /health and /version BEFORE the switch but has no index.html, so the
#      live check FAILS AFTER traffic moved -> expect the automatic rollback to put A back, D stopped, and
#      the database untouched. Requests to "/" fail while D is briefly live: that window is recorded, not hidden.
# It is a rehearsal for the staging demonstration (docs/ARCHITECTURE.md); it is not evidence from AWS.
# Needs: docker with compose, curl, a local Docker engine. Never touches the "shopnest-staging" or
# "shopnest-production" projects: its project name, port and files are its own.
#   bash deploy/scripts/demo-bluegreen-local.sh [--out DIR] [--keep] [--scenario full|post-switch]
# On a filesystem that cannot hold mode 600 (Windows) run it with BG_ALLOW_LOOSE_SECRETS=1; the library
# accepts that only because this script sets a non-default project prefix and a loopback bind.
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
    *) echo "usage: demo-bluegreen-local.sh [--out DIR] [--keep] [--scenario full|post-switch]" >&2; exit 2 ;;
  esac
done

PREFIX="shopnest-demo"
PORT=18081
A="$(printf '%040d' 0 | tr 0 a)"
B="$(printf '%040d' 0 | tr 0 b)"
C="$(printf '%040d' 0 | tr 0 c)"
D="$(printf '%040d' 0 | tr 0 d)"
case "$SCENARIO" in full | post-switch) ;; *) echo "scenario must be full or post-switch" >&2; exit 2 ;; esac
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
mkdir -p "$OUT" "$SHOPNEST_HOME/staging"
OUT="$(cd "$OUT" && pwd)"

cleanup() {
  step "cleanup (throwaway project $PREFIX-staging only)"
  # Dummy values only so Compose can parse the file's required variables; nothing is started.
  POSTGRES_PASSWORD=x DB_OWNER_PASSWORD=x DB_APP_PASSWORD=x ENV_DIR="$WORK_NATIVE" HTTP_PORT=1 \
    docker compose -p "$PREFIX-staging" -f "$WORK/bundles/$A/deploy/docker-compose.prod.yml" down -v --remove-orphans > /dev/null 2>&1 || true
  for sha in "$A" "$B" "$C" "$D"; do docker rmi -f "shopnest-backend:$sha" > /dev/null 2>&1 || true; done
  [ "$KEEP" = 1 ] || rm -rf "$WORK"
}
trap cleanup EXIT

printf 'POSTGRES_PASSWORD=%s\nDB_OWNER_PASSWORD=%s\nDB_APP_PASSWORD=%s\n' "$(openssl rand -hex 12)" "$(openssl rand -hex 12)" "$(openssl rand -hex 12)" > "$SHOPNEST_HOME/staging/secrets.env"
chmod 600 "$SHOPNEST_HOME/staging/secrets.env"

docker build -q --label "org.opencontainers.image.revision=$A" -t "shopnest-backend:$A" "$ROOT/backend" > /dev/null
if [ "$SCENARIO" = full ]; then
  step "build the three releases (A and B good; C starts and exits at once)"
  docker build -q --label "org.opencontainers.image.revision=$B" -t "shopnest-backend:$B" "$ROOT/backend" > /dev/null
  printf 'FROM shopnest-backend:%s\nCMD ["node","-e","process.exit(1)"]\n' "$A" | docker build -q --label "org.opencontainers.image.revision=$C" -t "shopnest-backend:$C" - > /dev/null
else
  step "build releases A and D (D is a healthy backend whose frontend files have no index.html)"
  docker build -q --label "org.opencontainers.image.revision=$D" -t "shopnest-backend:$D" "$ROOT/backend" > /dev/null
fi
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
if [ "$SCENARIO" = full ]; then
  make_bundle "$B" B; make_bundle "$C" C
else
  make_bundle "$D" D
  rm -f "$WORK/bundles/$D/frontend-dist/index.html"
  printf 'release D has no index.html on purpose\n' > "$WORK/bundles/$D/frontend-dist/NOTE.txt"
  # The checksum list was made before the file was removed; rebuild it so the bundle still verifies.
  (cd "$WORK/bundles/$D" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)
fi
# The rehearsal compresses the image only lightly and reuses the images already built above; the
# deploy script still loads them from the bundle exactly as it would on a server.
for sha in "$A" "$B" "$C" "$D"; do docker rmi -f "shopnest-backend:$sha" > /dev/null 2>&1 || true; done

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

loop() { bash "$ROOT/deploy/scripts/request-loop.sh" --url "http://127.0.0.1:$PORT/api/products" --seconds "$1" --interval 0.1 --log "$OUT/$2" > /dev/null 2>&1; }

if [ "$SCENARIO" = full ]; then
  step "2. deploy release B while requests flow"
  loop 60 02-request-loop-deploy-B.log & loop_pid=$!
  sleep 3
  run "$B" bluegreen-deploy.sh --env staging --sha "$B" > "$OUT/02-deploy-B.log" 2>&1 || { tail -30 "$OUT/02-deploy-B.log"; kill "$loop_pid" 2> /dev/null || true; fail "deploy B failed"; }
  [[ "$(version_live)" == *"$B"* ]] || fail "B is not live"
  pass "B is live"
  same_db "B deploy"
  wait "$loop_pid" && pass "request loop during the B deploy: no failed request" || { tail -3 "$OUT/02-request-loop-deploy-B.log"; fail "requests failed during the B deploy"; }

  step "3. deploy the deliberately broken release C (must fail and leave B live)"
  loop 40 03-request-loop-broken-C.log & loop_pid=$!
  sleep 3
  if run "$C" bluegreen-deploy.sh --env staging --sha "$C" > "$OUT/03-deploy-C-broken.log" 2>&1; then kill "$loop_pid" 2> /dev/null || true; fail "the broken release was deployed"; fi
  pass "broken release C was rejected"
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

else
  step "5. deploy release D (passes the pre-switch checks, fails the live check after traffic moved)"
  loop_root() { bash "$ROOT/deploy/scripts/request-loop.sh" --url "http://127.0.0.1:$PORT/" --seconds "$1" --interval 0.1 --log "$OUT/$2" > /dev/null 2>&1; }
  loop_root 45 05-request-loop-post-switch-D.log & loop_pid=$!
  sleep 3
  if run "$D" bluegreen-deploy.sh --env staging --sha "$D" > "$OUT/05-deploy-D-post-switch-failure.log" 2>&1; then kill "$loop_pid" 2> /dev/null || true; fail "release D was reported as deployed"; fi
  pass "release D was reported as failed"
  grep -q "validated; switching traffic" "$OUT/05-deploy-D-post-switch-failure.log" || fail "the log does not show that D passed the pre-switch validation"
  pass "D passed the pre-switch validation (traffic did move)"
  grep -q "post-switch verification FAILED" "$OUT/05-deploy-D-post-switch-failure.log" || fail "the log does not show the post-switch failure"
  grep -q "automatic rollback complete" "$OUT/05-deploy-D-post-switch-failure.log" || fail "the log does not show a completed automatic rollback"
  pass "the post-switch check failed and the automatic rollback completed"
  [[ "$(version_live)" == *"$A"* ]] || fail "A is not live after the automatic rollback"
  pass "A is live again after the automatic rollback"
  same_db "automatic rollback"
  if [ -n "$(docker ps -q --filter "name=$PREFIX-staging-backend-green")" ]; then fail "the failed colour (green, D) is still running"; fi
  pass "the failed colour was stopped"
  tail -n 2 "$SHOPNEST_HOME/staging/state/history.log" | grep -q "$D failed post-switch verification failed; automatic rollback to $A (restored=1)" || fail "the history does not record the automatic rollback"
  pass "the release history records the failure and restored=1"
  # Informational, not a pass condition: requests to "/" fail while D is briefly live.
  wait "$loop_pid" || true
  echo "INFO  $(grep SUMMARY "$OUT/05-request-loop-post-switch-D.log")  (failures are expected while D was live)"
fi

step "release history"
bash "$ROOT/deploy/scripts/release-status.sh" --env staging | tee "$OUT/05-release-status.txt"
cp "$SHOPNEST_HOME/staging/state/history.log" "$OUT/05-history.log"

step "result"
echo "ALL CHECKS PASSED ($PASSED). Output saved under $OUT"
