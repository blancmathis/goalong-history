#!/bin/bash
set -euo pipefail

BUILD_EDITION="unified"
APP_NAME="${LOCALHISTORY_APP_NAME:-Goalong History}"
EXECUTABLE_NAME="${LOCALHISTORY_EXECUTABLE_NAME:-Goalong History}"
BUNDLE_ID="${LOCALHISTORY_BUNDLE_ID:-ai.goalong.localhistory}"
PRODUCT_NAME="LocalHistory"
CLI_PRODUCT_NAME="goalong"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CODESIGN_POLICY="$ROOT_DIR/scripts/codesign_policy.sh"
if [[ ! -f "$CODESIGN_POLICY" ]]; then
  echo "Code-signing policy is missing: $CODESIGN_POLICY" >&2
  exit 1
fi
# shellcheck source=codesign_policy.sh
source "$CODESIGN_POLICY"
VERSION="${LOCALHISTORY_VERSION:-0.6.0}"
BUILD_NUMBER="${LOCALHISTORY_BUILD_NUMBER:-1}"
ARCHS="${LOCALHISTORY_ARCHS:-$(uname -m)}"
OUTPUT_DIR="${LOCALHISTORY_OUTPUT_DIR:-$ROOT_DIR/dist}"
SIGN_IDENTITY="${LOCALHISTORY_CODESIGN_IDENTITY:--}"
RUN_TESTS="${LOCALHISTORY_RUN_TESTS:-1}"

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

# A CLI launched outside the app bundle still needs a stable bundle identity so macOS TCC
# can evaluate it against the same certificate-backed designated requirement as the app.
# Without an embedded Info.plist, codesign supplies an identifier but TCC treats the Mach-O
# as an unrelated command-line tool and Goalong's Full Disk Access decision does not apply.
CLI_INFO_PLIST="$WORK_DIR/goalong-Info.plist"
cat > "$CLI_INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>$CLI_PRODUCT_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$CLI_PRODUCT_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
</dict>
</plist>
PLIST
/usr/bin/plutil -lint "$CLI_INFO_PLIST" >/dev/null
export LOCALHISTORY_CLI_INFO_PLIST="$CLI_INFO_PLIST"

if [[ "$RUN_TESTS" == "1" ]]; then
  echo "Testing Goalong History…"
  (cd "$ROOT_DIR" && xcrun swift test)
fi

build_arch() {
  local arch="$1"
  local scratch="$WORK_DIR/build-$arch"
  local log="$WORK_DIR/build-$arch.log"
  local cli_log="$WORK_DIR/build-$arch-cli.log"
  local command=(xcrun swift build -c release --product "$PRODUCT_NAME" --arch "$arch" --scratch-path "$scratch")

  echo "Building ${arch}…"
  set +e
  (cd "$ROOT_DIR" && "${command[@]}") >"$log" 2>&1
  local status=$?
  set -e

  if [[ $status -ne 0 ]]; then
    cat "$log" >&2
    return "$status"
  fi

  local bin_command=(xcrun swift build -c release --product "$PRODUCT_NAME" --arch "$arch" --scratch-path "$scratch" --show-bin-path)
  local bin_dir
  bin_dir="$(cd "$ROOT_DIR" && "${bin_command[@]}")"
  local binary="$bin_dir/$PRODUCT_NAME"
  if [[ ! -x "$binary" ]]; then
    echo "Build completed but $binary was not found." >&2
    return 1
  fi
  cp "$binary" "$WORK_DIR/$PRODUCT_NAME-$arch"

  local cli_command=(xcrun swift build -c release --product "$CLI_PRODUCT_NAME" --arch "$arch" --scratch-path "$scratch")
  if ! (cd "$ROOT_DIR" && "${cli_command[@]}") >"$cli_log" 2>&1; then
    cat "$cli_log" >&2
    return 1
  fi
  local cli_binary="$bin_dir/$CLI_PRODUCT_NAME"
  if [[ ! -x "$cli_binary" ]]; then
    echo "Build completed but $cli_binary was not found." >&2
    return 1
  fi
  cp "$cli_binary" "$WORK_DIR/$CLI_PRODUCT_NAME-$arch"
}

