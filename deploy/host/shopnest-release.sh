#!/bin/bash
# Source of BOTH root-owned release wrappers. setup-deploy-host.sh installs two COPIES of this file (no symlinks) as
#   /usr/local/sbin/shopnest-deploy     deploy one release to one environment
#   /usr/local/sbin/shopnest-rollback   roll one environment back to a release deployed earlier
# and /etc/sudoers.d/deploy lets the `deploy` user run exactly those two paths as root, and nothing else. The CD workflow reaches
# them over SSH (through a Systems Manager port-forwarding tunnel): `ssh deploy@... sudo /usr/local/sbin/shopnest-deploy --env ...`.
#
# What this file guarantees, because the sudoers rule cannot constrain arguments:
#   * the arguments are parsed with a fixed list of flags and each value must match a strict anchored pattern (a 40-hex SHA, an
#     environment name, a GHCR image DIGEST of this repository owner); anything else is refused before any privileged work;
#   * nothing the caller sends is ever executed, expanded, sourced or used as a path: the values only reach the release scripts as
#     separate, already validated arguments;
#   * the code that runs as root is a git checkout of a commit that GitHub reports as part of the history of `main`, fetched into a
#     directory only root can write, and the scripts it runs are the repository's own (deploy/scripts/bluegreen-deploy.sh and
#     rollback.sh), never a path or script the caller names;
#   * it refuses to run if the wrapper, its configuration or /opt/shopnest could be modified by anyone but root;
#   * the environment sudo passes in is ignored: PATH and the variables the release scripts read are set here.
# --check validates the arguments and prints "ok"; it does nothing else and needs no root (CI and the setup script use it).
# Exit codes: 0 done; 1 failed, the previous release is serving; 3 failed AND the automatic rollback failed (an operator is needed);
# 2 the request was refused (nothing was started); 4 the host was not in a safe state or the result could not be confirmed.
set -euo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
umask 022 # the nginx and database containers run as unprivileged users and must be able to read the staged files

SELF="${0##*/}"
case "$SELF" in
  shopnest-deploy) MODE=deploy ;;
  shopnest-rollback) MODE=rollback ;;
  *)
    echo "shopnest-release: install this file as shopnest-deploy or shopnest-rollback (it was run as '$SELF')" >&2
    exit 2
    ;;
esac

SHOPNEST_ROOT=/opt/shopnest
CONF_FILE=/etc/shopnest/release.conf
LOCK_FILE=/run/lock/shopnest-release.lock

die() { echo "$SELF: ERROR: $*" >&2; exit 2; }  # the request is refused; nothing was started
fail() { echo "$SELF: ERROR: $*" >&2; exit 4; } # the host is not in a safe state; nothing was changed

usage() {
  if [ "$MODE" = deploy ]; then
    echo "usage: $SELF --env <staging|production> --sha <40-hex> --image-ref <ghcr.io/OWNER/shopnest-backend@sha256:DIGEST> --frontend-ref <ghcr.io/OWNER/shopnest-frontend@sha256:DIGEST> [--seed] [--check]" >&2
  else
    echo "usage: $SELF --env <staging|production> --sha <40-hex release deployed earlier> --carrier-sha <40-hex commit of main> [--check]" >&2
  fi
  exit "${1:-2}"
}

ENV_NAME=""
SHA=""
IMAGE_REF=""
FRONTEND_REF=""
CARRIER_SHA=""
SEED=0
CHECK=0
declare -A SEEN=()
once() { [ -z "${SEEN[$1]:-}" ] || die "$1 was given twice"; SEEN[$1]=1; }
value_of() { [ "$1" -ge 2 ] || die "$2 needs a value"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --env) once env; value_of "$#" --env; ENV_NAME="$2"; shift 2 ;;
    --sha) once sha; value_of "$#" --sha; SHA="$2"; shift 2 ;;
    --check) once check; CHECK=1; shift ;;
    --image-ref)
      [ "$MODE" = deploy ] || die "unknown option --image-ref"
      once image; value_of "$#" --image-ref; IMAGE_REF="$2"; shift 2
      ;;
    --frontend-ref)
      [ "$MODE" = deploy ] || die "unknown option --frontend-ref"
      once frontend; value_of "$#" --frontend-ref; FRONTEND_REF="$2"; shift 2
      ;;
    --seed)
      [ "$MODE" = deploy ] || die "unknown option --seed"
      once seed; SEED=1; shift
      ;;
    --carrier-sha)
      [ "$MODE" = rollback ] || die "unknown option --carrier-sha"
      once carrier; value_of "$#" --carrier-sha; CARRIER_SHA="$2"; shift 2
      ;;
    -h | --help) usage 0 ;;
    *) die "unknown or unexpected argument (see --help)" ;;
  esac
done

