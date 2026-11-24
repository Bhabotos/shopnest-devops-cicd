#!/usr/bin/env bash
# Static checks of the lab Terraform configuration (infra/lab): the approved minimal architecture, the network rules, the identities,
# the gating of everything CI/CD, and that nothing sensitive is committed. Reads files only; no Terraform and no AWS. See
# deploy/tests/lab_check.py.
#   bash deploy/tests/lab.test.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
PYTHON=""
for candidate in python3 python py; do
  if command -v "$candidate" > /dev/null 2>&1 && "$candidate" -c 'import sys' > /dev/null 2>&1; then PYTHON="$candidate"; break; fi
done
[ -n "$PYTHON" ] || { echo "Python is required for this check" >&2; exit 2; }
exec "$PYTHON" "$HERE/lab_check.py" "$ROOT"
