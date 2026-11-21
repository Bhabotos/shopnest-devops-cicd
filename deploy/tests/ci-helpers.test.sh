#!/usr/bin/env bash
# Offline tests for the CI-side helpers in deploy/ci/: build-bundle.sh, push-image.sh, run-codebuild.sh, run-ssm-command.sh.
# build-bundle.sh runs for real on the repository's files; the others run against a fake `aws` and a fake `docker`, so what is
# checked is their DECISIONS and exit codes (a failed migration blocks the deploy; exit codes 1 and 3 survive the trip through
# Systems Manager; nothing is pushed by digest-less or mislabelled images). It does NOT prove that AWS accepts the calls: that
# needs a real run, after approval.
#   bash deploy/tests/ci-helpers.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
CI="$ROOT/deploy/ci"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
ORIG_PATH="$PATH"
PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); echo "PASS  $*"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL  $*"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: got [$2] expected [$3]"; fi; }
contains() { if grep -qF -- "$3" "$2" 2> /dev/null; then ok "$1"; else bad "$1: '$3' not found in $2"; fi; }
absent() { if grep -qF -- "$3" "$2" 2> /dev/null; then bad "$1: '$3' found in $2"; else ok "$1"; fi; }
count() { if [ -f "$2" ]; then grep -c -- "$1" "$2" || true; else echo 0; fi; }

SHA="$(printf '%040d' 0 | tr 0 a)"
SHA_B="$(printf '%040d' 0 | tr 0 b)"
DIGEST="sha256:$(printf '%064d' 0 | tr 0 c)"
ACCOUNT=111122223333
REGISTRY="$ACCOUNT.dkr.ecr.ap-south-1.amazonaws.com"
REPO="shopnest/staging/backend"
REF="$REGISTRY/$REPO@$DIGEST"
INSTANCE="i-0123456789abcdef0"
COMMAND_ID="11111111-2222-3333-4444-555555555555"

new_world() {
  W="$(mktemp -d "$T/w.XXXXXX")"
  mkdir -p "$W/bin" "$W/fake/ecr"
  cat > "$W/bin/aws" << EOF
#!/usr/bin/env bash
# fake aws: records every call; behaviour is chosen by files under \$FAKE
echo "aws \$*" >> "\$FAKE/calls.log"
q=""; prev=""
for a in "\$@"; do [ "\$prev" = "--query" ] && q="\$a"; prev="\$a"; done
pop() { # pop the first line of a file (keep the last one forever)
  local f="\$1" line
  [ -s "\$f" ] || { echo "\${2:-}"; return; }
  line="\$(head -n 1 "\$f")"
  if [ "\$(wc -l < "\$f")" -gt 1 ]; then tail -n +2 "\$f" > "\$f.new" && mv "\$f.new" "\$f"; fi
  echo "\$line"
}
case "\$1 \$2" in
  "sts get-caller-identity") [ -f "\$FAKE/sts_fail" ] && exit 1; echo $ACCOUNT ;;
  "ecr get-login-password") [ -f "\$FAKE/ecr_login_fail" ] && exit 1; echo "fake-registry-token" ;;
  "ecr describe-images")
    all="\$*"; tag="\${all#*imageTag=}"; tag="\${tag%% *}"   # join first: \${*#...} would strip each argument separately
    [ -f "\$FAKE/ecr/\$tag" ] || exit 254
    [ -f "\$FAKE/ecr_bad_digest" ] && { echo "not-a-digest"; exit 0; }
    case "\$q" in *imageDigest*) cat "\$FAKE/ecr/\$tag" ;; esac ;;
  "codebuild start-build") [ -f "\$FAKE/start_fail" ] && exit 1; echo "shopnest-staging-migrate:99999999-0000-0000-0000-000000000000" ;;
  "codebuild batch-get-builds")
    case "\$q" in
      *buildStatus*) pop "\$FAKE/build_statuses" SUCCEEDED ;;
      *groupName*) echo "/shopnest/staging/migrator" ;;
      *streamName*) echo "stream-1" ;;
    esac ;;
  "logs get-log-events") echo "migration 004_example.sql failed: syntax error near BROKEN" ;;
  "ssm send-command") [ -f "\$FAKE/ssm_send_fail" ] && exit 1; echo "$COMMAND_ID" ;;
  "ssm get-command-invocation")
    if [ -s "\$FAKE/ssm_missing" ]; then
      n="\$(cat "\$FAKE/ssm_missing")"
      if [ "\$n" -gt 0 ]; then echo \$((n - 1)) > "\$FAKE/ssm_missing"; exit 254; fi
    fi
    case "\$q" in
      Status) pop "\$FAKE/ssm_statuses" Success ;;
      ResponseCode) cat "\$FAKE/ssm_code" 2> /dev/null || echo 0 ;;
      StandardOutputContent) cat "\$FAKE/ssm_stdout" 2> /dev/null || echo "deploy output line" ;;
      StandardErrorContent) cat "\$FAKE/ssm_stderr" 2> /dev/null || echo "" ;;
    esac ;;
  *) exit 1 ;;
