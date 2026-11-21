#!/usr/bin/env bash
# Host guard for the EC2 instance metadata service (IMDS), run as root on the application instance.
#
# WHY: IMDSv2 keeps its hop limit at 2 so the BACKEND container can reach the instance role (it reads the db-app secret
# with the AWS SDK). Left alone, that lets EVERY container on the host read the same credentials. This guard lets only
# the two backend containers (blue and green) reach 169.254.169.254; nginx, a probe, or any other container is dropped.
#
# HOW: the containers live on a dedicated, EXTERNAL Docker network with a fixed subnet and fixed addresses; this script
# creates that network and installs iptables rules, in the DOCKER-USER chain, that match those addresses. The addresses
# come from ONE file (the environment's EDGE_* settings), which Compose and this script both read.
#
#   imds-guard.sh validate       <edge.env>             check the settings are consistent (no root needed)
#   imds-guard.sh render         <edge.env>             print the iptables-restore input (no root needed)
#   imds-guard.sh export-edge    <edge.env>             print only the EDGE_* settings, validated
#   imds-guard.sh ensure-network <edge.env>             create the Docker network, or refuse if it differs
#   imds-guard.sh apply          <edge.env>             install the rules (atomically) and the jump from DOCKER-USER
#   imds-guard.sh check          <edge.env>             exit 1 unless the rules are exactly the expected ones
#   imds-guard.sh verify         <edge.env> <image> [<nginx container>]   check, then PROVE a probe and nginx cannot reach IMDS
#
# What this does NOT claim: that isolation is proven. That only comes from the instance-level tests in
# docs/AWS_STAGING_INTEGRATION.md. Residual risk: a compromised backend still holds the instance role.
set -euo pipefail

IMDS=169.254.169.254
CHAIN=SHOPNEST-IMDS
KEYS=(EDGE_NETWORK EDGE_SUBNET EDGE_IP_RANGE EDGE_GATEWAY NGINX_IP BACKEND_BLUE_IP BACKEND_GREEN_IP)

