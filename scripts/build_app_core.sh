#!/bin/bash
set -euo pipefail

APP_NAME="Goalong History"
PRODUCT_NAME="LocalHistory"
EXECUTABLE_NAME="Goalong History"
BUNDLE_ID="ai.goalong.localhistory"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=sparkle_release.env
source "$ROOT_DIR/scripts/sparkle_release.env"
VERSION="${LOCALHISTORY_VERSION:-0.5.1}"
BUILD_NUMBER="${LOCALHISTORY_BUILD_NUMBER:-1}"
ARCHS="${LOCALHISTORY_ARCHS:-$(uname -m)}"
OUTPUT_DIR="${LOCALHISTORY_OUTPUT_DIR:-$ROOT_DIR/dist}"
SIGN_IDENTITY="${LOCALHISTORY_CODESIGN_IDENTITY:--}"
RUN_TESTS="${LOCALHISTORY_RUN_TESTS:-1}"
DISABLE_APP_ATTEST="${LOCALHISTORY_DISABLE_APP_ATTEST:-auto}"
SPARKLE_PUBLIC_ED_KEY="${LOCALHISTORY_SPARKLE_PUBLIC_ED_KEY:-}"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "build_app.sh must run on macOS." >&2
  exit 1
fi

if ! xcode-select -p >/dev/null 2>&1; then
  echo "Xcode Command Line Tools are required to build Goalong History." >&2
  exit 1
fi

for tool in xcrun plutil codesign ditto lipo sips iconutil otool; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Required build tool not found: $tool" >&2
    exit 1
  fi
done

mkdir -p "$OUTPUT_DIR"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/localhistory-build.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

APP_ATTEST_DISABLED=0
case "$DISABLE_APP_ATTEST" in
  1|true|yes) APP_ATTEST_DISABLED=1 ;;
  0|false|no) APP_ATTEST_DISABLED=0 ;;
  auto) ;;
  *)
    echo "LOCALHISTORY_DISABLE_APP_ATTEST must be auto, 0, or 1." >&2
    exit 1
    ;;
esac

is_app_attest_sdk_failure() {
  /usr/bin/grep -Eq "AppAttestManager\\.swift:[0-9]+:[0-9]+: (error|fatal error):|error: no such module 'DeviceCheck'|error: cannot find 'DCAppAttestService'" "$1"
}

run_swift_test() {
  if [[ "$APP_ATTEST_DISABLED" -eq 1 ]]; then
    xcrun swift test -Xswiftc -DLOCALHISTORY_NO_APP_ATTEST
  else
    xcrun swift test
  fi
}

if [[ "$RUN_TESTS" == "1" ]]; then
  echo "Testing Goalong History…"
  TEST_LOG="$WORK_DIR/tests.log"
  set +e
  (cd "$ROOT_DIR" && run_swift_test) >"$TEST_LOG" 2>&1
  TEST_STATUS=$?
  set -e

  if [[ $TEST_STATUS -ne 0 && "$DISABLE_APP_ATTEST" == "auto" ]] && is_app_attest_sdk_failure "$TEST_LOG"; then
    APP_ATTEST_DISABLED=1
    (cd "$ROOT_DIR" && run_swift_test)
  elif [[ $TEST_STATUS -ne 0 ]]; then
    cat "$TEST_LOG" >&2
    exit "$TEST_STATUS"
  else
    cat "$TEST_LOG"
  fi
fi

build_arch() {
  local arch="$1"
  local scratch="$WORK_DIR/build-$arch"
  local log="$WORK_DIR/build-$arch.log"
  local command=(xcrun swift build -c release --product "$PRODUCT_NAME" --arch "$arch" --scratch-path "$scratch")
  if [[ "$APP_ATTEST_DISABLED" -eq 1 ]]; then
    command+=( -Xswiftc -DLOCALHISTORY_NO_APP_ATTEST )
  fi

  echo "Building ${arch}…"
  set +e
  (cd "$ROOT_DIR" && "${command[@]}") >"$log" 2>&1
  local status=$?
  set -e

  if [[ $status -ne 0 && "$DISABLE_APP_ATTEST" == "auto" && "$APP_ATTEST_DISABLED" -eq 0 ]] && is_app_attest_sdk_failure "$log"; then
    return 42
  fi
  if [[ $status -ne 0 ]]; then
    cat "$log" >&2
    return "$status"
  fi

  local bin_command=(xcrun swift build -c release --product "$PRODUCT_NAME" --arch "$arch" --scratch-path "$scratch" --show-bin-path)
  if [[ "$APP_ATTEST_DISABLED" -eq 1 ]]; then
    bin_command+=( -Xswiftc -DLOCALHISTORY_NO_APP_ATTEST )
  fi
  local bin_dir
  bin_dir="$(cd "$ROOT_DIR" && "${bin_command[@]}")"
  local binary="$bin_dir/$PRODUCT_NAME"
  if [[ ! -x "$binary" ]]; then
    echo "Build completed but $binary was not found." >&2
    return 1
  fi
  cp "$binary" "$WORK_DIR/$PRODUCT_NAME-$arch"
}

