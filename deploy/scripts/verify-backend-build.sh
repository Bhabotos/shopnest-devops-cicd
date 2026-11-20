#!/usr/bin/env bash
# Backend "build" validation (our interpretation of Part B3, recorded as R in the checklist).
# The backend has no compile step, so the build is: the production image builds, every module
# imports using only production dependencies, and the entrypoint starts and fails safely when
# its configuration is missing. Lint and tests are separate steps (npm run lint / npm test).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
IMAGE="shopnest-backend:verify"
PASSED=0
pass() { PASSED=$((PASSED + 1)); echo "PASS  $*"; }
fail() { echo "FAIL  $*" >&2; exit 1; }

trap 'docker rmi -f "$IMAGE" >/dev/null 2>&1 || true' EXIT

echo "== docker build"
docker build -q -t "$IMAGE" "$ROOT/backend" >/dev/null
pass "image builds"

echo "== import validation (production dependencies only, no network, no database)"
docker run --rm --network none "$IMAGE" node --input-type=module -e '
for (const name of ["app", "config", "constants", "db", "errors", "logger", "migrate", "orders", "products", "seed", "validation"]) {
  await import(`./src/${name}.js`);
}
console.log("all modules imported");
' | grep -q "all modules imported" || fail "a module failed to import in the production image"
pass "every src module imports in the production image"

echo "== startup validation"
set +e
out="$(docker run --rm --network none "$IMAGE" 2>&1)"
code=$?
set -e
[[ $code -ne 0 ]] || fail "server started without DATABASE_URL"
[[ "$out" == *"DATABASE_URL is not set"* ]] || fail "unexpected startup output: $out"
pass "entrypoint refuses to start without DATABASE_URL (exit $code) and logs why"

echo "== image contents"
[[ "$(docker run --rm "$IMAGE" id -un)" == "node" ]] || fail "image does not run as node"
pass "runs as non-root user node"
if docker run --rm "$IMAGE" test -e test; then fail "tests were copied into the production image"; fi
pass "tests are not in the production image"
[[ "$(docker run --rm "$IMAGE" printenv NODE_ENV)" == "production" ]] || fail "NODE_ENV is not production"
pass "NODE_ENV=production (the seed script therefore refuses to run in this image)"

echo
echo "ALL CHECKS PASSED ($PASSED)"
