#!/usr/bin/env bash
# Offline tests for the root-owned release wrappers (deploy/host/shopnest-release.sh) and the host setup script
# (deploy/host/setup-deploy-host.sh). No root, no sudo, no network, no Docker: the wrappers run in their --check mode, which
# validates the arguments and does nothing else, and the setup script is only asked to print the sudoers rule.
#   - every well-formed request is accepted; every malformed or hostile one is refused with exit 2 BEFORE any privileged work
#   - the sudoers rule names exactly two fixed paths and grants no ALL, no docker and no wildcard
#   - static checks: the wrapper uses no eval, no `bash -c`, no sourcing of caller data, and never runs a caller-named path
# It does NOT prove the root-ownership checks, sudo, sshd or the deploy itself: those need the real host (setup-deploy-host.sh --verify).
#   bash deploy/tests/host-wrapper.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOST_DIR="$(cd "$HERE/../host" && pwd)"
WRAPPER_SRC="$HOST_DIR/shopnest-release.sh"
SETUP_SRC="$HOST_DIR/setup-deploy-host.sh"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); echo "PASS  $*"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL  $*"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: got [$2] expected [$3]"; fi; }
absent() { if grep -Eq -- "$3" "$2" 2> /dev/null; then bad "$1: '$3' found in $2"; else ok "$1"; fi; }

# The two wrappers are COPIES of one file under their installed names (the file decides its mode from its own name).
cp "$WRAPPER_SRC" "$T/shopnest-deploy"
cp "$WRAPPER_SRC" "$T/shopnest-rollback"
printf '%s\n' '# test configuration' 'REPOSITORY=ExampleOwner/shopnest-example' > "$T/release.conf"
export SHOPNEST_RELEASE_CONF="$T/release.conf"

SHA="$(printf '%040d' 0 | tr 0 a)"
SHA2="$(printf '%040d' 0 | tr 0 b)"
DIGEST="$(printf '%064d' 0 | tr 0 c)"
BACKEND="ghcr.io/exampleowner/shopnest-backend@sha256:$DIGEST"
FRONTEND="ghcr.io/exampleowner/shopnest-frontend@sha256:$DIGEST"

# run <wrapper> <args...>: prints the exit code
run() {
  local w="$1"
  shift
  bash "$T/$w" --check "$@" > "$T/out" 2> "$T/err"
  echo $?
}
deploy() { run shopnest-deploy "$@"; }
rollback() { run shopnest-rollback "$@"; }

echo "== wrapper: accepted requests"
check "deploy staging" "$(deploy --env staging --sha "$SHA" --image-ref "$BACKEND" --frontend-ref "$FRONTEND")" 0
check "deploy production" "$(deploy --env production --sha "$SHA" --image-ref "$BACKEND" --frontend-ref "$FRONTEND")" 0
check "deploy staging with seed" "$(deploy --env staging --sha "$SHA" --image-ref "$BACKEND" --frontend-ref "$FRONTEND" --seed)" 0
check "flags in another order" "$(deploy --frontend-ref "$FRONTEND" --image-ref "$BACKEND" --sha "$SHA" --env staging)" 0
check "rollback staging" "$(rollback --env staging --sha "$SHA" --carrier-sha "$SHA2")" 0
check "rollback production" "$(rollback --env production --sha "$SHA" --carrier-sha "$SHA2")" 0
check "the check prints only ok" "$(cat "$T/out")" ok

