#!/usr/bin/env bash
# Offline tests for deploy/host/imds-guard.sh, install-host-guards.sh, the systemd units and the AWS Compose file.
# They run the REAL scripts against a fake `iptables`, `iptables-restore`, `docker`, `systemctl` and `id`, so they check
# the script's decisions: the exact rules, their order, idempotence, and that it FAILS CLOSED. They do NOT prove that
# a real instance blocks the metadata service: that needs the instance-level tests (docs/AWS_STAGING_INTEGRATION.md,
# G1 to G12). Until those pass, isolation is designed and offline-tested only.
#   bash deploy/tests/imds-guard.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "$HERE/.." && pwd)"
GUARD="$DEPLOY_DIR/host/imds-guard.sh"
INSTALL="$DEPLOY_DIR/host/install-host-guards.sh"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
ORIG_PATH="$PATH"
PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); echo "PASS  $*"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL  $*"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: got [$2] expected [$3]"; fi; }
contains() { if grep -qF -- "$3" "$2" 2> /dev/null; then ok "$1"; else bad "$1: '$3' not found in $2"; fi; }
absent() { if grep -qF -- "$3" "$2" 2> /dev/null; then bad "$1: '$3' found in $2"; else ok "$1"; fi; }
count() { if [ -f "$2" ]; then grep -c -- "$1" "$2" || true; else echo 0; fi; }

new_world() {
  W="$(mktemp -d "$T/w.XXXXXX")"
  mkdir -p "$W/bin" "$W/fake/ipt" "$W/fake/networks"
  cat > "$W/bin/id" << 'EOF'
#!/usr/bin/env bash
[ "${1:-}" = "-u" ] && { echo "${FAKE_UID:-0}"; exit 0; }
exec /usr/bin/id "$@"
EOF
  cat > "$W/bin/iptables" << 'EOF'
#!/usr/bin/env bash
# fake iptables: chains are files under $FAKE/ipt, one rule per line, in `iptables -S` format
d="$FAKE/ipt"
echo "iptables $*" >> "$FAKE/calls.log"
case "$1" in
  -S) [ -f "$d/$2" ] || exit 1; echo "-N $2"; cat "$d/$2" ;;
  -D) [ -f "$d/$2" ] || exit 1
      line="-A $2 ${*:3}"
      grep -qxF -- "$line" "$d/$2" || exit 1
      awk -v l="$line" '!done && $0 == l { done = 1; next } { print }' "$d/$2" > "$d/$2.new" && mv "$d/$2.new" "$d/$2" ;;
  -I) [ -f "$d/$2" ] || exit 1
      pos="$3"
      line="-A $2 ${*:4}"
      { head -n $((pos - 1)) "$d/$2"; echo "$line"; tail -n +"$pos" "$d/$2"; } > "$d/$2.new" && mv "$d/$2.new" "$d/$2" ;;
  *) exit 1 ;;
esac
EOF
  cat > "$W/bin/iptables-restore" << 'EOF'
#!/usr/bin/env bash
# fake iptables-restore: only `--noflush` is accepted (a flushing restore would wipe Docker's rules)
echo "iptables-restore $*" >> "$FAKE/calls.log"
[ "${1:-}" = "--noflush" ] || { echo "iptables-restore without --noflush" >&2; exit 1; }
d="$FAKE/ipt"
tmp="$(cat)"
[ "$(printf '%s\n' "$tmp" | tail -n 1)" = "COMMIT" ] || exit 1
declare -A seen
while IFS= read -r line; do
  case "$line" in
    :*) chain="${line%% *}"; chain="${chain#:}"; : > "$d/$chain"; seen[$chain]=1 ;;
    -A\ *) chain="${line#-A }"; chain="${chain%% *}"; [ -n "${seen[$chain]:-}" ] || exit 1; echo "$line" >> "$d/$chain" ;;
  esac
done <<< "$tmp"
EOF
  cat > "$W/bin/docker" << 'EOF'
