#!/usr/bin/env bash
# Blue/green deploy of one release to one environment. Run ON THE SERVER by the CD workflow:
#   bash shopnest/incoming/<sha>/deploy/scripts/bluegreen-deploy.sh --env staging --sha <40-hex> [--seed]
#
# 1. verify the bundle (scripts and frontend files) and get the backend image built for this exact commit:
#    on AWS with RDS (BG_LAB unset) it is pulled from ECR BY DIGEST (--image-ref);
#    in lab mode (BG_LAB=1, the infra/lab instance) the backend AND the frontend are pulled from GHCR BY DIGEST (--image-ref,
#    --frontend-ref) and the scripts run from a git checkout of this exact commit instead of a bundle;
#    a local rehearsal (BG_LOCAL_DB=1) may still load a tarball from the bundle
# 2. check the database is reachable. On AWS the schema migrations are NOT applied here: they ran before this deploy, in
#    the CodeBuild migrator (the only place with the owner credentials), and a failed migration stopped the pipeline. A
#    local rehearsal (BG_LOCAL_DB=1) still applies them with the database container.
# 3. start the idle colour, require /health OK and /version == the release SHA
# 4. only then switch nginx (backend colour and frontend files in one atomic reload) and verify live
# 5. on any failure: traffic stays on, or returns to, the previous release (see bg_release)
# Exit codes: 0 deployed; 1 failed, the previous release is serving; 3 failed AND the automatic rollback
# did not restore a verified release (critical, needs an operator); 2 usage.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=lib/bluegreen-lib.sh
. "$SCRIPT_DIR/lib/bluegreen-lib.sh"

usage() {
  echo "usage: bluegreen-deploy.sh --env <staging|production> --sha <40-hex commit> --image-ref <ecr or ghcr repository@sha256:digest> (--bundle-key <s3 key> --bundle-sha256 <hex> | --frontend-ref <ghcr shopnest-frontend@sha256:digest>) [--seed (lab and local rehearsal only)]" >&2
  exit "${1:-2}"
}

ENV_NAME=""
SHA=""
IMAGE_REF=""
FRONTEND_REF=""
BUNDLE_KEY=""
BUNDLE_SHA256=""
SEED=0
while [ $# -gt 0 ]; do
  case "$1" in
    --env) [ $# -ge 2 ] || usage; ENV_NAME="$2"; shift 2 ;;
    --sha) [ $# -ge 2 ] || usage; SHA="$2"; shift 2 ;;
    --image-ref) [ $# -ge 2 ] || usage; IMAGE_REF="$2"; shift 2 ;;
    --frontend-ref) [ $# -ge 2 ] || usage; FRONTEND_REF="$2"; shift 2 ;;
    --bundle-key) [ $# -ge 2 ] || usage; BUNDLE_KEY="$2"; shift 2 ;;
    --bundle-sha256) [ $# -ge 2 ] || usage; BUNDLE_SHA256="$2"; shift 2 ;;
    --seed) SEED=1; shift ;;
    -h | --help) usage 0 ;;
    *) usage ;;
  esac
done
[ -n "$ENV_NAME" ] && [ -n "$SHA" ] || usage
bg_require_sha "$SHA"

if [ "${BG_LAB:-}" = "1" ]; then
  # Lab mode: every argument is checked BEFORE anything changes (before bg_init creates a directory or generates a password).
  [ -n "$IMAGE_REF" ] && [ -n "$FRONTEND_REF" ] || bg_die "--image-ref and --frontend-ref are required in lab mode: both images are taken from GHCR by digest, never from a tag"
  bg_validate_lab_image_ref "$IMAGE_REF" backend
  bg_validate_lab_image_ref "$FRONTEND_REF" frontend
  [ -z "$BUNDLE_KEY$BUNDLE_SHA256" ] || bg_die "--bundle-key and --bundle-sha256 are not used in lab mode (the release is a git checkout)"
  bg_lab_check_checkout "$SHA" "$BUNDLE_DIR"
fi

bg_init "$ENV_NAME" "$BUNDLE_DIR"
if [ "$BG_DB_MODE" = rds ]; then
  # EVERY argument is checked here, before anything changes: no guard is installed, no network is created, nothing is
  # pulled and nothing is started for a request that is going to be refused.
  [ "$SEED" = 0 ] || bg_die "--seed is not available on AWS: the instance never holds the owner credentials, so it cannot seed"
  [ -n "$IMAGE_REF" ] || bg_die "--image-ref is required: staging and production take the backend image from ECR by digest, never from a tarball"
  bg_validate_image_ref "$IMAGE_REF"
  { [ -n "$BUNDLE_KEY" ] && [ -n "$BUNDLE_SHA256" ]; } || bg_die "--bundle-key and --bundle-sha256 are required on AWS: the artifact reference is kept for rollback"
  bg_validate_bundle_ref "$BUNDLE_KEY" "$BUNDLE_SHA256"