echo "== wrapper: refused deploy requests (exit 2)"
good=(--env staging --sha "$SHA" --image-ref "$BACKEND" --frontend-ref "$FRONTEND")
check "unknown environment" "$(deploy --env dev --sha "$SHA" --image-ref "$BACKEND" --frontend-ref "$FRONTEND")" 2
check "environment with a path" "$(deploy --env ../production --sha "$SHA" --image-ref "$BACKEND" --frontend-ref "$FRONTEND")" 2
check "empty environment" "$(deploy --env '' --sha "$SHA" --image-ref "$BACKEND" --frontend-ref "$FRONTEND")" 2
check "short sha" "$(deploy --env staging --sha abc123 --image-ref "$BACKEND" --frontend-ref "$FRONTEND")" 2
check "uppercase sha" "$(deploy --env staging --sha "${SHA^^}" --image-ref "$BACKEND" --frontend-ref "$FRONTEND")" 2
check "sha with 41 characters" "$(deploy --env staging --sha "${SHA}a" --image-ref "$BACKEND" --frontend-ref "$FRONTEND")" 2
check "sha with a newline" "$(deploy --env staging --sha "$SHA"$'\n' --image-ref "$BACKEND" --frontend-ref "$FRONTEND")" 2
check "sha with a command" "$(deploy --env staging --sha "$SHA;id" --image-ref "$BACKEND" --frontend-ref "$FRONTEND")" 2
check "sha with command substitution" "$(deploy --env staging --sha '$(id)aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' --image-ref "$BACKEND" --frontend-ref "$FRONTEND")" 2
check "image by tag, not digest" "$(deploy --env staging --sha "$SHA" --image-ref ghcr.io/exampleowner/shopnest-backend:latest --frontend-ref "$FRONTEND")" 2
check "image of another owner" "$(deploy --env staging --sha "$SHA" --image-ref "ghcr.io/someoneelse/shopnest-backend@sha256:$DIGEST" --frontend-ref "$FRONTEND")" 2
check "image on another registry" "$(deploy --env staging --sha "$SHA" --image-ref "docker.io/exampleowner/shopnest-backend@sha256:$DIGEST" --frontend-ref "$FRONTEND")" 2
check "backend image given as the frontend" "$(deploy --env staging --sha "$SHA" --image-ref "$BACKEND" --frontend-ref "$BACKEND")" 2
check "digest with the wrong length" "$(deploy --env staging --sha "$SHA" --image-ref "ghcr.io/exampleowner/shopnest-backend@sha256:abc" --frontend-ref "$FRONTEND")" 2
check "image with a command appended" "$(deploy --env staging --sha "$SHA" --image-ref "$BACKEND; id" --frontend-ref "$FRONTEND")" 2
check "image with a space" "$(deploy --env staging --sha "$SHA" --image-ref "$BACKEND --privileged" --frontend-ref "$FRONTEND")" 2
check "image with a newline" "$(deploy --env staging --sha "$SHA" --image-ref "$BACKEND"$'\nid' --frontend-ref "$FRONTEND")" 2
check "production seed" "$(deploy --env production --sha "$SHA" --image-ref "$BACKEND" --frontend-ref "$FRONTEND" --seed)" 2
check "missing image" "$(deploy --env staging --sha "$SHA" --frontend-ref "$FRONTEND")" 2
check "missing environment" "$(deploy --sha "$SHA" --image-ref "$BACKEND" --frontend-ref "$FRONTEND")" 2
check "flag without a value" "$(deploy --env staging --sha "$SHA" --image-ref "$BACKEND" --frontend-ref)" 2
check "duplicate flag" "$(deploy "${good[@]}" --env production)" 2
check "unknown flag" "$(deploy "${good[@]}" --privileged)" 2
check "a flag of the rollback wrapper" "$(deploy "${good[@]}" --carrier-sha "$SHA2")" 2
check "stray positional argument" "$(deploy "${good[@]}" id)" 2
check "no arguments at all" "$(deploy)" 2

echo "== wrapper: refused rollback requests (exit 2)"
check "missing carrier" "$(rollback --env staging --sha "$SHA")" 2
check "carrier is not a sha" "$(rollback --env staging --sha "$SHA" --carrier-sha main)" 2
check "target is a branch name" "$(rollback --env staging --sha main --carrier-sha "$SHA2")" 2
check "target with a command" "$(rollback --env staging --sha "$SHA;id" --carrier-sha "$SHA2")" 2
check "unknown environment" "$(rollback --env qa --sha "$SHA" --carrier-sha "$SHA2")" 2
check "deploy flag on the rollback wrapper" "$(rollback --env staging --sha "$SHA" --carrier-sha "$SHA2" --image-ref "$BACKEND")" 2
check "seed on the rollback wrapper" "$(rollback --env staging --sha "$SHA" --carrier-sha "$SHA2" --seed)" 2
check "duplicate target" "$(rollback --env staging --sha "$SHA" --sha "$SHA2" --carrier-sha "$SHA2")" 2

