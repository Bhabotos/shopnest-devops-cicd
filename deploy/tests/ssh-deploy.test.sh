#!/usr/bin/env bash
# Offline tests for deploy/ci/ssh-deploy.sh (SSH through an SSM tunnel) and deploy/ci/install-ssm-plugin.sh, against FAKE aws, ssh, curl,
# sudo and session-manager-plugin programs (only ssh-keygen is real). No network, no AWS, no instance. What is proven:
#   - bad arguments, a missing or malformed key and a malformed host key are refused (exit 2) before anything is opened
#   - the tunnel is opened with the AWS port-forwarding document, ssh runs with StrictHostKeyChecking=yes against ONLY the pinned
#     host key, with key-only authentication, as the deploy user, to the tunnel's local end
#   - a --check pre-flight runs first; if it is refused the real command is never sent
#   - the host's exit codes 1 and 3 pass through; a lost connection, an unknown code or an unconfirmed success is 4
#   - on EVERY path (success, failure, refusal, a bad key, a dead tunnel, SIGTERM) the SSM session is terminated, the tunnel process is
#     stopped and the key and its directory are deleted; the key never appears in any output
#   - the plugin installer refuses a package whose SHA-256 differs from the pin and never installs it
# It does NOT prove that AWS, the SSM agent, sshd or the instance behave: that needs the real run.
#   bash deploy/tests/ssh-deploy.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CI_DIR="$(cd "$HERE/../ci" && pwd)"
SCRIPT="$CI_DIR/ssh-deploy.sh"
INSTALL="$CI_DIR/install-ssm-plugin.sh"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); echo "PASS  $*"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL  $*"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: got [$2] expected [$3]"; fi; }
has() { if grep -qF -- "$3" "$2" 2> /dev/null; then ok "$1"; else bad "$1: '$3' not found in $2"; fi; }
lacks() { if grep -qF -- "$3" "$2" 2> /dev/null; then bad "$1: '$3' found in $2"; else ok "$1"; fi; }

command -v ssh-keygen > /dev/null 2>&1 || { echo "SKIP  ssh-keygen is not installed"; exit 0; }

# ---- fakes ---------------------------------------------------------------------------------------------------------------------------
BIN="$T/bin"
FAKE="$T/fake"
mkdir -p "$BIN" "$FAKE"
cat > "$BIN/aws" << 'EOF'
#!/usr/bin/env bash
# fake aws: "ssm start-session" behaves like the real tunnel (prints, then waits for a signal); "ssm terminate-session" is recorded
case "$2" in
  start-session)
    echo "$*" >> "$FAKE_DIR/aws.calls"
    if [ "${FAKE_TUNNEL:-up}" = dies ]; then echo "An error occurred (TargetNotConnected) when calling the StartSession operation"; exit 254; fi
    if [ "${FAKE_TUNNEL:-up}" = denied ]; then echo "An error occurred (AccessDeniedException) when calling the StartSession operation: User: arn:aws:sts::123456789012:assumed-role/example-role/GitHubActions is not authorized to perform: ssm:StartSession on resource: arn:aws:ec2:ap-south-1:123456789012:instance/i-0123456789abcdef0"; exit 254; fi
    echo "Starting session with SessionId: test-user-0abc123"
    echo "Port 2222 opened for sessionId test-user-0abc123."
    echo "Waiting for connections..."
    trap 'echo terminated > "$FAKE_DIR/tunnel-killed"; exit 0' TERM
    while :; do sleep 1; done
    ;;
  terminate-session) echo "$*" >> "$FAKE_DIR/terminate.log" ;;
esac
EOF
cat > "$BIN/session-manager-plugin" << 'EOF'
#!/usr/bin/env bash
echo "${FAKE_PLUGIN_VERSION:-1.2.896.0}"
EOF
cat > "$BIN/ssh" << 'EOF'
#!/usr/bin/env bash
# fake ssh: records its arguments, the known_hosts it was given and the key file's state; answers like the host would
echo "---" >> "$FAKE_DIR/ssh.args"
printf '%s\n' "$@" >> "$FAKE_DIR/ssh.args"
key="" known=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  [ "${args[$i]}" = "-i" ] && key="${args[$((i + 1))]}"
  case "${args[$i]}" in UserKnownHostsFile=*) known="${args[$i]#UserKnownHostsFile=}" ;; esac
