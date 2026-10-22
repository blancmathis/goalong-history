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
  cp "$BINARY" "$APP/Contents/MacOS/goalong-relauncher"
  python3 - "$APP/Contents/Info.plist" "$version" <<'PLIST'
import plistlib,sys
with open(sys.argv[1],'wb') as stream:
    plistlib.dump({'CFBundleIdentifier':'ai.goalong.localhistory','CFBundleExecutable':'Goalong History','CFBundlePackageType':'APPL','CFBundleVersion':sys.argv[2]},stream)
PLIST
  codesign --force --timestamp=none --options runtime --sign "$IDENTITY" --identifier ai.goalong.localhistory "$APP/Contents/MacOS/goalong" 2>/dev/null
  codesign --force --timestamp=none --options runtime --sign "$IDENTITY" --identifier ai.goalong.localhistory.relauncher "$APP/Contents/MacOS/goalong-relauncher" 2>/dev/null
  codesign --force --timestamp=none --options runtime --sign "$IDENTITY" --identifier ai.goalong.localhistory "$APP" 2>/dev/null
  bash "$ROOT/scripts/verify_release_identity.sh" "$APP"
  codesign -d -r- "$APP" 2>&1 | sed -n 's/^designated => //p' > "$WORK/dr-$version"
  codesign -d --verbose=4 "$APP" 2>&1 | grep '^CDHash=' > "$WORK/hash-$version"
done
cmp "$WORK/dr-1" "$WORK/dr-2"
if cmp -s "$WORK/hash-1" "$WORK/hash-2"; then echo 'Fixture code hashes did not change.' >&2; exit 1; fi
REQ="$(cat "$WORK/dr-1")"
codesign --verify --strict "-R=$REQ" "$WORK/2/Goalong History.app"
# A valid signature under the right certificate must not allow a weakened DR.
codesign --force --timestamp=none --options runtime --sign "$IDENTITY" \
  --requirements '=designated => identifier "ai.goalong.localhistory"' "$WORK/2/Goalong History.app" 2>/dev/null
if bash "$ROOT/scripts/verify_release_identity.sh" "$WORK/2/Goalong History.app" >/dev/null 2>&1; then
  echo 'Weakened designated requirement was accepted.' >&2; exit 1
fi
codesign --force --sign - "$WORK/2/Goalong History.app" 2>/dev/null
if bash "$ROOT/scripts/verify_release_identity.sh" "$WORK/2/Goalong History.app" >/dev/null 2>&1; then
  echo 'Ad-hoc downgrade was accepted.' >&2; exit 1
fi
# Goalong Dev (make dev): same certificate, .dev identifiers, GoalongBuildChannel=dev.
make_dev_fixture() { # APP CHANNEL_KEY(dev|none) RELAUNCHER_ID
  local app="$1"
  rm -rf "$app"; mkdir -p "$app/Contents/MacOS"
  for name in 'Goalong History Dev' goalong goalong-relauncher; do cp /usr/bin/true "$app/Contents/MacOS/$name"; done
  python3 - "$app/Contents/Info.plist" "$2" <<'PLIST'
import plistlib,sys
info={'CFBundleIdentifier':'ai.goalong.localhistory.dev','CFBundleExecutable':'Goalong History Dev','CFBundlePackageType':'APPL','CFBundleVersion':'1'}
if sys.argv[2]=='dev': info['GoalongBuildChannel']='dev'
with open(sys.argv[1],'wb') as stream: plistlib.dump(info,stream)
PLIST
  codesign --force --timestamp=none --options runtime --sign "$IDENTITY" --identifier ai.goalong.localhistory.dev "$app/Contents/MacOS/goalong" 2>/dev/null
  codesign --force --timestamp=none --options runtime --sign "$IDENTITY" --identifier "$3" "$app/Contents/MacOS/goalong-relauncher" 2>/dev/null
  codesign --force --timestamp=none --options runtime --sign "$IDENTITY" --identifier ai.goalong.localhistory.dev "$app" 2>/dev/null
}
DEV_APP="$WORK/dev/Goalong Dev.app"
make_dev_fixture "$DEV_APP" dev ai.goalong.localhistory.dev.relauncher
bash "$ROOT/scripts/verify_release_identity.sh" "$DEV_APP" dev >/dev/null
if bash "$ROOT/scripts/verify_release_identity.sh" "$DEV_APP" >/dev/null 2>&1; then
  echo 'A Goalong Dev bundle was accepted as a release.' >&2; exit 1
fi
if bash "$ROOT/scripts/verify_release_identity.sh" "$WORK/1/Goalong History.app" dev >/dev/null 2>&1; then
  echo 'The release bundle ID was accepted as Goalong Dev.' >&2; exit 1
fi
make_dev_fixture "$DEV_APP" none ai.goalong.localhistory.dev.relauncher
if bash "$ROOT/scripts/verify_release_identity.sh" "$DEV_APP" dev >/dev/null 2>&1; then
  echo 'A dev identity without GoalongBuildChannel=dev was accepted.' >&2; exit 1
fi
make_dev_fixture "$DEV_APP" dev ai.goalong.localhistory.relauncher
if bash "$ROOT/scripts/verify_release_identity.sh" "$DEV_APP" dev >/dev/null 2>&1; then
  echo 'Goalong Dev with the release relauncher identifier was accepted.' >&2; exit 1
fi
echo 'PASS: Goalong Dev identity accepted only as dev, release and dev never cross.'
echo 'PASS: different binaries, identical certificate-backed DR, previous requirement satisfied, weakened requirement and ad-hoc downgrade rejected.'
