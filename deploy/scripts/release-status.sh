#!/usr/bin/env bash
# Prints which release is live in one environment, the last known good release and the recent
# release history. Read-only; needs no secrets and no Docker.
#   bash release-status.sh --env <staging|production> [--history N]
set -euo pipefail

ENV_NAME=""
LINES=10
while [ $# -gt 0 ]; do
  case "$1" in
    --env) ENV_NAME="${2:-}"; shift 2 ;;
    --history) LINES="${2:-10}"; shift 2 ;;
    *) echo "usage: release-status.sh --env <staging|production> [--history N]" >&2; exit 2 ;;
  esac
done
case "$ENV_NAME" in staging | production) ;; *) echo "environment must be staging or production" >&2; exit 2 ;; esac

state="${SHOPNEST_HOME:-$HOME/shopnest}/$ENV_NAME/state"
active="$(cat "$state/active" 2> /dev/null || true)"
echo "environment : $ENV_NAME"
if [ -n "$active" ]; then
  echo "live colour : $active"
  echo "live release: $(cat "$state/tag-$active" 2> /dev/null || echo unknown)"
else
  echo "live colour : none (nothing deployed yet)"
fi
echo "last good   : $(cat "$state/last_good" 2> /dev/null || echo none)"
echo "history (newest last, columns: time env sha status detail):"
if [ -f "$state/history.log" ]; then tail -n "$LINES" "$state/history.log"; else echo "  (empty)"; fi
