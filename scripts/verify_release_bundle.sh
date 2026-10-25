#!/bin/bash
# Architecture, pinned signature, identity, localized name, and privacy policy of a release app.
# Shared by the PR preparation, the exact-main promotion, and the full fallback build.
set -euo pipefail
APP="$1"
EXPECTED_VERSION="$2"
EXPECTED_BUILD="$3"
PRODUCT="Goalong History"
INFO="$APP/Contents/Info.plist"
lipo -info "$APP/Contents/MacOS/$PRODUCT"
lipo "$APP/Contents/MacOS/$PRODUCT" -verify_arch arm64 x86_64
codesign --verify --strict --verbose=4 "$APP"
bash "$(dirname "$0")/verify_release_identity.sh" "$APP"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO")" = ai.goalong.localhistory
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$INFO")" = "$PRODUCT"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$INFO")" = "$PRODUCT"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO")" = "$EXPECTED_VERSION"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO")" = "$EXPECTED_BUILD"
for locale in fr; do
  STRINGS="$APP/Contents/Resources/$locale.lproj/InfoPlist.strings"
  test "$(plutil -extract CFBundleDisplayName raw -o - "$STRINGS")" = "$PRODUCT"
  test "$(plutil -extract CFBundleName raw -o - "$STRINGS")" = "$PRODUCT"
done
LOCALHISTORY_APP_PATH="$APP" LOCALHISTORY_REQUIRE_SPARKLE_CONFIGURED=1 LOCALHISTORY_REQUIRE_LOCALIZED_NAME=1 \
  LOCALHISTORY_DISPLAY_NAME="$PRODUCT" "$(dirname "$0")/verify_local_bundle.sh"