#!/usr/bin/env bash
echo "docker $*" >> "$FAKE/calls.log"
case "$1 ${2:-}" in
  "network inspect")
    name="${*: -1}"
    [ -f "$FAKE/networks/$name" ] || exit 1
    case "$*" in *"-f"*) printf '%s \n' "$(cat "$FAKE/networks/$name")" ;; esac
    exit 0 ;;
  "network create")
    prev=""; subnet=""
    for a in "$@"; do [ "$prev" = "--subnet" ] && subnet="$a"; prev="$a"; done
    echo "$subnet" > "$FAKE/networks/${*: -1}"
    exit 0 ;;
esac
case "$1" in
  run)
    [ -f "$FAKE/probe_error" ] && exit 125
    [ -f "$FAKE/probe_reachable" ] && exit 0
    exit 7 ;;
  exec)
    [ -f "$FAKE/nginx_reachable" ] && exit 0
    exit 1 ;;
esac
exit 0
EOF
  cat > "$W/bin/systemctl" << 'EOF'
#!/usr/bin/env bash
echo "systemctl $*" >> "$FAKE/calls.log"
EOF
  chmod +x "$W/bin"/*
  export FAKE="$W/fake" PATH="$W/bin:$ORIG_PATH"
  unset FAKE_UID
  touch "$FAKE/ipt/DOCKER-USER"   # Docker is running: its chain exists
  cp "$DEPLOY_DIR/env/staging.env" "$W/staging.env"
}
guard() { bash "$GUARD" "$@" > "$W/out" 2>&1; }
rules() { cat "$FAKE/ipt/$1" 2> /dev/null; }
calls() { count "$1" "$FAKE/calls.log"; }

echo "== 1. the real environment files are valid and consistent"
new_world
for env_name in staging production; do
  guard validate "$DEPLOY_DIR/env/$env_name.env"; check "$env_name.env is valid" $? 0
done
check "staging and production use different networks" "$(grep '^EDGE_NETWORK=' "$DEPLOY_DIR/env/staging.env")" "EDGE_NETWORK=shopnest-staging-edge"
check "production has its own network name" "$(grep '^EDGE_NETWORK=' "$DEPLOY_DIR/env/production.env")" "EDGE_NETWORK=shopnest-production-edge"

echo "== 2. inconsistent settings are refused"
bad_setting() { # <label> <sed expression> <text expected in the output>
  new_world; sed -i "$2" "$W/staging.env"
  guard validate "$W/staging.env"; check "$1: refused" $? 1
  contains "$1: explains" "$W/out" "$3"
}
bad_setting "a backend address outside the subnet" 's/^BACKEND_BLUE_IP=.*/BACKEND_BLUE_IP=172.29.99.11/' "outside EDGE_SUBNET"
bad_setting "blue and green with the same address" 's/^BACKEND_GREEN_IP=.*/BACKEND_GREEN_IP=172.29.10.11/' "four different addresses"
bad_setting "nginx with the gateway's address" 's/^NGINX_IP=.*/NGINX_IP=172.29.10.1/' "four different addresses"
bad_setting "a fixed address inside the automatic range" 's/^BACKEND_BLUE_IP=.*/BACKEND_BLUE_IP=172.29.10.200/' "inside EDGE_IP_RANGE"
bad_setting "the network address" 's/^NGINX_IP=.*/NGINX_IP=172.29.10.0/' "network address"
bad_setting "the broadcast address" 's/^NGINX_IP=.*/NGINX_IP=172.29.10.255/' "broadcast address"
bad_setting "a huge subnet" 's#^EDGE_SUBNET=.*#EDGE_SUBNET=172.29.0.0/8#' "between /16 and /28"
bad_setting "a subnet that is not the one the addresses belong to (the metadata address's own /24)" 's#^EDGE_SUBNET=.*#EDGE_SUBNET=169.254.169.254/24#' "outside EDGE_SUBNET"
bad_setting "a malformed address" 's/^NGINX_IP=.*/NGINX_IP=172.29.10.999/' "not an IPv4 address"
bad_setting "a value with a shell metacharacter" 's/^EDGE_NETWORK=.*/EDGE_NETWORK=edge;touch pwned/' "not a plain value"
bad_setting "a missing setting" '/^BACKEND_GREEN_IP=/d' "BACKEND_GREEN_IP is not set"
bad_setting "a network name with a space" 's/^EDGE_NETWORK=.*/EDGE_NETWORK=edge net/' "not a plain value"
bad_setting "an automatic range outside the subnet" 's#^EDGE_IP_RANGE=.*#EDGE_IP_RANGE=172.29.20.128/25#' "not inside EDGE_SUBNET"
check "the settings file is parsed, never sourced (no command ran)" "$([ -e ./pwned ] && echo yes || echo no)" no
rm -f ./pwned
guard validate "$W/missing.env"; check "a missing file is refused" $? 1

