#!/bin/bash
# Prepares the lab instance so GitHub Actions can deploy over SSH (through a Systems Manager port-forwarding tunnel) as an
# UNPRIVILEGED user that can start exactly two root-owned commands. Run it ON THE INSTANCE, as root, from a checkout of this
# repository (for example in a Session Manager session):
#   sudo bash deploy/host/setup-deploy-host.sh --repository OWNER/NAME #        --staging-key-file /path/staging_key.pub --production-key-file /path/production_key.pub
#   sudo bash deploy/host/setup-deploy-host.sh --verify          (read-only checks, safe to repeat)
# The script is idempotent. It handles PUBLIC key material only: it refuses anything that looks like a private key, and it stores
# no credential, token or address. Each private key lives only in its GitHub Environment's secret. The two keys must be DIFFERENT:
# each one is bound to its environment in authorized_keys (forced command), so a staging key cannot deploy production.
#
# What it sets up:
#   1. the `deploy` user: no password, no sudo/docker/admin group membership
#   2. /usr/local/sbin/shopnest-deploy and shopnest-rollback: root-owned COPIES of deploy/host/shopnest-release.sh, and
#      /usr/local/sbin/shopnest-ssh-entry: the forced command that binds a key to one environment
#   3. /etc/shopnest/release.conf: REPOSITORY=owner/name (read by the wrappers, root-owned)
#   4. /etc/sudoers.d/deploy: ONLY those two commands, as root, without a password (replaces any earlier rule, for example sudo docker)
#   5. the deploy user's SSH keys, restricted: no port forwarding, no agent/X11 forwarding, no pty, only from the loopback
#      address (the tunnel arrives from there), and only the forced command for the key's environment. The home directory, ~/.ssh and authorized_keys are root-owned, so the deploy user
#      cannot add keys or drop these restrictions
#   6. /opt/shopnest and everything the deploy user owned in it become root-owned
# It does not touch sshd's configuration, so key-only authentication stays as it is.
set -euo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SBIN=/usr/local/sbin
WRAPPERS=(shopnest-deploy shopnest-rollback)
ENTRY=shopnest-ssh-entry
SUDOERS_FILE=/etc/sudoers.d/deploy
CONF_FILE=/etc/shopnest/release.conf
SHOPNEST_ROOT=/opt/shopnest

DEPLOY_USER=deploy
REPOSITORY=""
STAGING_KEY_FILE=""
PRODUCTION_KEY_FILE=""
ALLOW_FROM="127.0.0.1,::1"
ACTION=setup

die() { echo "setup-deploy-host: ERROR: $*" >&2; exit 1; }
log() { echo "setup-deploy-host: $*"; }

usage() {
  echo "usage: setup-deploy-host.sh --repository OWNER/NAME --staging-key-file FILE --production-key-file FILE [--deploy-user NAME] [--allow-from CSV]" >&2
  echo "       setup-deploy-host.sh --verify [--deploy-user NAME]" >&2
  echo "       setup-deploy-host.sh --print-sudoers [--deploy-user NAME]" >&2
  exit "${1:-2}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --repository) [ $# -ge 2 ] || usage; REPOSITORY="$2"; shift 2 ;;
    --staging-key-file) [ $# -ge 2 ] || usage; STAGING_KEY_FILE="$2"; shift 2 ;;
    --production-key-file) [ $# -ge 2 ] || usage; PRODUCTION_KEY_FILE="$2"; shift 2 ;;
    --deploy-user) [ $# -ge 2 ] || usage; DEPLOY_USER="$2"; shift 2 ;;
    --allow-from) [ $# -ge 2 ] || usage; ALLOW_FROM="$2"; shift 2 ;;
    --verify) ACTION=verify; shift ;;
    --print-sudoers) ACTION=print-sudoers; shift ;;
    -h | --help) usage 0 ;;
    *) usage ;;
  esac
done

[[ $DEPLOY_USER =~ ^[a-z][a-z0-9_-]{0,30}$ ]] || die "--deploy-user is not a valid user name"
[ "$DEPLOY_USER" != root ] || die "the deploy user must not be root"
[[ $ALLOW_FROM =~ ^[0-9A-Fa-f:.,]+$ ]] || die "--allow-from must be a comma-separated list of addresses (default 127.0.0.1,::1)"

# The ONLY sudo rule: two fixed paths, run as root, no arguments constrained here (the wrappers validate them strictly).
sudoers_text() {
  printf '%s\n' \
    "# Managed by deploy/host/setup-deploy-host.sh. The deploy user may start exactly these two root-owned wrappers and nothing else." \
    "$DEPLOY_USER ALL=(root) NOPASSWD: $SBIN/shopnest-deploy" \
    "$DEPLOY_USER ALL=(root) NOPASSWD: $SBIN/shopnest-rollback"
}

