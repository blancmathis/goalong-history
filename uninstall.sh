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

# Spec K: the latest future end among the lock markers of a Blocking folder (locked-until and the
# blocking guard's guard-until), or 0. Only regular files are read; a link is ignored.
goalong_marker_until() { # MARKER_FILE: its end when it is a regular file in the future, else 0
  local value
  [[ -f "$1" && ! -L "$1" ]] || { echo 0; return; }
  value="$(/usr/bin/head -c 12 "$1" | /usr/bin/tr -cd '0-9')"
  if [[ -n "$value" ]] && (( value > $(/bin/date +%s) )); then echo "$value"; else echo 0; fi
}
goalong_severe_block_until() { # BLOCKING_DIR
  local marker value latest=0
  for marker in "$1/locked-until" "$1/guard-until"; do
    value="$(goalong_marker_until "$marker")"
    if (( value > latest )); then latest="$value"; fi
  done
  echo "$latest"
}

# Spec K: stop the blocking guard agent and remove its registration, so it cannot reopen Goalong
# during a replacement or a removal. Only builds that know --unregister-guard are run (an older
# build would start the full app); the app itself refuses (exit 3) during a severe block unless
# GOALONG_UNINSTALL_DURING_LOCK=1 or GOALONG_INSTALL_DURING_LOCK=1.
# --unregister-guard runs first: with the override it leaves guard-override, so the running app neither
# registers the guard again when its connection drops nor ignores the SIGTERM that follows.
release_blocking_guard() { # APP_PATH...
  local app executable
  for app in "$@"; do
    executable="$app/Contents/MacOS/$EXECUTABLE_NAME"
    [[ -x "$executable" ]] || continue
    /usr/bin/grep -qaF -- '--unregister-guard' "$executable" 2>/dev/null || continue
    "$executable" --unregister-guard >/dev/null 2>&1 || true
  done
  /bin/launchctl bootout "gui/$UID/$BUNDLE_ID.blocking-guard" >/dev/null 2>&1 || true
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
if [[ "${GOALONG_UNINSTALL_DURING_LOCK:-}" != 1 ]]; then
  locked_until="$(goalong_severe_block_until "$DATA_DIR/Blocking")"
  if (( locked_until > 0 )); then
    echo "A locked block is active until $(date -r "$locked_until" '+%Y-%m-%d %H:%M')." >&2
    echo "Goalong History was not removed. Run this again after that time." >&2
    echo "To remove it anyway: GOALONG_UNINSTALL_DURING_LOCK=1 ./uninstall.sh" >&2
    exit 3
  fi
fi
# The guard goes first: otherwise it would reopen Goalong while it is quit and removed.
release_blocking_guard "/Applications/$APP_NAME.app" "$HOME/Applications/$APP_NAME.app"

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
