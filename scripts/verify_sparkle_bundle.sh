#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=sparkle_release.env
source "$ROOT_DIR/scripts/sparkle_release.env"
APP_PATH="${LOCALHISTORY_APP_PATH:-$ROOT_DIR/dist/LocalHistory.app}"
INFO="$APP_PATH/Contents/Info.plist"
FRAMEWORK="$APP_PATH/Contents/Frameworks/Sparkle.framework"
BINARY="$APP_PATH/Contents/MacOS/LocalHistory"
REQUIRE_CONFIGURED="${LOCALHISTORY_REQUIRE_SPARKLE_CONFIGURED:-0}"

if [[ ! -d "$APP_PATH" || ! -f "$INFO" || ! -x "$BINARY" ]]; then
  echo "LocalHistory app bundle is incomplete: $APP_PATH" >&2
  exit 1
fi
if [[ ! -d "$FRAMEWORK" ]]; then
  echo "Sparkle.framework is missing from the app bundle." >&2
  exit 1
fi

/usr/bin/codesign --verify --strict --verbose=2 "$FRAMEWORK"
/usr/bin/codesign --verify --strict --verbose=2 "$APP_PATH"

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
  echo "LocalHistory is not dynamically linked to the embedded Sparkle framework." >&2
  exit 1
fi
if ! /usr/bin/otool -l "$BINARY" | /usr/bin/grep -A2 LC_RPATH | /usr/bin/grep -q '@executable_path/../Frameworks'; then
  echo "LocalHistory is missing the app-relative Frameworks rpath." >&2
  exit 1
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
SYSTEM_PROFILING="$(/usr/libexec/PlistBuddy -c 'Print :SUEnableSystemProfiling' "$INFO")"
SEND_PROFILE="$(/usr/libexec/PlistBuddy -c 'Print :SUSendProfileInfo' "$INFO")"
ALLOW_AUTO="$(/usr/libexec/PlistBuddy -c 'Print :SUAllowsAutomaticUpdates' "$INFO")"

[[ "$FEED_URL" == "$SPARKLE_FEED_URL" ]]
[[ "$FEED_URL" == https://* ]]
[[ "$REQUIRE_SIGNED" == "true" ]]
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

echo "Sparkle bundle verification passed: embedded framework, app-relative rpath, signed-feed policy, and privacy defaults are valid."
