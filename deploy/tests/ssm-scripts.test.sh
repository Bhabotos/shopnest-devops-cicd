#!/usr/bin/env bash
# Static tests of the shell scripts embedded in the SSM command documents (infra/terraform/ssm_documents.tf). They are shell text inside
# Terraform, so no other lint covers them; this test extracts exactly what Systems Manager will run and checks it.
#   - the script starts with a bash shebang (SSM runs a script with sh unless told otherwise, and `pipefail` is not guaranteed in sh);
#   - the PATH includes /snap/bin before the first `aws` (the CLI is installed with snap);
#   - ShellCheck is clean on both scripts;
#   - and the test CATCHES the two mistakes it exists for: a script without a shebang, and one that declares /bin/sh.
# It reads the .tf source only: no Terraform, no AWS. It needs ShellCheck (preinstalled on GitHub's Ubuntu runners; set SHELLCHECK to a
# path to use another). A missing ShellCheck is a failure, never a silent skip.
#   bash deploy/tests/ssm-scripts.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); echo "PASS  $*"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL  $*"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: got [$2] expected [$3]"; fi; }

SHELLCHECK="${SHELLCHECK:-$(command -v shellcheck || true)}"
[ -n "$SHELLCHECK" ] || { echo "ShellCheck is required for this test (install it, or set SHELLCHECK to its path)" >&2; exit 2; }
PYTHON="$(command -v python3 || command -v python || true)"
[ -n "$PYTHON" ] || { echo "python is required for this test" >&2; exit 2; }

"$PYTHON" "$HERE/ssm_scripts_extract.py" "$ROOT/infra/terraform/ssm_documents.tf" "$T/out" > "$T/extract.log" 2>&1
check "both embedded scripts are extracted, every placeholder resolved" $? 0
[ -s "$T/out/deploy.sh" ] && [ -s "$T/out/rollback.sh" ] || { cat "$T/extract.log"; echo "nothing to check"; exit 1; }

for name in deploy rollback; do
  f="$T/out/$name.sh"
  echo "== the $name document's script"
  check "$name: the first line is a bash shebang" "$(head -n 1 "$f")" "#!/bin/bash"
  check "$name: the second line makes any error fatal" "$(sed -n '2p' "$f")" "set -euo pipefail"
  path_line="$(grep -n '^export PATH=' "$f" | head -n 1 | cut -d: -f1)"
  aws_line="$(grep -n '\baws ' "$f" | head -n 1 | cut -d: -f1)"
  check "$name: the PATH includes /snap/bin (where the snap-installed AWS CLI lives)" "$(grep -c '^export PATH=.*:/snap/bin' "$f")" 1
  check "$name: the PATH is set before the first use of aws" "$([ -n "$path_line" ] && [ -n "$aws_line" ] && [ "$path_line" -lt "$aws_line" ] && echo yes || echo no)" yes
  check "$name: the bundle hash is verified before anything is extracted" "$([ "$(grep -n 'sha256sum --check --strict' "$f" | head -n 1 | cut -d: -f1)" -lt "$(grep -n 'tar -xzf' "$f" | head -n 1 | cut -d: -f1)" ] && echo yes || echo no)" yes
  check "$name: it ends by passing the exit code through" "$(tail -n 1 "$f")" 'exit "$rc"'
  bash -n "$f" 2> /dev/null; check "$name: bash accepts the syntax" $? 0
  "$SHELLCHECK" --severity=style "$f" > "$T/sc-$name.log" 2>&1; check "$name: ShellCheck is clean (every severity)" $? 0
  [ -s "$T/sc-$name.log" ] && sed 's/^/        /' "$T/sc-$name.log"
done

echo "== the test would have caught the original mistakes (negative controls on copies)"
sed '1d' "$T/out/deploy.sh" > "$T/no-shebang.sh"
"$SHELLCHECK" --severity=warning "$T/no-shebang.sh" > /dev/null 2>&1
check "a script WITHOUT a shebang is rejected by ShellCheck" "$([ $? -ne 0 ] && echo rejected || echo accepted)" rejected
sed '1s#.*#\#!/bin/sh#' "$T/out/deploy.sh" > "$T/sh-shebang.sh"
"$SHELLCHECK" --severity=warning "$T/sh-shebang.sh" > "$T/sh.log" 2>&1
check "a script that declares /bin/sh is rejected (pipefail is undefined there)" "$([ $? -ne 0 ] && echo rejected || echo accepted)" rejected
check "and the reason given is pipefail being undefined in sh (SC3040)" "$(grep -q 'SC3040' "$T/sh.log" && echo yes || echo no)" yes
sed '/^export PATH=/d' "$T/out/deploy.sh" > "$T/no-path.sh"
check "a script without the PATH line is caught by this test's own PATH check" "$([ "$(grep -c '^export PATH=.*:/snap/bin' "$T/no-path.sh")" = 1 ] && echo accepted || echo rejected)" rejected

echo
echo "ssm-scripts tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
