#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=sparkle_release.env
source "$ROOT_DIR/scripts/sparkle_release.env"
APP_PATH="${LOCALHISTORY_APP_PATH:-$ROOT_DIR/dist/Goalong History.app}"
INFO="$APP_PATH/Contents/Info.plist"
FRAMEWORK="$APP_PATH/Contents/Frameworks/Sparkle.framework"
RESOURCES="$APP_PATH/Contents/Resources"
REQUIRE_CONFIGURED="${LOCALHISTORY_REQUIRE_SPARKLE_CONFIGURED:-0}"
REQUIRE_LOCALIZED_NAME="${LOCALHISTORY_REQUIRE_LOCALIZED_NAME:-0}"
EXPECTED_DISPLAY_NAME="${LOCALHISTORY_DISPLAY_NAME:-Goalong History}"

if [[ ! -d "$APP_PATH" || ! -f "$INFO" ]]; then
  echo "Goalong History app bundle is incomplete: $APP_PATH" >&2
  exit 1
fi
EXECUTABLE_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$INFO")"
BINARY="$APP_PATH/Contents/MacOS/$EXECUTABLE_NAME"
CLI_BINARY="$APP_PATH/Contents/MacOS/goalong"
if [[ ! -x "$BINARY" ]]; then
  echo "Goalong History executable is missing: $BINARY" >&2
  exit 1
fi
if [[ ! -x "$CLI_BINARY" ]]; then
  echo "Goalong CLI is missing from the app bundle: $CLI_BINARY" >&2
  exit 1
fi
if [[ ! -d "$FRAMEWORK" ]]; then
  echo "Sparkle.framework is missing from the app bundle." >&2
  exit 1
fi

/usr/bin/codesign --verify --strict --verbose=2 "$FRAMEWORK"
/usr/bin/codesign --verify --strict --verbose=2 "$CLI_BINARY"
/usr/bin/codesign --verify --strict --verbose=2 "$APP_PATH"

APP_SIGNATURE="$({ /usr/bin/codesign -dvv "$APP_PATH" 2>&1 || true; })"
FRAMEWORK_SIGNATURE="$({ /usr/bin/codesign -dvv "$FRAMEWORK" 2>&1 || true; })"
CLI_SIGNATURE="$({ /usr/bin/codesign -dvv "$CLI_BINARY" 2>&1 || true; })"
APP_TEAM="$(printf '%s\n' "$APP_SIGNATURE" | /usr/bin/awk -F= '/^TeamIdentifier=/{print $2; exit}')"
FRAMEWORK_TEAM="$(printf '%s\n' "$FRAMEWORK_SIGNATURE" | /usr/bin/awk -F= '/^TeamIdentifier=/{print $2; exit}')"
CLI_TEAM="$(printf '%s\n' "$CLI_SIGNATURE" | /usr/bin/awk -F= '/^TeamIdentifier=/{print $2; exit}')"
if [[ "$APP_TEAM" != "$FRAMEWORK_TEAM" || "$APP_TEAM" != "$CLI_TEAM" ]]; then
  echo "The app, Goalong CLI and Sparkle.framework have different signing Team IDs." >&2
  exit 1
fi
if [[ "$APP_TEAM" == "not set" ]] && printf '%s\n' "$APP_SIGNATURE" | /usr/bin/grep -q 'runtime'; then
  echo "Ad-hoc development bundles cannot enable Hardened Runtime with Sparkle.framework." >&2
  exit 1
fi

HELPERS="$FRAMEWORK/Versions/B"
if [[ ! -d "$HELPERS" ]]; then
  HELPERS="$FRAMEWORK/Versions/Current"
fi
for nested in \
  "$HELPERS/XPCServices/Installer.xpc" \
  "$HELPERS/XPCServices/Downloader.xpc" \
  "$HELPERS/Autoupdate" \
  "$HELPERS/Updater.app"; do
  if [[ -e "$nested" ]]; then
    /usr/bin/codesign --verify --strict --verbose=2 "$nested"
  fi
done

if ! /usr/bin/otool -L "$BINARY" | /usr/bin/grep -q '@rpath/Sparkle.framework'; then
  echo "The app is not dynamically linked to the embedded Sparkle framework." >&2
  exit 1