esac
EOF
  cat > "$W/bin/docker" << 'EOF'
#!/usr/bin/env bash
echo "docker $*" >> "$FAKE/calls.log"
case "$1" in
  load) cat > /dev/null; [ -f "$FAKE/load_fail" ] && exit 1; exit 0 ;;
  image) # docker image inspect <ref> --format ...
    cat "$FAKE/image_label" 2> /dev/null || echo "$FAKE_SHA"; exit 0 ;;
  login) cat > /dev/null; exit 0 ;;
  tag) exit 0 ;;
  push) [ -f "$FAKE/push_fail" ] && exit 1
        tag="${2##*:}"; cat "$FAKE/new_digest" > "$FAKE/ecr/$tag"; exit 0 ;;
esac
exit 0
EOF
  chmod +x "$W/bin/aws" "$W/bin/docker"
  echo "$DIGEST" > "$W/fake/new_digest"
  export FAKE="$W/fake" FAKE_SHA="$SHA" PATH="$W/bin:$ORIG_PATH"
  unset GITHUB_OUTPUT
}
calls() { count "$1" "$FAKE/calls.log"; }

# ================================================================== build-bundle.sh (real script, real files)
echo "== 1. build-bundle.sh: a release bundle"
new_world
mkdir -p "$W/front/assets"
echo "<html>release</html>" > "$W/front/index.html"
echo "console.log(1)" > "$W/front/assets/app.js"
bash "$CI/build-bundle.sh" --mode release --sha "$SHA" --frontend-dist "$W/front" --out "$W/out1" > "$W/log" 2>&1; check "release bundle builds" $? 0
tar -tzf "$W/out1/bundle.tar.gz" > "$W/list1"
for member in deploy/docker-compose.prod.yml deploy/scripts/bluegreen-deploy.sh deploy/scripts/rollback.sh deploy/scripts/lib/bluegreen-lib.sh \
  deploy/host/imds-guard.sh deploy/host/install-host-guards.sh deploy/host/shopnest-imds-guard.service deploy/host/shopnest-imds-guard-check.timer \
  deploy/env/staging.env deploy/env/production.env deploy/nginx/nginx.conf frontend-dist/index.html frontend-dist/assets/app.js RELEASE_SHA SHA256SUMS; do
  contains "contains $member" "$W/list1" "$member"
done
for forbidden in "deploy/tests" "docker-compose.dev.yml" "docker-compose.test.yml" "docker-compose.local-db.yml" ".env.example" "deploy/db" "backend-image" ".pem" "node_modules" "deploy/ci"; do
  absent "never contains $forbidden" "$W/list1" "$forbidden"
