#!/bin/bash
set -euo pipefail

APP_NAME="Goalong History"
EXECUTABLE_NAME="Goalong History"
PREVIOUS_APP_NAME="GoLong History"
LEGACY_APP_NAME="LocalHistory"
DISPLAY_NAME="Goalong History"
BUNDLE_ID="ai.goalong.localhistory"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY="blancmathis/goalong-history"
RELEASE_TAG="${GOALONG_RELEASE_TAG:-latest-main}"
RELEASE_ASSET="Goalong-History-macOS-universal.zip"
SOURCE_ONLY=false
VERBOSE=false

for argument in "$@"; do
  case "$argument" in
    --source) SOURCE_ONLY=true ;;
    --verbose) VERBOSE=true ;;
    -h|--help)
      cat <<HELP
Usage: ./install.sh [--source] [--verbose]

The normal path downloads the latest Sparkle-enabled Goalong History build from GitHub.
Use --source only for a local developer build; source builds cannot self-update.
HELP
      exit 0
      ;;
    *)
      echo "Unknown option: $argument" >&2
      exit 2
      ;;
  esac
done

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "$DISPLAY_NAME can only be installed on macOS." >&2
  exit 1
fi

MACOS_MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
if [[ "$MACOS_MAJOR" -lt 13 ]]; then
  echo "$DISPLAY_NAME requires macOS 13 Ventura or later." >&2
  exit 1
fi

if [[ -t 1 ]]; then
  RESET='\033[0m'
  BOLD='\033[1m'
  DIM='\033[2m'
  BLUE='\033[38;5;75m'
  GREEN='\033[38;5;78m'
  YELLOW='\033[38;5;214m'
  RED='\033[38;5;203m'
else
  RESET='' BOLD='' DIM='' BLUE='' GREEN='' YELLOW='' RED=''
fi

headline() {
  printf '\n%b%s%b\n' "$BOLD$BLUE" "$1" "$RESET"
}
status() {
  printf '  %b✓%b %s\n' "$GREEN" "$RESET" "$1"
}
note() {
  printf '  %b%s%b\n' "$DIM" "$1" "$RESET"
}
warn() {
  printf '  %b!%b %s\n' "$YELLOW" "$RESET" "$1"
}
fail() {
  printf '  %b×%b %s\n' "$RED" "$RESET" "$1" >&2
}

clear 2>/dev/null || true
printf '%b' "$BLUE"
cat <<'BANNER'

       ╭──────────────────────────────╮
       │      ◷  Goalong History      │
       │   private • local • trusted  │
       ╰──────────────────────────────╯
BANNER
printf '%b' "$RESET"

note "A clean, private setup for this Mac. No sudo required."

install_source() {
  headline "Developer installation"
  warn "This creates a local development build without production update credentials."
  if [[ ! -x "$ROOT_DIR/scripts/install_from_source.sh" ]]; then
    fail "This folder does not contain the source installer."
    return 1
  fi
  if [[ "$VERBOSE" == true ]]; then
    LOCALHISTORY_INSTALL_VERBOSE=1 "$ROOT_DIR/scripts/install_from_source.sh"
  else
    "$ROOT_DIR/scripts/install_from_source.sh"
  fi
}

if [[ "$SOURCE_ONLY" == true ]]; then
  install_source
  exit $?
fi

headline "Preparing $DISPLAY_NAME"
status "macOS $(sw_vers -productVersion) detected"
status "$(uname -m) Mac detected"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/localhistory-install.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT
ZIP_PATH="$WORK_DIR/$RELEASE_ASSET"
CHECKSUM_PATH="$WORK_DIR/$RELEASE_ASSET.sha256"
BASE_URL="https://github.com/$REPOSITORY/releases/download/$RELEASE_TAG"
DOWNLOAD_LOG="$WORK_DIR/download.log"