echo "== wrapper: configuration and naming"
printf '%s\n' 'REPOSITORY=a/b' 'REPOSITORY=c/d' > "$T/two.conf"
check "two REPOSITORY lines" "$(SHOPNEST_RELEASE_CONF="$T/two.conf" bash "$T/shopnest-deploy" --check "${good[@]}" > /dev/null 2>&1; echo $?)" 4
printf '%s\n' 'REPOSITORY=a/b; id' > "$T/inject.conf"
check "configuration line with a command" "$(SHOPNEST_RELEASE_CONF="$T/inject.conf" bash "$T/shopnest-deploy" --check "${good[@]}" > /dev/null 2>&1; echo $?)" 4
printf '%s\n' 'SOMETHING=else' > "$T/other.conf"
check "unknown configuration key" "$(SHOPNEST_RELEASE_CONF="$T/other.conf" bash "$T/shopnest-deploy" --check "${good[@]}" > /dev/null 2>&1; echo $?)" 4
check "missing configuration file" "$(SHOPNEST_RELEASE_CONF="$T/none.conf" bash "$T/shopnest-deploy" --check "${good[@]}" > /dev/null 2>&1; echo $?)" 4
cp "$WRAPPER_SRC" "$T/some-other-name"
check "refuses to run under another name" "$(bash "$T/some-other-name" --check "${good[@]}" > /dev/null 2>&1; echo $?)" 2
# Without --check the wrapper must not honour the test override: it reads /etc/shopnest/release.conf and needs root.
check "a real run does not accept the override and refuses without root" "$(bash "$T/shopnest-deploy" "${good[@]}" > /dev/null 2>&1; echo $?)" 4

echo "== sudoers rule"
sudoers="$(bash "$SETUP_SRC" --print-sudoers)"
rules="$(printf '%s\n' "$sudoers" | grep -v '^#' | grep -v '^$')"
check "exactly two rules" "$(printf '%s\n' "$rules" | wc -l | tr -d ' ')" 2
check "deploy rule" "$(printf '%s\n' "$rules" | sed -n 1p)" "deploy ALL=(root) NOPASSWD: /usr/local/sbin/shopnest-deploy"
check "rollback rule" "$(printf '%s\n' "$rules" | sed -n 2p)" "deploy ALL=(root) NOPASSWD: /usr/local/sbin/shopnest-rollback"
check "no ALL command, wildcard or docker rule" "$(printf '%s\n' "$rules" | grep -Ec 'NOPASSWD: *ALL|\*|docker|SETENV|ALL=\(ALL')" 0

