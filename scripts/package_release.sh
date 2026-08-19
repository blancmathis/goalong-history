#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="${LOCALHISTORY_OUTPUT_DIR:-$ROOT_DIR/dist}"
APP_PATH="$OUTPUT_DIR/LocalHistory.app"
DMG_PATH="$OUTPUT_DIR/LocalHistory-macOS-universal.dmg"
ZIP_PATH="$OUTPUT_DIR/LocalHistory-macOS-universal.zip"
CREATE_DMG_BIN="${LOCALHISTORY_CREATE_DMG_BIN:-$(command -v create-dmg || true)}"
DMG_SIGN_IDENTITY="${LOCALHISTORY_CODESIGN_IDENTITY:-}"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/localhistory-package.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

if [[ ! -d "$APP_PATH" ]]; then
  echo "App bundle not found: $APP_PATH" >&2
  exit 1
fi
if [[ -z "$CREATE_DMG_BIN" || ! -x "$CREATE_DMG_BIN" ]]; then
  echo "create-dmg is required. Install it with: brew install create-dmg" >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"
rm -f "$DMG_PATH" "$ZIP_PATH"

/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"

STAGING_DIR="$WORK_DIR/staging"
mkdir -p "$STAGING_DIR"
/usr/bin/ditto "$APP_PATH" "$STAGING_DIR/LocalHistory.app"
ln -s /Applications "$STAGING_DIR/Applications"

"$CREATE_DMG_BIN" \
  --volname "Go Long History" \
  --window-pos 200 120 \
  --window-size 620 390 \
  --icon-size 110 \
  --icon "LocalHistory.app" 165 190 \
  --hide-extension "LocalHistory.app" \
  --app-drop-link 455 190 \
  --no-internet-enable \
  "$DMG_PATH" \
  "$STAGING_DIR"

if [[ -n "$DMG_SIGN_IDENTITY" && "$DMG_SIGN_IDENTITY" != "-" ]]; then
  /usr/bin/codesign --force --timestamp --sign "$DMG_SIGN_IDENTITY" "$DMG_PATH"
  /usr/bin/codesign --verify --verbose=2 "$DMG_PATH"
fi

printf 'Created release artifacts:\n- %s\n- %s\n' "$DMG_PATH" "$ZIP_PATH"