done
echo "$key" >> "$FAKE_DIR/keypath"
[ -f "$key" ] && stat -c '%a' "$key" >> "$FAKE_DIR/keymode"
[ -f "$known" ] && cat "$known" >> "$FAKE_DIR/known_hosts.seen"
remote="${args[$((${#args[@]} - 1))]}"
echo "$remote" >> "$FAKE_DIR/ssh.remote"
sha="$(printf '%s' "$remote" | grep -o -- '--sha [0-9a-f]\{40\}' | cut -d' ' -f2)"
case "$remote" in
  *" --check")
    case "${FAKE_SSH_MODE:-ok}" in
      refuse_check) echo "shopnest-ssh-entry: refused: this key may only act on staging" >&2; exit 2 ;;
      lost_connection) exit 255 ;;
      *) echo ok; exit 0 ;;
    esac
    ;;
esac
touch "$FAKE_DIR/real-command-sent"
case "${FAKE_SSH_MODE:-ok}" in
  slow) touch "$FAKE_DIR/ssh-running"; sleep 60; exit 0 ;;
  rc1) echo "release failed health check; previous release is serving"; exit 1 ;;
  rc3) echo "ROLLBACK FAILED AND RECOVERY FAILED"; exit 3 ;;
  rc255) echo "client_loop: send disconnect: Broken pipe"; exit 255 ;;
  rc7) echo "something unexpected"; exit 7 ;;
  noconfirm) echo "release done (but nothing that confirms the commit)"; exit 0 ;;
esac
case "$remote" in
  shopnest-rollback*)
    echo "manual rollback"
    echo "ROLLBACK SUCCEEDED: $sha is live on staging"
    ;;
  *)
    echo "lab mode: scripts are a git checkout of $sha"
    echo "backend image shopnest-backend:$sha pulled from GHCR by digest and its revision label matches"
    echo "frontend files for $sha unpacked from the GHCR image (digest pinned, revision label matches)"
    echo "release $sha is live on green"
    ;;
