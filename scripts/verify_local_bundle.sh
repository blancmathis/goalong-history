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

for forbidden_key in SUFeedURL SUPublicEDKey SUEnableAutomaticChecks; do
  if /usr/libexec/PlistBuddy -c "Print :$forbidden_key" "$INFO" >/dev/null 2>&1; then
    echo "The single app contains forbidden update key: $forbidden_key" >&2
    exit 1
  fi
done

if [[ -e "$APP_PATH/Contents/Frameworks/Sparkle.framework" ]]; then
  echo "The single app contains Sparkle.framework." >&2
  exit 1
fi
if /usr/bin/otool -L "$BINARY" | /usr/bin/grep -q 'Sparkle.framework'; then
  echo "The single app links Sparkle.framework." >&2
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

/usr/bin/strings "$BINARY" >"$STRINGS"
for forbidden_marker in \
  'SUFeedURL' \
  'SPUStandardUpdaterController' \
  'URLSessionConfiguration.ephemeral'; do
  if /usr/bin/grep -Fq "$forbidden_marker" "$STRINGS"; then
    echo "The single app contains forbidden transport/process marker: $forbidden_marker" >&2
    exit 1
  fi
done

/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_PATH"
/usr/bin/codesign --verify --strict --verbose=2 "$CLI_BINARY"

LOCALHISTORY_AUDIT_BINARY="$BINARY" "$ROOT_DIR/scripts/audit_privacy_boundaries.sh"

if ! /usr/bin/grep -Fq 'app-server' "$STRINGS"; then
  echo "The single app is missing its explicit-consent Codex analysis bridge." >&2
  exit 1
fi

echo "Single-app verification passed: no Sparkle framework/feed, first-party HTTP uploader or network entitlement is present; the Codex bridge remains visible for explicit-consent analysis."
