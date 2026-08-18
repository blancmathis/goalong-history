#!/bin/bash
set -euo pipefail

APP_NAME="LocalHistory"
BUNDLE_ID="ai.goalong.localhistory"
VERSION="0.3.2"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="$HOME/Applications"
TARGET_APP="$TARGET_DIR/$APP_NAME.app"
LAUNCH_AGENT="$HOME/Library/LaunchAgents/$BUNDLE_ID.plist"
LOG_DIR="$HOME/Library/Logs/LocalHistory"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This installer must be run on macOS." >&2
  exit 1
fi

if ! xcode-select -p >/dev/null 2>&1; then
  echo "Xcode Command Line Tools are required. macOS will now offer to install them."
  xcode-select --install || true
  echo "Run this installer again after the Command Line Tools installation finishes."
  exit 1
fi

mkdir -p "$TARGET_DIR" "$HOME/Library/LaunchAgents" "$LOG_DIR"
chmod 700 "$LOG_DIR"
touch "$LOG_DIR/stdout.log" "$LOG_DIR/stderr.log"
chmod 600 "$LOG_DIR/stdout.log" "$LOG_DIR/stderr.log"

cd "$ROOT_DIR"
echo "Running privacy-boundary audit…"
./scripts/audit_local_only.sh

echo "Running tests…"
# macOS still ships Bash 3.2. With `set -u`, expanding an empty array can fail
# as an "unbound variable". Keep compatibility mode as a scalar and use
# explicit command branches instead of optional array expansion.
APP_ATTEST_DISABLED=0

swift_test_for_current_mode() {
  if [[ "$APP_ATTEST_DISABLED" -eq 1 ]]; then
    xcrun swift test -Xswiftc -DLOCALHISTORY_NO_APP_ATTEST
  else
    xcrun swift test
  fi
}

swift_build_release_for_current_mode() {
  if [[ "$APP_ATTEST_DISABLED" -eq 1 ]]; then
    xcrun swift build -c release --product LocalHistory -Xswiftc -DLOCALHISTORY_NO_APP_ATTEST
  else
    xcrun swift build -c release --product LocalHistory
  fi
}

swift_release_bin_path_for_current_mode() {
  if [[ "$APP_ATTEST_DISABLED" -eq 1 ]]; then
    xcrun swift build -c release --show-bin-path -Xswiftc -DLOCALHISTORY_NO_APP_ATTEST
  else
    xcrun swift build -c release --show-bin-path
  fi
}

TEST_LOG="$(mktemp)"
set +e
xcrun swift test 2>&1 | tee "$TEST_LOG"
TEST_STATUS=${PIPESTATUS[0]}
set -e

if [[ $TEST_STATUS -ne 0 ]]; then
  if /usr/bin/grep -Eq "AppAttestManager\.swift:[0-9]+:[0-9]+: (error|fatal error):|error: no such module 'DeviceCheck'|error: cannot find 'DCAppAttestService'" "$TEST_LOG"; then
    echo
    echo "The optional App Attest bridge is not compatible with this installed SDK."
    echo "Retrying with App Attest disabled; Secure Enclave signatures and live anchors remain enabled."
    APP_ATTEST_DISABLED=1
    swift_test_for_current_mode
  else
    echo
    echo "Compilation failed for a reason unrelated to App Attest. No compatibility fallback was applied." >&2
    rm -f "$TEST_LOG"
    exit "$TEST_STATUS"
  fi
fi
rm -f "$TEST_LOG"

echo "Building $APP_NAME in release mode…"
swift_build_release_for_current_mode
BIN_DIR="$(swift_release_bin_path_for_current_mode)"
BINARY="$BIN_DIR/LocalHistory"

if [[ ! -x "$BINARY" ]]; then
  echo "Build succeeded but the executable was not found at $BINARY" >&2
  exit 1
fi

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
APP="$STAGING/$APP_NAME.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/$APP_NAME"
chmod 755 "$APP/Contents/MacOS/$APP_NAME"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
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
    <string>5</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSAccessibilityUsageDescription</key>
    <string>LocalHistory uses macOS Accessibility to record the active app, window, focused control, URL, and clicked interface element locally on this Mac.</string>
    <key>NSInputMonitoringUsageDescription</key>
    <string>LocalHistory uses Input Monitoring to record clicks, scroll activity, keyboard shortcuts, navigation keys, and non-content typing activity locally on this Mac.</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST

/usr/bin/plutil -lint "$APP/Contents/Info.plist" >/dev/null
/usr/bin/codesign --force --deep --options runtime --sign - --identifier "$BUNDLE_ID" "$APP"
/usr/bin/codesign --verify --deep --strict "$APP"

/usr/bin/pkill -x "$APP_NAME" >/dev/null 2>&1 || true
sleep 0.5
rm -rf "$TARGET_APP"
/usr/bin/ditto "$APP" "$TARGET_APP"

launchctl bootout "gui/$UID" "$LAUNCH_AGENT" >/dev/null 2>&1 || true
cat > "$LAUNCH_AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$BUNDLE_ID</string>
    <key>ProgramArguments</key>
    <array>
        <string>$TARGET_APP/Contents/MacOS/$APP_NAME</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>LimitLoadToSessionType</key>
    <string>Aqua</string>
    <key>ProcessType</key>
    <string>Interactive</string>
    <key>Umask</key>
    <integer>63</integer>
    <key>StandardOutPath</key>
    <string>$LOG_DIR/stdout.log</string>
    <key>StandardErrorPath</key>
    <string>$LOG_DIR/stderr.log</string>
</dict>
</plist>
PLIST
chmod 600 "$LAUNCH_AGENT"
/usr/bin/plutil -lint "$LAUNCH_AGENT" >/dev/null
launchctl bootstrap "gui/$UID" "$LAUNCH_AGENT"

sleep 0.7
open "$TARGET_APP"

echo
echo "$APP_NAME is installed at:"
echo "  $TARGET_APP"
echo
echo "Data will be stored locally at:"
echo "  $HOME/Library/Application Support/LocalHistory/events/"
echo
echo "The LocalHistory dashboard opens on first launch. Use the menu-bar icon to reopen it, pause capture, or share a selectively anonymized verified day."
