#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="${LOCALHISTORY_APP_PATH:-$ROOT_DIR/dist/Goalong History.app}"
INFO="$APP_PATH/Contents/Info.plist"
EXPECTED_DISPLAY_NAME="${LOCALHISTORY_DISPLAY_NAME:-Goalong History}"

if [[ ! -d "$APP_PATH" || ! -f "$INFO" ]]; then
  echo "Goalong app bundle is incomplete: $APP_PATH" >&2
  exit 1
fi

EXECUTABLE_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$INFO")"
BINARY="$APP_PATH/Contents/MacOS/$EXECUTABLE_NAME"
CLI_BINARY="$APP_PATH/Contents/MacOS/goalong"

test "$(/usr/libexec/PlistBuddy -c 'Print :GoalongBuildEdition' "$INFO")" = "unified"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$INFO")" = "$EXPECTED_DISPLAY_NAME"
test -x "$BINARY"
test -x "$CLI_BINARY"

EXPECTED_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO")"
CLI_SIGNATURE_DETAILS="$(/usr/bin/codesign -d --verbose=4 "$CLI_BINARY" 2>&1)"
if ! /usr/bin/grep -q 'Info.plist entries=' <<<"$CLI_SIGNATURE_DETAILS"; then
  echo "Goalong CLI is missing its embedded Info.plist TCC identity." >&2
  exit 1
fi
if ! /usr/bin/grep -Fq "Identifier=$EXPECTED_BUNDLE_ID" <<<"$CLI_SIGNATURE_DETAILS"; then
  echo "Goalong CLI identity does not match $EXPECTED_BUNDLE_ID." >&2
  exit 1
fi

/usr/bin/python3 "$ROOT_DIR/scripts/verify_cli_plist.py" "$APP_PATH"

UPDATE_ARGS=(--verify-info "$INFO")
if [[ "${LOCALHISTORY_REQUIRE_SPARKLE_CONFIGURED:-0}" == "1" ]]; then
  UPDATE_ARGS+=(--require-configured)
fi
/usr/bin/python3 "$ROOT_DIR/scripts/update_policy.py" "${UPDATE_ARGS[@]}"
FRAMEWORK="$APP_PATH/Contents/Frameworks/Sparkle.framework"
test -d "$FRAMEWORK"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$FRAMEWORK/Resources/Info.plist")" = "2.9.6"
if [[ -e "$FRAMEWORK/XPCServices" || -e "$FRAMEWORK/Versions/B/XPCServices" ]]; then
  echo "Unexpected optional Sparkle XPC services in the non-sandboxed app." >&2
  exit 1
fi
if ! /usr/bin/otool -L "$BINARY" | /usr/bin/grep -q '@rpath/Sparkle.framework'; then
  echo "The real updater is not linked." >&2
  exit 1
fi

ENTITLEMENTS="$(/usr/bin/mktemp "${TMPDIR:-/tmp}/goalong-local-entitlements.XXXXXX")"
STRINGS="$(/usr/bin/mktemp "${TMPDIR:-/tmp}/goalong-local-strings.XXXXXX")"
trap '/bin/rm -f -- "$ENTITLEMENTS" "$STRINGS"' EXIT
if ! /usr/bin/codesign -d --entitlements :- "$APP_PATH" >"$ENTITLEMENTS" 2>/dev/null; then
  : >"$ENTITLEMENTS"
fi
for forbidden_entitlement in \
  com.apple.security.network.client \
  com.apple.security.network.server \
  com.apple.security.automation.apple-events \
  com.apple.security.cs.disable-library-validation \
  com.apple.security.get-task-allow; do
  if /usr/bin/grep -Fq "$forbidden_entitlement" "$ENTITLEMENTS"; then
    echo "The single app contains forbidden entitlement: $forbidden_entitlement" >&2
    exit 1
  fi
done

# A certificate-signed app runs under Hardened Runtime, so it must carry the Calendar
# entitlement or EventKit access is denied silently. Ad-hoc builds have neither.
SIGNATURE_DETAILS="$(/usr/bin/codesign -d --verbose=4 "$APP_PATH" 2>&1)"
if ! /usr/bin/grep -Fq 'Signature=adhoc' <<<"$SIGNATURE_DETAILS"; then
  if ! /usr/bin/grep -Eq 'flags=0x[0-9a-f]+\(.*runtime' <<<"$SIGNATURE_DETAILS"; then
    echo "The signed app is missing the Hardened Runtime flag." >&2
    exit 1
  fi
  if ! /usr/bin/python3 - "$ENTITLEMENTS" <<'PY'