esac
exit 0
EOF
chmod +x "$BIN"/*

# ---- inputs --------------------------------------------------------------------------------------------------------------------------
ssh-keygen -q -t ed25519 -N '' -C 'test-deploy-key' -f "$T/deploykey"
ssh-keygen -q -t ed25519 -N '' -C 'test-host' -f "$T/hostkey"
ssh-keygen -q -t rsa -b 2048 -N '' -C 'test-rsa' -f "$T/rsakey"
DEPLOY_KEY="$(cat "$T/deploykey")"
KEY_BODY="$(sed -n 2p "$T/deploykey")"
HOST_KEY="$(cut -d' ' -f1,2 "$T/hostkey.pub")"
SHA="$(printf '%040d' 0 | tr 0 a)"
SHA2="$(printf '%040d' 0 | tr 0 b)"
DIGEST="$(printf '%064d' 0 | tr 0 c)"
BACKEND="ghcr.io/exampleowner/shopnest-backend@sha256:$DIGEST"
FRONTEND="ghcr.io/exampleowner/shopnest-frontend@sha256:$DIGEST"
INSTANCE="i-0123456789abcdef0"

probe="$T/modeprobe"; : > "$probe"; chmod 600 "$probe"
if [ "$(stat -c '%a' "$probe")" = 600 ]; then MODE_OK=1; else MODE_OK=0; fi

# run <name> <env assignments...> -- <script args...>: runs the script with the fakes first in PATH; $T/<name>.out is its output
run() {
  local name="$1"
  shift
  rm -rf "$FAKE"
  mkdir -p "$FAKE"
  local envs=()
  while [ "$1" != "--" ]; do envs+=("$1"); shift; done
  shift
  env -i HOME="$T" PATH="$BIN:/usr/bin:/bin:/mingw64/bin" FAKE_DIR="$FAKE" DEPLOY_SSH_KEY="$DEPLOY_KEY" SSH_HOST_KEY="$HOST_KEY" TMPDIR="$T" "${envs[@]}" \
    bash "$SCRIPT" "$@" > "$T/$name.out" 2>&1
  echo $?
}
deploy_args=(deploy --environment staging --instance "$INSTANCE" --region ap-south-1 --sha "$SHA" --image-ref "$BACKEND" --frontend-ref "$FRONTEND" --seed)
prod_args=(deploy --environment production --instance "$INSTANCE" --region ap-south-1 --sha "$SHA" --image-ref "$BACKEND" --frontend-ref "$FRONTEND")
rollback_args=(rollback --environment production --instance "$INSTANCE" --region ap-south-1 --sha "$SHA" --carrier-sha "$SHA2")

after_cleanup() { # the clean-up invariants that must hold after EVERY run that got as far as the tunnel
  local label="$1"
  [ -f "$FAKE/tunnel-killed" ] && ok "$label: the tunnel process was stopped" || bad "$label: the tunnel process was not stopped"
  has "$label: the SSM session was terminated" "$FAKE/terminate.log" "--session-id test-user-0abc123"
}
key_deleted() {
  local label="$1" path
  path="$(head -n 1 "$FAKE/keypath" 2> /dev/null)"
  if [ -n "$path" ] && [ ! -e "$path" ] && [ ! -d "$(dirname "$path")" ]; then ok "$label: the key and its directory are deleted"; else bad "$label: the key or its directory is still there ($path)"; fi
}

echo "== a deploy to staging"
check "exit code" "$(run stg -- "${deploy_args[@]}")" 0
has "the result is confirmed" "$T/stg.out" "CONFIRMED: $SHA is live in staging"
has "the digests are reported" "$T/stg.out" "$DIGEST"
has "only the PUBLIC fingerprint of the key is logged" "$T/stg.out" "(public fingerprint)"
check "ssh ran twice: the --check pre-flight, then the real command" "$(grep -c '^---$' "$FAKE/ssh.args")" 2
check "the first remote command is the pre-flight" "$(sed -n 1p "$FAKE/ssh.remote")" "shopnest-deploy --env staging --sha $SHA --image-ref $BACKEND --frontend-ref $FRONTEND --seed --check"
check "the second is exactly the deploy, with the seed flag" "$(sed -n 2p "$FAKE/ssh.remote")" "shopnest-deploy --env staging --sha $SHA --image-ref $BACKEND --frontend-ref $FRONTEND --seed"
has "StrictHostKeyChecking is yes" "$FAKE/ssh.args" "StrictHostKeyChecking=yes"
lacks "StrictHostKeyChecking is never relaxed" "$FAKE/ssh.args" "StrictHostKeyChecking=no"
lacks "no accept-new either" "$FAKE/ssh.args" "accept-new"
has "only the pinned known_hosts file is used" "$FAKE/ssh.args" "GlobalKnownHostsFile=/dev/null"
has "password login is off" "$FAKE/ssh.args" "PasswordAuthentication=no"
has "batch mode (no prompt can ever wait)" "$FAKE/ssh.args" "BatchMode=yes"
has "no agent is used" "$FAKE/ssh.args" "IdentityAgent=none"
has "the user is deploy, at the tunnel's local end" "$FAKE/ssh.args" "deploy@127.0.0.1"
check "the pinned host key is the ONLY known host, recorded for the tunnel's local port" "$(sort -u "$FAKE/known_hosts.seen")" "[127.0.0.1]:2222 $HOST_KEY"
has "the tunnel uses the AWS port-forwarding document" "$FAKE/aws.calls" "--document-name AWS-StartPortForwardingSession"
has "the tunnel targets the one instance" "$FAKE/aws.calls" "--target $INSTANCE"
has "the tunnel forwards port 22 to the local port" "$FAKE/aws.calls" '"portNumber":["22"]'
if [ "$MODE_OK" = 1 ]; then check "the key file is mode 600" "$(head -n 1 "$FAKE/keymode")" 600; else echo "SKIP  key file mode (this filesystem cannot hold mode 600; CI runs on Linux)"; fi
lacks "the key never appears in the output" "$T/stg.out" "$KEY_BODY"
lacks "no private key marker in the output" "$T/stg.out" "BEGIN OPENSSH PRIVATE KEY"
after_cleanup "staging deploy"
key_deleted "staging deploy"

echo "== a deploy to production (no seed)"
check "exit code" "$(run prod -- "${prod_args[@]}")" 0
check "the real command names production and has no --seed" "$(sed -n 2p "$FAKE/ssh.remote")" "shopnest-deploy --env production --sha $SHA --image-ref $BACKEND --frontend-ref $FRONTEND"
after_cleanup "production deploy"

echo "== a rollback"
check "exit code" "$(run rb -- "${rollback_args[@]}")" 0
check "the real command is the rollback wrapper with the carrier" "$(sed -n 2p "$FAKE/ssh.remote")" "shopnest-rollback --env production --sha $SHA --carrier-sha $SHA2"
has "the result is confirmed" "$T/rb.out" "CONFIRMED: production is serving $SHA"
after_cleanup "rollback"

echo "== what the host answers"
check "the host exits 1 (failed, previous release serving)" "$(run r1 FAKE_SSH_MODE=rc1 -- "${deploy_args[@]}")" 1
after_cleanup "exit 1"; key_deleted "exit 1"
check "the host exits 3 (failed and the rollback failed)" "$(run r3 FAKE_SSH_MODE=rc3 -- "${deploy_args[@]}")" 3
after_cleanup "exit 3"
check "the connection breaks (255)" "$(run r255 FAKE_SSH_MODE=rc255 -- "${deploy_args[@]}")" 4
after_cleanup "exit 255"
check "an unexpected code is unconfirmed (4)" "$(run r7 FAKE_SSH_MODE=rc7 -- "${deploy_args[@]}")" 4
after_cleanup "unexpected code"
check "exit 0 without the host's confirmation is unconfirmed (4)" "$(run nc FAKE_SSH_MODE=noconfirm -- "${deploy_args[@]}")" 4
has "it says why" "$T/nc.out" "did not report"
after_cleanup "unconfirmed success"

echo "== the pre-flight"
check "a refused pre-flight stops everything (exit 4)" "$(run pf FAKE_SSH_MODE=refuse_check -- "${deploy_args[@]}")" 4
[ ! -f "$FAKE/real-command-sent" ] && ok "the real command is NEVER sent after a refused pre-flight" || bad "the real command was sent after a refused pre-flight"
has "the host's reason is shown" "$T/pf.out" "this key may only act on staging"
after_cleanup "refused pre-flight"; key_deleted "refused pre-flight"

echo "== a dead tunnel and a bad key"
check "the tunnel cannot be opened (exit 4)" "$(run dead FAKE_TUNNEL=dies -- "${deploy_args[@]}")" 4
check "an AccessDenied from AWS fails closed (exit 4)" "$(run denied FAKE_TUNNEL=denied -- "${deploy_args[@]}")" 4
has "the AWS error text is still shown" "$T/denied.out" "AccessDeniedException"
lacks "the account id is redacted from the printed error" "$T/denied.out" "123456789012"
lacks "the instance id is redacted from the printed error" "$T/denied.out" "i-0123456789abcdef0"
has "redaction leaves a marker for the account" "$T/denied.out" "<account>"
has "redaction leaves a marker for the instance" "$T/denied.out" "<instance>"
has "the tunnel's own error is shown" "$T/dead.out" "TargetNotConnected"
[ ! -f "$FAKE/ssh.args" ] && ok "ssh is never run without a tunnel" || bad "ssh ran without a tunnel"
check "a key that is not a private key (exit 4)" "$(run badkey DEPLOY_SSH_KEY='not a key at all' -- "${deploy_args[@]}")" 4
[ ! -f "$FAKE/aws.calls" ] && ok "no tunnel is opened for a bad key" || bad "a tunnel was opened for a bad key"
check "an RSA key is refused (exit 4)" "$(run rsa DEPLOY_SSH_KEY="$(cat "$T/rsakey")" -- "${deploy_args[@]}")" 4
has "it says ed25519" "$T/rsa.out" "not an ed25519 key"
[ ! -f "$FAKE/aws.calls" ] && ok "no tunnel is opened for an RSA key" || bad "a tunnel was opened for an RSA key"

echo "== a signal during the deploy"
rm -rf "$FAKE"; mkdir -p "$FAKE"
env -i HOME="$T" PATH="$BIN:/usr/bin:/bin:/mingw64/bin" FAKE_DIR="$FAKE" FAKE_SSH_MODE=slow DEPLOY_SSH_KEY="$DEPLOY_KEY" SSH_HOST_KEY="$HOST_KEY" TMPDIR="$T" \
  bash "$SCRIPT" "${deploy_args[@]}" > "$T/sig.out" 2>&1 &
pid=$!
for _ in $(seq 1 60); do [ -f "$FAKE/ssh-running" ] && break; sleep 0.5; done
if [ -f "$FAKE/ssh-running" ]; then
  kill -TERM "$pid" 2> /dev/null
  wait "$pid" 2> /dev/null
  rc=$?
  check "exit code after SIGTERM" "$rc" 143
  after_cleanup "SIGTERM"
  key_deleted "SIGTERM"
else
  kill "$pid" 2> /dev/null
  bad "the slow fake ssh never started"
fi
pkill -f "$BIN/ssh" 2> /dev/null || true

echo "== refused before anything opens (exit 2)"
check "no action" "$(run a0 -- )" 2
check "unknown action" "$(run a1 -- upgrade --environment staging)" 2
check "unknown environment" "$(run a2 -- deploy --environment dev --instance "$INSTANCE" --region ap-south-1 --sha "$SHA" --image-ref "$BACKEND" --frontend-ref "$FRONTEND")" 2
check "bad instance id" "$(run a3 -- deploy --environment staging --instance "i-123;id" --region ap-south-1 --sha "$SHA" --image-ref "$BACKEND" --frontend-ref "$FRONTEND")" 2
check "bad region" "$(run a4 -- deploy --environment staging --instance "$INSTANCE" --region "ap south" --sha "$SHA" --image-ref "$BACKEND" --frontend-ref "$FRONTEND")" 2
check "short sha" "$(run a5 -- deploy --environment staging --instance "$INSTANCE" --region ap-south-1 --sha abc --image-ref "$BACKEND" --frontend-ref "$FRONTEND")" 2
check "image by tag" "$(run a6 -- deploy --environment staging --instance "$INSTANCE" --region ap-south-1 --sha "$SHA" --image-ref ghcr.io/exampleowner/shopnest-backend:latest --frontend-ref "$FRONTEND")" 2
check "image with a command appended" "$(run a7 -- deploy --environment staging --instance "$INSTANCE" --region ap-south-1 --sha "$SHA" --image-ref "$BACKEND;id" --frontend-ref "$FRONTEND")" 2
check "production with --seed" "$(run a8 -- "${prod_args[@]}" --seed)" 2
check "privileged local port" "$(run a9 -- "${deploy_args[@]}" --local-port 22)" 2
check "unknown flag" "$(run a10 -- "${deploy_args[@]}" --privileged)" 2
# A valued option with no value must be refused at once (exit 2), never looped on: `timeout` turns a hang into exit 124.
for opt in --environment --instance --region --sha --image-ref --frontend-ref --carrier-sha --local-port --log-file; do
  check "$opt without a value is refused immediately" "$(timeout 20 bash "$SCRIPT" deploy "$opt" > /dev/null 2>&1; echo $?)" 2
  check "$opt as the LAST argument without a value is refused immediately" "$(timeout 20 bash "$SCRIPT" deploy --environment staging "$opt" > /dev/null 2>&1; echo $?)" 2
done
check "rollback without the carrier" "$(run a11 -- rollback --environment staging --instance "$INSTANCE" --region ap-south-1 --sha "$SHA")" 2
check "rollback with an image" "$(run a12 -- "${rollback_args[@]}" --image-ref "$BACKEND")" 2
check "deploy with a carrier" "$(run a13 -- "${deploy_args[@]}" --carrier-sha "$SHA2")" 2
check "no key set" "$(run a14 DEPLOY_SSH_KEY= -- "${deploy_args[@]}")" 2
check "host key missing" "$(run a15 SSH_HOST_KEY= -- "${deploy_args[@]}")" 2
check "host key of another type" "$(run a16 SSH_HOST_KEY="$(cut -d' ' -f1,2 "$T/rsakey.pub")" -- "${deploy_args[@]}")" 2
check "host key with a trailing comment" "$(run a17 SSH_HOST_KEY="$HOST_KEY extra" -- "${deploy_args[@]}")" 2
for n in a0 a1 a2 a3 a4 a5 a6 a7 a8 a9 a10 a11 a12 a13 a14 a15 a16 a17; do
  [ ! -f "$FAKE/aws.calls" ] || { bad "$n: a tunnel was opened for a refused request"; break; }
done
[ ! -f "$FAKE/aws.calls" ] && ok "no tunnel was ever opened for a refused request"
lacks "a refusal does not print the key" "$T/a14.out" "$KEY_BODY"

echo "== the pinned plugin installer"
IBIN="$T/ibin"
mkdir -p "$IBIN" "$T/idir"
cat > "$IBIN/curl" << 'EOF'
#!/usr/bin/env bash
out=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do [ "${args[$i]}" = "--output" ] && out="${args[$((i + 1))]}"; done
printf '%s' "${FAKE_PAYLOAD-genuine plugin package}" > "$out"
echo "${args[*]}" >> "$FAKE_DIR/curl.args"
EOF
cat > "$IBIN/sudo" << 'EOF'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_DIR/sudo.calls"
EOF
cp "$BIN/session-manager-plugin" "$IBIN/session-manager-plugin"
chmod +x "$IBIN"/*
good_sha="$(printf '%s' 'genuine plugin package' | sha256sum | cut -d' ' -f1)"
# A test copy of the installer whose pin is the checksum of the fake "genuine" payload (the real pin belongs to the real package).
sed "s/^PLUGIN_SHA256=.*/PLUGIN_SHA256=\"$good_sha\"/" "$INSTALL" > "$T/install-test.sh"
irun() { # irun <script> <env...>
  local script="$1"
  shift
  rm -rf "$FAKE"; mkdir -p "$FAKE"
  env -i HOME="$T" PATH="$IBIN:/usr/bin:/bin:/mingw64/bin" FAKE_DIR="$FAKE" TMPDIR="$T" "$@" bash "$script" > "$T/install.out" 2>&1
  echo $?
}
check "the genuine package is installed" "$(irun "$T/install-test.sh")" 0
has "it installed through dpkg" "$FAKE/sudo.calls" "dpkg --install"
has "the download is HTTPS only" "$FAKE/curl.args" "--proto =https"
has "the pinned version is in the URL (never latest)" "$FAKE/curl.args" "/plugin/1.2.896.0/ubuntu_64bit/"
lacks "the URL never says latest" "$FAKE/curl.args" "/latest/"
check "a tampered package is refused" "$(irun "$T/install-test.sh" FAKE_PAYLOAD='tampered package')" 1
has "it says it will not install it" "$T/install.out" "NOT installing it"
[ ! -f "$FAKE/sudo.calls" ] && ok "a tampered package is never passed to dpkg" || bad "dpkg was called for a tampered package"
check "an empty download is refused" "$(irun "$T/install-test.sh" FAKE_PAYLOAD='')" 1
check "a wrong installed version is refused" "$(irun "$T/install-test.sh" FAKE_PLUGIN_VERSION=1.2.999.0)" 1
check "the REAL pin (an unmodified copy) refuses the fake package" "$(irun "$INSTALL")" 1
[ ! -f "$FAKE/sudo.calls" ] && ok "the real pin never installs the fake package" || bad "the real pin installed a fake package"

echo
echo "ssh-deploy tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
