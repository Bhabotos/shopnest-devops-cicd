#!/usr/bin/env bash
# Offline tests for LAB mode of the blue/green deploy and rollback scripts (BG_LAB=1, the infra/lab instance): the REAL scripts and
# library against the fake `docker` (deploy/tests/fake-docker.sh), so the decisions are tested without a Docker engine:
#   - nothing is touched for a bad request (a tag instead of a digest, a missing frontend image, a wrong commit checkout)
#   - the database passwords are generated on the host, mode 600, and never printed
#   - staging binds to the loopback address, production to all addresses
#   - both images are pulled by digest, their revision labels are checked and their references are recorded
#   - a broken release (wrong revision label, frontend without index.html, failed health check) never takes traffic
#   - a rollback pulls the recorded digests again if the host lost the images
# It does NOT prove that the containers, nginx, Docker Compose, GHCR or AWS behave: that needs a real instance.
#   bash deploy/tests/lab-mode.test.sh
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
absent() { if grep -q -- "$3" "$2" 2> /dev/null; then bad "$1: '$3' found in $2"; else ok "$1"; fi; }

DIGEST="$(printf '%064d' 0 | tr 0 c)"
BACKEND_REF="ghcr.io/exampleowner/shopnest-backend@sha256:$DIGEST"
FRONTEND_REF="ghcr.io/exampleowner/shopnest-frontend@sha256:$DIGEST"

# Can this filesystem hold mode 600? (NTFS under Git Bash cannot: every file reports 644.) Where it cannot, the existing, narrow
# rehearsal bypass is used for the mode check ONLY and the mode assertions are skipped; CI runs on Linux and checks them all.
probe="$T/modeprobe"; : > "$probe"; chmod 600 "$probe"
if [ "$(stat -c '%a' "$probe")" = 600 ]; then MODE_OK=1; else MODE_OK=0; fi

new_world() {
  W="$(mktemp -d "$T/w.XXXXXX")"
  mkdir -p "$W/home" "$W/fake" "$W/bin" "$W/co"
  cp "$HERE/fake-docker.sh" "$W/bin/docker"
  chmod +x "$W/bin/docker"
  unset BG_LOCAL_DB BG_ALLOW_LOOSE_SECRETS SHOPNEST_PROJECT_PREFIX HTTP_BIND SHOPNEST_HTTP_PORT
  export SHOPNEST_HOME="$W/home" FAKE="$W/fake" PATH="$W/bin:$ORIG_PATH" BG_LAB=1 BG_SKIP_PUBLIC_CHECK=1
  if [ "$MODE_OK" = 0 ]; then export BG_ALLOW_LOOSE_SECRETS=1 SHOPNEST_PROJECT_PREFIX=shopnest-test HTTP_BIND=127.0.0.1; fi
}

# make_checkout <label>: a git checkout of the deploy tooling with ONE commit; LAST_SHA is that commit (the release), LAST_CO the directory.
# (Not called in a command substitution: that would lose the variables.)
make_checkout() {
  local b="$W/co/$1" env_name
  mkdir -p "$b/deploy/scripts/lib" "$b/deploy/env" "$b/deploy/db/init" "$b/deploy/nginx"
  cp "$DEPLOY_DIR/scripts/"*.sh "$b/deploy/scripts/"
  cp "$DEPLOY_DIR/scripts/lib/"*.sh "$b/deploy/scripts/lib/"
  : > "$b/deploy/docker-compose.prod.yml"
  : > "$b/deploy/docker-compose.local-db.yml"
  echo '#!/bin/sh' > "$b/deploy/db/init/01-roles.sh"
  echo 'server { listen 8080; }' > "$b/deploy/nginx/nginx.conf"
  for env_name in staging production; do
    printf 'HTTP_PORT=1\nREADY_ATTEMPTS=3\nREADY_INTERVAL=0\nLIVE_ATTEMPTS=2\nLIVE_INTERVAL=0\nDRAIN_SECONDS=0\nDB_WAIT_ATTEMPTS=2\nDB_WAIT_INTERVAL=0\n' > "$b/deploy/env/$env_name.env"
    grep -E '^(EDGE_|NGINX_IP|BACKEND_)' "$DEPLOY_DIR/env/$env_name.env" >> "$b/deploy/env/$env_name.env"
  done
  echo "$1" > "$b/RELEASE_LABEL"
  git -C "$b" init -q
  git -C "$b" config core.autocrlf false
  git -C "$b" add -A 2> /dev/null
  git -C "$b" -c user.name=test -c user.email=test@example.invalid -c commit.gpgsign=false commit -q -m "release $1"
  LAST_SHA="$(git -C "$b" rev-parse HEAD)"
  LAST_CO="$b"
}