done
check "bundle.sha256 is the tarball's SHA-256" "$(cat "$W/out1/bundle.sha256")" "$(sha256sum "$W/out1/bundle.tar.gz" | cut -d' ' -f1)"
mkdir -p "$W/x1" && tar -xzf "$W/out1/bundle.tar.gz" -C "$W/x1"
check "RELEASE_SHA is the commit" "$(cat "$W/x1/RELEASE_SHA")" "$SHA"
check "the internal SHA256SUMS verifies" "$(cd "$W/x1" && sha256sum --check --strict SHA256SUMS > /dev/null 2>&1; echo $?)" 0
check "the bundled scripts are the repository's" "$(cmp -s "$ROOT/deploy/scripts/lib/bluegreen-lib.sh" "$W/x1/deploy/scripts/lib/bluegreen-lib.sh" && echo same || echo different)" same
# The guard does not rely on a file mode kept in Git (a checkout on Windows cannot record one): it is invoked through bash by the deploy
# path, and the host installer gives the INSTALLED copy mode 0755. These checks cover each of those facts in the bundle itself.
check "the guard is in the bundle, byte for byte the repository's" "$(cmp -s "$ROOT/deploy/host/imds-guard.sh" "$W/x1/deploy/host/imds-guard.sh" && echo same || echo different)" same
check "the host installer is in the bundle, byte for byte the repository's" "$(cmp -s "$ROOT/deploy/host/install-host-guards.sh" "$W/x1/deploy/host/install-host-guards.sh" && echo same || echo different)" same
check "the bundled installer installs the guard with mode 0755" "$(grep -cF 'install -m 0755 "$HERE/imds-guard.sh" "$ROOT/usr/local/sbin/shopnest-imds-guard"' "$W/x1/deploy/host/install-host-guards.sh")" 1
check "the bundled deploy path runs the guard through bash" "$(grep -cF 'bash "$BG_RELEASE_DIR/deploy/host/imds-guard.sh"' "$W/x1/deploy/scripts/lib/bluegreen-lib.sh")" 1
check "and never executes it directly (no mode needed)" "$(grep -E '(^|[^a-z] )"\$BG_RELEASE_DIR/deploy/host/imds-guard\.sh"' "$W/x1/deploy/scripts/lib/bluegreen-lib.sh" | grep -vc 'bash ')" 0
bash "$CI/build-bundle.sh" --mode release --sha "$SHA" --frontend-dist "$W/front" --out "$W/out1b" > /dev/null 2>&1
check "the bundle is reproducible (same inputs, same SHA-256)" "$(cat "$W/out1b/bundle.sha256")" "$(cat "$W/out1/bundle.sha256")"
echo "<html>changed</html>" > "$W/front/index.html"
bash "$CI/build-bundle.sh" --mode release --sha "$SHA" --frontend-dist "$W/front" --out "$W/out1c" > /dev/null 2>&1
if [ "$(cat "$W/out1c/bundle.sha256")" != "$(cat "$W/out1/bundle.sha256")" ]; then ok "different content gives a different hash"; else bad "different content gave the same hash"; fi

echo "== 2. build-bundle.sh: a carrier bundle (rollback tooling only)"
bash "$CI/build-bundle.sh" --mode carrier --sha "$SHA_B" --out "$W/out2" > "$W/log" 2>&1; check "carrier bundle builds" $? 0
tar -tzf "$W/out2/bundle.tar.gz" > "$W/list2"
absent "a carrier has no frontend files" "$W/list2" "frontend-dist"
contains "a carrier has the rollback script" "$W/list2" "deploy/scripts/rollback.sh"
contains "a carrier has the guard" "$W/list2" "deploy/host/imds-guard.sh"

echo "== 3. build-bundle.sh refuses bad requests (nothing is built)"
refuse_bundle() { # <label> <args...>
  local label="$1"; shift
  rm -rf "$W/o"; bash "$CI/build-bundle.sh" "$@" --out "$W/o" > "$W/log" 2>&1; check "$label: refused" $? 1
  check "$label: no tarball was produced" "$([ -e "$W/o/bundle.tar.gz" ] && echo yes || echo no)" no
}
refuse_bundle "a malformed sha" --mode release --sha nothex --frontend-dist "$W/front"
refuse_bundle "an unknown mode" --mode other --sha "$SHA"
refuse_bundle "a release without a frontend build" --mode release --sha "$SHA"
refuse_bundle "a release with a missing frontend directory" --mode release --sha "$SHA" --frontend-dist "$W/nowhere"
mkdir -p "$W/empty"; : > "$W/empty/index.html"
refuse_bundle "a frontend whose index.html is empty" --mode release --sha "$SHA" --frontend-dist "$W/empty"
refuse_bundle "a carrier that carries frontend files" --mode carrier --sha "$SHA" --frontend-dist "$W/front"
bash "$CI/build-bundle.sh" --mode carrier --sha "$SHA" > "$W/log" 2>&1; check "a missing --out is refused" $? 1
bash "$CI/build-bundle.sh" --bogus > "$W/log" 2>&1; check "an unknown argument is refused" $? 1

