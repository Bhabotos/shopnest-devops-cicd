#!/usr/bin/env bash
# Builds the release bundle that the SSM deploy document fetches from S3: ONE tarball, with an explicit file list (the host
# gets only what the deploy scripts use, never tests, the development or test Compose files, the rehearsal-only local-database
# file, or any .env example).
#
#   build-bundle.sh --mode release --sha <40 hex> --frontend-dist <dir> --out <dir>
#   build-bundle.sh --mode carrier --sha <40 hex> --out <dir>
#
#   release  scripts, settings, nginx config AND the frontend build: what a deploy installs.
#   carrier  scripts and settings only: it just CARRIES the rollback tooling to the host (a rollback restores the frontend of an
#            earlier release from that release's own recorded bundle). Its S3 key is derived from its own content, so it can
#            never overwrite a release bundle.
#
# Output in <dir>: bundle.tar.gz, and bundle.sha256 (the hash only). The tarball is reproducible: sorted, fixed owner and time.
set -euo pipefail

die() { echo "build-bundle: ERROR: $*" >&2; exit 1; }

MODE="" SHA="" FRONTEND="" OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --mode) MODE="${2:-}"; shift 2 ;;
    --sha) SHA="${2:-}"; shift 2 ;;
    --frontend-dist) FRONTEND="${2:-}"; shift 2 ;;
    --out) OUT="${2:-}"; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done
case "$MODE" in release | carrier) ;; *) die "--mode must be release or carrier" ;; esac
[[ "$SHA" =~ ^[0-9a-f]{40}$ ]] || die "--sha must be a full 40-character commit SHA"
[ -n "$OUT" ] || die "--out is required"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

if [ "$MODE" = release ]; then
  [ -n "$FRONTEND" ] || die "--frontend-dist is required for a release bundle"
  [ -s "$FRONTEND/index.html" ] || die "the frontend build has no non-empty index.html: refusing to build a bundle that would serve a broken page"
elif [ -n "$FRONTEND" ]; then
  die "a carrier bundle carries no frontend files"
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
B="$WORK/bundle"
mkdir -p "$B/deploy/scripts/lib" "$B/deploy/env" "$B/deploy/nginx" "$B/deploy/host"

cp "$ROOT/deploy/docker-compose.prod.yml" "$B/deploy/"
cp "$ROOT/deploy/scripts/bluegreen-deploy.sh" "$ROOT/deploy/scripts/rollback.sh" "$ROOT/deploy/scripts/release-status.sh" "$ROOT/deploy/scripts/request-loop.sh" "$B/deploy/scripts/"
cp "$ROOT/deploy/scripts/lib/bluegreen-lib.sh" "$B/deploy/scripts/lib/"
cp "$ROOT/deploy/env/staging.env" "$ROOT/deploy/env/production.env" "$B/deploy/env/"
cp "$ROOT/deploy/nginx/nginx.conf" "$B/deploy/nginx/"
cp "$ROOT/deploy/host/imds-guard.sh" "$ROOT/deploy/host/install-host-guards.sh" "$ROOT/deploy/host/"*.service "$ROOT/deploy/host/"*.timer "$B/deploy/host/"
if [ "$MODE" = release ]; then
  mkdir -p "$B/frontend-dist"
  cp -R "$FRONTEND/." "$B/frontend-dist/"
fi
find "$B" -name '.env' -type f -delete
printf '%s\n' "$SHA" > "$B/RELEASE_SHA"
# Internal integrity list, checked by bluegreen-deploy.sh on the host.
(cd "$B" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)

mkdir -p "$OUT"
TARBALL="$OUT/bundle.tar.gz"
ENTRIES=(deploy RELEASE_SHA SHA256SUMS)
[ "$MODE" = release ] && ENTRIES=(deploy frontend-dist RELEASE_SHA SHA256SUMS)
# Reproducible: sorted names, fixed owner and modification time; gzip without a timestamp.
(cd "$B" && tar --sort=name --owner=0 --group=0 --numeric-owner --mtime='2000-01-01 00:00:00' -cf - "${ENTRIES[@]}") | gzip -n -9 > "$TARBALL"

# Verify what was built: required members present, forbidden ones absent.
LIST="$(tar -tzf "$TARBALL")"
for required in deploy/docker-compose.prod.yml deploy/scripts/bluegreen-deploy.sh deploy/scripts/rollback.sh deploy/scripts/lib/bluegreen-lib.sh \
  deploy/host/imds-guard.sh deploy/host/install-host-guards.sh deploy/env/staging.env deploy/env/production.env deploy/nginx/nginx.conf RELEASE_SHA SHA256SUMS; do
  grep -qxF "$required" <<< "$LIST" || die "the bundle is missing $required"
done
if [ "$MODE" = release ]; then grep -qxF "frontend-dist/index.html" <<< "$LIST" || die "the bundle is missing frontend-dist/index.html"; fi
if forbidden="$(grep -E '(^|/)(tests|db)/|docker-compose\.(dev|test|local-db)\.yml|(^|/)\.env|\.env\.example|backend-image|\.tar$|\.pem$|node_modules|\.git/' <<< "$LIST")" && [ -n "$forbidden" ]; then
  die "the bundle contains files that must never reach the host: $(echo "$forbidden" | head -3 | tr '\n' ' ')"
fi
if [ "$MODE" = carrier ] && grep -q '^frontend-dist' <<< "$LIST"; then die "a carrier bundle must not contain frontend files"; fi

HASH="$(sha256sum "$TARBALL" | cut -d' ' -f1)"
printf '%s\n' "$HASH" > "$OUT/bundle.sha256"
echo "bundle ($MODE) for $SHA: $(wc -c < "$TARBALL") bytes, sha256 $HASH"
