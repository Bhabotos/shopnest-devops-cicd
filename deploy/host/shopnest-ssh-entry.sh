#!/bin/bash
# Forced command of the deploy user's SSH keys, installed as /usr/local/sbin/shopnest-ssh-entry. authorized_keys binds EACH key to one
# environment:
#   restrict,from="127.0.0.1,::1",command="/usr/local/sbin/shopnest-ssh-entry staging" ssh-ed25519 AAAA...
# so whatever command a client asks for, sshd runs this script with the environment of THAT key as its only argument, and the client's
# request arrives in SSH_ORIGINAL_COMMAND. This is what keeps a staging key from deploying production (the sudo rule cannot).
#
# It accepts exactly one thing: `shopnest-deploy <args>` or `shopnest-rollback <args>`, where the arguments contain only plain
# characters and exactly one --env, equal to the key's environment. It then runs the matching root-owned wrapper through sudo, by its
# fixed absolute path; the wrapper validates every argument again (deploy/host/shopnest-release.sh). Nothing the client sends is
# evaluated, expanded or used as a path. It runs as the unprivileged deploy user and needs no root itself.
set -euo pipefail

SBIN=/usr/local/sbin
die() { echo "shopnest-ssh-entry: refused: $*" >&2; exit 2; }

[ $# -eq 1 ] || die "this entry point must be given exactly one environment (it comes from authorized_keys)"
KEY_ENV="$1"
[[ $KEY_ENV =~ ^(staging|production)$ ]] || die "the key's environment is not staging or production"

REQUEST="${SSH_ORIGINAL_COMMAND:-}"
[ -n "$REQUEST" ] || die "no command was requested (interactive shells are not available)"
# Plain characters only: letters, digits, space and . / : @ _ = - . No quotes, no $ ; & | < > ( ) ` \ newline or tab.
PLAIN='^[A-Za-z0-9 ./:@_=-]+$'
[[ $REQUEST =~ $PLAIN ]] || die "the request contains characters that are not allowed"

read -r -a WORDS <<< "$REQUEST"
case "${WORDS[0]}" in
  shopnest-deploy | shopnest-rollback) ;;
  *) die "only shopnest-deploy and shopnest-rollback can be requested" ;;
esac

env_count=0
for ((i = 1; i < ${#WORDS[@]}; i++)); do
  if [ "${WORDS[$i]}" = "--env" ]; then
    env_count=$((env_count + 1))
    [ "${WORDS[$((i + 1))]:-}" = "$KEY_ENV" ] || die "this key may only act on $KEY_ENV"
  fi
done
[ "$env_count" -eq 1 ] || die "the request must contain exactly one --env"

# Test hook for the offline tests: print what would run instead of running it. It can only make this script do LESS.
if [ "${SHOPNEST_ENTRY_PRINT_ONLY:-}" = 1 ]; then
  printf '%s\n' "sudo -n $SBIN/${WORDS[0]} ${WORDS[*]:1}"
  exit 0
fi
exec sudo -n "$SBIN/${WORDS[0]}" "${WORDS[@]:1}"
