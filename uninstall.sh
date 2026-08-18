#!/bin/bash
set -euo pipefail

APP_NAME="LocalHistory"
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

for app in "/Applications/$APP_NAME.app" "$HOME/Applications/$APP_NAME.app"; do
  if [[ -x "$app/Contents/MacOS/$APP_NAME" ]]; then
    "$app/Contents/MacOS/$APP_NAME" --unregister-login-item >/dev/null 2>&1 || true
  fi
done

launchctl bootout "gui/$UID" "$HOME/Library/LaunchAgents/$BUNDLE_ID.plist" >/dev/null 2>&1 || true
pkill -x "$APP_NAME" >/dev/null 2>&1 || true
rm -f "$HOME/Library/LaunchAgents/$BUNDLE_ID.plist"
rm -rf "/Applications/$APP_NAME.app" 2>/dev/null || true
rm -rf "$HOME/Applications/$APP_NAME.app"
rm -rf "$LOG_DIR"

tccutil reset Accessibility "$BUNDLE_ID" >/dev/null 2>&1 || true
tccutil reset ListenEvent "$BUNDLE_ID" >/dev/null 2>&1 || true

if [[ "$PURGE_DATA" == true ]]; then
  rm -rf "$DATA_DIR"
  echo "LocalHistory, its permissions, and all recorded data were removed."
else
  echo "LocalHistory and its permissions were removed."
  echo "Your recorded history was kept at:"
  echo "  $DATA_DIR"
fi
