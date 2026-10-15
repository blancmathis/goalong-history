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

# Ask the running app to quit with SIGTERM: it flushes its history, seals the minute and closes
# its journal. Wait for it (8 s by default), and only then force it. Names are executable names.
quit_running_goalong() {
  local name waited=0 limit="${GOALONG_QUIT_WAIT_TENTHS:-80}" running
  for name in "$@"; do /usr/bin/pkill -TERM -x "$name" >/dev/null 2>&1 || true; done
  while (( waited < limit )); do
    running=0
    for name in "$@"; do
      if /usr/bin/pgrep -x "$name" >/dev/null 2>&1; then running=1; fi
    done
    (( running == 0 )) && return 0
    /bin/sleep 0.1
    waited=$((waited + 1))
  done
  for name in "$@"; do /usr/bin/pkill -KILL -x "$name" >/dev/null 2>&1 || true; done
  /bin/sleep 0.4
}

# Remove ~/.local/bin/goalong only when it is a symlink into a Goalong bundle (the same targets
# scripts/install_cli_link.sh accepts). A regular file or an unrelated link is never touched.
remove_goalong_cli_link() {
  local link_path="${1:-$HOME/.local/bin/goalong}" target
  [[ -L "$link_path" ]] || return 0
  target="$(readlink "$link_path")"
  case "$target" in
    */Goalong\ History.app/Contents/MacOS/goalong|\
    */Goalong\ History\ Local.app/Contents/MacOS/goalong|\
    */Goalong\ History.app/Contents/MacOS/Goalong\ History|\
    */Goalong\ History\ Local.app/Contents/MacOS/Goalong\ History\ Local|\
    */GoLong\ History.app/Contents/MacOS/*|\
    */LocalHistory.app/Contents/MacOS/*)
      rm -f -- "$link_path"
      ;;
  esac
}

[[ "${BASH_SOURCE[0]}" == "$0" ]] || return 0

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

AGENT_HOOKS_NOTE=false
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
    # Older builds do not know this flag and would start the full app, so only call builds that do.
    if /usr/bin/grep -qaF -- '--uninstall-agent-integrations' "$executable" 2>/dev/null; then
      "$executable" --uninstall-agent-integrations >/dev/null 2>&1 || true
    else
      AGENT_HOOKS_NOTE=true
    fi
  fi
done

if [[ "$AGENT_HOOKS_NOTE" == true ]]; then
  echo "An older Goalong build could not remove its agent hooks. If they remain, delete the Goalong entries in:" >&2
  echo "  ~/.claude/settings.json, ~/.codex/hooks.json, ~/.cursor/hooks.json, ~/.config/opencode/plugins/goalong-history.js" >&2
fi

launchctl bootout "gui/$UID" "$HOME/Library/LaunchAgents/$BUNDLE_ID.plist" >/dev/null 2>&1 || true
quit_running_goalong "$EXECUTABLE_NAME" "$PREVIOUS_APP_NAME" "$LEGACY_APP_NAME"
rm -f "$HOME/Library/LaunchAgents/$BUNDLE_ID.plist"
rm -rf "/Applications/$APP_NAME.app" 2>/dev/null || true
rm -rf "$HOME/Applications/$APP_NAME.app"
rm -rf "/Applications/$PREVIOUS_APP_NAME.app" 2>/dev/null || true
rm -rf "$HOME/Applications/$PREVIOUS_APP_NAME.app"
rm -rf "/Applications/$LEGACY_APP_NAME.app" 2>/dev/null || true
rm -rf "$HOME/Applications/$LEGACY_APP_NAME.app"
rm -rf "$LOG_DIR"

remove_goalong_cli_link

tccutil reset Accessibility "$BUNDLE_ID" >/dev/null 2>&1 || true
tccutil reset ListenEvent "$BUNDLE_ID" >/dev/null 2>&1 || true
tccutil reset SystemPolicyAllFiles "$BUNDLE_ID" >/dev/null 2>&1 || true
tccutil reset Calendar "$BUNDLE_ID" >/dev/null 2>&1 || true
tccutil reset Reminders "$BUNDLE_ID" >/dev/null 2>&1 || true

if [[ "$PURGE_DATA" == true ]]; then
  rm -rf "$DATA_DIR" "$DATA_DIR-Dev"
  rm -rf "$HOME/Library/Caches/$BUNDLE_ID"
  defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
  while security delete-generic-password -s "goalong.evidence.v1" >/dev/null 2>&1; do :; done
  echo "Goalong History, its permissions, its recorded history, logs, preferences and caches were removed."
  echo "The device identity key in the Keychain is not removed by this script."
else
  echo "Goalong History and its permissions were removed."
  echo "Your recorded history was kept at:"
  echo "  $DATA_DIR"
fi
