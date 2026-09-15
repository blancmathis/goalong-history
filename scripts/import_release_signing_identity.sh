#!/bin/bash
# Only an explicitly configured encrypted CI credential is read. No developer key export.
set -euo pipefail
: "${RUNNER_TEMP:?GitHub-hosted runner required}"
: "${GITHUB_ENV:?GitHub environment file required}"
: "${MACOS_SIGNING_CERTIFICATE_P12:?Stable signing certificate is not configured; refusing an ad-hoc public release}"
: "${MACOS_SIGNING_CERTIFICATE_PASSWORD:?Missing encrypted certificate password}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KEYCHAIN="$RUNNER_TEMP/goalong-release-signing.keychain-db"
ARCHIVE="$RUNNER_TEMP/goalong-release-signing.p12"
umask 077
KEYCHAIN_PASSWORD="$(openssl rand -hex 32)"
echo "::add-mask::$KEYCHAIN_PASSWORD"
trap 'rm -f "$ARCHIVE"' EXIT
printf '%s' "$MACOS_SIGNING_CERTIFICATE_P12" | base64 --decode > "$ARCHIVE"
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 3600 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security import "$ARCHIVE" -k "$KEYCHAIN" -P "$MACOS_SIGNING_CERTIFICATE_PASSWORD" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
security list-keychains -d user -s "$KEYCHAIN"
IDENTITY="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["certificateSHA1"])' "$ROOT/Distribution/release-signing.json")"
security find-identity -v -p codesigning "$KEYCHAIN" | grep -Fq "$IDENTITY"
echo "LOCALHISTORY_CODESIGN_IDENTITY=$IDENTITY" >> "$GITHUB_ENV"
