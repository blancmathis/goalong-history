#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE_BUILDER="$ROOT_DIR/scripts/build_app_core.sh"
CODESIGN_POLICY="$ROOT_DIR/scripts/codesign_policy.sh"
SOURCE_CODESIGN_IDENTITY="$ROOT_DIR/scripts/source_codesign_identity.sh"
APP_NAME="Goalong History"
BUNDLE_ID="ai.goalong.localhistory"
DISPLAY_NAME="${LOCALHISTORY_DISPLAY_NAME:-Goalong History}"
OUTPUT_DIR="${LOCALHISTORY_OUTPUT_DIR:-$ROOT_DIR/dist}"
if [[ ! -f "$SOURCE_CODESIGN_IDENTITY" ]]; then
  echo "Source code-signing identity resolver is missing: $SOURCE_CODESIGN_IDENTITY" >&2
  exit 1
fi
# shellcheck source=source_codesign_identity.sh
source "$SOURCE_CODESIGN_IDENTITY"
SIGN_IDENTITY="$(localhistory_resolve_source_codesign_identity)"
export LOCALHISTORY_CODESIGN_IDENTITY="$SIGN_IDENTITY"
localhistory_verify_source_codesign_identity "$SIGN_IDENTITY"

if [[ ! -x "$CORE_BUILDER" ]]; then
  echo "Internal app builder is missing: $CORE_BUILDER" >&2
  exit 1
fi
if [[ ! -f "$CODESIGN_POLICY" ]]; then
  echo "Code-signing policy is missing: $CODESIGN_POLICY" >&2
  exit 1
fi
# shellcheck source=codesign_policy.sh
source "$CODESIGN_POLICY"

if [[ "$SIGN_IDENTITY" == "-" ]]; then
  echo "Warning: no Apple Development identity is available; this build is ad-hoc signed and macOS may request permissions again after replacement." >&2
else
  echo "Using stable local code-signing identity: $SIGN_IDENTITY"
fi

# Keep the Swift target and compatibility identifiers internal, while the physical bundle,
# executable, base plist, localizations, Finder name, and Dock name all use the public identity.
"$CORE_BUILDER" "$@"

APP_PATH="$OUTPUT_DIR/$APP_NAME.app"
CONTENTS="$APP_PATH/Contents"
INFO_PLIST="$CONTENTS/Info.plist"
RESOURCES="$CONTENTS/Resources"
if [[ ! -d "$APP_PATH" || ! -f "$INFO_PLIST" ]]; then
  echo "The core build did not produce a complete app bundle: $APP_PATH" >&2
  exit 1
fi

/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $DISPLAY_NAME" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $DISPLAY_NAME" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :NSAccessibilityUsageDescription $DISPLAY_NAME uses Accessibility to understand the foreground app, window, permitted URL, focused control, and clicked interface element. It never controls your Mac." "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :NSInputMonitoringUsageDescription $DISPLAY_NAME uses event-listening access to count clicks, scrolling, shortcuts, navigation keys, and typing duration. It never stores typed characters, passwords, or clipboard contents." "$INFO_PLIST"
/usr/bin/plutil -lint "$INFO_PLIST" >/dev/null

for locale in en fr; do
  locale_dir="$RESOURCES/$locale.lproj"
  mkdir -p "$locale_dir"
  cat > "$locale_dir/InfoPlist.strings" <<STRINGS
"CFBundleDisplayName" = "$DISPLAY_NAME";
"CFBundleName" = "$DISPLAY_NAME";
STRINGS
  /usr/bin/plutil -lint "$locale_dir/InfoPlist.strings" >/dev/null
done

APP_SIGN_ARGS=(--force --sign "$SIGN_IDENTITY" --identifier "$BUNDLE_ID")
if [[ "$SIGN_IDENTITY" != "-" ]]; then
  SIGN_TIMESTAMP_ARGUMENT="$(localhistory_codesign_timestamp_argument "$SIGN_IDENTITY")"
  APP_SIGN_ARGS+=(--options runtime "$SIGN_TIMESTAMP_ARGUMENT")
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
LOCALHISTORY_APP_PATH="$APP_PATH" \
LOCALHISTORY_DISPLAY_NAME="$DISPLAY_NAME" \
LOCALHISTORY_REQUIRE_LOCALIZED_NAME=1 \
  "$ROOT_DIR/scripts/verify_sparkle_bundle.sh"

test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$INFO_PLIST")" = "$DISPLAY_NAME"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$INFO_PLIST")" = "$DISPLAY_NAME"
for locale in en fr; do
  localized="$RESOURCES/$locale.lproj/InfoPlist.strings"
  test "$(/usr/bin/plutil -extract CFBundleDisplayName raw -o - "$localized")" = "$DISPLAY_NAME"
  test "$(/usr/bin/plutil -extract CFBundleName raw -o - "$localized")" = "$DISPLAY_NAME"
done
printf 'Finalized %s at %s\n' "$DISPLAY_NAME" "$APP_PATH"