build_all_archs() {
  local arch
  for arch in $ARCHS; do
    build_arch "$arch" || return $?
  done
}

build_all_archs

APP_DIR="$WORK_DIR/$APP_NAME.app"
CONTENTS="$APP_DIR/Contents"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

BINARY_COUNT=0
for arch in $ARCHS; do
  BINARY_COUNT=$((BINARY_COUNT + 1))
done

if [[ $BINARY_COUNT -gt 1 ]]; then
  BINARIES=()
  CLI_BINARIES=()
  for arch in $ARCHS; do
    BINARIES+=("$WORK_DIR/$PRODUCT_NAME-$arch")
    CLI_BINARIES+=("$WORK_DIR/$CLI_PRODUCT_NAME-$arch")
  done
  lipo -create "${BINARIES[@]}" -output "$CONTENTS/MacOS/$EXECUTABLE_NAME"
  lipo -create "${CLI_BINARIES[@]}" -output "$CONTENTS/MacOS/$CLI_PRODUCT_NAME"
else
  first_arch="${ARCHS%% *}"
  cp "$WORK_DIR/$PRODUCT_NAME-$first_arch" "$CONTENTS/MacOS/$EXECUTABLE_NAME"
  cp "$WORK_DIR/$CLI_PRODUCT_NAME-$first_arch" "$CONTENTS/MacOS/$CLI_PRODUCT_NAME"
fi
chmod 755 "$CONTENTS/MacOS/$EXECUTABLE_NAME"
chmod 755 "$CONTENTS/MacOS/$CLI_PRODUCT_NAME"

if /usr/bin/otool -L "$CONTENTS/MacOS/$EXECUTABLE_NAME" | /usr/bin/grep -q 'Sparkle.framework'; then
  echo "The single public app unexpectedly links Sparkle.framework." >&2
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
    <key>LocalHistoryAgentActivityDirectSourceV2</key>
    <true/>
    <key>GoalongBuildEdition</key>
    <string>$BUILD_EDITION</string>
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

plutil -lint "$CONTENTS/Info.plist" >/dev/null

if [[ "$SIGN_IDENTITY" == "-" ]]; then
  # Hardened Runtime library validation rejects ad-hoc signed dynamic frameworks
  # because neither side has a Team ID. Development bundles stay ad-hoc without
  # runtime; certificate-backed bundles keep Hardened Runtime.
  SIGN_ARGS=(--force --sign "$SIGN_IDENTITY")
else
  SIGN_TIMESTAMP_ARGUMENT="$(localhistory_codesign_timestamp_argument "$SIGN_IDENTITY")"
  SIGN_ARGS=(--force --options runtime --sign "$SIGN_IDENTITY" "$SIGN_TIMESTAMP_ARGUMENT")
fi

codesign "${SIGN_ARGS[@]}" --identifier "$BUNDLE_ID" "$CONTENTS/MacOS/$CLI_PRODUCT_NAME"

APP_SIGN_ARGS=(--force --sign "$SIGN_IDENTITY" --identifier "$BUNDLE_ID")
if [[ "$SIGN_IDENTITY" != "-" ]]; then
  APP_SIGN_ARGS+=(--options runtime "$SIGN_TIMESTAMP_ARGUMENT")
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

LOCALHISTORY_APP_PATH="$OUTPUT_DIR/$APP_NAME.app" "$ROOT_DIR/scripts/verify_local_bundle.sh"
LOCALHISTORY_AUDIT_BINARY="$OUTPUT_DIR/$APP_NAME.app/Contents/MacOS/$EXECUTABLE_NAME" \
  "$ROOT_DIR/scripts/audit_privacy_boundaries.sh"

echo
printf 'Built %s %s (%s)\n' "$APP_NAME" "$VERSION" "$ARCHS"
printf 'Output: %s\n' "$OUTPUT_DIR/$APP_NAME.app"
printf 'Edition: %s\n' "$BUILD_EDITION"
echo "Sparkle, first-party HTTP uploader and App Attest transport: physically absent"
echo "Optional ChatGPT analysis: delegated to Codex after explicit consent"