printf '  • Downloading the latest update-enabled Git build… '
set +e
/usr/bin/curl --fail --location --silent --show-error --retry 2 --connect-timeout 12 \
  "$BASE_URL/$RELEASE_ASSET" -o "$ZIP_PATH" >"$DOWNLOAD_LOG" 2>&1
DOWNLOAD_STATUS=$?
set -e
if [[ $DOWNLOAD_STATUS -ne 0 ]]; then
  echo "unavailable"
  fail "No rolling release is currently available from GitHub."
  note "The installer will not silently fall back to a source build because that would disable in-app updates."
  note "Developers can explicitly run ./install.sh --source."
  if [[ "$VERBOSE" == true ]]; then
    cat "$DOWNLOAD_LOG" >&2
  fi
  exit 1
fi
echo "done"

printf '  • Checking the download… '
set +e
/usr/bin/curl --fail --location --silent --show-error --retry 2 --connect-timeout 12 \
  "$BASE_URL/$RELEASE_ASSET.sha256" -o "$CHECKSUM_PATH" >>"$DOWNLOAD_LOG" 2>&1
CHECKSUM_DOWNLOAD_STATUS=$?
set -e
if [[ $CHECKSUM_DOWNLOAD_STATUS -ne 0 ]]; then
  echo "failed"
  fail "The release checksum could not be downloaded."
  exit 1
fi

EXPECTED_HASH="$(awk '{print $1}' "$CHECKSUM_PATH" | head -n 1)"
ACTUAL_HASH="$(/usr/bin/shasum -a 256 "$ZIP_PATH" | awk '{print $1}')"
if [[ -z "$EXPECTED_HASH" || "$EXPECTED_HASH" != "$ACTUAL_HASH" ]]; then
  echo "failed"
  fail "The downloaded archive did not match its published checksum."
  exit 1
fi
echo "verified"

printf '  • Verifying the release bundle… '
/usr/bin/ditto -x -k "$ZIP_PATH" "$WORK_DIR/unpacked"
SOURCE_APP="$WORK_DIR/unpacked/$APP_NAME.app"
if [[ ! -d "$SOURCE_APP" ]]; then
  echo "failed"
  fail "The release archive does not contain $APP_NAME.app."
  exit 1
fi

IDENTIFIER="$(/usr/bin/codesign -dv --verbose=4 "$SOURCE_APP" 2>&1 | awk -F= '/^Identifier=/{print $2; exit}')"
if [[ "$IDENTIFIER" != "$BUNDLE_ID" ]]; then
  echo "failed"
  fail "Unexpected application identifier: ${IDENTIFIER:-missing}"
  exit 1
fi
/usr/bin/codesign --verify --deep --strict "$SOURCE_APP"
INFO_PLIST="$SOURCE_APP/Contents/Info.plist"
FEED_URL="$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$INFO_PLIST" 2>/dev/null || true)"
PUBLIC_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$INFO_PLIST" 2>/dev/null || true)"
REQUIRE_SIGNED_FEED="$(/usr/libexec/PlistBuddy -c 'Print :SURequireSignedFeed' "$INFO_PLIST" 2>/dev/null || true)"
VERIFY_BEFORE_EXTRACTION="$(/usr/libexec/PlistBuddy -c 'Print :SUVerifyUpdateBeforeExtraction' "$INFO_PLIST" 2>/dev/null || true)"
PUBLIC_KEY_BYTES="$(printf '%s' "$PUBLIC_KEY" | /usr/bin/base64 -D 2>/dev/null | /usr/bin/wc -c | /usr/bin/tr -d ' ')"

if [[ "$FEED_URL" != "$BASE_URL/appcast.xml" || "$PUBLIC_KEY_BYTES" != "32" || "$REQUIRE_SIGNED_FEED" != "true" || "$VERIFY_BEFORE_EXTRACTION" != "true" ]]; then
  echo "failed"
  fail "This release is missing the required Sparkle update verification policy."
  exit 1
