#!/bin/bash
set -euo pipefail

APP_NAME="Goalong History"
EXECUTABLE_NAME="Goalong History"
PREVIOUS_APP_NAME="GoLong History"
LEGACY_APP_NAME="LocalHistory"
BUNDLE_ID="ai.goalong.localhistory"
DATA_DIR="$HOME/Library/Application Support/LocalHistory"
LOG_DIR="$HOME/Library/Logs/LocalHistory"
PURGE_DATA=false

case "${1:-}" in
  "") ;;
  --purge-data) PURGE_DATA=true ;;
  -h|--help)
    echo "Usage: ./uninstall.sh [--purge-data]"
    exit 0
    ;;
  *)
    echo "Unknown option: ${1:-}" >&2
    exit 2
    ;;
esac

# A locked block (Goalong › Blocage) is a commitment: refuse before any effect, until its end.
LOCK_MARKER="$DATA_DIR/Blocking/locked-until"
if [[ "${GOALONG_UNINSTALL_DURING_LOCK:-}" != 1 && -f "$LOCK_MARKER" && ! -L "$LOCK_MARKER" ]]; then
  locked_until="$(head -c 12 "$LOCK_MARKER" | tr -cd '0-9')"
  if [[ -n "$locked_until" ]] && (( locked_until > $(date +%s) )); then
    echo "A locked block is active until $(date -r "$locked_until" '+%Y-%m-%d %H:%M')." >&2
    echo "Goalong History was not removed. Run this again after that time." >&2
    echo "To remove it anyway: GOALONG_UNINSTALL_DURING_LOCK=1 ./uninstall.sh" >&2
    exit 3
  fi
fi

for app in \
  "/Applications/$APP_NAME.app" \
  "$HOME/Applications/$APP_NAME.app" \
  "/Applications/$PREVIOUS_APP_NAME.app" \
  "$HOME/Applications/$PREVIOUS_APP_NAME.app" \
  "/Applications/$LEGACY_APP_NAME.app" \
  "$HOME/Applications/$LEGACY_APP_NAME.app"; do
  executable="$app/Contents/MacOS/$EXECUTABLE_NAME"
  if [[ ! -x "$executable" ]]; then
    executable="$app/Contents/MacOS/$PREVIOUS_APP_NAME"
  fi
  if [[ ! -x "$executable" ]]; then
    executable="$app/Contents/MacOS/$LEGACY_APP_NAME"
  fi
  if [[ -x "$executable" ]]; then
    "$executable" --unregister-login-item >/dev/null 2>&1 || true
  fi
done

launchctl bootout "gui/$UID" "$HOME/Library/LaunchAgents/$BUNDLE_ID.plist" >/dev/null 2>&1 || true
pkill -x "$EXECUTABLE_NAME" >/dev/null 2>&1 || true
pkill -x "$PREVIOUS_APP_NAME" >/dev/null 2>&1 || true
pkill -x "$LEGACY_APP_NAME" >/dev/null 2>&1 || true
rm -f "$HOME/Library/LaunchAgents/$BUNDLE_ID.plist"
rm -rf "/Applications/$APP_NAME.app" 2>/dev/null || true
rm -rf "$HOME/Applications/$APP_NAME.app"
rm -rf "/Applications/$PREVIOUS_APP_NAME.app" 2>/dev/null || true
rm -rf "$HOME/Applications/$PREVIOUS_APP_NAME.app"
rm -rf "/Applications/$LEGACY_APP_NAME.app" 2>/dev/null || true
rm -rf "$HOME/Applications/$LEGACY_APP_NAME.app"
rm -rf "$LOG_DIR"

tccutil reset Accessibility "$BUNDLE_ID" >/dev/null 2>&1 || true
tccutil reset ListenEvent "$BUNDLE_ID" >/dev/null 2>&1 || true

if [[ "$PURGE_DATA" == true ]]; then
  rm -rf "$DATA_DIR"
  echo "Goalong History, its permissions, and all recorded data were removed."
else
  echo "Goalong History and its permissions were removed."
  echo "Your recorded history was kept at:"
  echo "  $DATA_DIR"
fi
