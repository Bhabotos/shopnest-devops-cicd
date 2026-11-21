#!/usr/bin/env bash
# Sends ONE of the two fixed SSM command documents to the application instance, waits for it, prints its output, and turns the
# result into the exit codes the deploy scripts already use. There is no SSH anywhere: the instance has no inbound port.
#
#   run-ssm-command.sh --document <name> --instance <i-...> --region <region> --timeout <seconds>
#                      [--poll <seconds>] [--max-wait <seconds>] [--log-file <file>] -- Key=Value [Key=Value ...]
#
# Parameter names and values are validated here (letters, digits and . _ / @ : + - only) and again by the document's own
# allowedPattern rules, so nothing a caller passes can become a command.
#
# Exit codes (the same meaning as bluegreen-deploy.sh and rollback.sh, carried back through Systems Manager):
#   0  the command succeeded (the release is live / the rollback is done)
#   1  it failed and the previous release is still serving
#   3  it failed AND the recovery failed: the environment may be serving a release that did not verify (needs an operator now)
#   4  the result could not be confirmed: the command could not be sent, was cancelled or timed out, did not finish in time,
#      or ended with an unexpected code. Treat it as a failure and look at the host.
#   2  bad arguments
# SSM keeps only the first 24,000 characters of a command's output; the deploy scripts also write a full log on the host.
set -euo pipefail

usage_error() { echo "run-ssm-command: ERROR: $*" >&2; exit 2; }

DOCUMENT="" INSTANCE="" REGION="" TIMEOUT="" POLL=10 MAX_WAIT=1500 LOG_FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --document) DOCUMENT="${2:-}"; shift 2 ;;
    --instance) INSTANCE="${2:-}"; shift 2 ;;
    --region) REGION="${2:-}"; shift 2 ;;
    --timeout) TIMEOUT="${2:-}"; shift 2 ;;
    --poll) POLL="${2:-}"; shift 2 ;;
    --max-wait) MAX_WAIT="${2:-}"; shift 2 ;;
    --log-file) LOG_FILE="${2:-}"; shift 2 ;;
    --) shift; break ;;
    *) usage_error "unknown argument: $1" ;;
  esac
done
[[ "$DOCUMENT" =~ ^[A-Za-z0-9_.-]{3,128}$ ]] || usage_error "--document is not a document name"
[[ "$INSTANCE" =~ ^i-[0-9a-f]{8,17}$ ]] || usage_error "--instance must be an instance id"
[[ "$REGION" =~ ^[a-z]{2}-[a-z]+-[0-9]$ ]] || usage_error "--region is not a region"
[[ "$TIMEOUT" =~ ^[0-9]{2,5}$ ]] || usage_error "--timeout must be whole seconds"
[[ "$POLL" =~ ^[0-9]+$ && "$MAX_WAIT" =~ ^[0-9]+$ ]] || usage_error "--poll and --max-wait must be whole seconds"
[ $# -gt 0 ] || usage_error "at least one Key=Value parameter is required"

PARAMS="{"
sep=""
for pair in "$@"; do
  [[ "$pair" =~ ^([A-Za-z][A-Za-z0-9]*)=([A-Za-z0-9._/@:+-]+)$ ]] || usage_error "parameter '${pair%%=*}' is not a plain Key=Value"
  PARAMS="$PARAMS$sep\"${BASH_REMATCH[1]}\":[\"${BASH_REMATCH[2]}\"]"
  sep=","
done
PARAMS="$PARAMS}"

emit() { if [ -n "$LOG_FILE" ]; then printf '%s\n' "$*" | tee -a "$LOG_FILE"; else printf '%s\n' "$*"; fi; }
[ -z "$LOG_FILE" ] || : > "$LOG_FILE"

COMMAND_ID="$(aws ssm send-command --region "$REGION" --document-name "$DOCUMENT" --instance-ids "$INSTANCE" \
  --timeout-seconds "$TIMEOUT" --parameters "$PARAMS" --comment "ShopNest CD" \
  --query 'Command.CommandId' --output text)" || { emit "run-ssm-command: could not send the command"; exit 4; }
[[ "$COMMAND_ID" =~ ^[0-9a-f-]{36}$ ]] || { emit "run-ssm-command: SSM returned no command id"; exit 4; }
emit "command $COMMAND_ID sent to $INSTANCE ($DOCUMENT)"

waited=0
status="Pending"
missing=0
while [ "$waited" -le "$MAX_WAIT" ]; do
  if out="$(aws ssm get-command-invocation --region "$REGION" --command-id "$COMMAND_ID" --instance-id "$INSTANCE" --query 'Status' --output text 2> /dev/null)"; then
    status="$out"
    case "$status" in Success | Failed | Cancelled | TimedOut) break ;; esac
  else
    # Right after sending, the invocation may not exist yet: allow a short grace period, then give up.
    missing=$((missing + 1))
    if [ "$missing" -gt 12 ]; then emit "run-ssm-command: the invocation never appeared"; exit 4; fi
  fi
  sleep "$POLL"
  # Time always advances (at least one second per round), so a command that never finishes ends in exit 4, never a hang.
  waited=$((waited + (POLL > 0 ? POLL : 1)))
done

case "$status" in
  Success | Failed | Cancelled | TimedOut) ;;
  *) emit "run-ssm-command: the command did not finish within ${MAX_WAIT}s (last status: $status). It may still be running on the host: check it before retrying."; exit 4 ;;
esac

CODE="$(aws ssm get-command-invocation --region "$REGION" --command-id "$COMMAND_ID" --instance-id "$INSTANCE" --query 'ResponseCode' --output text 2> /dev/null || echo "")"
emit "---- output of the command (status: $status, exit code: ${CODE:-unknown}) ----"
emit "$(aws ssm get-command-invocation --region "$REGION" --command-id "$COMMAND_ID" --instance-id "$INSTANCE" --query 'StandardOutputContent' --output text 2> /dev/null || echo '(no output)')"
ERR="$(aws ssm get-command-invocation --region "$REGION" --command-id "$COMMAND_ID" --instance-id "$INSTANCE" --query 'StandardErrorContent' --output text 2> /dev/null || true)"
if [ -n "$ERR" ] && [ "$ERR" != "None" ]; then emit "---- errors ----"; emit "$ERR"; fi

case "$status:$CODE" in
  Success:0) emit "run-ssm-command: succeeded"; exit 0 ;;
  Failed:1) emit "run-ssm-command: FAILED, and the previous release is still serving (exit 1)"; exit 1 ;;
  Failed:3) emit "run-ssm-command: CRITICAL: it failed AND the automatic recovery failed (exit 3). The environment may be serving a release that did not verify. An operator is needed now."; exit 3 ;;
  *) emit "run-ssm-command: the result could not be confirmed (status: $status, exit code: ${CODE:-unknown}): treat it as a failure"; exit 4 ;;
esac