echo "== 3. the rendered rules"
new_world
guard render "$W/staging.env"; check "render exit code" $? 0
check "exactly two ACCEPT rules" "$(grep -c -- '-j ACCEPT' "$W/out")" 2
contains "blue may reach the metadata service" "$W/out" "-A SHOPNEST-IMDS -s 172.29.10.11/32 -d 169.254.169.254/32 -j ACCEPT"
contains "green may reach the metadata service" "$W/out" "-A SHOPNEST-IMDS -s 172.29.10.12/32 -d 169.254.169.254/32 -j ACCEPT"
contains "everything else to the metadata service is dropped" "$W/out" "-A SHOPNEST-IMDS -d 169.254.169.254/32 -j DROP"
check "the DROP comes after both ACCEPT rules" "$(grep -n -- '-j DROP' "$W/out" | cut -d: -f1)" 5
check "nginx's address is never allowed" "$(grep -c '172.29.10.2/32' "$W/out")" 0
check "the chain is declared (so a restore replaces it atomically)" "$(grep -c '^:SHOPNEST-IMDS - \[0:0\]$' "$W/out")" 1
check "there is a COMMIT" "$(tail -n 1 "$W/out")" COMMIT
guard render "$DEPLOY_DIR/env/production.env"; contains "production renders its own addresses" "$W/out" "-s 172.29.20.11/32"

echo "== 4. apply installs the rules and the jump, atomically and idempotently"
new_world
guard apply "$W/staging.env"; check "apply exit code" $? 0
check "the chain is exactly the expected one" "$(rules SHOPNEST-IMDS | wc -l | tr -d ' ')" 4
check "the jump is the FIRST rule of DOCKER-USER" "$(rules DOCKER-USER | head -n 1)" "-A DOCKER-USER -j SHOPNEST-IMDS"
check "one restore, with --noflush (Docker's own rules are never flushed)" "$(calls '^iptables-restore --noflush$')" 1
guard apply "$W/staging.env"; check "a second apply succeeds" $? 0
check "there is still exactly one jump" "$(rules DOCKER-USER | grep -c -- '-j SHOPNEST-IMDS')" 1
echo "-A DOCKER-USER -j DOCKER-ISOLATION" > "$FAKE/ipt/DOCKER-USER.tmp"; cat "$FAKE/ipt/DOCKER-USER" >> "$FAKE/ipt/DOCKER-USER.tmp"; mv "$FAKE/ipt/DOCKER-USER.tmp" "$FAKE/ipt/DOCKER-USER"
guard apply "$W/staging.env"; check "apply after another rule was put in front" $? 0
check "the jump is first again" "$(rules DOCKER-USER | head -n 1)" "-A DOCKER-USER -j SHOPNEST-IMDS"
check "the other rule was kept" "$(rules DOCKER-USER | grep -c DOCKER-ISOLATION)" 1

