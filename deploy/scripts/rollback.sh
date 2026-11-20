#!/usr/bin/env bash
# Manual rollback of one environment to a release that was deployed earlier. Run ON THE SERVER:
#   bash shopnest/incoming/<sha>/deploy/scripts/rollback.sh --env staging --sha <earlier 40-hex commit>
#
# It uses the SAME validation path as a deploy (bg_release): the old release is started on the idle
# colour, must report /health OK and /version == that SHA, and only then does traffic move. No
# migrations run: a rollback never changes the schema. The old image and frontend files must still be
# on the server (they are kept), and the SHA must appear as "deployed" in the release history.
# Exit codes: 0 rolled back (or already live); 1 failed, the previous release is serving; 3 failed AND the
# recovery failed (critical, needs an operator); 2 usage.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=lib/bluegreen-lib.sh
. "$SCRIPT_DIR/lib/bluegreen-lib.sh"

usage() {
  echo "usage: rollback.sh --env <staging|production> --sha <40-hex earlier release>" >&2
  exit "${1:-2}"
}

ENV_NAME=""
SHA=""
while [ $# -gt 0 ]; do
  case "$1" in
    --env) ENV_NAME="${2:-}"; shift 2 ;;
    --sha) SHA="${2:-}"; shift 2 ;;
    -h | --help) usage 0 ;;
    *) usage ;;
  esac
done
[ -n "$ENV_NAME" ] && [ -n "$SHA" ] || usage
bg_require_sha "$SHA"

bg_init "$ENV_NAME" "$BUNDLE_DIR"
exec > >(tee -a "$BG_LOG_DIR/rollback-$BG_ENV-$SHA.log") 2>&1
trap 'sleep 1' EXIT   # lets tee flush the log
bg_lock
trap 'bg_unlock; sleep 1' EXIT   # from here on this run owns the lock and must release it

bg_log "manual rollback of $BG_ENV to $SHA"

bg_history_has_deployed "$SHA" || bg_die "$SHA is not in the release history as deployed; see $BG_STATE_DIR/history.log"
[ "$(bg_image_revision "$SHA" || true)" = "$SHA" ] || bg_die "image shopnest-backend:$SHA is not on this server any more"
[ -d "$BG_FRONTEND_DIR/releases/$SHA" ] || bg_die "frontend files for $SHA are not on this server any more"
bg_frontend_ok "$BG_FRONTEND_DIR/releases/$SHA" || bg_die "frontend files for $SHA have no non-empty index.html; refusing before anything is changed"

live="$(bg_active)"
if [ -n "$live" ] && [ "$(cat "$BG_STATE_DIR/tag-$live")" = "$SHA" ]; then
  bg_log "$SHA is already the live release on $live; nothing to do"
  exit 0
fi

bg_log "ensuring the database is up (it is never recreated or restarted by a rollback)"
bg_db_up || bg_die "the database did not become ready"

if bg_release "$SHA" "manual rollback"; then
  bg_log "ROLLBACK SUCCEEDED: $SHA is live on $BG_ENV"
else
  rc=$?
  if [ "$rc" = 3 ]; then
    bg_log "ROLLBACK FAILED AND RECOVERY FAILED (exit 3): the environment may be serving a release that did not verify"
  else
    bg_log "ROLLBACK FAILED (exit $rc): the live release is unchanged or was restored; see the messages above"
  fi
  exit "$rc"
fi
