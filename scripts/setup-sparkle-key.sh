#!/bin/bash
# SPDX-License-Identifier: MIT
#
# One time, by the owner: creates OpenSweep's Sparkle update key and stores it
# on GitHub (docs/RELEASING.md). The private key stays in your login keychain
# (that is its backup) and goes to the release environment's
# SPARKLE_PRIVATE_KEY secret through a
# temporary file that is erased. Run as yourself, not with sudo: the keychain
# is per user.
set -euo pipefail
cd "$(dirname "$0")/.."

ACCOUNT=com.finjineers.opensweep
REPO=Finjineersdev/OpenSweep
BIN=build/dd/SourcePackages/artifacts/sparkle/Sparkle/bin

if [ "$(id -u)" = 0 ]; then echo "Run this without sudo." >&2; exit 1; fi
gh auth status >/dev/null 2>&1 || { echo "Sign in first: gh auth login" >&2; exit 1; }
if [ ! -x "$BIN/generate_keys" ]; then
  echo "Fetching Sparkle's tools..."
  xcodebuild -project OpenSweep.xcodeproj -scheme OpenSweep -derivedDataPath build/dd \
    -resolvePackageDependencies >/dev/null
fi

echo "Creating the key (macOS may ask to allow keychain access: choose Allow)..."
"$BIN/generate_keys" --account "$ACCOUNT" >/dev/null
PUBLIC=$("$BIN/generate_keys" --account "$ACCOUNT" -p)
[ -n "$PUBLIC" ] || { echo "No public key came back." >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -P "$TMP/key" 2>/dev/null || true; rm -rf "$TMP"' EXIT
"$BIN/generate_keys" --account "$ACCOUNT" -x "$TMP/key" >/dev/null
# Only the release environment can read it (scripts/protect-releases.sh).
gh secret set SPARKLE_PRIVATE_KEY --env release -R "$REPO" < "$TMP/key"
gh secret delete SPARKLE_PRIVATE_KEY -R "$REPO" 2>/dev/null || true
gh variable set SPARKLE_PUBLIC_KEY -R "$REPO" --body "$PUBLIC"

echo "Done. Public key: $PUBLIC"
echo "Releases tagged from now on carry signed in-app updates."
