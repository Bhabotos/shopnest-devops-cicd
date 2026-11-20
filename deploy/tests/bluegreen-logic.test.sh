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
}

make_bundle() { # <sha>
  local b="$W/bundles/$1" env_name
  rm -rf "$b"
  mkdir -p "$b/deploy/scripts/lib" "$b/deploy/env" "$b/frontend-dist"
  cp "$DEPLOY_DIR/scripts/"*.sh "$b/deploy/scripts/"
  cp "$DEPLOY_DIR/scripts/lib/"*.sh "$b/deploy/scripts/lib/"
  : > "$b/deploy/docker-compose.prod.yml"
  mkdir -p "$b/deploy/db/init" "$b/deploy/nginx"
  echo '#!/bin/sh' > "$b/deploy/db/init/01-roles.sh"
  echo 'server { listen 8080; }' > "$b/deploy/nginx/nginx.conf"
  for env_name in staging production; do
    printf 'HTTP_PORT=1\nREADY_ATTEMPTS=3\nREADY_INTERVAL=0\nLIVE_ATTEMPTS=2\nLIVE_INTERVAL=0\nDRAIN_SECONDS=0\n' > "$b/deploy/env/$env_name.env"
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
check "compose has no bundle-relative bind mounts" "$(grep -cE '^[[:space:]]+- \./' "$DEPLOY_DIR/docker-compose.prod.yml")" 0
contains "compose mounts the stable db-init path" "$DEPLOY_DIR/docker-compose.prod.yml" 'ENV_DIR:?ENV_DIR is required}/db-init'
contains "compose mounts the stable nginx conf path" "$DEPLOY_DIR/docker-compose.prod.yml" 'ENV_DIR}/nginx/conf:/etc/nginx/conf.d'

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

echo "== 12. no secrets in any log"
if grep -rq 'aaaaaaaaaaaaaaaa11\|bbbbbbbbbbbbbbbb22\|cccccccccccccccc33' "$SHOPNEST_HOME/logs" "$W/out" 2> /dev/null; then bad "a password appears in a log"; else ok "no password appears in the deployment logs"; fi

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
