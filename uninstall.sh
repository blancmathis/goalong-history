#!/bin/bash
set -euo pipefail

APP_NAME="Goalong History"
EXECUTABLE_NAME="Goalong History"
PREVIOUS_APP_NAME="GoLong History"
LEGACY_APP_NAME="LocalHistory"
BUNDLE_ID="ai.goalong.localhistory"
DATA_DIR="$HOME/Library/Application Support/LocalHistory"
LOG_DIR="$HOME/Library/Logs/LocalHistory"
# Goalong Dev (make dev): only --purge-data touches it, since that option also removes LocalHistory-Dev.
DEV_APP_PATH="$HOME/Applications/Goalong Dev.app"
DEV_EXECUTABLE_NAME="Goalong History Dev"
DEV_BUNDLE_ID="$BUNDLE_ID.dev"
DEV_DATA_DIR="$DATA_DIR-Dev"
# The standalone Braise app's folder: Goalong imports its settings once (docs/BRAISE.md). Only --purge-data removes it.
LEGACY_BRAISE_DIR="$HOME/Library/Application Support/Braise"
PURGE_DATA=false
TCC_SERVICES=(Accessibility ListenEvent SystemPolicyAllFiles Calendar Reminders)

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
  local app executable guard_status
  for app in "$@"; do
    executable="$app/Contents/MacOS/$EXECUTABLE_NAME"
    [[ -x "$executable" ]] || continue
    /usr/bin/grep -qaF -- '--unregister-guard' "$executable" 2>/dev/null || continue
    guard_status=0
    "$executable" --unregister-guard >/dev/null 2>&1 || guard_status=$?
    # Exit 4: the guard may still be registered, or this copy has no known guard.
    # The replacement or removal goes on (stopping here would leave a
    # half-done install or a bundle that cannot be removed), but the person is told.
    if [[ "$guard_status" -eq 4 ]]; then
      echo "  ! Goalong n’a pas pu confirmer que le service de protection de $app est supprimé. Si Goalong se rouvre seul, retirez-le dans Réglages Système > Général > Ouverture > Éléments de connexion." >&2
    fi
  done
  /bin/launchctl bootout "gui/$UID/$BUNDLE_ID.blocking-guard" >/dev/null 2>&1 || true
}

# The lock end that refuses this run: Goalong's own block, and Goalong Dev's too when its data is purged.
uninstall_locked_until() { # PURGE_DATA (true|false)
  local latest value
  latest="$(goalong_severe_block_until "$DATA_DIR/Blocking")"
  if [[ "$1" == true ]]; then
    value="$(goalong_severe_block_until "$DEV_DATA_DIR/Blocking")"
    if (( value > latest )); then latest="$value"; fi
  fi
  echo "$latest"
}

