#!/usr/bin/env bash
# Runs ONE release action on the lab instance over real SSH, through an AWS Systems Manager port-forwarding tunnel. The instance has no
# inbound SSH port: the tunnel is opened with the job's short-lived OIDC credentials, SSH runs through it to the unprivileged `deploy`
# user, and that user can only start the two root-owned wrappers (deploy/host/shopnest-release.sh) through the key's forced command
# (deploy/host/shopnest-ssh-entry.sh).
#
#   ssh-deploy.sh deploy   --environment <staging|production> --instance <i-...> --region <region> --sha <40-hex>
#                          --image-ref <ghcr.io/OWNER/shopnest-backend@sha256:...> --frontend-ref <ghcr.io/OWNER/shopnest-frontend@sha256:...>
#                          [--seed] [--local-port <port>] [--log-file <file>] [--preflight-only]
#   ssh-deploy.sh rollback --environment <staging|production> --instance <i-...> --region <region> --sha <40-hex earlier release>
#                          --carrier-sha <40-hex commit of main> [--local-port <port>] [--log-file <file>]
#
# Environment (never arguments, never printed):
#   DEPLOY_SSH_KEY   the PRIVATE key of this environment (a GitHub Environment secret): OpenSSH ed25519, no passphrase
#   SSH_HOST_KEY     the PUBLIC host key of the instance, "ssh-ed25519 AAAA..." (a GitHub Environment variable): pinned, so
#                    StrictHostKeyChecking can stay "yes" and the first connection is not trusted blindly
# The AWS credentials come from the environment too (the OIDC step of the workflow).
#
# --preflight-only stops after the pre-flight (nothing is started on the host): it proves the tunnel, the key, the pinned host key, the
# key's environment binding and the argument check, which is what the ssh-preflight workflow uses.
# What it does, in order: check the arguments, write the key and the known_hosts file to a private temporary directory, open the tunnel,
# wait for it, run the wrapper's --check (proves the tunnel, the key, the pinned host key and the arguments before anything starts),
# run the real command, confirm from the host's own output that THIS commit went live from THIS image digest, and then -- on every
# path, including failure, a signal or a bad key -- terminate the SSM session, stop the tunnel process and delete the key.
# The private key is written once, to a mode 600 file in a mode 700 directory, never to a log, never to an argument list.
#
# Exit codes (the same meaning as the deploy scripts):
#   0 done and confirmed; 1 failed, the previous release is serving; 3 failed AND the automatic rollback failed (an operator is needed
#   now); 4 the result could not be confirmed (no tunnel, no connection, the host refused, or the success was not confirmed);
#   2 bad arguments.
set -uo pipefail
set +x

usage_error() { echo "ssh-deploy: ERROR: $*" >&2; exit 2; }
needs_value() { [ "$#" -ge 2 ] || usage_error "$1 needs a value"; } # needs_value "$@": the option is followed by something

ACTION="${1:-}"
[ $# -eq 0 ] || shift
case "$ACTION" in deploy | rollback) ;; *) usage_error "the first argument must be deploy or rollback" ;; esac

ENVIRONMENT="" INSTANCE="" REGION="" SHA="" IMAGE_REF="" FRONTEND_REF="" CARRIER_SHA="" SEED=0 PORT=2222 LOG_FILE="" PREFLIGHT_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --environment) needs_value "$@"; ENVIRONMENT="$2"; shift 2 ;;
    --instance) needs_value "$@"; INSTANCE="$2"; shift 2 ;;
    --region) needs_value "$@"; REGION="$2"; shift 2 ;;
    --sha) needs_value "$@"; SHA="$2"; shift 2 ;;
    --image-ref) needs_value "$@"; IMAGE_REF="$2"; shift 2 ;;
    --frontend-ref) needs_value "$@"; FRONTEND_REF="$2"; shift 2 ;;
    --carrier-sha) needs_value "$@"; CARRIER_SHA="$2"; shift 2 ;;
    --seed) SEED=1; shift ;;
    --preflight-only) PREFLIGHT_ONLY=1; shift ;;
    --local-port) needs_value "$@"; PORT="$2"; shift 2 ;;
    --log-file) needs_value "$@"; LOG_FILE="$2"; shift 2 ;;
    *) usage_error "unknown argument: $1" ;;
  esac
done

