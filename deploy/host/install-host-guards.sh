#!/usr/bin/env bash
# Installs the metadata-service guard on the application instance. Run as root by the deploy flow, from the
# checksum-verified release bundle, BEFORE any container is started:
#   bash install-host-guards.sh <env file, e.g. deploy/env/staging.env>
# It copies the guard to a fixed root-owned path and writes the EDGE_* settings to /etc/shopnest/edge.env, so the
# rules can be re-applied at boot and after a Docker restart without any bundle being present.
# GUARD_ROOT (empty on a real host) prefixes every destination path; the offline tests use it.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${GUARD_ROOT:-}"
die() { echo "install-host-guards: ERROR: $*" >&2; exit 1; }

env_file="${1:-}"
[ -n "$env_file" ] || { echo "usage: install-host-guards.sh <env file>" >&2; exit 2; }
[ -f "$HERE/imds-guard.sh" ] || die "imds-guard.sh is missing from $HERE"
if [ -z "$ROOT" ] && [ "$(id -u)" != 0 ]; then die "must run as root"; fi

# Validate and extract the settings BEFORE anything is installed.
edge="$(bash "$HERE/imds-guard.sh" export-edge "$env_file")" || die "the settings in $env_file are not valid"

install -d -m 0755 "$ROOT/usr/local/sbin" "$ROOT/etc/shopnest" "$ROOT/etc/systemd/system"
install -m 0755 "$HERE/imds-guard.sh" "$ROOT/usr/local/sbin/shopnest-imds-guard"
printf '%s\n' "# Written by install-host-guards.sh from the release bundle. Not secret." "$edge" > "$ROOT/etc/shopnest/edge.env.tmp"
chmod 0644 "$ROOT/etc/shopnest/edge.env.tmp"
mv -f "$ROOT/etc/shopnest/edge.env.tmp" "$ROOT/etc/shopnest/edge.env"
for unit in shopnest-imds-guard.service shopnest-imds-guard-check.service shopnest-imds-guard-check.timer; do
  install -m 0644 "$HERE/$unit" "$ROOT/etc/systemd/system/$unit"
done

systemctl daemon-reload
systemctl enable shopnest-imds-guard.service shopnest-imds-guard-check.timer > /dev/null
systemctl start shopnest-imds-guard-check.timer
echo "install-host-guards: installed; the rules are applied by the deploy flow before any container starts"
