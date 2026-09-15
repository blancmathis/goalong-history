#!/bin/bash
# Public releases keep one certificate-backed identity. Never weaken a DR to a bundle ID alone.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/dist/Goalong History.app}"
PIN="$ROOT/Distribution/release-signing.json"
test -d "$APP" && test ! -L "$APP"
IDENTITY="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["certificateSHA1"])' "$PIN")"
TEAM="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["teamIdentifier"])' "$PIN")"
BUNDLE="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["bundleIdentifier"])' "$PIN")"
[[ "$IDENTITY" =~ ^[0-9A-F]{40}$ && "$TEAM" =~ ^[A-Z0-9]{10}$ ]]
DETAILS="$(codesign -dv --verbose=4 "$APP" 2>&1)"
if grep -Fxq 'Signature=adhoc' <<<"$DETAILS"; then
  echo 'Refusing public release: an ad-hoc identity breaks permission continuity.' >&2; exit 1
fi
grep -Fxq "TeamIdentifier=$TEAM" <<<"$DETAILS"
grep -Eq '^Authority=(Apple Development:|Developer ID Application:)' <<<"$DETAILS"
DR="$(codesign -d -r- "$APP" 2>&1)"
if grep -q 'cdhash' <<<"$DR"; then
  echo 'Refusing a binary-hash-pinned designated requirement.' >&2; exit 1
fi
REQUIREMENT="identifier \"$BUNDLE\" and anchor apple generic and certificate leaf = H\"$IDENTITY\" and certificate leaf[subject.OU] = \"$TEAM\""
codesign --verify --deep --strict "-R=$REQUIREMENT" "$APP"
codesign --verify --strict "-R=$REQUIREMENT" "$APP/Contents/MacOS/goalong"
echo 'Release identity verified: pinned Apple certificate, team, app and CLI; no ad-hoc downgrade.'