echo "== SSH entry point (the forced command that binds a key to one environment)"
ENTRY_SRC="$HOST_DIR/shopnest-ssh-entry.sh"
# entry <key environment> <requested command>: prints the exit code; the output is what WOULD run (print-only hook)
entry() {
  SHOPNEST_ENTRY_PRINT_ONLY=1 SSH_ORIGINAL_COMMAND="$2" bash "$ENTRY_SRC" "$1" > "$T/eout" 2> "$T/eerr"
  echo $?
}
REQ_DEPLOY="shopnest-deploy --env staging --sha $SHA --image-ref $BACKEND --frontend-ref $FRONTEND --seed"
check "staging key: a staging deploy is accepted" "$(entry staging "$REQ_DEPLOY")" 0
check "it runs the root-owned wrapper by its fixed path through sudo" "$(cat "$T/eout")" "sudo -n /usr/local/sbin/shopnest-deploy --env staging --sha $SHA --image-ref $BACKEND --frontend-ref $FRONTEND --seed"
check "production key: a production rollback is accepted" "$(entry production "shopnest-rollback --env production --sha $SHA --carrier-sha $SHA2")" 0
check "the --check pre-flight is accepted" "$(entry staging "$REQ_DEPLOY --check")" 0
check "STAGING key cannot deploy PRODUCTION" "$(entry staging "shopnest-deploy --env production --sha $SHA --image-ref $BACKEND --frontend-ref $FRONTEND")" 2
check "PRODUCTION key cannot deploy STAGING" "$(entry production "$REQ_DEPLOY")" 2
check "staging key cannot roll back production" "$(entry staging "shopnest-rollback --env production --sha $SHA --carrier-sha $SHA2")" 2
check "two --env, the second is the other environment" "$(entry staging "shopnest-deploy --env staging --env production --sha $SHA")" 2
check "the same --env twice is refused too" "$(entry staging "shopnest-deploy --env staging --env staging --sha $SHA")" 2
check "an --env hidden as the value of another flag" "$(entry staging "shopnest-deploy --sha --env production")" 2
check "no --env at all" "$(entry staging "shopnest-deploy --sha $SHA")" 2
check "a shell is not available" "$(entry staging "bash")" 2
check "no command (an interactive login) is refused" "$(entry staging "")" 2
check "any other command is refused" "$(entry staging "docker ps")" 2
check "the wrapper by a full path is refused" "$(entry staging "/usr/local/sbin/shopnest-deploy --env staging")" 2
check "a path traversal is refused" "$(entry staging "../shopnest-deploy --env staging")" 2
check "a second command after ; is refused" "$(entry staging "$REQ_DEPLOY; id")" 2
check "command substitution is refused" "$(entry staging 'shopnest-deploy --env staging --sha $(id)')" 2
check "backticks are refused" "$(entry staging 'shopnest-deploy --env staging --sha `id`')" 2
check "a pipe is refused" "$(entry staging "$REQ_DEPLOY | sh")" 2
check "a redirect is refused" "$(entry staging "$REQ_DEPLOY > /etc/passwd")" 2
check "a backslash is refused" "$(entry staging 'shopnest-deploy --env staging\x')" 2
check "a quote is refused" "$(entry staging "shopnest-deploy --env 'staging'")" 2
check "a newline (a second command) is refused" "$(entry staging "$REQ_DEPLOY"$'\n'"id")" 2
check "a tab is refused" "$(entry staging "shopnest-deploy"$'\t'"--env staging")" 2
check "no environment argument (a misconfigured key line)" "$(SHOPNEST_ENTRY_PRINT_ONLY=1 SSH_ORIGINAL_COMMAND="$REQ_DEPLOY" bash "$ENTRY_SRC" > /dev/null 2>&1; echo $?)" 2
check "an unknown environment argument" "$(entry dev "$REQ_DEPLOY")" 2
check "two environment arguments" "$(SHOPNEST_ENTRY_PRINT_ONLY=1 SSH_ORIGINAL_COMMAND="$REQ_DEPLOY" bash "$ENTRY_SRC" staging production > /dev/null 2>&1; echo $?)" 2
check "a refusal says why and prints nothing to run" "$(entry staging "bash" > /dev/null; cat "$T/eout")" ""