echo "== 5. apply fails closed"
new_world; rm "$FAKE/ipt/DOCKER-USER"
guard apply "$W/staging.env"; check "no DOCKER-USER chain (Docker not running): refused" $? 1
contains "it says the guard is NOT in place" "$W/out" "NOT in place"
check "nothing was loaded" "$(calls '^iptables-restore')" 0
new_world; FAKE_UID=1000 guard apply "$W/staging.env"; check "apply without root is refused" $? 1
contains "explains" "$W/out" "must run as root"
check "no rule was touched" "$(calls '^iptables')" 0
new_world; sed -i 's/^NGINX_IP=.*/NGINX_IP=172.29.99.2/' "$W/staging.env"; guard apply "$W/staging.env"; check "invalid settings: apply refused before any rule is touched" $? 1
check "no rule was touched" "$(calls '^iptables')" 0

echo "== 6. check detects every kind of drift"
new_world; guard apply "$W/staging.env" > /dev/null
guard check "$W/staging.env"; check "a freshly applied guard passes" $? 0
grep -v -- '-j DROP' "$FAKE/ipt/SHOPNEST-IMDS" > "$FAKE/ipt/x" && mv "$FAKE/ipt/x" "$FAKE/ipt/SHOPNEST-IMDS"
guard check "$W/staging.env"; check "a missing DROP rule is detected" $? 1
new_world; guard apply "$W/staging.env" > /dev/null
sed -i '2i -A SHOPNEST-IMDS -s 172.29.10.2/32 -d 169.254.169.254/32 -j ACCEPT' "$FAKE/ipt/SHOPNEST-IMDS"
guard check "$W/staging.env"; check "an extra ACCEPT (nginx allowed) is detected" $? 1
new_world; guard apply "$W/staging.env" > /dev/null
grep -v 'SHOPNEST-IMDS$' "$FAKE/ipt/DOCKER-USER" > "$FAKE/ipt/x"; mv "$FAKE/ipt/x" "$FAKE/ipt/DOCKER-USER"
guard check "$W/staging.env"; check "a removed jump is detected" $? 1
new_world; guard apply "$W/staging.env" > /dev/null
echo "-A DOCKER-USER -j SHOPNEST-IMDS" >> "$FAKE/ipt/DOCKER-USER"
guard check "$W/staging.env"; check "a duplicate jump is detected" $? 1
new_world; guard apply "$W/staging.env" > /dev/null
{ echo "-A DOCKER-USER -j RETURN"; cat "$FAKE/ipt/DOCKER-USER"; } > "$FAKE/ipt/x"; mv "$FAKE/ipt/x" "$FAKE/ipt/DOCKER-USER"
guard check "$W/staging.env"; check "a rule in front of the jump is detected" $? 1
new_world; guard check "$W/staging.env"; check "no rules at all is detected" $? 1

echo "== 7. the Docker network is created once, with the fixed subnet, and never silently changed"
new_world
guard ensure-network "$W/staging.env"; check "creates the network" $? 0
check "created once" "$(calls '^docker network create')" 1
contains "with the fixed subnet" "$FAKE/calls.log" "--subnet 172.29.10.0/24"
contains "with the automatic range" "$FAKE/calls.log" "--ip-range 172.29.10.128/25"
contains "with the gateway" "$FAKE/calls.log" "--gateway 172.29.10.1"
contains "named from the settings" "$FAKE/calls.log" "shopnest-staging-edge"
guard ensure-network "$W/staging.env"; check "a second run succeeds" $? 0
check "and creates nothing" "$(calls '^docker network create')" 1
new_world; echo "172.29.77.0/24" > "$FAKE/networks/shopnest-staging-edge"
guard ensure-network "$W/staging.env"; check "an existing network with another subnet is refused" $? 1
contains "explains" "$W/out" "refusing to change it"
check "it was not created or removed" "$(calls '^docker network \(create\|rm\)')" 0

