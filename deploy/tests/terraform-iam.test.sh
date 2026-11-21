#!/usr/bin/env bash
# Static checks of the CI/CD Terraform (who may do what; everything new is gated by enable_cicd). Reads the .tf source only:
# no Terraform command, no AWS, no credentials. See deploy/tests/terraform_iam_check.py for what is asserted and what is NOT
# (it cannot show what AWS accepts: that needs a real plan and the IAM policy simulator, after approval).
#   bash deploy/tests/terraform-iam.test.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
PYTHON="$(command -v python3 || command -v python || true)"
[ -n "$PYTHON" ] || { echo "python is required for this check" >&2; exit 2; }
exec "$PYTHON" "$HERE/terraform_iam_check.py" "$ROOT/infra/terraform"
