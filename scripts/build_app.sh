#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE_BUILDER="$ROOT_DIR/scripts/build_app_core.sh"
APP_NAME="LocalHistory"
BUNDLE_ID="ai.goalong.localhistory"
DISPLAY_NAME="${LOCALHISTORY_DISPLAY_NAME:-Go Long History}"
OUTPUT_DIR="${LOCALHISTORY_OUTPUT_DIR:-$ROOT_DIR/dist}"
SIGN_IDENTITY="${LOCALHISTORY_CODESIGN_IDENTITY:--}"

if [[ ! -x "$CORE_BUILDER" ]]; then
  echo "Internal app builder is missing: $CORE_BUILDER" >&2
  exit 1
fi

# Keep the mature build/signing implementation isolated, then finalize only the public
# product identity. This preserves the executable name, bundle ID and data paths used by
# existing installations while Finder and every macOS surface show Go Long History.
"$CORE_BUILDER" "$@"

APP_PATH="$OUTPUT_DIR/$APP_NAME.app"
INFO_PLIST="$APP_PATH/Contents/Info.plist"
if [[ ! -d "$APP_PATH" || ! -f "$INFO_PLIST" ]]; then
  echo "The core build did not produce a complete app bundle: $APP_PATH" >&2
  exit 1
fi

/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $DISPLAY_NAME" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $DISPLAY_NAME" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :NSAccessibilityUsageDescription $DISPLAY_NAME uses Accessibility to understand the foreground app, window, permitted URL, focused control, and clicked interface element. It never controls your Mac." "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :NSInputMonitoringUsageDescription $DISPLAY_NAME uses event-listening access to count clicks, scrolling, shortcuts, navigation keys, and typing duration. It never stores typed characters, passwords, or clipboard contents." "$INFO_PLIST"
/usr/bin/plutil -lint "$INFO_PLIST" >/dev/null

APP_SIGN_ARGS=(--force --sign "$SIGN_IDENTITY" --identifier "$BUNDLE_ID")
if [[ "$SIGN_IDENTITY" != "-" ]]; then
  APP_SIGN_ARGS+=(--options runtime --timestamp)
  if [[ -n "${LOCALHISTORY_APP_ENTITLEMENTS:-}" ]]; then
    if [[ ! -f "$LOCALHISTORY_APP_ENTITLEMENTS" ]]; then
      echo "LOCALHISTORY_APP_ENTITLEMENTS does not exist: $LOCALHISTORY_APP_ENTITLEMENTS" >&2
      exit 1
    fi
    APP_SIGN_ARGS+=(--entitlements "$LOCALHISTORY_APP_ENTITLEMENTS")
  fi
fi

/usr/bin/codesign "${APP_SIGN_ARGS[@]}" "$APP_PATH"
/usr/bin/codesign --verify --strict --verbose=2 "$APP_PATH"
LOCALHISTORY_APP_PATH="$APP_PATH" "$ROOT_DIR/scripts/verify_sparkle_bundle.sh"

test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$INFO_PLIST")" = "$DISPLAY_NAME"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$INFO_PLIST")" = "$DISPLAY_NAME"
printf 'Finalized %s at %s\n' "$DISPLAY_NAME" "$APP_PATH"