[[ $ENVIRONMENT =~ ^(staging|production)$ ]] || usage_error "--environment must be staging or production"
[[ $INSTANCE =~ ^i-[0-9a-f]{8,17}$ ]] || usage_error "--instance must be an instance id"
[[ $REGION =~ ^[a-z]{2}-[a-z]+-[0-9]$ ]] || usage_error "--region is not a region"
[[ $SHA =~ ^[0-9a-f]{40}$ ]] || usage_error "--sha must be a full 40-character lowercase commit"
[[ $PORT =~ ^[0-9]{4,5}$ ]] && [ "$PORT" -ge 1024 ] && [ "$PORT" -le 65535 ] || usage_error "--local-port must be an unprivileged port (1024-65535)"
if [ "$ACTION" = deploy ]; then
  [[ $IMAGE_REF =~ ^ghcr\.io/[a-z0-9][a-z0-9-]*/shopnest-backend@sha256:[0-9a-f]{64}$ ]] || usage_error "--image-ref must be a GHCR backend image DIGEST"
  [[ $FRONTEND_REF =~ ^ghcr\.io/[a-z0-9][a-z0-9-]*/shopnest-frontend@sha256:[0-9a-f]{64}$ ]] || usage_error "--frontend-ref must be a GHCR frontend image DIGEST"
  [ "$SEED" = 0 ] || [ "$ENVIRONMENT" = staging ] || usage_error "--seed is only allowed for staging"
  [ -z "$CARRIER_SHA" ] || usage_error "--carrier-sha belongs to rollback"
else
  [[ $CARRIER_SHA =~ ^[0-9a-f]{40}$ ]] || usage_error "--carrier-sha must be a full 40-character lowercase commit"
  [ -z "$IMAGE_REF$FRONTEND_REF" ] && [ "$SEED" = 0 ] || usage_error "--image-ref, --frontend-ref and --seed belong to deploy"
fi
[ -n "${DEPLOY_SSH_KEY:-}" ] || usage_error "DEPLOY_SSH_KEY is not set (the ${ENVIRONMENT} Environment's secret)"
[[ ${SSH_HOST_KEY:-} =~ ^ssh-ed25519\ [A-Za-z0-9+/]{68}$ ]] || usage_error "SSH_HOST_KEY must be the host's public key, 'ssh-ed25519 AAAA...' (the ${ENVIRONMENT} Environment's variable)"
for tool in aws ssh ssh-keygen session-manager-plugin; do
  command -v "$tool" > /dev/null 2>&1 || { echo "ssh-deploy: ERROR: $tool is not installed (deploy/ci/install-ssm-plugin.sh installs the plugin)" >&2; exit 4; }
done

umask 077
TMP="$(mktemp -d)" || { echo "ssh-deploy: ERROR: no temporary directory" >&2; exit 4; }
chmod 700 "$TMP"
KEY="$TMP/id_ed25519"
KNOWN_HOSTS="$TMP/known_hosts"
TUNNEL_LOG="$TMP/tunnel.log"
SESSION_LOG="${LOG_FILE:-$TMP/run.log}"
[ -z "$LOG_FILE" ] || : > "$LOG_FILE"
: >> "$SESSION_LOG"
TUNNEL_PID=""
SESSION_ID=""

emit() { printf '%s\n' "$*" | tee -a "$SESSION_LOG"; }
# AWS error text names the account and the instance (for example in an AccessDenied ARN). They are identifiers, not credentials, but they
# do not belong in a public job log or its artifact: a 12-digit number standing alone and an instance id are replaced. (Only the error text
# of the tunnel and of the pre-flight goes through this; the host's own deploy output is kept as it is, because the success check reads it.)
redact() { sed -E 's/(^|[^0-9A-Za-z])[0-9]{12}([^0-9A-Za-z]|$)/\1<account>\2/g; s/(^|[^0-9A-Za-z-])i-[0-9a-f]{8,17}([^0-9A-Za-z]|$)/\1<instance>\2/g'; }

