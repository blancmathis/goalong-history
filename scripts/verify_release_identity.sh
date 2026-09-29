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
codesign --verify --all-architectures --deep --strict "-R=$REQUIREMENT" "$APP"
codesign --verify --all-architectures --strict "-R=$REQUIREMENT" "$APP/Contents/MacOS/goalong"
HELPER_REQUIREMENT="identifier \"$BUNDLE.relauncher\" and anchor apple generic and certificate leaf = H\"$IDENTITY\" and certificate leaf[subject.OU] = \"$TEAM\""
codesign --verify --all-architectures --strict "-R=$HELPER_REQUIREMENT" "$APP/Contents/MacOS/goalong-relauncher"
for component in app cli relauncher; do
  case "$component" in
    app) target="$APP"; executable="$APP/Contents/MacOS/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist")" ;;
    cli) target="$APP/Contents/MacOS/goalong"; executable="$target" ;;
    relauncher) target="$APP/Contents/MacOS/goalong-relauncher"; executable="$target" ;;
  esac
  for architecture in $(/usr/bin/lipo -archs "$executable"); do
    codesign -d --arch "$architecture" -r- "$target" 2>&1 | python3 "$ROOT/scripts/permission_requirement_policy.py" \
      --pins "$ROOT/Distribution/permission-requirements.json" --component "$component"
  done
done
echo 'Release identity verified: pinned certificate and unchanged app/CLI/relauncher requirements on every architecture.'