build_all_archs() {
  local arch
  for arch in $ARCHS; do
    build_arch "$arch" || return $?
  done
}

set +e
build_all_archs
BUILD_STATUS=$?
set -e
if [[ $BUILD_STATUS -eq 42 ]]; then
  echo "The installed SDK does not support the optional App Attest bridge; rebuilding with it disabled."
  APP_ATTEST_DISABLED=1
  rm -f "$WORK_DIR/$PRODUCT_NAME-"*
  rm -rf "$WORK_DIR"/build-*
  build_all_archs
elif [[ $BUILD_STATUS -ne 0 ]]; then
  exit "$BUILD_STATUS"
fi

APP_DIR="$WORK_DIR/$APP_NAME.app"
CONTENTS="$APP_DIR/Contents"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources" "$CONTENTS/Frameworks"

BINARY_COUNT=0
for arch in $ARCHS; do
  BINARY_COUNT=$((BINARY_COUNT + 1))
done

if [[ $BINARY_COUNT -gt 1 ]]; then
  BINARIES=()
  for arch in $ARCHS; do
    BINARIES+=("$WORK_DIR/$PRODUCT_NAME-$arch")
  done
  lipo -create "${BINARIES[@]}" -output "$CONTENTS/MacOS/$EXECUTABLE_NAME"
else
  first_arch="${ARCHS%% *}"
  cp "$WORK_DIR/$PRODUCT_NAME-$first_arch" "$CONTENTS/MacOS/$EXECUTABLE_NAME"
fi
chmod 755 "$CONTENTS/MacOS/$EXECUTABLE_NAME"

# SwiftPM links Sparkle dynamically but does not create our hand-built .app bundle for us.
# Copy the exact binary artifact resolved by Package.swift, preserving symlinks and metadata.
SPARKLE_FRAMEWORK="$(find "$WORK_DIR" -type d -name Sparkle.framework -path '*/artifacts/sparkle/Sparkle/*' -print -quit 2>/dev/null || true)"
if [[ -z "$SPARKLE_FRAMEWORK" ]]; then
  echo "Sparkle.framework was not found in SwiftPM build artifacts." >&2
  exit 1
fi
/usr/bin/ditto "$SPARKLE_FRAMEWORK" "$CONTENTS/Frameworks/Sparkle.framework"

if ! /usr/bin/otool -L "$CONTENTS/MacOS/$EXECUTABLE_NAME" | /usr/bin/grep -q '@rpath/Sparkle.framework'; then
  echo "Built binary is not linked to Sparkle.framework." >&2
  exit 1
fi
if ! /usr/bin/otool -l "$CONTENTS/MacOS/$EXECUTABLE_NAME" | /usr/bin/grep -A2 LC_RPATH | /usr/bin/grep -q '@executable_path/../Frameworks'; then
  echo "Built binary is missing the app-relative Frameworks rpath." >&2
  exit 1
fi

ICON_SOURCE="$ROOT_DIR/Distribution/AppIcon.png"
if [[ ! -f "$ICON_SOURCE" && -f "$ROOT_DIR/scripts/generate_distribution_assets.swift" ]]; then
  GENERATED_ASSETS="$WORK_DIR/generated-assets"
  mkdir -p "$GENERATED_ASSETS"
  xcrun swift "$ROOT_DIR/scripts/generate_distribution_assets.swift" "$GENERATED_ASSETS" >/dev/null
  ICON_SOURCE="$GENERATED_ASSETS/AppIcon.png"
fi
if [[ -f "$ICON_SOURCE" ]]; then
  ICONSET="$WORK_DIR/LocalHistory.iconset"
  mkdir -p "$ICONSET"
  sips -z 16 16 "$ICON_SOURCE" --out "$ICONSET/icon_16x16.png" >/dev/null
  sips -z 32 32 "$ICON_SOURCE" --out "$ICONSET/icon_16x16@2x.png" >/dev/null
  sips -z 32 32 "$ICON_SOURCE" --out "$ICONSET/icon_32x32.png" >/dev/null
  sips -z 64 64 "$ICON_SOURCE" --out "$ICONSET/icon_32x32@2x.png" >/dev/null
  sips -z 128 128 "$ICON_SOURCE" --out "$ICONSET/icon_128x128.png" >/dev/null
  sips -z 256 256 "$ICON_SOURCE" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
  sips -z 256 256 "$ICON_SOURCE" --out "$ICONSET/icon_256x256.png" >/dev/null
  sips -z 512 512 "$ICON_SOURCE" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
  sips -z 512 512 "$ICON_SOURCE" --out "$ICONSET/icon_512x512.png" >/dev/null
  sips -z 1024 1024 "$ICON_SOURCE" --out "$ICONSET/icon_512x512@2x.png" >/dev/null
  iconutil -c icns "$ICONSET" -o "$CONTENTS/Resources/LocalHistory.icns"