fi
if ! /usr/bin/otool -l "$BINARY" | /usr/bin/grep -A2 LC_RPATH | /usr/bin/grep -q '@executable_path/../Frameworks'; then
  echo "The app is missing the app-relative Frameworks rpath." >&2
  exit 1
fi

# The core builder invokes this verifier before public-name localizations are installed. Once
# the finalizer has created them—or when explicitly required—also validate the complete Finder,
# Dock, executable, and bundle filename contract.
LOCALIZED_NAME_PRESENT=0
if [[ -f "$RESOURCES/en.lproj/InfoPlist.strings" && -f "$RESOURCES/fr.lproj/InfoPlist.strings" ]]; then
  LOCALIZED_NAME_PRESENT=1
fi
if [[ "$REQUIRE_LOCALIZED_NAME" == "1" || "$LOCALIZED_NAME_PRESENT" == "1" ]]; then
  BASE_DISPLAY_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$INFO")"
  BASE_BUNDLE_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$INFO")"
  [[ "$BASE_DISPLAY_NAME" == "$EXPECTED_DISPLAY_NAME" ]]
  [[ "$BASE_BUNDLE_NAME" == "$EXPECTED_DISPLAY_NAME" ]]
  [[ "$EXECUTABLE_NAME" == "$EXPECTED_DISPLAY_NAME" ]]
  [[ "$(basename "$APP_PATH")" == "$EXPECTED_DISPLAY_NAME.app" ]]
  for locale in en fr; do
    localized="$RESOURCES/$locale.lproj/InfoPlist.strings"
    if [[ ! -f "$localized" ]]; then
      echo "Missing localized product name: $localized" >&2
      exit 1
    fi
    [[ "$(/usr/bin/plutil -extract CFBundleDisplayName raw -o - "$localized")" == "$EXPECTED_DISPLAY_NAME" ]]
    [[ "$(/usr/bin/plutil -extract CFBundleName raw -o - "$localized")" == "$EXPECTED_DISPLAY_NAME" ]]
  done
fi

PUBLIC_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$INFO" 2>/dev/null || true)"
if [[ -z "$PUBLIC_KEY" ]]; then
  if [[ "$REQUIRE_CONFIGURED" == "1" ]]; then
    echo "Sparkle update configuration is required but SUPublicEDKey is absent." >&2
    exit 1
  fi
  echo "Sparkle framework is embedded; update checks are intentionally disabled for this development build."
  exit 0
fi

FEED_URL="$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$INFO")"
REQUIRE_SIGNED="$(/usr/libexec/PlistBuddy -c 'Print :SURequireSignedFeed' "$INFO")"
VERIFY_BEFORE_EXTRACTION="$(/usr/libexec/PlistBuddy -c 'Print :SUVerifyUpdateBeforeExtraction' "$INFO")"
SYSTEM_PROFILING="$(/usr/libexec/PlistBuddy -c 'Print :SUEnableSystemProfiling' "$INFO")"
SEND_PROFILE="$(/usr/libexec/PlistBuddy -c 'Print :SUSendProfileInfo' "$INFO")"
ALLOW_AUTO="$(/usr/libexec/PlistBuddy -c 'Print :SUAllowsAutomaticUpdates' "$INFO")"

[[ "$FEED_URL" == "$SPARKLE_FEED_URL" ]]
[[ "$FEED_URL" == https://* ]]
[[ "$REQUIRE_SIGNED" == "true" ]]
[[ "$VERIFY_BEFORE_EXTRACTION" == "true" ]]
[[ "$SYSTEM_PROFILING" == "false" ]]
[[ "$SEND_PROFILE" == "false" ]]
[[ "$ALLOW_AUTO" == "false" ]]

# Validate that SUPublicEDKey is exactly a 32-byte Ed25519 public key without printing it.
PUBLIC_KEY="$PUBLIC_KEY" /usr/bin/python3 - <<'PY'
import base64, os
raw = base64.b64decode(os.environ["PUBLIC_KEY"], validate=True)
if len(raw) != 32:
    raise SystemExit("SUPublicEDKey must decode to exactly 32 bytes")
PY

echo "Sparkle bundle verification passed: embedded framework, app-relative rpath, signed-feed policy, privacy defaults, and finalized branding (when present) are valid."
