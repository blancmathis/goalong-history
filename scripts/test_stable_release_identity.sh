#!/bin/bash
# Real codesign round-trip; never launches test apps or changes TCC.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IDENTITY="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["certificateSHA1"])' "$ROOT/Distribution/release-signing.json")"
if ! security find-identity -v -p codesigning | grep -Fq "$IDENTITY"; then
  echo 'SKIP: real identity continuity test requires the pinned signing key.'; exit 0
fi
WORK="$(mktemp -d /tmp/goalong-identity-regression.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
for version in 1 2; do
  APP="$WORK/$version/Goalong History.app"
  mkdir -p "$APP/Contents/MacOS"
  if [[ "$version" == 1 ]]; then BINARY=/usr/bin/true; else BINARY=/usr/bin/false; fi
  cp "$BINARY" "$APP/Contents/MacOS/Goalong History"
  cp "$BINARY" "$APP/Contents/MacOS/goalong"
  python3 - "$APP/Contents/Info.plist" "$version" <<'PLIST'
import plistlib,sys
with open(sys.argv[1],'wb') as stream:
    plistlib.dump({'CFBundleIdentifier':'ai.goalong.localhistory','CFBundleExecutable':'Goalong History','CFBundlePackageType':'APPL','CFBundleVersion':sys.argv[2]},stream)
PLIST
  codesign --force --timestamp=none --options runtime --sign "$IDENTITY" --identifier ai.goalong.localhistory "$APP/Contents/MacOS/goalong" 2>/dev/null
  codesign --force --timestamp=none --options runtime --sign "$IDENTITY" --identifier ai.goalong.localhistory "$APP" 2>/dev/null
  bash "$ROOT/scripts/verify_release_identity.sh" "$APP"
  codesign -d -r- "$APP" 2>&1 | sed -n 's/^designated => //p' > "$WORK/dr-$version"
  codesign -d --verbose=4 "$APP" 2>&1 | grep '^CDHash=' > "$WORK/hash-$version"
done
cmp "$WORK/dr-1" "$WORK/dr-2"
if cmp -s "$WORK/hash-1" "$WORK/hash-2"; then echo 'Fixture code hashes did not change.' >&2; exit 1; fi
REQ="$(cat "$WORK/dr-1")"
codesign --verify --strict "-R=$REQ" "$WORK/2/Goalong History.app"
codesign --force --sign - "$WORK/2/Goalong History.app" 2>/dev/null
if bash "$ROOT/scripts/verify_release_identity.sh" "$WORK/2/Goalong History.app" >/dev/null 2>&1; then
  echo 'Ad-hoc downgrade was accepted.' >&2; exit 1
fi
echo 'PASS: different binaries, identical certificate-backed DR, previous requirement satisfied, ad-hoc downgrade rejected.'