deploy() { # <checkout dir> <env> <sha> [more args]; output in $W/out
  echo "$3" > "$FAKE/load-tag"
  bash "$1/deploy/scripts/bluegreen-deploy.sh" --env "$2" --sha "$3" --image-ref "$BACKEND_REF" --frontend-ref "$FRONTEND_REF" "${@:4}" > "$W/out" 2>&1
}
rollback() { # <carrier checkout dir> <env> <sha>
  bash "$1/deploy/scripts/rollback.sh" --env "$2" --sha "$3" > "$W/out" 2>&1
}
state() { cat "$SHOPNEST_HOME/$1/state/$2" 2> /dev/null || true; }
served() { cat "$FAKE/served" 2> /dev/null || true; }

echo "== 1. first lab deploy of release A to staging"
new_world
make_checkout A; CO_A="$LAST_CO"; A="$LAST_SHA"
deploy "$CO_A" staging "$A"; check "deploy A exit code" $? 0
check "live colour" "$(state staging active)" blue
check "blue runs A" "$(state staging tag-blue)" "$A"
check "nginx serves blue with A's frontend" "$(served)" "blue $A"
check "last good" "$(state staging last_good)" "$A"
check "the backend digest is recorded for a later rollback" "$(cat "$SHOPNEST_HOME/staging/state/image-ref-$A")" "$BACKEND_REF"
check "the frontend digest is recorded for a later rollback" "$(cat "$SHOPNEST_HOME/staging/state/frontend-ref-$A")" "$FRONTEND_REF"
contains "the frontend files were unpacked from the image" "$SHOPNEST_HOME/staging/frontend/releases/$A/index.html" "frontend files"
contains "both images were pulled by digest" "$FAKE/calls.log" "pull $BACKEND_REF"
contains "the frontend image was pulled by digest" "$FAKE/calls.log" "pull $FRONTEND_REF"
contains "the migrations ran before traffic moved" "$FAKE/calls.log" "run migrate"
contains "the database container was started" "$FAKE/calls.log" "up db"
absent "the metadata-service guard is not used in lab mode" "$FAKE/calls.log" "guard "
contains "the deploy log is kept" "$SHOPNEST_HOME/logs/staging-$A.log" "DEPLOY SUCCEEDED"
contains "the log names the commit checkout" "$SHOPNEST_HOME/logs/staging-$A.log" "lab mode: scripts are a git checkout"

echo "== 2. the database passwords are generated on the host, mode 600, and never printed"
secrets="$SHOPNEST_HOME/staging/secrets.env"
check "secrets.env exists" "$([ -f "$secrets" ] && echo yes || echo no)" yes
if [ "$MODE_OK" = 1 ]; then check "secrets.env is mode 600" "$(stat -c '%a' "$secrets")" 600; else echo "SKIP  secrets.env mode 600 (this filesystem cannot hold it; CI on Linux checks it)"; fi
for key in POSTGRES_PASSWORD DB_OWNER_PASSWORD DB_APP_PASSWORD; do
  value="$(sed -n "s/^$key=//p" "$secrets")"
  check "$key is 48 hex characters" "$([[ "$value" =~ ^[0-9a-f]{48}$ ]] && echo yes || echo no)" yes
  absent "$key is not printed in the deploy output" "$W/out" "$value"
  absent "$key is not in the deploy log" "$SHOPNEST_HOME/logs/staging-$A.log" "$value"
done
before="$(cat "$secrets")"
make_checkout B; CO_B="$LAST_CO"; B="$LAST_SHA"
deploy "$CO_B" staging "$B"; check "deploy B exit code" $? 0
check "a later deploy reuses the generated passwords" "$(cat "$secrets")" "$before"

echo "== 3. staging is bound to loopback, production to all addresses"
check "staging nginx bind" "$(grep '^bind ' "$FAKE/calls.log" | sort -u | tr '\n' ' ')" "bind 127.0.0.1 "
# The fake engine has one namespace; a real instance runs the two Compose projects side by side. Reset it for production.
rm -rf "$FAKE/running" "$FAKE/served" "$FAKE/calls.log"
deploy "$CO_A" production "$A"; check "deploy A to production exit code" $? 0
check "production nginx bind" "$(grep '^bind ' "$FAKE/calls.log" | sort -u | tr '\n' ' ')" "bind 0.0.0.0 "
check "the two environments keep separate state" "$(state production tag-blue)" "$A"
check "production has its own secrets" "$([ -f "$SHOPNEST_HOME/production/secrets.env" ] && [ "$(cat "$SHOPNEST_HOME/production/secrets.env")" != "$(cat "$SHOPNEST_HOME/staging/secrets.env")" ] && echo yes || echo no)" yes