fi

APPLE_VERIFIED=false
if /usr/sbin/spctl --assess --type execute --verbose=2 "$SOURCE_APP" >/dev/null 2>&1; then
  APPLE_VERIFIED=true
  echo "verified by Apple and Sparkle"
else
  SIGNATURE="$(/usr/bin/codesign -dv --verbose=4 "$SOURCE_APP" 2>&1 | awk -F= '/^Signature=/{print $2; exit}')"
  TEAM_ID="$(/usr/bin/codesign -dv --verbose=4 "$SOURCE_APP" 2>&1 | awk -F= '/^TeamIdentifier=/{print $2; exit}')"
  if [[ "$SIGNATURE" != "adhoc" || "$TEAM_ID" != "not set" ]]; then
    echo "failed"
    fail "The release has an unexpected code-signing identity."
    exit 1
  fi
  echo "verified by Sparkle (Apple verification pending)"
fi

if [[ -d "/Applications/$APP_NAME.app" && -w "/Applications/$APP_NAME.app" ]]; then
  TARGET_DIR="/Applications"
elif [[ -d "/Applications/$PREVIOUS_APP_NAME.app" && -w "/Applications/$PREVIOUS_APP_NAME.app" ]]; then
  TARGET_DIR="/Applications"
elif [[ -d "/Applications/$LEGACY_APP_NAME.app" && -w "/Applications/$LEGACY_APP_NAME.app" ]]; then
  TARGET_DIR="/Applications"
elif [[ -w /Applications ]]; then
  TARGET_DIR="/Applications"
else
  TARGET_DIR="$HOME/Applications"
  mkdir -p "$TARGET_DIR"
fi
TARGET_APP="$TARGET_DIR/$APP_NAME.app"

headline "Installing"
/usr/bin/launchctl bootout "gui/$UID" "$HOME/Library/LaunchAgents/$BUNDLE_ID.plist" >/dev/null 2>&1 || true
rm -f "$HOME/Library/LaunchAgents/$BUNDLE_ID.plist"
/usr/bin/pkill -x "$EXECUTABLE_NAME" >/dev/null 2>&1 || true
/usr/bin/pkill -x "$PREVIOUS_APP_NAME" >/dev/null 2>&1 || true
/usr/bin/pkill -x "$LEGACY_APP_NAME" >/dev/null 2>&1 || true
sleep 0.4
rm -rf "$TARGET_APP"
/usr/bin/ditto "$SOURCE_APP" "$TARGET_APP"
/usr/bin/codesign --verify --deep --strict "$TARGET_APP"
for legacy_app in \
  "/Applications/$PREVIOUS_APP_NAME.app" \
  "$HOME/Applications/$PREVIOUS_APP_NAME.app" \
  "/Applications/$LEGACY_APP_NAME.app" \
  "$HOME/Applications/$LEGACY_APP_NAME.app"; do
  if [[ -d "$legacy_app" ]] && [[ "$(/usr/bin/codesign -dv --verbose=4 "$legacy_app" 2>&1 | awk -F= '/^Identifier=/{print $2; exit}')" == "$BUNDLE_ID" ]]; then
    rm -rf "$legacy_app"
  fi
done
status "Installed in $TARGET_DIR"
status "Legacy background service cleaned up"
status "Your existing history, settings, and bundle ID were preserved"
status "Sparkle update verification enabled"
if [[ "$APPLE_VERIFIED" == true ]]; then
  warn "macOS may ask you to approve this app copy once; the in-app guide handles that step"
else
  warn "Apple Developer verification is not enabled yet; macOS may require Open Anyway on this first copy"
fi

headline "Ready"
note "Opening the guided setup now…"
/usr/bin/open "$TARGET_APP"

printf '\n%bInstallation complete.%b The rest happens inside %s.\n\n' "$BOLD$GREEN" "$RESET" "$DISPLAY_NAME"
