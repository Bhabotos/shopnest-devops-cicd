#!/usr/bin/env bash
# Static checks of the deployment workflows (cd.yml, rollback.yml): no SSH, no stored credential, pinned actions, a failed
# migration blocks the deploy, production is never deployed, a rollback request is refused rather than ignored. Reads the YAML
# only; runs nothing. See deploy/tests/workflows_check.py.
#   bash deploy/tests/workflows.test.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# The first Python that has PyYAML (a machine can have several; GitHub's Ubuntu runners have it in python3).
PYTHON=""
for candidate in python3 python py; do
  if command -v "$candidate" > /dev/null 2>&1 && "$candidate" -c 'import yaml' > /dev/null 2>&1; then PYTHON="$candidate"; break; fi
done
[ -n "$PYTHON" ] || { echo "a Python with PyYAML is required for this check" >&2; exit 2; }
exec "$PYTHON" "$HERE/workflows_check.py" "$ROOT"