# Runs on EVERY exit path (success, failure, a bad key, SIGINT/SIGTERM): end the SSM session, stop the tunnel, delete the key.
cleanup() {
  local rc=$?
  trap - EXIT INT TERM HUP
  if [ -n "$SESSION_ID" ]; then
    aws ssm terminate-session --region "$REGION" --session-id "$SESSION_ID" > /dev/null 2>&1 || echo "ssh-deploy: warning: could not terminate SSM session $SESSION_ID (it ends when the tunnel process stops)" >&2
  fi
  if [ -n "$TUNNEL_PID" ]; then
    kill -TERM -- "-$TUNNEL_PID" 2> /dev/null || kill -TERM "$TUNNEL_PID" 2> /dev/null || true
    for _ in 1 2 3 4 5; do kill -0 "$TUNNEL_PID" 2> /dev/null || break; sleep 1; done
    if kill -0 "$TUNNEL_PID" 2> /dev/null; then kill -KILL -- "-$TUNNEL_PID" 2> /dev/null || kill -KILL "$TUNNEL_PID" 2> /dev/null || true; fi
    wait "$TUNNEL_PID" 2> /dev/null || true
    echo "ssh-deploy: tunnel closed"
  fi
  [ ! -f "$KEY" ] || shred -u "$KEY" 2> /dev/null || rm -f "$KEY"
  rm -rf "$TMP"
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

# The private key: written once, never echoed. The variable is dropped from the environment straight away.
printf '%s\n' "$DEPLOY_SSH_KEY" > "$KEY"
unset DEPLOY_SSH_KEY
chmod 600 "$KEY"
if ! ssh-keygen -y -P '' -f "$KEY" > "$TMP/id.pub" 2> /dev/null; then
  emit "ssh-deploy: ERROR: DEPLOY_SSH_KEY is not a valid, unencrypted OpenSSH private key"
  exit 4
fi
grep -q '^ssh-ed25519 ' "$TMP/id.pub" || { emit "ssh-deploy: ERROR: DEPLOY_SSH_KEY is not an ed25519 key"; exit 4; }
emit "ssh-deploy: ${ACTION} ${ENVIRONMENT} ${SHA}; key $(ssh-keygen -l -f "$TMP/id.pub" | awk '{print $2}') (public fingerprint)"

# The pinned host key. The tunnel's local end is 127.0.0.1:PORT, so that is the name the key is recorded under.
printf '[127.0.0.1]:%s %s\n' "$PORT" "$SSH_HOST_KEY" > "$KNOWN_HOSTS"

ssh_run() { # ssh_run <the one remote command>: strict host key checking against the pinned key, key only, no agent, no tty
  ssh -F /dev/null -p "$PORT" -i "$KEY" \
    -o IdentitiesOnly=yes -o IdentityAgent=none \
    -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$KNOWN_HOSTS" -o GlobalKnownHostsFile=/dev/null -o HashKnownHosts=no \
    -o BatchMode=yes -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no -o PubkeyAuthentication=yes \
    -o ConnectTimeout=20 -o ServerAliveInterval=15 -o ServerAliveCountMax=8 -o LogLevel=ERROR \
    -T "deploy@127.0.0.1" "$1"
}

# ---- the tunnel ----------------------------------------------------------------------------------------------------------------
PARAMS="{\"portNumber\":[\"22\"],\"localPortNumber\":[\"${PORT}\"]}"
START=(aws ssm start-session --region "$REGION" --target "$INSTANCE" --document-name AWS-StartPortForwardingSession --parameters "$PARAMS")
# Its own session (and so its own process group) where setsid exists, so one signal ends the AWS CLI and the plugin it spawned.
if command -v setsid > /dev/null 2>&1; then
  setsid "${START[@]}" > "$TUNNEL_LOG" 2>&1 &
else
  "${START[@]}" > "$TUNNEL_LOG" 2>&1 &
fi
TUNNEL_PID=$!
emit "ssh-deploy: opening the SSM port-forwarding tunnel to the instance (local port ${PORT})"

up=0
for _ in $(seq 1 45); do
  if ! kill -0 "$TUNNEL_PID" 2> /dev/null; then
    emit "ssh-deploy: ERROR: the tunnel process ended before it was ready:"
    sed 's/^/  tunnel: /' "$TUNNEL_LOG" | redact | tee -a "$SESSION_LOG"
    exit 4
  fi
  if grep -q 'Waiting for connections' "$TUNNEL_LOG" 2> /dev/null; then up=1; break; fi
  sleep 2
done
SESSION_ID="$(sed -n 's/^Starting session with SessionId: *//p' "$TUNNEL_LOG" | head -n 1 | tr -d '\r')"
[[ $SESSION_ID =~ ^[A-Za-z0-9_.@:-]+$ ]] || SESSION_ID=""
if [ "$up" != 1 ]; then
  emit "ssh-deploy: ERROR: the tunnel was not ready after 90 seconds:"
  sed 's/^/  tunnel: /' "$TUNNEL_LOG" | redact | tee -a "$SESSION_LOG"
  exit 4
fi
emit "ssh-deploy: tunnel is up"

# ---- the request ---------------------------------------------------------------------------------------------------------------
if [ "$ACTION" = deploy ]; then
  REMOTE="shopnest-deploy --env ${ENVIRONMENT} --sha ${SHA} --image-ref ${IMAGE_REF} --frontend-ref ${FRONTEND_REF}"
  [ "$SEED" = 0 ] || REMOTE="${REMOTE} --seed"
else
  REMOTE="shopnest-rollback --env ${ENVIRONMENT} --sha ${SHA} --carrier-sha ${CARRIER_SHA}"
fi

# Pre-flight: the wrapper only validates the request and answers "ok". This proves the tunnel, the SSH key, the pinned host key, the
# environment binding of the key and the arguments BEFORE anything on the host is touched.
check_ok=0
for attempt in 1 2 3; do
  answer="$(ssh_run "${REMOTE} --check" 2> "$TMP/ssh.err")"
  rc=$?
  if [ "$rc" -eq 0 ] && [ "$answer" = ok ]; then check_ok=1; break; fi
  # A refusal by the host (not a connection problem) will not change on a retry.
  [ "$rc" -eq 255 ] || break
  [ "$attempt" -eq 3 ] || sleep 5
done
if [ "$check_ok" != 1 ]; then
  emit "ssh-deploy: ERROR: the pre-flight check failed (ssh exit ${rc}); nothing was started on the host:"
  { cat "$TMP/ssh.err"; [ -z "$answer" ] || printf '%s\n' "$answer"; } | sed 's/^/  host: /' | redact | tee -a "$SESSION_LOG"
  exit 4
fi
emit "ssh-deploy: pre-flight ok (tunnel, key, pinned host key and request accepted)"
if [ "$PREFLIGHT_ONLY" = 1 ]; then
  # A diagnostic: everything up to the point where the real command would start has been proven, and nothing was started on the host.
  emit "ssh-deploy: --preflight-only: the real command was NOT sent; nothing was started or changed on the host"
  exit 0
fi

emit "ssh-deploy: running: ${REMOTE}"
ssh_run "$REMOTE" 2>&1 | tee -a "$SESSION_LOG"
rc="${PIPESTATUS[0]}"
emit "ssh-deploy: the host answered with exit code ${rc}"

case "$rc" in
  0) ;;
  1) exit 1 ;;
  3) exit 3 ;;
  255) emit "ssh-deploy: ERROR: the SSH connection failed or broke; the result is unconfirmed, check the instance"; exit 4 ;;
  *) emit "ssh-deploy: ERROR: unexpected exit code ${rc} from the host; the result is unconfirmed"; exit 4 ;;