echo "== 4. a bad request changes nothing"
new_world
make_checkout A; CO_A="$LAST_CO"; A="$LAST_SHA"
echo "$A" > "$FAKE/load-tag"
run() { bash "$CO_A/deploy/scripts/bluegreen-deploy.sh" "$@" > "$W/out" 2>&1; }
run --env staging --sha "$A" --image-ref "ghcr.io/exampleowner/shopnest-backend:latest" --frontend-ref "$FRONTEND_REF"; check "a tag instead of a digest is refused" $? 1
contains "the refusal says a digest is required" "$W/out" "a digest, never a tag"
run --env staging --sha "$A" --image-ref "$BACKEND_REF"; check "a missing --frontend-ref is refused" $? 1
run --env staging --sha "$A" --image-ref "$BACKEND_REF" --frontend-ref "$BACKEND_REF"; check "the backend image given as the frontend is refused" $? 1
run --env staging --sha "$A" --image-ref "$BACKEND_REF" --frontend-ref "$FRONTEND_REF" --bundle-key deploy/staging/x/bundle.tar.gz --bundle-sha256 "$DIGEST"; check "bundle arguments are refused in lab mode" $? 1
run --env staging --sha "$(printf '%040d' 0 | tr 0 9)" --image-ref "$BACKEND_REF" --frontend-ref "$FRONTEND_REF"; check "a SHA that is not the checkout's commit is refused" $? 1
contains "the refusal names the checkout" "$W/out" "must run from a git checkout"
BG_LOCAL_DB=1 run --env staging --sha "$A" --image-ref "$BACKEND_REF" --frontend-ref "$FRONTEND_REF"; check "BG_LAB and BG_LOCAL_DB together are refused" $? 1
check "nothing was pulled for any of those" "$(grep -c '^pull' "$FAKE/calls.log" 2> /dev/null || echo 0)" 0
check "no environment directory holds a release" "$([ -f "$SHOPNEST_HOME/staging/state/active" ] && echo yes || echo no)" no
check "no password file was generated for a refused request" "$([ -f "$SHOPNEST_HOME/staging/secrets.env" ] && echo yes || echo no)" no

echo "== 5. a broken release never takes traffic"
new_world
make_checkout A; CO_A="$LAST_CO"; A="$LAST_SHA"
deploy "$CO_A" staging "$A"
make_checkout B; CO_B="$LAST_CO"; B="$LAST_SHA"
touch "$FAKE/pull_wrong_revision"
deploy "$CO_B" staging "$B"; check "an image with the wrong revision label is refused" $? 1
rm -f "$FAKE/pull_wrong_revision"
check "traffic stays on A" "$(state staging tag-blue)" "$A"
touch "$FAKE/frontend_empty"
deploy "$CO_B" staging "$B"; check "a frontend image without index.html is refused" $? 1
rm -f "$FAKE/frontend_empty"
check "traffic still on A" "$(served)" "blue $A"
mkdir -p "$FAKE/bad_health"; touch "$FAKE/bad_health/$B"
deploy "$CO_B" staging "$B"; check "a release that fails its health check is rejected (exit 1)" $? 1
contains "the log says traffic was not moved" "$W/out" "traffic was NOT moved"
check "A is still live after the rejected release" "$(served)" "blue $A"
rm -f "$FAKE/bad_health/$B"
touch "$FAKE/pull_fail"
deploy "$CO_B" staging "$B"; check "an image the registry no longer has is refused" $? 1
rm -f "$FAKE/pull_fail"

echo "== 6. production is never seeded without an explicit operator choice"
new_world
make_checkout A; CO_A="$LAST_CO"; A="$LAST_SHA"
deploy "$CO_A" production "$A" --seed; check "--seed on production without ALLOW_PRODUCTION_SEED is refused" $? 1
contains "the refusal names the flag" "$W/out" "ALLOW_PRODUCTION_SEED"
deploy "$CO_A" staging "$A" --seed; check "--seed on staging is accepted in lab mode" $? 0
contains "the seed job ran for staging" "$FAKE/calls.log" "run seed"