fi

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundleExecutable</key>
    <string>$EXECUTABLE_NAME</string>
    <key>CFBundleIconFile</key>
    <string>LocalHistory</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.productivity</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSAccessibilityUsageDescription</key>
    <string>Goalong History uses Accessibility to understand the foreground app, window, permitted URL, focused control, and clicked interface element. It never controls your Mac.</string>
    <key>NSInputMonitoringUsageDescription</key>
    <string>Goalong History uses Input Monitoring to count clicks, scrolling, shortcuts, navigation keys, and typing duration. It never stores typed characters, passwords, or clipboard contents.</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 Goalong. All rights reserved.</string>
</dict>
</plist>
PLIST

# Production/CI bundles receive a Sparkle key explicitly. Development source builds omit
# the updater keys and SoftwareUpdateManager fails closed instead of hitting a live feed.
if [[ -n "$SPARKLE_PUBLIC_ED_KEY" ]]; then
  /usr/libexec/PlistBuddy -c "Add :SUFeedURL string $SPARKLE_FEED_URL" "$CONTENTS/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $SPARKLE_PUBLIC_ED_KEY" "$CONTENTS/Info.plist"
  /usr/libexec/PlistBuddy -c 'Add :SURequireSignedFeed bool true' "$CONTENTS/Info.plist"
  /usr/libexec/PlistBuddy -c 'Add :SUVerifyUpdateBeforeExtraction bool true' "$CONTENTS/Info.plist"
  /usr/libexec/PlistBuddy -c 'Add :SUEnableAutomaticChecks bool true' "$CONTENTS/Info.plist"
  /usr/libexec/PlistBuddy -c 'Add :SUScheduledCheckInterval integer 86400' "$CONTENTS/Info.plist"
  /usr/libexec/PlistBuddy -c 'Add :SUAllowsAutomaticUpdates bool false' "$CONTENTS/Info.plist"
  /usr/libexec/PlistBuddy -c 'Add :SUAutomaticallyUpdate bool false' "$CONTENTS/Info.plist"
  /usr/libexec/PlistBuddy -c 'Add :SUEnableSystemProfiling bool false' "$CONTENTS/Info.plist"
  /usr/libexec/PlistBuddy -c 'Add :SUSendProfileInfo bool false' "$CONTENTS/Info.plist"
fi

plutil -lint "$CONTENTS/Info.plist" >/dev/null

if [[ "$SIGN_IDENTITY" == "-" ]]; then
  # Hardened Runtime library validation rejects ad-hoc signed dynamic frameworks
  # because neither side has a Team ID. Development bundles stay ad-hoc without
  # runtime; production Developer ID bundles keep Hardened Runtime and timestamps.
  SIGN_ARGS=(--force --sign "$SIGN_IDENTITY")
else
  SIGN_ARGS=(--force --options runtime --sign "$SIGN_IDENTITY" --timestamp)
fi

sign_sparkle_component() {
  local path="$1"
  shift
  if [[ -e "$path" ]]; then
    codesign "${SIGN_ARGS[@]}" "$@" "$path"
  fi
}

# Explicit nested-code signing order from Sparkle's manual distribution guidance.
# Do not use --deep: Downloader.xpc carries its own entitlement metadata.
SPARKLE_VERSION_DIR="$CONTENTS/Frameworks/Sparkle.framework/Versions/B"
if [[ ! -d "$SPARKLE_VERSION_DIR" ]]; then
  SPARKLE_VERSION_DIR="$CONTENTS/Frameworks/Sparkle.framework/Versions/Current"
fi
sign_sparkle_component "$SPARKLE_VERSION_DIR/XPCServices/Installer.xpc"
sign_sparkle_component "$SPARKLE_VERSION_DIR/XPCServices/Downloader.xpc" --preserve-metadata=entitlements
sign_sparkle_component "$SPARKLE_VERSION_DIR/Autoupdate"
sign_sparkle_component "$SPARKLE_VERSION_DIR/Updater.app"
sign_sparkle_component "$CONTENTS/Frameworks/Sparkle.framework"

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
codesign "${APP_SIGN_ARGS[@]}" "$APP_DIR"
codesign --verify --strict --verbose=2 "$APP_DIR"

rm -rf "$OUTPUT_DIR/$APP_NAME.app"
ditto "$APP_DIR" "$OUTPUT_DIR/$APP_NAME.app"

LOCALHISTORY_APP_PATH="$OUTPUT_DIR/$APP_NAME.app" "$ROOT_DIR/scripts/verify_sparkle_bundle.sh"

echo
printf 'Built %s %s (%s)\n' "$APP_NAME" "$VERSION" "$ARCHS"
printf 'Output: %s\n' "$OUTPUT_DIR/$APP_NAME.app"
if [[ "$APP_ATTEST_DISABLED" -eq 1 ]]; then
  echo "Optional App Attest bridge: disabled for SDK compatibility"
else
  echo "Optional App Attest bridge: enabled"
fi
if [[ -n "$SPARKLE_PUBLIC_ED_KEY" ]]; then
  echo "Sparkle updates: configured for signed feed checks"
else
  echo "Sparkle updates: framework embedded, live checks disabled in this development build"
fi
