#!/bin/bash
# Public releases keep one certificate-backed identity. Never weaken a DR to a bundle ID alone.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/dist/Goalong History.app}"
# Channel: release (default) requires the pinned release bundle ID; "dev" (make dev) requires
# ai.goalong.localhistory.dev with the same certificate and the same reviewed requirement shape.
CHANNEL="${2:-release}"
[[ "$CHANNEL" == release || "$CHANNEL" == dev ]] || { echo "Unknown channel: $CHANNEL" >&2; exit 2; }
PIN="$ROOT/Distribution/release-signing.json"
test -d "$APP" && test ! -L "$APP"
IDENTITY="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["certificateSHA1"])' "$PIN")"
TEAM="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["teamIdentifier"])' "$PIN")"
BUNDLE="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["bundleIdentifier"])' "$PIN")"
[[ "$IDENTITY" =~ ^[0-9A-F]{40}$ && "$TEAM" =~ ^[A-Z0-9]{10}$ ]]
RELEASE_BUNDLE="$BUNDLE"
INFO_CHANNEL="$(/usr/libexec/PlistBuddy -c 'Print :GoalongBuildChannel' "$APP/Contents/Info.plist" 2>/dev/null || true)"
INFO_BUNDLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"
if [[ "$CHANNEL" == dev ]]; then
  BUNDLE="$RELEASE_BUNDLE.dev"
  [[ "$INFO_CHANNEL" == dev ]] || { echo 'Refusing a dev identity on a bundle without GoalongBuildChannel=dev.' >&2; exit 1; }
else
  [[ -z "$INFO_CHANNEL" ]] || { echo 'Refusing a development bundle as a release.' >&2; exit 1; }
fi
[[ "$INFO_BUNDLE" == "$BUNDLE" ]] || { echo "Unexpected bundle ID $INFO_BUNDLE (expected $BUNDLE)." >&2; exit 1; }
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
  suffix=''
  case "$component" in
    app) target="$APP"; executable="$APP/Contents/MacOS/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist")" ;;
    cli) target="$APP/Contents/MacOS/goalong"; executable="$target" ;;
    relauncher) target="$APP/Contents/MacOS/goalong-relauncher"; executable="$target"; suffix=.relauncher ;;
  esac
  for architecture in $(/usr/bin/lipo -archs "$executable"); do
    # A release requirement is checked as signed. A dev requirement must be the reviewed release requirement
    # with only its exact identifier changed: a literal, quoted match (no regex), applied in dev only.
    codesign -d --arch "$architecture" -r- "$target" 2>&1 \
      | if [[ "$CHANNEL" == dev ]]; then
          python3 -c 'import sys; print(sys.stdin.read().replace(sys.argv[1], sys.argv[2]), end="")' \
            "identifier \"$BUNDLE$suffix\"" "identifier \"$RELEASE_BUNDLE$suffix\""
        else cat; fi \
      | python3 "$ROOT/scripts/permission_requirement_policy.py" \
      --pins "$ROOT/Distribution/permission-requirements.json" --component "$component"
  done
done
echo "Identity verified ($CHANNEL, $BUNDLE): pinned certificate and unchanged app/CLI/relauncher requirements on every architecture."