# ================================================================== push-image.sh
echo "== 4. push-image.sh"
push() { bash "$CI/push-image.sh" --image-tar "$W/image.tar.gz" --repository "$REPO" --sha "$SHA" --region ap-south-1 > "$W/out" 2>&1; }
new_world; echo image > "$W/image.tar.gz"; gzip -f "$W/image.tar.gz" 2> /dev/null || true; [ -f "$W/image.tar.gz" ] || cp "$W/image.tar.gz.gz" "$W/image.tar.gz" 2> /dev/null
printf 'x' | gzip > "$W/image.tar.gz"
export GITHUB_OUTPUT="$W/gh_output"
push; check "a correct image is pushed" $? 0
contains "it prints the DIGEST reference" "$W/out" "image_ref=$REF"
contains "and exports it to the workflow" "$W/gh_output" "image_ref=$REF"
check "it was pushed once, under the commit tag" "$(calls "^docker push $REGISTRY/$REPO:$SHA$")" 1
check "the account id was masked before it could appear in a log" "$(grep -n '::add-mask::' "$W/out" | head -1 | cut -d: -f1)" 1
check "the login used a password on stdin, not on the command line" "$(calls 'fake-registry-token')" 0
check "the digest was read back from ECR, not assumed" "$(calls '^aws ecr describe-images.*imageDigest')" 1
unset GITHUB_OUTPUT

new_world; printf 'x' | gzip > "$W/image.tar.gz"; echo "$SHA_B" > "$FAKE/image_label"
push; check "an image labelled with another commit is refused" $? 1
contains "explains" "$W/out" "revision label"
check "and was never pushed" "$(calls '^docker push')" 0

new_world; printf 'x' | gzip > "$W/image.tar.gz"; echo "" > "$FAKE/image_label"
push; check "an image with no revision label is refused" $? 1
check "and was never pushed" "$(calls '^docker push')" 0

new_world; printf 'x' | gzip > "$W/image.tar.gz"; echo "$DIGEST" > "$FAKE/ecr/$SHA"
push; check "an existing immutable tag (a re-run): succeeds" $? 0
check "nothing is pushed again" "$(calls '^docker push')" 0
contains "it uses the existing image's digest" "$W/out" "image_ref=$REF"

new_world; printf 'x' | gzip > "$W/image.tar.gz"; touch "$FAKE/push_fail"
push; check "a failed push fails the step" $? 1
absent "and prints no image reference" "$W/out" "image_ref="
new_world; printf 'x' | gzip > "$W/image.tar.gz"; touch "$FAKE/ecr_login_fail"
push; check "a failed registry login fails the step" $? 1
check "nothing was pushed" "$(calls '^docker push')" 0
new_world; printf 'x' | gzip > "$W/image.tar.gz"; touch "$FAKE/ecr_bad_digest"; echo "$DIGEST" > "$FAKE/ecr/$SHA"
push; check "a digest that is not a digest is refused" $? 1
new_world; printf 'x' | gzip > "$W/image.tar.gz"; touch "$FAKE/sts_fail"
push; check "an unknown AWS identity is refused" $? 1
new_world; printf 'x' | gzip > "$W/image.tar.gz"; touch "$FAKE/load_fail"
push; check "an image that will not load is refused" $? 1
new_world
bash "$CI/push-image.sh" --image-tar "$W/none.tar.gz" --repository "$REPO" --sha "$SHA" --region ap-south-1 > "$W/out" 2>&1; check "a missing image file is refused" $? 1
printf 'x' | gzip > "$W/image.tar.gz"
bash "$CI/push-image.sh" --image-tar "$W/image.tar.gz" --repository "Bad Repo" --sha "$SHA" --region ap-south-1 > "$W/out" 2>&1; check "a bad repository name is refused" $? 1
bash "$CI/push-image.sh" --image-tar "$W/image.tar.gz" --repository "$REPO" --sha short --region ap-south-1 > "$W/out" 2>&1; check "a bad sha is refused" $? 1
bash "$CI/push-image.sh" --image-tar "$W/image.tar.gz" --repository "$REPO" --sha "$SHA" --region mumbai > "$W/out" 2>&1; check "a bad region is refused" $? 1
check "none of those touched AWS or Docker" "$(calls '^aws \|^docker ')" 0

