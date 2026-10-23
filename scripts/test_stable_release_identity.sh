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
# Every refusal must fail with its own message: a refusal that only fails by accident (another check)
# would hide a deleted guard.
expect_refusal() { # message, then verify_release_identity.sh arguments
  local message="$1"; shift
  if bash "$ROOT/scripts/verify_release_identity.sh" "$@" >"$WORK/out" 2>&1; then
    echo "Accepted, expected refusal '$message': $*" >&2; exit 1
  fi
  grep -qF -- "$message" "$WORK/out" || { echo "Refused for another reason than '$message': $(cat "$WORK/out")" >&2; exit 1; }
}
# A valid signature under the right certificate must not allow a weakened DR.
codesign --force --timestamp=none --options runtime --sign "$IDENTITY" \
  --requirements '=designated => identifier "ai.goalong.localhistory"' "$WORK/2/Goalong History.app" 2>/dev/null
expect_refusal 'Designated requirement changed' "$WORK/2/Goalong History.app"
# The reviewed requirement with an identifier that only matches the pinned one as a regex ('.' as a joker):
# a release is checked as signed, never rewritten.
codesign --force --timestamp=none --options runtime --sign "$IDENTITY" --identifier ai.goalong.localhistory \
  --requirements "=designated => ${REQ/identifier \"ai.goalong.localhistory\"/identifier \"ai-goalong-localhistory\"}" \
  "$WORK/2/Goalong History.app" 2>/dev/null
codesign -d -r- "$WORK/2/Goalong History.app" 2>&1 | grep -qF 'identifier "ai-goalong-localhistory" and' || { echo 'joker fixture not signed' >&2; exit 1; }
expect_refusal 'Designated requirement changed' "$WORK/2/Goalong History.app"
codesign --force --sign - "$WORK/2/Goalong History.app" 2>/dev/null
expect_refusal 'Refusing public release: an ad-hoc identity' "$WORK/2/Goalong History.app"
# Goalong Dev (make dev): same certificate, .dev identifiers, GoalongBuildChannel=dev.
make_fixture() { # APP BUNDLE_ID CHANNEL_KEY(dev|none) RELAUNCHER_ID [GUARD_ID]
  local app="$1"
  rm -rf "$app"; mkdir -p "$app/Contents/MacOS" "$app/Contents/Library/LaunchAgents"
  for name in 'Goalong History Dev' goalong goalong-relauncher goalong-blocking-guard; do cp /usr/bin/true "$app/Contents/MacOS/$name"; done
  : > "$app/Contents/Library/LaunchAgents/$2.blocking-guard.plist"
  python3 - "$app/Contents/Info.plist" "$2" "$3" <<'PLIST'
import plistlib,sys
info={'CFBundleIdentifier':sys.argv[2],'CFBundleExecutable':'Goalong History Dev','CFBundlePackageType':'APPL','CFBundleVersion':'1'}
if sys.argv[3]=='dev': info['GoalongBuildChannel']='dev'
with open(sys.argv[1],'wb') as stream: plistlib.dump(info,stream)
PLIST
  codesign --force --timestamp=none --options runtime --sign "$IDENTITY" --identifier "$2" "$app/Contents/MacOS/goalong" 2>/dev/null
  codesign --force --timestamp=none --options runtime --sign "$IDENTITY" --identifier "$4" "$app/Contents/MacOS/goalong-relauncher" 2>/dev/null
  codesign --force --timestamp=none --options runtime --sign "$IDENTITY" --identifier "${5:-$2.blocking-guard}" "$app/Contents/MacOS/goalong-blocking-guard" 2>/dev/null
  codesign --force --timestamp=none --options runtime --sign "$IDENTITY" --identifier "$2" "$app" 2>/dev/null
}
DEV_APP="$WORK/dev/Goalong Dev.app"
make_fixture "$DEV_APP" ai.goalong.localhistory.dev dev ai.goalong.localhistory.dev.relauncher
bash "$ROOT/scripts/verify_release_identity.sh" "$DEV_APP" dev >/dev/null
expect_refusal 'Refusing a development bundle as a release.' "$DEV_APP"
expect_refusal 'Refusing a dev identity on a bundle without GoalongBuildChannel=dev.' "$WORK/1/Goalong History.app" dev
make_fixture "$DEV_APP" ai.goalong.localhistory.dev none ai.goalong.localhistory.dev.relauncher
expect_refusal 'Refusing a dev identity on a bundle without GoalongBuildChannel=dev.' "$DEV_APP" dev
make_fixture "$DEV_APP" ai.goalong.localhistory.dev dev ai.goalong.localhistory.relauncher
expect_refusal 'failed to satisfy specified code requirement' "$DEV_APP" dev
# Spec K: a dev bundle whose guard kept the release identifier is refused.
make_fixture "$DEV_APP" ai.goalong.localhistory.dev dev ai.goalong.localhistory.dev.relauncher ai.goalong.localhistory.blocking-guard
expect_refusal 'failed to satisfy specified code requirement' "$DEV_APP" dev
# A development build that kept the release bundle ID: only GoalongBuildChannel=dev tells it apart.
DEV_AS_RELEASE="$WORK/dev-release-id/Goalong History.app"
make_fixture "$DEV_AS_RELEASE" ai.goalong.localhistory dev ai.goalong.localhistory.relauncher
expect_refusal 'Refusing a development bundle as a release.' "$DEV_AS_RELEASE"
# A bundle with the dev channel key but the dev ID checked as a release hits the bundle ID check too.
make_fixture "$DEV_APP" ai.goalong.localhistory.dev none ai.goalong.localhistory.dev.relauncher
expect_refusal 'Unexpected bundle ID ai.goalong.localhistory.dev (expected ai.goalong.localhistory).' "$DEV_APP"
echo 'PASS: Goalong Dev identity accepted only as dev, release and dev never cross.'
echo 'PASS: different binaries, identical certificate-backed DR, previous requirement satisfied, weakened requirement and ad-hoc downgrade rejected.'