echo "== setup script: keys per environment"
absent "setup script has no single shared key option" "$SETUP_SRC" '\-\-public-key-file'
if grep -q -- '--staging-key-file' "$SETUP_SRC" && grep -q -- '--production-key-file' "$SETUP_SRC"; then ok "separate key files for staging and production"; else bad "separate key files are missing"; fi
if grep -q 'share a key: use a different key for each environment' "$SETUP_SRC"; then ok "the same key for both environments is refused"; else bad "a shared key is not refused"; fi
if grep -q 'command=\\"\$SBIN/\$ENTRY \$env\\"' "$SETUP_SRC" && grep -q 'restrict,from=' "$SETUP_SRC"; then ok "every key is written restricted, loopback-only and with its environment's forced command"; else bad "the authorized_keys line is not restricted"; fi
if grep -q 'chown -h root:root "\$home"' "$SETUP_SRC" && grep -q 'install -d -o root -g root -m 0755 "\$home/.ssh"' "$SETUP_SRC"; then ok "home and ~/.ssh are root-owned (the deploy user cannot add keys or drop the restrictions)"; else bad "home or ~/.ssh stays writable by the deploy user"; fi
if grep -q 'find "\$SHOPNEST_ROOT" -xdev -user "\$DEPLOY_USER" -exec chown -h root:root' "$SETUP_SRC"; then ok "everything the deploy user owned in /opt/shopnest becomes root-owned (chown -h: a planted symbolic link is re-owned, never followed)"; else bad "files owned by the deploy user in /opt/shopnest are kept, or chown follows symbolic links"; fi
absent "setup script never uses chown without -h" "$SETUP_SRC" '^[^#]*chown[[:space:]]+(root:root|-R)'
# The private-key guard of the setup script, exercised on its own regex (the script itself needs root to run).
re='^ssh-ed25519\ ([A-Za-z0-9+/]+=*)(\ [A-Za-z0-9@._:+=-]+)?$'
if [[ "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIexample ci@lab" =~ $re ]]; then ok "an ed25519 public key line is accepted"; else bad "a valid public key was refused"; fi
if [[ "-----BEGIN OPENSSH PRIVATE KEY-----" =~ $re ]]; then bad "a private key header was accepted"; else ok "a private key header is refused"; fi
if [[ "ssh-ed25519 AAAA; rm -rf /" =~ $re ]]; then bad "an injected key line was accepted"; else ok "a key line with a command is refused"; fi
if [[ 'command="/bin/sh" ssh-ed25519 AAAAC3Nza' =~ $re ]]; then bad "a key line with its own options was accepted"; else ok "a key line with its own options (command=, no-restrict) is refused"; fi

echo "== static checks"
grep -v '^[[:space:]]*#' "$ENTRY_SRC" > "$T/entry.code" # the code without comment lines (a comment may contain " . ")
absent "entry point has no eval" "$T/entry.code" '(^|[[:space:];&|(])eval[[:space:]]'
absent "entry point never runs a shell on the request" "$T/entry.code" '(bash|sh)[[:space:]]+-c'
absent "entry point never sources a file" "$T/entry.code" '(^|[[:space:];&|])(source|\.)[[:space:]]+[^[:space:]]'
if grep -q 'exec sudo -n "\$SBIN/\${WORDS\[0\]}"' "$ENTRY_SRC"; then ok "the only thing it runs is sudo on a fixed directory plus a whitelisted name"; else bad "the entry point runs something else"; fi
absent "wrapper has no eval" "$WRAPPER_SRC" '(^|[[:space:];&|(])eval[[:space:]]'
absent "wrapper has no bash -c / sh -c" "$WRAPPER_SRC" '(bash|sh)[[:space:]]+-c'
absent "wrapper never sources a file" "$WRAPPER_SRC" '(^|[[:space:];&|])(source|\.)[[:space:]]+[^[:space:]]'
absent "wrapper never uses a sudo or ssh original command" "$WRAPPER_SRC" 'SSH_ORIGINAL_COMMAND'
absent "wrapper never runs an unquoted caller variable as a command" "$WRAPPER_SRC" '^[[:space:]]*\$[A-Za-z_{]'
absent "wrapper runs no script path taken from the request" "$WRAPPER_SRC" 'bash[[:space:]]+"?\$\{?(ENV_NAME|SHA|IMAGE_REF|FRONTEND_REF|CARRIER_SHA)'
absent "wrapper does not read the caller's PATH" "$WRAPPER_SRC" 'PATH=.*:\$PATH'
absent "setup script stores no private key" "$SETUP_SRC" 'BEGIN [A-Z ]*PRIVATE KEY'
absent "setup script writes no address or token" "$SETUP_SRC" '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}[^"]*(ghp_|github_pat_)'
if grep -q 'bash deploy/scripts/bluegreen-deploy.sh' "$WRAPPER_SRC" && grep -q 'bash deploy/scripts/rollback.sh' "$WRAPPER_SRC"; then ok "the only scripts run are the repository's two fixed release scripts"; else bad "the wrapper does not call the two fixed scripts"; fi
check "the wrapper runs exactly two repository scripts" "$(grep -Ec '^[[:space:]]*bash deploy/' "$WRAPPER_SRC")" 2