# ================================================================== run-codebuild.sh
echo "== 5. run-codebuild.sh: a failed migration blocks the deployment"
migrate() { bash "$CI/run-codebuild.sh" --project shopnest-staging-migrate --image-ref "$REF" --release-sha "$SHA" --region ap-south-1 --poll 0 "$@" > "$W/out" 2>&1; }
new_world; printf 'IN_PROGRESS\nIN_PROGRESS\nSUCCEEDED\n' > "$FAKE/build_statuses"
migrate; check "a build that succeeds: exit 0" $? 0
contains "the release image is the image override, by digest" "$FAKE/calls.log" "--image-override $REF"
contains "it pulls with the project's own role" "$FAKE/calls.log" "--image-pull-credentials-type-override SERVICE_ROLE"
contains "it passes the release commit" "$FAKE/calls.log" "name=RELEASE_SHA,value=$SHA,type=PLAINTEXT"
check "it waited for the build (three status reads)" "$(calls 'buildStatus')" 3
for status in FAILED FAULT STOPPED TIMED_OUT; do
  new_world; printf 'IN_PROGRESS\n%s\n' "$status" > "$FAKE/build_statuses"
  migrate; check "$status: exit 1, so the workflow does NOT deploy" $? 1
  contains "$status: says the deployment is blocked" "$W/out" "The deployment is blocked; nothing was deployed"
done
new_world; printf 'FAILED\n' > "$FAKE/build_statuses"; migrate
contains "a failure shows the tail of the build log" "$W/out" "migration 004_example.sql failed"
absent "and no secret" "$W/out" "fake-registry-token"
new_world; printf 'IN_PROGRESS\n' > "$FAKE/build_statuses"; migrate --max-wait 0
check "a build that does not finish in time is a failure, not a success" $? 1
contains "explains" "$W/out" "NOT_FINISHED"
new_world; touch "$FAKE/start_fail"; migrate; check "a build that cannot be started fails" $? 1
check "and never polled" "$(calls 'batch-get-builds')" 0
new_world
bash "$CI/run-codebuild.sh" --project shopnest-staging-migrate --image-ref "$REGISTRY/$REPO:latest" --release-sha "$SHA" --region ap-south-1 > "$W/out" 2>&1; check "a tag instead of a digest is refused (exit 2)" $? 2
bash "$CI/run-codebuild.sh" --project "bad name" --image-ref "$REF" --release-sha "$SHA" --region ap-south-1 > "$W/out" 2>&1; check "a bad project name is refused (exit 2)" $? 2
bash "$CI/run-codebuild.sh" --project shopnest-staging-migrate --image-ref "$REF" --release-sha nothex --region ap-south-1 > "$W/out" 2>&1; check "a bad sha is refused (exit 2)" $? 2
bash "$CI/run-codebuild.sh" --project shopnest-staging-migrate --image-ref "$REF" --release-sha "$SHA" --region ap-south-1 --poll x > "$W/out" 2>&1; check "a bad poll interval is refused (exit 2)" $? 2
check "none of those started a build" "$(calls 'start-build')" 0

# ================================================================== run-ssm-command.sh
echo "== 6. run-ssm-command.sh: exit codes 0, 1 and 3 survive Systems Manager"
ssm() { bash "$CI/run-ssm-command.sh" --document shopnest-staging-deploy --instance "$INSTANCE" --region ap-south-1 --timeout 1200 --poll 0 --max-wait 5 "$@" > "$W/out" 2>&1; }
PARAMS=(Sha="$SHA" ImageRef="$REF" BundleKey="deploy/staging/$SHA/bundle.tar.gz" BundleSha256="$(printf '%064d' 0 | tr 0 d)")
new_world; printf 'InProgress\nSuccess\n' > "$FAKE/ssm_statuses"; echo 0 > "$FAKE/ssm_code"
ssm -- "${PARAMS[@]}"; check "Success with exit code 0: 0" $? 0
contains "the command output is shown" "$W/out" "deploy output line"
contains "the parameters are sent as JSON" "$FAKE/calls.log" "\"Sha\":[\"$SHA\"]"
contains "the image is sent as a digest" "$FAKE/calls.log" "\"ImageRef\":[\"$REF\"]"
contains "the timeout is passed" "$FAKE/calls.log" "--timeout-seconds 1200"
contains "exactly the named document and instance" "$FAKE/calls.log" "--document-name shopnest-staging-deploy --instance-ids $INSTANCE"
absent "no SSH, no key, no host" "$FAKE/calls.log" "ssh"