if [ "$ACTION" = print-sudoers ]; then
  sudoers_text
  exit 0
fi

[ "$(id -u)" = 0 ] || die "must run as root"

# ---- verification (also run at the end of the setup) ---------------------------------------------------------------------------
FAILS=0
check() { # check <name> <command...>: PASS when the command succeeds
  local name="$1"
  shift
  if "$@" > /dev/null 2>&1; then echo "PASS  $name"; else echo "FAIL  $name"; FAILS=$((FAILS + 1)); fi
}
owned_by_root_not_writable() { # the path and every parent: owner root, no group/other write
  local p mode
  p="$(readlink -f "$1")" || return 1
  while :; do
    [ "$(stat -c %u "$p")" = 0 ] || return 1
    mode="$(stat -c %a "$p")"
    [ $((8#$mode & 8#022)) -eq 0 ] || return 1
    [ "$p" != / ] || return 0
    p="$(dirname "$p")"
  done
}
not_member_of() { ! id -nG "$DEPLOY_USER" | tr ' ' '\n' | grep -qx -e "$1"; }
cannot_write() { ! runuser -u "$DEPLOY_USER" -- test -w "$1"; }
sudo_rights_are_exactly_the_wrappers() {
  local listing cmds
  listing="$(sudo -l -U "$DEPLOY_USER" 2> /dev/null)" || return 1
  cmds="$(printf '%s\n' "$listing" | sed -n '/may run the following commands/,$p' | tail -n +2 | sed 's/^[[:space:]]*//' | grep -v '^$')"
  [ "$(printf '%s\n' "$cmds" | wc -l)" -eq 2 ] || return 1
  printf '%s\n' "$cmds" | grep -qx "(root) NOPASSWD: $SBIN/shopnest-deploy" || return 1
  printf '%s\n' "$cmds" | grep -qx "(root) NOPASSWD: $SBIN/shopnest-rollback" || return 1
  ! printf '%s\n' "$cmds" | grep -q -e 'ALL$'
}
no_other_sudoers_mention() { # no other sudoers file grants the deploy user anything
  ! grep -rEl "^[[:space:]]*($DEPLOY_USER|%$DEPLOY_USER)[[:space:]]" /etc/sudoers /etc/sudoers.d 2> /dev/null | grep -v -x "$SUDOERS_FILE" | grep -q .
}
sudoers_valid() { visudo -cf "$SUDOERS_FILE" && [ "$(stat -c '%U:%a' "$SUDOERS_FILE")" = "root:440" ]; }
conf_ok() { grep -Eqx 'REPOSITORY=[A-Za-z0-9-]+/[A-Za-z0-9_.-]+' "$CONF_FILE" && owned_by_root_not_writable "$CONF_FILE"; }
wrapper_ok() { # a root-owned copy of the repository file, executable, not writable by others
  [ -f "$SBIN/$1" ] && [ ! -L "$SBIN/$1" ] && [ "$(stat -c '%U:%G:%a' "$SBIN/$1")" = "root:root:755" ] && owned_by_root_not_writable "$SBIN/$1"
}
authorized_keys_restricted() { # every key line: restricted, loopback only, bound to ONE environment, ed25519; both environments present
  local f="/home/$DEPLOY_USER/.ssh/authorized_keys" shape
  shape="^restrict,from=\"[0-9A-Fa-f:.,]+\",command=\"$SBIN/$ENTRY (staging|production)\" ssh-ed25519 [A-Za-z0-9+/]+=* ?[A-Za-z0-9@._:+=-]*$"
  [ -s "$f" ] || return 1
  ! grep -v -e '^#' -e '^$' "$f" | grep -Evq "$shape" || return 1
  ! grep -qi 'PRIVATE KEY' "$f" || return 1
  grep -q "$ENTRY staging\"" "$f" && grep -q "$ENTRY production\"" "$f"
}
keys_differ_between_environments() { # the key blob (second word after the options) of each environment, compared
  local f="/home/$DEPLOY_USER/.ssh/authorized_keys" st pr
  st="$(grep "$ENTRY staging\"" "$f" | awk '{ for (i = 1; i <= NF; i++) if ($i == "ssh-ed25519") print $(i + 1) }' | sort -u)"
  pr="$(grep "$ENTRY production\"" "$f" | awk '{ for (i = 1; i <= NF; i++) if ($i == "ssh-ed25519") print $(i + 1) }' | sort -u)"
  [ -n "$st" ] && [ -n "$pr" ] && [ -z "$(comm -12 <(printf '%s\n' "$st") <(printf '%s\n' "$pr"))" ]
}

verify() {
  log "verification"
  check "deploy user exists and is not root" bash -c 'id "$1" > /dev/null && [ "$(id -u "$1")" != 0 ]' _ "$DEPLOY_USER"
  check "deploy has no password login" bash -c '[ "$(passwd -S "$1" | cut -d" " -f2)" != P ]' _ "$DEPLOY_USER"
  for g in sudo admin docker lxd root; do check "deploy is not in group $g" not_member_of "$g"; done
  check "sudo rights are exactly the two wrappers" sudo_rights_are_exactly_the_wrappers
  check "no other sudoers entry names the deploy user" no_other_sudoers_mention
  check "$SUDOERS_FILE is valid (visudo) and root:root 0440" sudoers_valid
  for w in "${WRAPPERS[@]}" "$ENTRY"; do check "$SBIN/$w is a root-owned executable copy" wrapper_ok "$w"; done
  check "wrappers match deploy/host/shopnest-release.sh" bash -c 'cmp -s "$1" "$2" && cmp -s "$1" "$3"' _ "$HERE/shopnest-release.sh" "$SBIN/shopnest-deploy" "$SBIN/shopnest-rollback"
  check "the SSH entry point matches deploy/host/shopnest-ssh-entry.sh" cmp -s "$HERE/shopnest-ssh-entry.sh" "$SBIN/$ENTRY"
  check "$CONF_FILE is root-owned and well formed" conf_ok
  check "$SHOPNEST_ROOT is root-owned and not writable by others" owned_by_root_not_writable "$SHOPNEST_ROOT"
  check "no file in $SHOPNEST_ROOT is owned by the deploy user" bash -c '! find "$1" -xdev -user "$2" 2> /dev/null | grep -q .' _ "$SHOPNEST_ROOT" "$DEPLOY_USER"
  check "home, .ssh and authorized_keys are root-owned" bash -c 'for p in "/home/$1" "/home/$1/.ssh" "/home/$1/.ssh/authorized_keys"; do [ "$(stat -c %u "$p")" = 0 ] && [ $((8#$(stat -c %a "$p") & 8#022)) -eq 0 ] || exit 1; done' _ "$DEPLOY_USER"
  check "authorized_keys: every key is restricted, loopback-only and bound to one environment" authorized_keys_restricted
  check "the staging and production keys are different keys" keys_differ_between_environments
  check "deploy cannot write the wrappers" cannot_write "$SBIN/shopnest-deploy"
  check "deploy cannot write $SHOPNEST_ROOT" cannot_write "$SHOPNEST_ROOT"
  check "deploy cannot write its own authorized_keys" cannot_write "/home/$DEPLOY_USER/.ssh/authorized_keys"
  check "deploy cannot use the Docker socket" cannot_write /var/run/docker.sock
  if [ -f /var/lib/shopnest/bootstrap-complete ]; then echo "PASS  host bootstrap completed"; else echo "WARN  host bootstrap marker /var/lib/shopnest/bootstrap-complete is missing"; fi
  if [ "$FAILS" -eq 0 ]; then log "all checks passed"; else die "$FAILS check(s) failed"; fi
}

if [ "$ACTION" = verify ]; then
  verify
  exit 0
fi

# ---- setup ------------------------------------------------------------------------------------------------------------------------
[[ $REPOSITORY =~ ^[A-Za-z0-9-]+/[A-Za-z0-9_.-]+$ ]] || die "--repository must look like owner/name"
[ -n "$STAGING_KEY_FILE" ] && [ -f "$STAGING_KEY_FILE" ] || die "--staging-key-file is required and must be a file"
[ -n "$PRODUCTION_KEY_FILE" ] && [ -f "$PRODUCTION_KEY_FILE" ] || die "--production-key-file is required and must be a file"
for f in shopnest-release.sh shopnest-ssh-entry.sh; do
  [ -f "$HERE/$f" ] || die "$f is missing next to this script"
  bash -n "$HERE/$f" || die "$f has a syntax error"
done
command -v visudo > /dev/null || die "visudo is required"

# Validate the public keys BEFORE anything changes: ed25519 public keys only, one per line, never a private key, and the two
# environments must not share a key (a shared key could not be bound to one environment).
# read_keys <file> <environment>: appends the validated authorized_keys lines for that environment to AUTH_LINES and its key blobs to
# BLOBS_<environment>.
AUTH_LINES=()
BLOBS_staging=()
BLOBS_production=()
read_keys() {
  local file="$1" env="$2" line n=0 blob
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in '' | '#'*) continue ;; esac
    [[ $line != *PRIVATE* ]] || die "$file contains private key material: refusing (only PUBLIC keys belong on the host)"
    [[ $line =~ ^ssh-ed25519\ ([A-Za-z0-9+/]+=*)(\ [A-Za-z0-9@._:+=-]+)?$ ]] || die "each line of $file must be one 'ssh-ed25519 AAAA... [comment]' public key"
    blob="${BASH_REMATCH[1]}"
    AUTH_LINES+=("restrict,from=\"$ALLOW_FROM\",command=\"$SBIN/$ENTRY $env\" $line")
    if [ "$env" = staging ]; then BLOBS_staging+=("$blob"); else BLOBS_production+=("$blob"); fi
    n=$((n + 1))
  done < "$1"
  [ "$n" -ge 1 ] || die "$file holds no public key"
}
read_keys "$STAGING_KEY_FILE" staging
read_keys "$PRODUCTION_KEY_FILE" production
for a in "${BLOBS_staging[@]}"; do
  for b in "${BLOBS_production[@]}"; do
    [ "$a" != "$b" ] || die "the staging and production key files share a key: use a different key for each environment"
  done