echo "== wrapper: lock location and rollback carrier"
absent "the release lock is not in /run/lock (world-writable)" "$WRAPPER_SRC" '^[^#]*/run/lock'
check "the release lock is in /var/lib/shopnest" "$(grep -c '^LOCK_FILE=/var/lib/shopnest/release.lock' "$WRAPPER_SRC")" 1
if grep -q 'assert_protected "\$(dirname "\$LOCK_FILE")"' "$WRAPPER_SRC"; then ok "the lock directory must be root-owned and not writable by others"; else bad "the lock directory is not checked"; fi
check "the rollback carrier must be the tip of main" "$(grep -c 'verify_on_main "\$CARRIER_SHA" tip' "$WRAPPER_SRC")" 1
check "the deploy target only has to be in the history of main" "$(grep -c 'verify_on_main "\$SHA"$' "$WRAPPER_SRC")" 1
# verify_on_main itself, with a fake curl: the function is cut out of the wrapper and run on its own (needs python3, as the wrapper does).
if python3 -I -c 'import json' > /dev/null 2>&1; then
  mkdir -p "$T/vbin"
  printf '%s\n' '#!/bin/sh' 'echo "{\"status\": \"${FAKE_STATUS:-}\"}"' > "$T/vbin/curl"
  chmod +x "$T/vbin/curl"
  VOM="$(awk '/^verify_on_main\(\) \{/,/^}/' "$WRAPPER_SRC")"
  vom() { # vom <status> [tip]: the exit code of verify_on_main when GitHub answers <status>
    FAKE_STATUS="$1" PATH="$T/vbin:$PATH" REPOSITORY=Example/example bash -c 'die() { exit 2; }; fail() { exit 4; }; eval "$1"; shift; verify_on_main "$@"' _ "$VOM" "$SHA" ${2:+"$2"} > /dev/null 2>&1
    echo $?
  }
  check "deploy target: identical to main is accepted" "$(vom identical)" 0
  check "deploy target: an ancestor of main is accepted" "$(vom behind)" 0
  check "deploy target: ahead of main is refused" "$(vom ahead)" 2
  check "deploy target: diverged from main is refused" "$(vom diverged)" 2
  check "deploy target: an empty answer is refused" "$(vom '')" 2
  check "carrier: the tip of main is accepted" "$(vom identical tip)" 0
  check "carrier: an OLDER commit of main is refused" "$(vom behind tip)" 2
  check "carrier: ahead of main is refused" "$(vom ahead tip)" 2
  check "carrier: diverged from main is refused" "$(vom diverged tip)" 2
else
  echo "SKIP  verify_on_main behaviour (no working python3 on this machine; it runs in CI)"
fi

echo "== rollback target: an earlier release can be rolled back; only the carrier has to be the tip of main"
# Static: in rollback mode the ONLY verify_on_main call is the carrier with "tip"; the rollback target (--sha) is never put to it. The
# target's legitimacy is enforced elsewhere (rollback.sh on the host: it must be in the release history; rollback.yml: ancestor of main).
RB_BLOCK="$(awk '/^if \[ "\$MODE" = deploy \]; then$/,/^fi$/' "$WRAPPER_SRC")"
RB_ELSE="$(printf '%s\n' "$RB_BLOCK" | awk '/^else$/{f=1;next} /^fi$/{f=0} f')"
check "rollback mode makes exactly one verify_on_main call" "$(printf '%s\n' "$RB_ELSE" | grep -c 'verify_on_main')" 1
check "that call is the carrier, with tip" "$(printf '%s\n' "$RB_ELSE" | grep -c 'verify_on_main "\$CARRIER_SHA" tip')" 1
check "the rollback target is never put to verify_on_main" "$(printf '%s\n' "$RB_ELSE" | grep -c 'verify_on_main "\$SHA"')" 0
check "the rollback target only reaches rollback.sh as --sha" "$(printf '%s\n' "$RB_ELSE" | grep -c 'rollback.sh --env "\$ENV_NAME" --sha "\$SHA"')" 1
# Behaviour: the wrapper's real deploy/rollback block is run with a fake curl that answers per commit and a fake `bash` that records which
# script would run. Carrier = tip (identical) and target = an earlier release (behind): the rollback goes ahead, and GitHub is asked about
# the carrier only. Carrier = an older commit: refused before anything runs.
if python3 -I -c 'import json' > /dev/null 2>&1; then
  mkdir -p "$T/rbin"
  cat > "$T/rbin/curl" << 'FAKECURL'