esac

# Confirmation: the host must say, in its own words, that THIS commit went live from images pulled BY DIGEST with a matching revision.
confirmed=1
want() { grep -qF -- "$1" "$SESSION_LOG" || { emit "ssh-deploy: ERROR: the host did not report: $1"; confirmed=0; }; }
if [ "$ACTION" = deploy ]; then
  want "backend image shopnest-backend:${SHA} pulled from GHCR by digest and its revision label matches"
  want "frontend files for ${SHA} unpacked from the GHCR image (digest pinned, revision label matches)"
  want "release ${SHA} is live on"
else
  if ! grep -qF -e "ROLLBACK SUCCEEDED: ${SHA} is live on" -e "${SHA} is already the live release on" "$SESSION_LOG"; then
    emit "ssh-deploy: ERROR: the host did not report that ${SHA} is live"
    confirmed=0
  fi
fi
if [ "$confirmed" != 1 ]; then
  emit "ssh-deploy: the host exited 0 but did not confirm the release: treating the result as unconfirmed"
  exit 4
fi
if [ "$ACTION" = deploy ]; then
  emit "ssh-deploy: CONFIRMED: ${SHA} is live in ${ENVIRONMENT}; images by digest ${IMAGE_REF##*@} (backend) and ${FRONTEND_REF##*@} (frontend)"
else
  emit "ssh-deploy: CONFIRMED: ${ENVIRONMENT} is serving ${SHA}"
fi
exit 0