echo "== 7. a rollback pulls the recorded digests again if the host lost the images"
new_world
make_checkout A; CO_A="$LAST_CO"; A="$LAST_SHA"
deploy "$CO_A" staging "$A"
make_checkout B; CO_B="$LAST_CO"; B="$LAST_SHA"
deploy "$CO_B" staging "$B"
make_checkout C; CO_C="$LAST_CO"; C="$LAST_SHA"
check "B is live before the rollback" "$(served)" "green $B"
rm -f "$FAKE/images/$A" "$FAKE/images/frontend-$A"
rm -rf "$SHOPNEST_HOME/staging/frontend/releases/$A"
: > "$FAKE/calls.log"
echo "$A" > "$FAKE/load-tag"
rollback "$CO_C" staging "$A"; check "rollback to A exit code" $? 0
check "traffic is on A again" "$(served)" "blue $A"
contains "the recorded backend digest was pulled again" "$FAKE/calls.log" "pull $BACKEND_REF"
contains "the recorded frontend digest was pulled again" "$FAKE/calls.log" "pull $FRONTEND_REF"
absent "a rollback never runs migrations" "$FAKE/calls.log" "run migrate"
contains "the rollback is logged" "$SHOPNEST_HOME/logs/rollback-staging-$A.log" "ROLLBACK SUCCEEDED"
rollback "$CO_C" staging "$C"; check "a release that was never deployed cannot be rolled back to" $? 1
contains "the refusal names the history" "$W/out" "not in the release history as deployed"

echo "== 8. staging-only, one-shot fault injection (Part G: automatic rollback of a release that fails its post-switch check)"
THIS_UID="$(id -u)"
export BG_FAULT_OWNER_UID="$THIS_UID"   # the offline tests do not run as root; on the instance the owner must be root (uid 0)
FAULT_LINE='FAULT=post-switch-unhealthy'
arm() { mkdir -p "$SHOPNEST_HOME/$1"; printf '%s\n' "${2:-$FAULT_LINE}" > "$SHOPNEST_HOME/$1/fault.env"; chmod 600 "$SHOPNEST_HOME/$1/fault.env" 2> /dev/null || true; }
has_fault() { [ -e "$SHOPNEST_HOME/$1/fault.env" ] && echo yes || echo no; }
new_world
make_checkout A; CO_A="$LAST_CO"; A="$LAST_SHA"
deploy "$CO_A" staging "$A"
make_checkout B; CO_B="$LAST_CO"; B="$LAST_SHA"
arm staging
deploy "$CO_B" staging "$B"; check "an armed fault makes the staging deploy fail with the previous release serving (exit 1, never 3)" $? 1
check "the fault file is consumed and removed" "$(has_fault staging)" no
contains "the log says the fault was armed for B" "$W/out" "FAULT INJECTION (staging test): armed for release $B"
contains "the log says the post-switch verification failed" "$W/out" "post-switch verification FAILED"
contains "the log says the failure was injected" "$W/out" "this failure was INJECTED by the staging fault file"
contains "the log records the automatic rollback" "$W/out" "previous release $A is live again (automatic rollback complete)"
check "traffic is back on A (the previous release)" "$(served)" "blue $A"
check "A is the active colour again" "$(state staging active)" blue
check "the history records the failure and the automatic rollback" "$(grep -c " staging $B failed post-switch verification failed; automatic rollback to $A (restored=1)" "$SHOPNEST_HOME/staging/state/history.log")" 1
check "B was never recorded as deployed" "$(grep -c " $B deployed " "$SHOPNEST_HOME/staging/state/history.log")" 0
check "last good is still A" "$(state staging last_good)" "$A"
deploy "$CO_B" staging "$B"; check "the fault is one-shot: the next deploy of B succeeds" $? 0
check "B is live on green" "$(served)" "green $B"

new_world
make_checkout A; CO_A="$LAST_CO"; A="$LAST_SHA"
make_checkout B; CO_B="$LAST_CO"; B="$LAST_SHA"
deploy "$CO_A" production "$A"
arm production
deploy "$CO_B" production "$B"; check "production never reads the fault file: the deploy succeeds" $? 0
check "the fault file is untouched in production" "$(has_fault production)" yes
absent "production logs no fault injection" "$W/out" "FAULT INJECTION"
check "B is live in production" "$(served)" "green $B"

new_world
make_checkout A; CO_A="$LAST_CO"; A="$LAST_SHA"
make_checkout B; CO_B="$LAST_CO"; B="$LAST_SHA"
arm staging
deploy "$CO_A" staging "$A"; check "the very first deploy is never sabotaged (no previous release)" $? 0
check "the file is left in place for a later deploy" "$(has_fault staging)" yes
contains "the log says why" "$W/out" "no previous release to fall back to"

