#!/bin/bash
set -euo pipefail

APP_NAME="LocalHistory"
BUNDLE_ID="ai.goalong.localhistory"
TARGET_APP="$HOME/Applications/$APP_NAME.app"
LAUNCH_AGENT="$HOME/Library/LaunchAgents/$BUNDLE_ID.plist"
DATA_DIR="$HOME/Library/Application Support/LocalHistory"
LOG_DIR="$HOME/Library/Logs/LocalHistory"
PURGE_DATA=false

if [[ "${1:-}" == "--purge-data" ]]; then
  PURGE_DATA=true
fi

launchctl bootout "gui/$UID" "$LAUNCH_AGENT" >/dev/null 2>&1 || true
/usr/bin/pkill -x "$APP_NAME" >/dev/null 2>&1 || true
rm -f "$LAUNCH_AGENT"
rm -rf "$TARGET_APP"
rm -rf "$LOG_DIR"

# Remove the app's TCC entries where supported. Failures are harmless.
tccutil reset Accessibility "$BUNDLE_ID" >/dev/null 2>&1 || true
tccutil reset ListenEvent "$BUNDLE_ID" >/dev/null 2>&1 || true

if [[ "$PURGE_DATA" == true ]]; then
  rm -rf "$DATA_DIR"
  echo "LocalHistory and all recorded data were removed."
else
  echo "LocalHistory was removed. Recorded data was kept at:"
  echo "  $DATA_DIR"
  echo "Run ./uninstall.sh --purge-data to remove it too."
fi