echo "== 8. verify proves the isolation, and fails closed"
new_world; guard apply "$W/staging.env" > /dev/null
guard verify "$W/staging.env" shopnest-backend:test shopnest-staging-nginx-1; check "isolated: verify passes" $? 0
contains "reports the probe result" "$W/out" "probe container on shopnest-staging-edge cannot reach"
contains "reports the nginx result" "$W/out" "nginx container cannot reach"
contains "the probe runs on the guarded network" "$FAKE/calls.log" "--network shopnest-staging-edge"
contains "the probe has no capabilities" "$FAKE/calls.log" "--cap-drop ALL"
contains "the probe cannot gain privileges" "$FAKE/calls.log" "--security-opt no-new-privileges"
absent "the probe is NOT given a fixed address (so it can never be an allowed one)" "$FAKE/calls.log" "--ip "
touch "$FAKE/probe_reachable"; guard verify "$W/staging.env" shopnest-backend:test; check "a probe that CAN reach the metadata service fails the verify" $? 1
contains "FAIL CLOSED" "$W/out" "FAIL CLOSED: a probe container CAN reach"
rm "$FAKE/probe_reachable"; touch "$FAKE/probe_error"; guard verify "$W/staging.env" shopnest-backend:test; check "a probe that cannot run fails the verify (unconfirmed is not isolated)" $? 1
contains "explains" "$W/out" "could not run"
rm "$FAKE/probe_error"; touch "$FAKE/nginx_reachable"; guard verify "$W/staging.env" shopnest-backend:test shopnest-staging-nginx-1; check "nginx that CAN reach the metadata service fails the verify" $? 1
contains "explains" "$W/out" "nginx container CAN reach"
rm "$FAKE/nginx_reachable"
new_world; guard verify "$W/staging.env" shopnest-backend:test; check "no rules in place: verify refuses" $? 1
check "and never ran a probe" "$(calls '^docker run')" 0
new_world; guard apply "$W/staging.env" > /dev/null; guard verify "$W/staging.env"; check "verify without an image is refused" $? 1

echo "== 9. the installer"
new_world; export GUARD_ROOT="$W/root"
bash "$INSTALL" "$DEPLOY_DIR/env/staging.env" > "$W/out" 2>&1; check "install exit code" $? 0
check "the guard is installed at the fixed path" "$([ -x "$GUARD_ROOT/usr/local/sbin/shopnest-imds-guard" ] && echo yes || echo no)" yes
check "it is the same script" "$(cmp -s "$GUARD" "$GUARD_ROOT/usr/local/sbin/shopnest-imds-guard" && echo same || echo different)" same
for unit in shopnest-imds-guard.service shopnest-imds-guard-check.service shopnest-imds-guard-check.timer; do
  check "unit installed: $unit" "$([ -f "$GUARD_ROOT/etc/systemd/system/$unit" ] && echo yes || echo no)" yes
done
check "edge.env has exactly the seven EDGE settings and a comment" "$(grep -cE '^[A-Z_]+=' "$GUARD_ROOT/etc/shopnest/edge.env")" 7
absent "edge.env does not carry unrelated settings" "$GUARD_ROOT/etc/shopnest/edge.env" "HTTP_PORT"
absent "edge.env does not carry unrelated settings (version)" "$GUARD_ROOT/etc/shopnest/edge.env" "APP_VERSION"
check "the installed settings are valid for the installed guard" "$(bash "$GUARD_ROOT/usr/local/sbin/shopnest-imds-guard" validate "$GUARD_ROOT/etc/shopnest/edge.env" > /dev/null 2>&1; echo $?)" 0
contains "systemd was reloaded" "$FAKE/calls.log" "systemctl daemon-reload"
contains "the guard service and timer are enabled" "$FAKE/calls.log" "systemctl enable shopnest-imds-guard.service shopnest-imds-guard-check.timer"
contains "the timer is started" "$FAKE/calls.log" "systemctl start shopnest-imds-guard-check.timer"
bash "$INSTALL" "$DEPLOY_DIR/env/staging.env" > "$W/out" 2>&1; check "installing again is safe" $? 0
new_world; export GUARD_ROOT="$W/root"; sed 's/^NGINX_IP=.*/NGINX_IP=172.29.99.2/' "$DEPLOY_DIR/env/staging.env" > "$W/bad.env"
bash "$INSTALL" "$W/bad.env" > "$W/out" 2>&1; check "an invalid settings file is refused" $? 1
check "nothing was installed" "$([ -e "$GUARD_ROOT/usr/local/sbin" ] && echo yes || echo no)" no
bash "$INSTALL" > "$W/out" 2>&1; check "a missing argument is refused" $? 2
unset GUARD_ROOT