die() { echo "imds-guard: ERROR: $*" >&2; exit 1; }
usage() { sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//' | sed '$d' >&2; exit 2; }

# ---- settings: PARSED, never sourced -------------------------------------------------------------------------------
read_settings() { # <file>: export only the known EDGE_* keys, plain values only
  local file="$1" line key value k allowed n=0
  [ -f "$file" ] || die "missing settings file $file"
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    line="${line%$'\r'}"
    [[ -z "$line" || "$line" == \#* ]] && continue
    [[ "$line" =~ ^([A-Z][A-Z0-9_]*)=(.*)$ ]] || continue   # the shared env file holds other settings too
    key="${BASH_REMATCH[1]}"
    value="${BASH_REMATCH[2]}"
    allowed=0
    for k in "${KEYS[@]}"; do [ "$k" = "$key" ] && allowed=1; done
    [ "$allowed" = 1 ] || continue
    [[ "$value" =~ ^[A-Za-z0-9._/-]+$ ]] || die "$file line $n: the value of $key is not a plain value"
    printf -v "$key" '%s' "$value"
    # shellcheck disable=SC2163
    export "$key"
  done < "$file"
  for k in "${KEYS[@]}"; do [ -n "${!k:-}" ] || die "$k is not set in $file"; done
}

# ---- IPv4 arithmetic (bash only) -------------------------------------------------------------------------------------
ip_ok() { [[ "$1" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] && [ "${BASH_REMATCH[1]}" -le 255 ] && [ "${BASH_REMATCH[2]}" -le 255 ] && [ "${BASH_REMATCH[3]}" -le 255 ] && [ "${BASH_REMATCH[4]}" -le 255 ]; }
ip2int() { local a b c d; IFS=. read -r a b c d <<< "$1"; echo $(((a << 24) | (b << 16) | (c << 8) | d)); }
cidr_ok() { # BASH_REMATCH is overwritten by every [[ =~ ]], so the parts are copied out first
  local addr len
  [[ "$1" =~ ^([0-9.]+)/([0-9]{1,2})$ ]] || return 1
  addr="${BASH_REMATCH[1]}"
  len="${BASH_REMATCH[2]}"
  ip_ok "$addr" && [ "$len" -ge 16 ] && [ "$len" -le 28 ]
}
cidr_first() { local ip="${1%/*}" len="${1#*/}"; echo $(($(ip2int "$ip") & (0xFFFFFFFF << (32 - len) & 0xFFFFFFFF))); }
cidr_last() { local len="${1#*/}"; echo $(($(cidr_first "$1") | (0xFFFFFFFF >> len))); }
in_cidr() { local v; v="$(ip2int "$1")"; [ "$v" -ge "$(cidr_first "$2")" ] && [ "$v" -le "$(cidr_last "$2")" ]; }

validate_settings() {
  [[ "$EDGE_NETWORK" =~ ^[a-z0-9][a-z0-9_.-]*$ ]] || die "EDGE_NETWORK is not a plain network name"
  cidr_ok "$EDGE_SUBNET" || die "EDGE_SUBNET must be an IPv4 CIDR with a prefix between /16 and /28"
  cidr_ok "$EDGE_IP_RANGE" || die "EDGE_IP_RANGE must be an IPv4 CIDR with a prefix between /16 and /28"
  [ "$(cidr_first "$EDGE_SUBNET")" -ge 0 ] || die "EDGE_SUBNET is not valid"
  local ip
  for ip in "$EDGE_GATEWAY" "$NGINX_IP" "$BACKEND_BLUE_IP" "$BACKEND_GREEN_IP"; do
    ip_ok "$ip" || die "$ip is not an IPv4 address"
    in_cidr "$ip" "$EDGE_SUBNET" || die "$ip is outside EDGE_SUBNET ($EDGE_SUBNET)"
    [ "$(ip2int "$ip")" != "$(cidr_first "$EDGE_SUBNET")" ] || die "$ip is the network address"
    [ "$(ip2int "$ip")" != "$(cidr_last "$EDGE_SUBNET")" ] || die "$ip is the broadcast address"
    # The fixed addresses must never be handed out automatically to some other container.
    if [ "$ip" != "$EDGE_GATEWAY" ]; then in_cidr "$ip" "$EDGE_IP_RANGE" && die "$ip is inside EDGE_IP_RANGE: an automatically assigned container could take it"; fi
  done
  in_cidr "${EDGE_IP_RANGE%/*}" "$EDGE_SUBNET" && in_cidr "$(ip2int_back "$(cidr_last "$EDGE_IP_RANGE")")" "$EDGE_SUBNET" || die "EDGE_IP_RANGE is not inside EDGE_SUBNET"
  [ "$NGINX_IP" != "$BACKEND_BLUE_IP" ] && [ "$NGINX_IP" != "$BACKEND_GREEN_IP" ] && [ "$BACKEND_BLUE_IP" != "$BACKEND_GREEN_IP" ] \
    && [ "$EDGE_GATEWAY" != "$NGINX_IP" ] && [ "$EDGE_GATEWAY" != "$BACKEND_BLUE_IP" ] && [ "$EDGE_GATEWAY" != "$BACKEND_GREEN_IP" ] \
    || die "the gateway, nginx and the two backends must have four different addresses"
  # The metadata service must not be inside the container network.
  in_cidr "$IMDS" "$EDGE_SUBNET" && die "EDGE_SUBNET must not contain the metadata address"
  return 0
}
ip2int_back() { local n="$1"; echo "$(((n >> 24) & 255)).$(((n >> 16) & 255)).$(((n >> 8) & 255)).$((n & 255))"; }

# ---- the rules ---------------------------------------------------------------------------------------------------------
render() {
  cat << EOF
*filter
:$CHAIN - [0:0]
-A $CHAIN -s $BACKEND_BLUE_IP/32 -d $IMDS/32 -j ACCEPT
-A $CHAIN -s $BACKEND_GREEN_IP/32 -d $IMDS/32 -j ACCEPT
-A $CHAIN -d $IMDS/32 -j DROP
-A $CHAIN -j RETURN
COMMIT
EOF
}
expected_chain() { # the output of `iptables -S SHOPNEST-IMDS` for the rendered rules
  printf '%s\n' "-N $CHAIN" \
    "-A $CHAIN -s $BACKEND_BLUE_IP/32 -d $IMDS/32 -j ACCEPT" \
    "-A $CHAIN -s $BACKEND_GREEN_IP/32 -d $IMDS/32 -j ACCEPT" \
    "-A $CHAIN -d $IMDS/32 -j DROP" \
    "-A $CHAIN -j RETURN"
}

need_root() { [ "$(id -u)" = 0 ] || die "$1 must run as root"; }

jump_is_first() { [ "$(iptables -S DOCKER-USER | sed -n '2p')" = "-A DOCKER-USER -j $CHAIN" ]; }

cmd_ensure_network() {
  need_root ensure-network
  local found
  if docker network inspect "$EDGE_NETWORK" > /dev/null 2>&1; then
    found="$(docker network inspect -f '{{range .IPAM.Config}}{{.Subnet}} {{end}}' "$EDGE_NETWORK" | tr -d '[:space:]')"
    [ "$found" = "$EDGE_SUBNET" ] || die "network $EDGE_NETWORK exists with subnet '$found', not $EDGE_SUBNET; refusing to change it (the firewall rules depend on the addresses)"
    echo "imds-guard: network $EDGE_NETWORK already exists with the expected subnet"
  else
    docker network create --driver bridge --subnet "$EDGE_SUBNET" --ip-range "$EDGE_IP_RANGE" --gateway "$EDGE_GATEWAY" --label shopnest.managed=true "$EDGE_NETWORK" > /dev/null \
      || die "could not create network $EDGE_NETWORK"
    echo "imds-guard: created network $EDGE_NETWORK ($EDGE_SUBNET)"
  fi
}

cmd_apply() {
  need_root apply
  # Fail closed: without Docker's own chain there is nowhere to put the rules, and containers would be unprotected.
  iptables -S DOCKER-USER > /dev/null 2>&1 || die "the DOCKER-USER chain does not exist (is Docker running?); the metadata guard is NOT in place"
  # One atomic step: the chain is replaced in a single transaction, so there is no moment without rules.
  render | iptables-restore --noflush || die "could not load the rules"
  # The jump must exist exactly once and be the FIRST rule of DOCKER-USER.
  while iptables -D DOCKER-USER -j "$CHAIN" 2> /dev/null; do :; done
  iptables -I DOCKER-USER 1 -j "$CHAIN" || die "could not insert the jump into DOCKER-USER"
  echo "imds-guard: rules applied (backends $BACKEND_BLUE_IP and $BACKEND_GREEN_IP may reach the metadata service; every other container is dropped)"
}

cmd_check() {
  iptables -S DOCKER-USER > /dev/null 2>&1 || { echo "imds-guard: DOCKER-USER chain missing" >&2; return 1; }
  [ "$(iptables -S "$CHAIN" 2> /dev/null)" = "$(expected_chain)" ] || { echo "imds-guard: the $CHAIN rules are missing or differ from the expected ones" >&2; return 1; }
  jump_is_first || { echo "imds-guard: the jump to $CHAIN is not the first rule of DOCKER-USER" >&2; return 1; }
  [ "$(iptables -S DOCKER-USER | grep -c -- "-j $CHAIN")" = 1 ] || { echo "imds-guard: the jump to $CHAIN exists more than once" >&2; return 1; }
}

# The probe: a throwaway container on the guarded network, NOT at an allowed address, with no capabilities. It tries a
# TCP connection to the metadata address. Exit 7 means "could not connect" (the wanted result); 0 means it CONNECTED.
PROBE_JS="const s=require('net').connect({host:'$IMDS',port:80});s.setTimeout(3000,()=>process.exit(7));s.on('connect',()=>{console.log('REACHABLE');process.exit(0)});s.on('error',()=>process.exit(7));"

cmd_verify() {
  need_root verify
  local image="${1:-}" nginx_container="${2:-}" rc=0
  [ -n "$image" ] || die "verify needs an image to run the probe from"
  cmd_check || die "the rules are not in place: refusing (fail closed)"
  docker run --rm --network "$EDGE_NETWORK" --cap-drop ALL --security-opt no-new-privileges --entrypoint node "$image" -e "$PROBE_JS" > /dev/null 2>&1 || rc=$?
  case "$rc" in
    7) echo "imds-guard: ok: a probe container on $EDGE_NETWORK cannot reach the metadata service" ;;
    0) die "FAIL CLOSED: a probe container CAN reach the metadata service" ;;
    *) die "FAIL CLOSED: the probe could not run (exit $rc), so isolation is unconfirmed" ;;
  esac
  if [ -n "$nginx_container" ]; then
    if docker exec "$nginx_container" wget -q -T 3 -O /dev/null "http://$IMDS/latest/meta-data/" > /dev/null 2>&1; then
      die "FAIL CLOSED: the nginx container CAN reach the metadata service"
    fi
    echo "imds-guard: ok: the nginx container cannot reach the metadata service"
  fi
}

command="${1:-}"
file="${2:-}"
[ -n "$command" ] && [ -n "$file" ] || usage
shift 2
read_settings "$file"
validate_settings

case "$command" in
  validate) echo "imds-guard: settings are consistent" ;;
  render) render ;;
  export-edge) for k in "${KEYS[@]}"; do printf '%s=%s\n' "$k" "${!k}"; done ;;
  ensure-network) cmd_ensure_network ;;
  apply) cmd_apply ;;
  check) cmd_check ;;
  verify) cmd_verify "$@" ;;
  *) usage ;;
esac
