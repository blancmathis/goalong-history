#!/bin/bash
set -euo pipefail

APP_NAME="LocalHistory"
BUNDLE_ID="ai.goalong.localhistory"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="$HOME/Library/Logs/LocalHistory"
LOG_FILE="$LOG_DIR/installer.log"
VERBOSE="${LOCALHISTORY_INSTALL_VERBOSE:-0}"

mkdir -p "$LOG_DIR"
chmod 700 "$LOG_DIR"
touch "$LOG_FILE"
chmod 600 "$LOG_FILE"

if ! xcode-select -p >/dev/null 2>&1; then
  echo "Xcode Command Line Tools are needed only for source installation." >&2
  echo "Run: xcode-select --install" >&2
  exit 1
fi

run_step() {
  local title="$1"
  shift
  printf '  • %s… ' "$title"
  if [[ "$VERBOSE" == "1" ]]; then
    echo
    "$@" 2>&1 | tee -a "$LOG_FILE"
    echo "    done"
  elif "$@" >>"$LOG_FILE" 2>&1; then
    echo "done"
  else
    echo "failed"
    echo "See $LOG_FILE" >&2
    tail -n 40 "$LOG_FILE" >&2 || true
    return 1
  fi
}

run_step "Checking privacy boundaries" "$ROOT_DIR/scripts/audit_privacy_boundaries.sh"

BUILD_OUTPUT="$(mktemp -d "${TMPDIR:-/tmp}/localhistory-source-install.XXXXXX")"
trap 'rm -rf "$BUILD_OUTPUT"' EXIT
run_step "Testing and building the native app" env \
  LOCALHISTORY_VERSION="${LOCALHISTORY_VERSION:-0.5.1}" \
  LOCALHISTORY_ARCHS="$(uname -m)" \
  LOCALHISTORY_OUTPUT_DIR="$BUILD_OUTPUT" \
  "$ROOT_DIR/scripts/build_app.sh"

SOURCE_APP="$BUILD_OUTPUT/$APP_NAME.app"
if [[ ! -d "$SOURCE_APP" ]]; then
  echo "The source build did not produce $SOURCE_APP" >&2
  exit 1
fi

if [[ -w /Applications ]]; then
  TARGET_DIR="/Applications"
else
  TARGET_DIR="$HOME/Applications"
  mkdir -p "$TARGET_DIR"
fi
TARGET_APP="$TARGET_DIR/$APP_NAME.app"

launchctl bootout "gui/$UID" "$HOME/Library/LaunchAgents/$BUNDLE_ID.plist" >/dev/null 2>&1 || true
rm -f "$HOME/Library/LaunchAgents/$BUNDLE_ID.plist"
pkill -x "$APP_NAME" >/dev/null 2>&1 || true
sleep 0.4
rm -rf "$TARGET_APP"
/usr/bin/ditto "$SOURCE_APP" "$TARGET_APP"
/usr/bin/codesign --verify --strict "$TARGET_APP"
/usr/bin/open "$TARGET_APP"

printf '\nInstalled from source at %s\n' "$TARGET_APP"
