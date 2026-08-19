#!/bin/bash
set -euo pipefail

APP_NAME="LocalHistory"
DISPLAY_NAME="${LOCALHISTORY_DISPLAY_NAME:-Go Long History}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="${LOCALHISTORY_APP_PATH:-$ROOT_DIR/dist/$APP_NAME.app}"
OUTPUT_DIR="${LOCALHISTORY_OUTPUT_DIR:-$ROOT_DIR/dist}"
DMG_NAME="${LOCALHISTORY_DMG_NAME:-LocalHistory-macOS-universal.dmg}"
ZIP_NAME="${LOCALHISTORY_ZIP_NAME:-LocalHistory-macOS-universal.zip}"
SIGN_IDENTITY="${LOCALHISTORY_CODESIGN_IDENTITY:-}"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "package_release.sh must run on macOS." >&2
  exit 1
fi
if [[ ! -d "$APP_PATH" ]]; then
  echo "App bundle not found: $APP_PATH" >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"
rm -f "$OUTPUT_DIR/$DMG_NAME" "$OUTPUT_DIR/$ZIP_NAME"

/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$OUTPUT_DIR/$ZIP_NAME"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/localhistory-dmg.XXXXXX")"
STAGING="$WORK_DIR/staging"
mkdir -p "$STAGING"
trap 'rm -rf "$WORK_DIR"' EXIT
/usr/bin/ditto "$APP_PATH" "$STAGING/$APP_NAME.app"

BACKGROUND_SOURCE="$ROOT_DIR/Distribution/DMGBackground.png"
if [[ ! -f "$BACKGROUND_SOURCE" && -f "$ROOT_DIR/scripts/generate_distribution_assets.swift" ]]; then
  GENERATED_ASSETS="$WORK_DIR/generated-assets"
  mkdir -p "$GENERATED_ASSETS"
  xcrun swift "$ROOT_DIR/scripts/generate_distribution_assets.swift" "$GENERATED_ASSETS" >/dev/null
  BACKGROUND_SOURCE="$GENERATED_ASSETS/DMGBackground.png"
fi

if command -v create-dmg >/dev/null 2>&1; then
  CREATE_ARGS=(
    --volname "$DISPLAY_NAME"
    --window-pos 200 120
    --window-size 720 440
    --icon-size 108
    --icon "$APP_NAME.app" 180 225
    --hide-extension "$APP_NAME.app"
    --app-drop-link 540 225
    --no-internet-enable
  )
  if [[ -f "$BACKGROUND_SOURCE" ]]; then
    CREATE_ARGS+=(--background "$BACKGROUND_SOURCE")
  fi
  if [[ -f "$APP_PATH/Contents/Resources/LocalHistory.icns" ]]; then
    CREATE_ARGS+=(--volicon "$APP_PATH/Contents/Resources/LocalHistory.icns")
  fi
  create-dmg "${CREATE_ARGS[@]}" "$OUTPUT_DIR/$DMG_NAME" "$STAGING"
else
  echo "create-dmg is unavailable; creating a standard Finder disk image."
  ln -s /Applications "$STAGING/Applications"
  /usr/bin/hdiutil create \
    -volname "$DISPLAY_NAME" \
    -srcfolder "$STAGING" \
    -ov \
    -format UDZO \
    "$OUTPUT_DIR/$DMG_NAME" >/dev/null
fi

if [[ -n "$SIGN_IDENTITY" && "$SIGN_IDENTITY" != "-" ]]; then
  /usr/bin/codesign --force --timestamp --sign "$SIGN_IDENTITY" "$OUTPUT_DIR/$DMG_NAME"
  /usr/bin/codesign --verify --verbose=2 "$OUTPUT_DIR/$DMG_NAME"
fi

(
  cd "$OUTPUT_DIR"
  /usr/bin/shasum -a 256 "$ZIP_NAME" > "$ZIP_NAME.sha256"
  /usr/bin/shasum -a 256 "$DMG_NAME" > "$DMG_NAME.sha256"
)

printf 'Release artifacts for %s:\n  %s\n  %s\n' "$DISPLAY_NAME" "$OUTPUT_DIR/$DMG_NAME" "$OUTPUT_DIR/$ZIP_NAME"