# assert_protected <path>: the path and every parent directory are owned by root and not writable by group or others.
assert_protected() {
  local p mode
  p="$(readlink -f "$1")" || fail "cannot resolve $1"
  while :; do
    [ "$(stat -c %u "$p")" = 0 ] || fail "$p is not owned by root"
    mode="$(stat -c %a "$p")"
    [ $((8#$mode & 8#022)) -eq 0 ] || fail "$p is writable by group or others"
    [ "$p" != / ] || break
    p="$(dirname "$p")"
  done
}

# The configuration is PARSED (never sourced): one line, REPOSITORY=owner/name. Only --check honours SHOPNEST_RELEASE_CONF (the
# tests); sudo discards the caller's environment, so a deploy session cannot redirect a real run.
read_conf() {
  local conf="$CONF_FILE" line count=0
  if [ "$CHECK" = 1 ] && [ -n "${SHOPNEST_RELEASE_CONF:-}" ]; then conf="$SHOPNEST_RELEASE_CONF"; fi
  [ -f "$conf" ] || fail "missing $conf (run setup-deploy-host.sh)"
  [ "$CHECK" = 1 ] || assert_protected "$conf"
  REPOSITORY=""
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in '' | '#'*) continue ;; esac
    [[ $line =~ ^REPOSITORY=([A-Za-z0-9-]+/[A-Za-z0-9_.-]+)$ ]] || fail "unexpected line in $conf"
    REPOSITORY="${BASH_REMATCH[1]}"
    count=$((count + 1))
  done < "$conf"
  [ "$count" = 1 ] || fail "$conf must contain exactly one REPOSITORY=owner/name line"
  OWNER="${REPOSITORY%%/*}"
  OWNER="${OWNER,,}"
}

validate() {
  [[ $ENV_NAME =~ ^(staging|production)$ ]] || die "--env must be staging or production"
  [[ $SHA =~ ^[0-9a-f]{40}$ ]] || die "--sha must be a full 40-character lowercase hex commit"
  if [ "$MODE" = deploy ]; then
    [[ $IMAGE_REF =~ ^ghcr\.io/${OWNER}/shopnest-backend@sha256:[0-9a-f]{64}$ ]] || die "--image-ref must be a digest of this owner's shopnest-backend image on GHCR"
    [[ $FRONTEND_REF =~ ^ghcr\.io/${OWNER}/shopnest-frontend@sha256:[0-9a-f]{64}$ ]] || die "--frontend-ref must be a digest of this owner's shopnest-frontend image on GHCR"
    [ "$SEED" = 0 ] || [ "$ENV_NAME" = staging ] || die "--seed is only allowed for staging"
  else
    [[ $CARRIER_SHA =~ ^[0-9a-f]{40}$ ]] || die "--carrier-sha must be a full 40-character lowercase hex commit"
  fi
}

# verify_on_main <sha>: GitHub must report the commit as identical to, or an ancestor of, main. Fails closed (no answer, no run).
verify_on_main() {
  local body status
  body="$(curl --fail --silent --show-error --max-time 30 -H 'Accept: application/vnd.github+json' \
    "https://api.github.com/repos/${REPOSITORY}/compare/main...$1")" || fail "could not ask GitHub whether $1 is part of main"
  status="$(printf '%s' "$body" | python3 -I -c 'import json, sys; print(json.load(sys.stdin).get("status", ""))')" || fail "unreadable answer from GitHub"
  case "$status" in
    identical | behind) ;;
    *) die "commit $1 is not part of the history of main (GitHub reports '$status')" ;;
  esac
}

# checkout <sha> <directory name>: a fresh checkout of the public repository at exactly that commit, in a root-only directory.
checkout() {
  local work="$SHOPNEST_ROOT/incoming/$2"
  rm -rf "$work"
  mkdir -p "$work"
  cd "$work"
  git init --quiet
  git fetch --quiet --depth 1 "https://github.com/${REPOSITORY}.git" "$1"
  git checkout --quiet FETCH_HEAD
  [ "$(git rev-parse HEAD)" = "$1" ] || fail "the fetched commit is not $1"
}

read_conf
validate
if [ "$CHECK" = 1 ]; then
  echo ok
  exit 0
fi

[ "$(id -u)" = 0 ] || fail "must run as root (through sudo)"
assert_protected "$0"
assert_protected "$SHOPNEST_ROOT"
[ -f /var/lib/shopnest/bootstrap-complete ] || fail "the host bootstrap has not completed (see /var/lib/shopnest/bootstrap-failed)"
exec 9> "$LOCK_FILE"
flock -n 9 || fail "another release or rollback is already running"

export HOME=/root
export SHOPNEST_HOME="$SHOPNEST_ROOT"
export BG_LAB=1
rc=0
if [ "$MODE" = deploy ]; then
  verify_on_main "$SHA"
  checkout "$SHA" "$SHA"
  args=(--env "$ENV_NAME" --sha "$SHA" --image-ref "$IMAGE_REF" --frontend-ref "$FRONTEND_REF")
  [ "$SEED" = 0 ] || args+=(--seed)
  bash deploy/scripts/bluegreen-deploy.sh "${args[@]}" || rc=$?
else
  verify_on_main "$CARRIER_SHA"
  checkout "$CARRIER_SHA" "carrier-$CARRIER_SHA"
  bash deploy/scripts/rollback.sh --env "$ENV_NAME" --sha "$SHA" || rc=$?
fi
exit "$rc"