#!/bin/sh
for a in "$@"; do url="$a"; done
echo "$url" >> "$RB_CURL_LOG"
case "$url" in
  *"$RB_CARRIER"*) status="$RB_CARRIER_STATUS" ;;
  *"$RB_TARGET"*) status="$RB_TARGET_STATUS" ;;
  *) status="" ;;
esac
echo "{\"status\": \"$status\"}"
FAKECURL
  chmod +x "$T/rbin/curl"
  VOM2="$(awk '/^verify_on_main\(\) \{/,/^}/' "$WRAPPER_SRC")"
  rbrun() { # rbrun <deploy|rollback> <status GitHub gives the carrier (rollback) or ignored> <status GitHub gives the target>: prints the exit code
    : > "$T/rb.curl.log"
    : > "$T/rb.bash.log"
    env RB_CURL_LOG="$T/rb.curl.log" RB_BASH_LOG="$T/rb.bash.log" RB_CARRIER="$SHA2" RB_TARGET="$SHA" RB_CARRIER_STATUS="$2" RB_TARGET_STATUS="$3" \
      PATH="$T/rbin:$PATH" REPOSITORY=Example/example MODE="$1" SHA="$SHA" CARRIER_SHA="$SHA2" ENV_NAME=staging IMAGE_REF=img FRONTEND_REF=fe SEED=0 \
      bash -c 'die() { exit 2; }; fail() { exit 4; }; checkout() { :; }; bash() { echo "$*" >> "$RB_BASH_LOG"; }; eval "$1"; rc=0; eval "$2"; exit "$rc"' _ "$VOM2" "$RB_BLOCK" > /dev/null 2>&1
    echo $?
  }
  check "rollback: carrier is the tip, target is an earlier release (behind main): accepted" "$(rbrun rollback identical behind)" 0
  check "  ... and rollback.sh is started for exactly that earlier release" "$(cat "$T/rb.bash.log")" "deploy/scripts/rollback.sh --env staging --sha $SHA"
  check "  ... and GitHub was asked about the carrier only, never about the target" "$(grep -c "$SHA2" "$T/rb.curl.log")/$(grep -c "$SHA\$" "$T/rb.curl.log")" "1/0"
  check "rollback: carrier is an older commit of main: refused before anything runs" "$(rbrun rollback behind behind)" 2
  check "  ... and no script was started" "$(wc -c < "$T/rb.bash.log" | tr -d ' ')" 0
  check "rollback: carrier ahead of main: refused" "$(rbrun rollback ahead behind)" 2
  check "rollback: carrier diverged from main: refused" "$(rbrun rollback diverged behind)" 2
  check "deploy of an earlier release (behind main): accepted" "$(rbrun deploy x behind)" 0
  check "  ... and the deploy script is the one started" "$(grep -c 'deploy/scripts/bluegreen-deploy.sh --env staging --sha' "$T/rb.bash.log")" 1
  check "deploy of a commit that is not in main (ahead): refused" "$(rbrun deploy x ahead)" 2
else
  echo "SKIP  rollback-target behaviour (no working python3 on this machine; it runs in CI)"
fi

echo "== syntax"
if bash -n "$WRAPPER_SRC" && bash -n "$SETUP_SRC" && bash -n "$ENTRY_SRC"; then ok "bash -n on the wrapper, the setup script and the entry point"; else bad "bash -n failed"; fi

echo
echo "host wrapper tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