new_world
make_checkout A; CO_A="$LAST_CO"; A="$LAST_SHA"
make_checkout B; CO_B="$LAST_CO"; B="$LAST_SHA"
deploy "$CO_A" staging "$A"
deploy "$CO_B" staging "$B"
arm staging
echo "$A" > "$FAKE/load-tag"
rollback "$CO_B" staging "$A"; check "a rollback is never sabotaged by the fault file" $? 0
check "the fault file is left untouched by a rollback" "$(has_fault staging)" yes
contains "the log says a rollback is not a deploy" "$W/out" "this is a manual rollback and not a deploy"
check "traffic is on A after the rollback" "$(served)" "blue $A"

for case_name in content owner; do
  new_world
  make_checkout A; CO_A="$LAST_CO"; A="$LAST_SHA"
  make_checkout B; CO_B="$LAST_CO"; B="$LAST_SHA"
  deploy "$CO_A" staging "$A"
  case "$case_name" in
    content) arm staging "FAULT=something-else" ;;
    owner) arm staging; export BG_FAULT_OWNER_UID=999999 ;;
  esac
  deploy "$CO_B" staging "$B"; check "an invalid fault file ($case_name) is ignored: the deploy succeeds" $? 0
  check "the invalid fault file ($case_name) is left in place" "$(has_fault staging)" yes
  contains "the log says the fault file was ignored ($case_name)" "$W/out" "fault file ignored"
  export BG_FAULT_OWNER_UID="$THIS_UID"
done
new_world
make_checkout A; CO_A="$LAST_CO"; A="$LAST_SHA"
make_checkout B; CO_B="$LAST_CO"; B="$LAST_SHA"
deploy "$CO_A" staging "$A"
arm staging "FAULT=post-switch-unhealthy
FAULT=extra-line"
deploy "$CO_B" staging "$B"; check "a fault file with extra lines is ignored" $? 0
if [ "$MODE_OK" = 1 ]; then
  new_world
  make_checkout A; CO_A="$LAST_CO"; A="$LAST_SHA"
  make_checkout B; CO_B="$LAST_CO"; B="$LAST_SHA"
  deploy "$CO_A" staging "$A"
  arm staging; chmod 666 "$SHOPNEST_HOME/staging/fault.env"
  deploy "$CO_B" staging "$B"; check "a group- or world-writable fault file is ignored" $? 0
  check "it is left in place" "$(has_fault staging)" yes
  new_world
  make_checkout A; CO_A="$LAST_CO"; A="$LAST_SHA"
  make_checkout B; CO_B="$LAST_CO"; B="$LAST_SHA"
  deploy "$CO_A" staging "$A"
  printf '%s\n' "$FAULT_LINE" > "$W/real-fault"; chmod 600 "$W/real-fault"; ln -s "$W/real-fault" "$SHOPNEST_HOME/staging/fault.env"
  deploy "$CO_B" staging "$B"; check "a symbolic link as the fault file is ignored" $? 0
  contains "the log says it is not a plain file" "$W/out" "not a plain file"
else
  echo "SKIP  group-writable and symlink fault files (this filesystem cannot represent them; CI on Linux checks them)"
fi
# The staging deploy says what it looked for when nothing is armed, and shows a misplaced file by name (never its content).
new_world
make_checkout A; CO_A="$LAST_CO"; A="$LAST_SHA"
make_checkout B; CO_B="$LAST_CO"; B="$LAST_SHA"
deploy "$CO_A" staging "$A"
mkdir -p "$SHOPNEST_HOME/staging"; printf '%s\n' "$FAULT_LINE" > "$SHOPNEST_HOME/staging/fault.env.txt"
deploy "$CO_B" staging "$B"; check "a misnamed fault file does not arm anything: the deploy succeeds" $? 0
contains "the log says nothing was armed and where it looked" "$W/out" "fault injection: no fault file at $SHOPNEST_HOME/staging/fault.env, not armed"
contains "the log names the misplaced file" "$W/out" "found instead (NOT used):.*fault.env.txt"
absent "the log never prints the content of a fault file" "$W/out" "post-switch-unhealthy"
new_world
make_checkout A; CO_A="$LAST_CO"; A="$LAST_SHA"
deploy "$CO_A" production "$A"; check "a production deploy succeeds" $? 0
absent "production never looks for, nor mentions, a fault file" "$W/out" "fault injection"
unset BG_FAULT_OWNER_UID

echo
echo "lab-mode checks: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