done
log "accepted ${#BLOBS_staging[@]} staging and ${#BLOBS_production[@]} production ed25519 public key(s); the repository is $REPOSITORY"

# 1. the deploy user: no password, no privileged groups
if ! id "$DEPLOY_USER" > /dev/null 2>&1; then
  useradd --create-home --shell /bin/bash "$DEPLOY_USER"
  log "created user $DEPLOY_USER"
fi
passwd -l "$DEPLOY_USER" > /dev/null
for g in sudo admin docker lxd; do
  if getent group "$g" > /dev/null && id -nG "$DEPLOY_USER" | tr ' ' '\n' | grep -qx "$g"; then
    gpasswd -d "$DEPLOY_USER" "$g" > /dev/null
    log "removed $DEPLOY_USER from group $g"
  fi
done

# 2. the wrappers: root-owned copies, never symlinks
install -d -o root -g root -m 0755 "$SBIN"
for w in "${WRAPPERS[@]}"; do
  install -o root -g root -m 0755 "$HERE/shopnest-release.sh" "$SBIN/$w"
done
install -o root -g root -m 0755 "$HERE/shopnest-ssh-entry.sh" "$SBIN/$ENTRY"

# 3. the wrapper configuration
install -d -o root -g root -m 0755 /etc/shopnest
printf '%s\n' "# Written by deploy/host/setup-deploy-host.sh. Not secret." "REPOSITORY=$REPOSITORY" > "$CONF_FILE.tmp"
chown -h root:root "$CONF_FILE.tmp"
chmod 0644 "$CONF_FILE.tmp"
mv "$CONF_FILE.tmp" "$CONF_FILE"