fi
exec > >(tee -a "$BG_LOG_DIR/$BG_ENV-$SHA.log") 2>&1
trap 'sleep 1' EXIT   # lets tee flush the log
bg_lock
trap 'bg_unlock; sleep 1' EXIT   # from here on this run owns the lock and must release it

bg_log "deploy $SHA to $BG_ENV (bundle $BUNDLE_DIR)"

if [ "$BG_DB_MODE" = lab ]; then
  bg_log "lab mode: scripts are a git checkout of $SHA; the images are pulled from GHCR by digest"
else
  [ "$(cat "$BUNDLE_DIR/RELEASE_SHA" 2> /dev/null)" = "$SHA" ] || bg_die "the bundle is for a different commit than --sha"
  (cd "$BUNDLE_DIR" && sha256sum --check --strict SHA256SUMS > /dev/null) || bg_die "bundle checksum verification failed"
  bg_log "bundle verified"
  bg_frontend_ok "$BUNDLE_DIR/frontend-dist" || bg_die "frontend-dist has no non-empty index.html; refusing before anything is changed"
fi

# Before any container exists: the metadata-service guard (AWS mode).
bg_host_guard

if [ "$BG_DB_MODE" = lab ]; then
  bg_pull_lab_image "$IMAGE_REF" "$SHA" backend
  bg_log "backend image shopnest-backend:$SHA pulled from GHCR by digest and its revision label matches"
  bg_pull_lab_image "$FRONTEND_REF" "$SHA" frontend
  bg_frontend_from_image "$SHA" || bg_die "could not install the frontend files from the frontend image"
  bg_log "frontend files for $SHA unpacked from the GHCR image (digest pinned, revision label matches)"
elif [ -n "$IMAGE_REF" ]; then
  bg_pull_image "$IMAGE_REF" "$SHA"
  bg_log "backend image shopnest-backend:$SHA pulled from ECR by digest and its revision label matches"
elif [ "$BG_DB_MODE" = rds ]; then
  bg_die "--image-ref is required: staging and production take the backend image from ECR by digest, never from a tarball"
else
  [ -f "$BUNDLE_DIR/backend-image.tar.gz" ] || bg_die "backend-image.tar.gz is missing from the bundle"
  docker load --input "$BUNDLE_DIR/backend-image.tar.gz" > /dev/null
  revision="$(bg_image_revision "$SHA" || true)"
  [ "$revision" = "$SHA" ] || bg_die "image revision label '$revision' does not match $SHA"
  bg_log "backend image shopnest-backend:$SHA loaded (local rehearsal tarball)"
fi

if [ "$BG_DB_MODE" != lab ]; then
  bg_frontend_install "$SHA" "$BUNDLE_DIR/frontend-dist" || bg_die "could not install the frontend files"
fi
if [ "$BG_DB_MODE" = rds ]; then bg_record_bundle "$SHA" "$BUNDLE_KEY" "$BUNDLE_SHA256"; fi

export MIGRATE_TAG="$SHA"
if [ "$BG_DB_MODE" = rds ]; then
  bg_log "checking that the RDS endpoint is reachable (there is no database container to start)"
else
  bg_log "ensuring the database is up (it is never recreated or restarted by a deploy)"
fi
bg_db_up || bg_die "the database did not become ready"

if [ "$BG_DB_MODE" = rds ]; then
  bg_log "schema migrations are applied before the deploy by the CodeBuild migrator; this host never runs them"
else
  bg_log "applying migrations (owner role; must stay compatible with the live release)"
  if ! bg_compose run --rm --no-deps -T migrate; then
    bg_history failed "$SHA" "migration failed; live release unchanged"
    bg_die "migration failed; the live release is unchanged"
  fi
fi

# FAIL CLOSED: no release starts unless the metadata-service isolation is confirmed.
bg_host_guard_verify "$SHA"

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
  rc=$?
  if [ "$rc" = 3 ]; then
    bg_log "DEPLOY FAILED AND RECOVERY FAILED (exit 3): the environment may be serving a release that did not verify; history: $BG_STATE_DIR/history.log"
  else
    bg_log "DEPLOY FAILED (exit $rc): the previous release is serving; see the messages above; history: $BG_STATE_DIR/history.log"
  fi
  exit "$rc"
fi