import plistlib, sys
data = open(sys.argv[1], 'rb').read()
try:
    entitlements = plistlib.loads(data)
except Exception:
    sys.exit(1)
sys.exit(0 if entitlements.get('com.apple.security.personal-information.calendars') is True else 1)
PY
  then
    echo "The signed app is missing the com.apple.security.personal-information.calendars entitlement." >&2
    exit 1
  fi
fi

/usr/bin/strings "$BINARY" >"$STRINGS"
for forbidden_marker in \
  'The commitment endpoint URL is invalid.'; do
  if /usr/bin/grep -Fq "$forbidden_marker" "$STRINGS"; then
    echo "The single app contains forbidden transport/process marker: $forbidden_marker" >&2
    exit 1
  fi
done

/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_PATH"
/usr/bin/codesign --verify --strict --verbose=2 "$CLI_BINARY"

RELAUNCHER="$APP_PATH/Contents/MacOS/goalong-relauncher"
if [[ -f "$ROOT_DIR/Sources/GoalongRelauncher/main.swift" ]]; then
  test -x "$RELAUNCHER"
  test ! -L "$RELAUNCHER"
  /usr/bin/codesign --verify --strict --verbose=2 "$RELAUNCHER"
  RELAUNCHER_DETAILS="$(/usr/bin/codesign -d --verbose=4 "$RELAUNCHER" 2>&1)"
  /usr/bin/grep -Fxq "Identifier=$EXPECTED_BUNDLE_ID.relauncher" <<< "$RELAUNCHER_DETAILS"
fi

GUARD="$APP_PATH/Contents/MacOS/goalong-blocking-guard"
GUARD_PLIST="$APP_PATH/Contents/Library/LaunchAgents/$EXPECTED_BUNDLE_ID.blocking-guard.plist"
if [[ -f "$ROOT_DIR/Sources/GoalongGuard/main.swift" ]]; then
  test -x "$GUARD"
  test ! -L "$GUARD"
  /usr/bin/codesign --verify --strict --verbose=2 "$GUARD"
  /usr/bin/grep -Fxq "Identifier=$EXPECTED_BUNDLE_ID.blocking-guard" <<< "$(/usr/bin/codesign -d --verbose=4 "$GUARD" 2>&1)"
  /usr/bin/plutil -lint "$GUARD_PLIST" >/dev/null
  test "$(/usr/libexec/PlistBuddy -c 'Print :Label' "$GUARD_PLIST")" == "$EXPECTED_BUNDLE_ID.blocking-guard"
  test "$(/usr/libexec/PlistBuddy -c 'Print :BundleProgram' "$GUARD_PLIST")" == "Contents/MacOS/goalong-blocking-guard"
  test "$(/usr/libexec/PlistBuddy -c 'Print :KeepAlive:SuccessfulExit' "$GUARD_PLIST")" == false
  test "$(/usr/libexec/PlistBuddy -c 'Print :ThrottleInterval' "$GUARD_PLIST")" -ge 10
  if [[ "$(/bin/ls "$APP_PATH/Contents/Library/LaunchAgents" | /usr/bin/wc -l | /usr/bin/tr -d ' ')" != 1 ]]; then
    echo "The bundle must embed exactly one launch agent: the blocking guard." >&2
    exit 1
  fi
fi

LOCALHISTORY_AUDIT_BINARY="$BINARY" "$ROOT_DIR/scripts/audit_privacy_boundaries.sh"

if ! /usr/bin/grep -Fq 'app-server' "$STRINGS"; then
  echo "The single app is missing its explicit-consent Codex analysis bridge." >&2
  exit 1
fi

if ! /usr/bin/grep -Fq '/api/goalong/v1/import' "$STRINGS"; then
  echo "The single app is missing its reviewed explicit website import transport." >&2
  exit 1
fi

echo "Single-app verification passed: reviewed explicit website transport present; pinned authenticated Sparkle updates; no retired commitment uploader or network entitlement; the Codex bridge remains visible for explicit-consent analysis."