new_world; printf 'Failed\n' > "$FAKE/ssm_statuses"; echo 1 > "$FAKE/ssm_code"
ssm -- "${PARAMS[@]}"; check "Failed with code 1 (previous release still serving): 1" $? 1
contains "says the previous release is serving" "$W/out" "previous release is still serving"
new_world; printf 'Failed\n' > "$FAKE/ssm_statuses"; echo 3 > "$FAKE/ssm_code"
ssm -- "${PARAMS[@]}"; check "Failed with code 3 (recovery failed too): 3" $? 3
contains "says an operator is needed" "$W/out" "CRITICAL"
for code in 2 4 127 255; do
  new_world; printf 'Failed\n' > "$FAKE/ssm_statuses"; echo "$code" > "$FAKE/ssm_code"
  ssm -- "${PARAMS[@]}"; check "Failed with unexpected code $code: 4 (unconfirmed, never success)" $? 4
done
for st in TimedOut Cancelled; do
  new_world; printf '%s\n' "$st" > "$FAKE/ssm_statuses"; echo -1 > "$FAKE/ssm_code"
  ssm -- "${PARAMS[@]}"; check "$st: 4" $? 4
done
new_world; printf 'Success\n' > "$FAKE/ssm_statuses"; echo 1 > "$FAKE/ssm_code"
ssm -- "${PARAMS[@]}"; check "Success status with a non-zero code is NOT treated as success: 4" $? 4
new_world; printf 'InProgress\n' > "$FAKE/ssm_statuses"
ssm --max-wait 0 -- "${PARAMS[@]}"; check "a command that does not finish in time: 4" $? 4
contains "warns it may still be running" "$W/out" "may still be running"
new_world; echo 3 > "$FAKE/ssm_missing"; printf 'Success\n' > "$FAKE/ssm_statuses"
ssm -- "${PARAMS[@]}"; check "an invocation that appears a moment late is waited for" $? 0
new_world; echo 99 > "$FAKE/ssm_missing"
ssm -- "${PARAMS[@]}"; check "an invocation that never appears: 4" $? 4
new_world; touch "$FAKE/ssm_send_fail"
ssm -- "${PARAMS[@]}"; check "a command that cannot be sent: 4" $? 4
new_world; printf 'Success\n' > "$FAKE/ssm_statuses"; echo "stderr-line" > "$FAKE/ssm_stderr"
ssm --log-file "$W/deploy.log" -- "${PARAMS[@]}"; check "a log file is written" $? 0
contains "the log has the output" "$W/deploy.log" "deploy output line"
contains "the log has the errors" "$W/deploy.log" "stderr-line"

echo "== 7. run-ssm-command.sh refuses anything that could become a command (nothing is sent)"
new_world
refuse_ssm() { # <label> <args...>
  local label="$1"; shift
  bash "$CI/run-ssm-command.sh" "$@" > "$W/out" 2>&1; check "$label: refused (exit 2)" $? 2
}
base=(--document shopnest-staging-deploy --instance "$INSTANCE" --region ap-south-1 --timeout 1200)
refuse_ssm "a value with a space" "${base[@]}" -- "Sha=a b"
refuse_ssm "a value with a semicolon" "${base[@]}" -- "Sha=$SHA;touch"
refuse_ssm "a value with a command substitution" "${base[@]}" -- 'Sha=$(id)'
refuse_ssm "a value with a quote" "${base[@]}" -- "Sha=\"x"
refuse_ssm "a value with a comma" "${base[@]}" -- "Sha=a,b"
refuse_ssm "an empty value" "${base[@]}" -- "Sha="
refuse_ssm "a parameter name with punctuation" "${base[@]}" -- "Sh-a=abc"
refuse_ssm "no parameters" "${base[@]}"
refuse_ssm "a document name with a space" --document "a b" --instance "$INSTANCE" --region ap-south-1 --timeout 1200 -- Sha=abc
refuse_ssm "an instance that is not an instance id" --document shopnest-staging-deploy --instance "web-server-1" --region ap-south-1 --timeout 1200 -- Sha=abc
refuse_ssm "a bad region" --document shopnest-staging-deploy --instance "$INSTANCE" --region mumbai --timeout 1200 -- Sha=abc
refuse_ssm "a bad timeout" --document shopnest-staging-deploy --instance "$INSTANCE" --region ap-south-1 --timeout x -- Sha=abc
refuse_ssm "an unknown argument" --bogus
check "none of those sent a command" "$(calls 'send-command')" 0

echo
echo "ci-helpers tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
