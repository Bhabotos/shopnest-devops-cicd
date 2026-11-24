#!/usr/bin/env bash
# Installs the AWS Session Manager plugin on a GitHub-hosted Ubuntu runner, at ONE pinned version whose SHA-256 is pinned here too.
# The package is downloaded from AWS's own bucket, checked against the pinned checksum BEFORE it is installed, and the installed
# version is checked afterwards. There is no "latest": a changed or tampered package fails the job instead of being installed.
#   bash deploy/ci/install-ssm-plugin.sh
#
# WHAT THE CHECKSUM PROVES, AND WHAT IT DOES NOT. The pinned SHA-256 was computed (2026-11-24) from the package downloaded from AWS's
# own bucket over HTTPS. It proves that every later run installs byte-for-byte the SAME file; it does NOT prove that the file is the
# one AWS signed, because the checksum was not taken from an independent source: AWS publishes no checksum, only a detached PGP
# signature (<package>.deb.sig). That signature was NOT verified when the pin was set: the signature page of the AWS documentation
# could not be retrieved by the tools available (it is rendered by JavaScript), so there was no AWS-published fingerprint to trust,
# and a key taken from a keyserver would prove nothing about who owns it. For the record, the .sig of 1.2.896.0 names the signing
# key ID 2C4D4AFF6F6757EE (an ECDSA key). The release is a download from AWS over TLS, pinned and checked on every run: a trade-off
# the README must state, not a verified chain of trust.
# TO VERIFY IT YOURSELF (once, in a browser and a clean directory): open "Verify the signature of the Session Manager plugin" in the AWS
# Systems Manager User Guide, import the public key shown there, check that its fingerprint matches the one printed on that page and
# that the key ID above is its long ID, then run `gpg --verify session-manager-plugin.deb.sig session-manager-plugin.deb` on the
# package whose SHA-256 is pinned here. A "Good signature" from that key closes the gap.
#
# To move to a newer plugin: read the version from https://s3.amazonaws.com/session-manager-downloads/plugin/latest/VERSION, download
# .../plugin/<version>/ubuntu_64bit/session-manager-plugin.deb in a clean directory, compute its SHA-256 (and, ideally, verify AWS's
# detached signature as described above), then change BOTH values below in one reviewed commit.
set -euo pipefail

PLUGIN_VERSION="1.2.896.0"
PLUGIN_SHA256="53f51fcc67314a4bf85888a38a3967cd41f8d0f28a60a9469a63acf935ba713e"
PLUGIN_URL="https://s3.amazonaws.com/session-manager-downloads/plugin/${PLUGIN_VERSION}/ubuntu_64bit/session-manager-plugin.deb"

die() { echo "install-ssm-plugin: ERROR: $*" >&2; exit 1; }

[[ $PLUGIN_VERSION =~ ^[0-9]+(\.[0-9]+){3}$ ]] || die "the pinned version is not a plain version number"
[[ $PLUGIN_SHA256 =~ ^[0-9a-f]{64}$ ]] || die "the pinned checksum is not a SHA-256"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
deb="$work/session-manager-plugin.deb"

curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --max-time 120 --output "$deb" "$PLUGIN_URL" \
  || die "could not download the pinned plugin ${PLUGIN_VERSION}"
actual="$(sha256sum "$deb" | cut -d' ' -f1)"
if [ "$actual" != "$PLUGIN_SHA256" ]; then
  die "the downloaded package does not match the pinned SHA-256 (expected $PLUGIN_SHA256, got $actual): NOT installing it"
fi
echo "session-manager-plugin ${PLUGIN_VERSION}: checksum verified"

sudo dpkg --install "$deb" > /dev/null
installed="$(session-manager-plugin --version 2> /dev/null | head -n 1 || true)"
[ "$installed" = "$PLUGIN_VERSION" ] || die "the installed plugin reports '$installed', expected ${PLUGIN_VERSION}"
echo "session-manager-plugin ${PLUGIN_VERSION} installed"
