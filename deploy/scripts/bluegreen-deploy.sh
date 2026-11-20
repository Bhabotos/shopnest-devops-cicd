#!/usr/bin/env bash
# Blue/green deploy of one release to one environment. Run ON THE SERVER by the CD workflow:
#   bash shopnest/incoming/<sha>/deploy/scripts/bluegreen-deploy.sh --env staging --sha <40-hex> [--seed]
#
# 1. verify the uploaded bundle and load the backend image built for this exact commit
# 2. start the database, apply migrations (they must stay backward compatible with the live release)
# 3. start the idle colour, require /health OK and /version == the release SHA
# 4. only then switch nginx (backend colour and frontend files in one atomic reload) and verify live
# 5. on any failure: traffic stays on, or returns to, the previous release (see bg_release)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=lib/bluegreen-lib.sh
. "$SCRIPT_DIR/lib/bluegreen-lib.sh"

usage() {
  echo "usage: bluegreen-deploy.sh --env <staging|production> --sha <40-hex commit> [--seed]" >&2
  exit "${1:-2}"
}

ENV_NAME=""
SHA=""
SEED=0
while [ $# -gt 0 ]; do
  case "$1" in
    --env) ENV_NAME="${2:-}"; shift 2 ;;
    --sha) SHA="${2:-}"; shift 2 ;;
    --seed) SEED=1; shift ;;
    -h | --help) usage 0 ;;
    *) usage ;;
  esac
done
[ -n "$ENV_NAME" ] && [ -n "$SHA" ] || usage
bg_require_sha "$SHA"

bg_init "$ENV_NAME" "$BUNDLE_DIR"
exec > >(tee -a "$BG_LOG_DIR/$BG_ENV-$SHA.log") 2>&1
trap 'sleep 1' EXIT   # lets tee flush the log
bg_lock
trap 'bg_unlock; sleep 1' EXIT   # from here on this run owns the lock and must release it

bg_log "deploy $SHA to $BG_ENV (bundle $BUNDLE_DIR)"

[ "$(cat "$BUNDLE_DIR/RELEASE_SHA" 2> /dev/null)" = "$SHA" ] || bg_die "the bundle is for a different commit than --sha"
(cd "$BUNDLE_DIR" && sha256sum --check --strict SHA256SUMS > /dev/null) || bg_die "bundle checksum verification failed"
bg_log "bundle verified"

[ -f "$BUNDLE_DIR/backend-image.tar.gz" ] || bg_die "backend-image.tar.gz is missing from the bundle"
docker load --input "$BUNDLE_DIR/backend-image.tar.gz" > /dev/null
revision="$(bg_image_revision "$SHA" || true)"
[ "$revision" = "$SHA" ] || bg_die "image revision label '$revision' does not match $SHA"
bg_log "backend image shopnest-backend:$SHA loaded"

bg_frontend_install "$SHA" "$BUNDLE_DIR/frontend-dist" || bg_die "could not install the frontend files"

export MIGRATE_TAG="$SHA"
bg_log "ensuring the database is up (it is never recreated or restarted by a deploy)"
bg_db_up || bg_die "the database did not become ready"

bg_log "applying migrations (owner role; must stay compatible with the live release)"
if ! bg_compose run --rm --no-deps -T migrate; then
  bg_history failed "$SHA" "migration failed; live release unchanged"
  bg_die "migration failed; the live release is unchanged"
fi

if [ "$SEED" = 1 ]; then
  if [ "$BG_ENV" = production ] && [ "${ALLOW_PRODUCTION_SEED:-}" != "true" ]; then
    bg_die "seeding production needs ALLOW_PRODUCTION_SEED=true in the operator's environment (a deliberate, manual choice)"
  fi
  bg_log "seeding the demo catalogue (idempotent)"
  bg_compose run --rm --no-deps -T seed
fi

if bg_release "$SHA" "deploy"; then
  bg_log "DEPLOY SUCCEEDED: $SHA is live on $BG_ENV"
else
  bg_log "DEPLOY FAILED: see the messages above; history: $BG_STATE_DIR/history.log"
  exit 1
fi