# Goalong Dev copies installed outside ~/Applications (make dev DEV_APP_DIR=...): the running one, and
# the ones Spotlight knows by the .dev bundle id. Build products (.build) and swap leftovers are skipped.
goalong_dev_app_candidates() {
  local pid executable
  for pid in $(/usr/bin/pgrep -x "$DEV_EXECUTABLE_NAME" 2>/dev/null); do
    executable="$(/bin/ps -o comm= -p "$pid" 2>/dev/null)" || continue
    [[ "$executable" != */Contents/MacOS/* ]] || echo "${executable%/Contents/MacOS/*}"
  done
  /usr/bin/mdfind "kMDItemCFBundleIdentifier == '$DEV_BUNDLE_ID'" 2>/dev/null || true
}
other_goalong_dev_apps() {
  local app id
  goalong_dev_app_candidates | while IFS= read -r app; do
    [[ "$app" == *.app && "$app" != "$DEV_APP_PATH" && "$app" != */.build/* && "${app##*/}" != .* ]] || continue
    [[ -d "$app" ]] || continue
    id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist" 2>/dev/null)" || continue
    [[ "$id" == "$DEV_BUNDLE_ID" ]] && echo "$app"
  done | /usr/bin/sort -u
}

# --purge-data: Goalong Dev goes first, like the release: its guard (it would reopen Goalong Dev), then the
# app itself (otherwise it recreates LocalHistory-Dev), then its data, preferences, permissions and key.
# A copy installed elsewhere loses its guard and is quit, but stays in place: it is listed in DEV_KEPT_APPS.
# DEV_REMOVED: Goalong Dev was in ~/Applications or had data, so the purge says it removed it.
DEV_KEPT_APPS=()
DEV_REMOVED=false
goalong_dev_purge_summary() {
  local app
  if [[ "$DEV_REMOVED" == true ]]; then
    echo "Goalong Dev ($DEV_APP_PATH), ses données, ses préférences, ses autorisations et sa clé de preuve ont aussi été supprimés."
  fi
  if (( ${#DEV_KEPT_APPS[@]} > 0 )); then
    echo "Goalong Dev installé ailleurs a été conservé (quitté, service de protection retiré, données effacées). Supprimez-le à la main si besoin :"
    for app in "${DEV_KEPT_APPS[@]}"; do echo "  $app"; done
  fi
}
purge_goalong_dev() {
  local app
  DEV_KEPT_APPS=()
  DEV_REMOVED=false
  if [[ -e "$DEV_APP_PATH" || -L "$DEV_APP_PATH" || -e "$DEV_DATA_DIR" || -L "$DEV_DATA_DIR" ]]; then DEV_REMOVED=true; fi
  while IFS= read -r app; do [[ -z "$app" ]] || DEV_KEPT_APPS+=("$app"); done < <(other_goalong_dev_apps)
  ( EXECUTABLE_NAME="$DEV_EXECUTABLE_NAME" BUNDLE_ID="$DEV_BUNDLE_ID"
    release_blocking_guard "$DEV_APP_PATH" ${DEV_KEPT_APPS[@]+"${DEV_KEPT_APPS[@]}"} )
  quit_running_goalong "$DEV_EXECUTABLE_NAME"
  rm -rf "$DEV_APP_PATH" "$DEV_DATA_DIR" "$HOME/Library/Caches/$DEV_BUNDLE_ID"
  defaults delete "$DEV_BUNDLE_ID" >/dev/null 2>&1 || true
  local service
  for service in "${TCC_SERVICES[@]}"; do tccutil reset "$service" "$DEV_BUNDLE_ID" >/dev/null 2>&1 || true; done
  while security delete-generic-password -s "goalong.evidence.v1.dev" >/dev/null 2>&1; do :; done
}

# rm -rf removes a symlink itself, never its target.
remove_legacy_braise_data() {
  rm -rf "$LEGACY_BRAISE_DIR"
}

[[ "${BASH_SOURCE[0]}" == "$0" ]] || return 0

case "${1:-}" in
  "") ;;
  --purge-data) PURGE_DATA=true ;;
  -h|--help)
    echo "Usage : ./uninstall.sh [--purge-data]"
    exit 0
    ;;
  *)
    echo "Option inconnue : ${1:-}" >&2
    exit 2
    ;;
esac

# A locked block (Goalong › Blocage) is a commitment: refuse before any effect, until its end.
if [[ "${GOALONG_UNINSTALL_DURING_LOCK:-}" != 1 ]]; then
  locked_until="$(uninstall_locked_until "$PURGE_DATA")"
  if (( locked_until > 0 )); then
    echo "Un blocage verrouillé est actif jusqu’au $(date -r "$locked_until" '+%Y-%m-%d %H:%M')." >&2
    echo "Goalong History n’a pas été supprimé. Relancez ce script après cette heure." >&2
    if [[ "$PURGE_DATA" == true ]] && (( $(goalong_severe_block_until "$DATA_DIR/Blocking") == 0 )); then
      echo "Le verrou appartient à Goalong Dev (--purge-data le supprime aussi). Sans --purge-data, Goalong Dev est conservé." >&2
    fi
    echo "Pour le supprimer quand même : GOALONG_UNINSTALL_DURING_LOCK=1 ./uninstall.sh" >&2
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
  echo "Une ancienne version de Goalong n’a pas pu retirer ses crochets d’agents. S’ils restent, supprimez les entrées Goalong dans :" >&2
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

for service in "${TCC_SERVICES[@]}"; do tccutil reset "$service" "$BUNDLE_ID" >/dev/null 2>&1 || true; done

if [[ "$PURGE_DATA" == true ]]; then
  purge_goalong_dev
  rm -rf "$DATA_DIR"
  remove_legacy_braise_data
  rm -rf "$HOME/Library/Caches/$BUNDLE_ID"
  defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
  while security delete-generic-password -s "goalong.evidence.v1" >/dev/null 2>&1; do :; done
  echo "Goalong History, ses autorisations, son historique enregistré, ses journaux, ses préférences, ses caches et les anciens réglages Braise ont été supprimés."
  goalong_dev_purge_summary
  echo "La clé d’identité de l’appareil dans le Trousseau n’est pas supprimée par ce script."
else
  echo "Goalong History et ses autorisations ont été supprimés."
  echo "Votre historique enregistré a été conservé ici :"
  echo "  $DATA_DIR"
fi