# 4. sudoers: written aside, validated with visudo, then moved into place (an invalid file would lock sudo for everyone)
tmp="/etc/sudoers.d/.deploy.new"
sudoers_text > "$tmp"
chown -h root:root "$tmp"
chmod 0440 "$tmp"
if ! visudo -cf "$tmp" > /dev/null; then rm -f "$tmp"; die "the generated sudoers file is invalid; nothing was installed"; fi
mv "$tmp" "$SUDOERS_FILE"
log "sudo rights for $DEPLOY_USER are now exactly the two wrappers"

# 5. SSH: restricted keys, all of it root-owned so the deploy user cannot change them
home="/home/$DEPLOY_USER"
install -d -o root -g root -m 0755 "$home/.ssh"
{
  echo "# Managed by deploy/host/setup-deploy-host.sh. Public keys only, each bound to one environment."
  for k in "${AUTH_LINES[@]}"; do
    echo "$k"
  done
} > "$home/.ssh/authorized_keys.tmp"
chown -h root:root "$home/.ssh/authorized_keys.tmp"
chmod 0644 "$home/.ssh/authorized_keys.tmp"
mv "$home/.ssh/authorized_keys.tmp" "$home/.ssh/authorized_keys"
chown -h root:root "$home"
chmod 0755 "$home"

# 6. /opt/shopnest: only root may write there (the wrappers run code from it as root)
install -d -o root -g root -m 0755 "$SHOPNEST_ROOT"
chown -h root:root "$SHOPNEST_ROOT"
chmod 0755 "$SHOPNEST_ROOT"
# -h: a symbolic link the deploy user planted is re-owned itself, never the file it points to
find "$SHOPNEST_ROOT" -xdev -user "$DEPLOY_USER" -exec chown -h root:root {} +

verify