echo "== 10. the systemd units"
SVC="$DEPLOY_DIR/host/shopnest-imds-guard.service"
contains "starts after Docker" "$SVC" "After=docker.service"
contains "is re-run when Docker restarts" "$SVC" "PartOf=docker.service"
contains "creates the network before applying the rules" "$SVC" "ExecStart=/usr/local/sbin/shopnest-imds-guard ensure-network /etc/shopnest/edge.env"
contains "applies the rules" "$SVC" "ExecStart=/usr/local/sbin/shopnest-imds-guard apply /etc/shopnest/edge.env"
contains "is wanted at boot" "$SVC" "WantedBy=multi-user.target"
contains "the periodic check re-applies on drift" "$DEPLOY_DIR/host/shopnest-imds-guard-check.service" "check /etc/shopnest/edge.env ||"
contains "the timer runs every minute" "$DEPLOY_DIR/host/shopnest-imds-guard-check.timer" "OnUnitActiveSec=60"
contains "the boot race is documented as unproven" "$SVC" "UNPROVEN"

echo "== 11. the AWS Compose file (static)"
PROD="$DEPLOY_DIR/docker-compose.prod.yml"
contains "the network is external" "$PROD" "external: true"
contains "its name comes from the settings" "$PROD" 'name: ${EDGE_NETWORK:?EDGE_NETWORK is required}'
contains "blue has a fixed address from the settings" "$PROD" 'ipv4_address: ${BACKEND_BLUE_IP:?BACKEND_BLUE_IP is required}'
contains "green has a fixed address from the settings" "$PROD" 'ipv4_address: ${BACKEND_GREEN_IP:?BACKEND_GREEN_IP is required}'
contains "nginx has a fixed address from the settings" "$PROD" 'ipv4_address: ${NGINX_IP:?NGINX_IP is required}'
contains "every container drops all capabilities" "$PROD" "cap_drop: [ALL]"
contains "no container can gain privileges" "$PROD" 'no-new-privileges:true'
check "migrate is not an AWS service" "$(grep -cE '^  migrate:' "$PROD")" 0
check "seed is not an AWS service" "$(grep -cE '^  seed:' "$PROD")" 0
check "no owner or master secret id is mentioned outside comments" "$(grep -v '^[[:space:]]*#' "$PROD" | grep -ciE 'OWNER|MASTER')" 0
check "no DATABASE_URL" "$(grep -v '^[[:space:]]*#' "$PROD" | grep -c 'DATABASE_URL')" 0
check "no host mount of a CA file or secret (volume entries only)" "$(grep -v '^[[:space:]]*#' "$PROD" | grep -E '^[[:space:]]+- ' | grep -cE '\.pem|secrets')" 0
check "the pinned CA bundle path is inside the image" "$(grep -c 'DB_SSL_CA_FILE: /app/certs/rds-global-bundle.pem' "$PROD")" 1
LOCAL="$DEPLOY_DIR/docker-compose.local-db.yml"
contains "the local file replaces the external network" "$LOCAL" "edge: !override {}"
contains "the local file defines migrate (AWS does not)" "$LOCAL" "  migrate:"
contains "the local file defines seed (AWS does not)" "$LOCAL" "  seed:"
contains "the local file says it is rehearsal only" "$LOCAL" "LOCAL REHEARSAL ONLY"

echo
echo "imds-guard tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
