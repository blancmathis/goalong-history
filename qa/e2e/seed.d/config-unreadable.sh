#!/usr/bin/env bash
# seed:config-unreadable (J-0734, J-0735, J-0736): config.json unreadable at launch -> banner « Réinitialiser les réglages… »; after the reset the « Ancien fichier conservé : … » line (id settings-config-backup) shows.
# Env: DATA. Exit 3 = config is read at launch. Throwaway CI runner only. The nav must click « Réinitialiser les réglages… » then « Réinitialiser » (alert) for J-0735/0736: the backup name is in memory only.
set -u
C="$DATA/config.json"; BAK="$DATA/.t046-config.bak"; NONE="$DATA/.t046-config.none"
case "${1:-}" in
  seed)
    # ConfigManager.init (AppPaths.swift:1971-1993): file exists but RecorderConfig.load throws -> config .default, isFailClosed = true (:1990) -> statusNotice (:1998) -> DashboardViewModel.swift:318-319 configNotice/configLocked.
    # Banner GoalongConfigStatusBanner (SettingsPage.swift:412-444): « Réinitialiser les réglages… » only if configLocked (:424), alert :432 -> resetToDefaults (AppPaths.swift:2033, moves the file aside, sets lastDamagedBackupName :2075) -> configBackupName line :437-442.
    if [[ -e "$C" ]]; then cp -p "$C" "$BAK"; else : > "$NONE"; fi
    chflags nouchg "$C" 2>/dev/null
    mkdir -p "$DATA" && printf '{ "t046": not json' > "$C" && chmod 600 "$C"
    exit 3 ;;
  unseed)
    # Drop the damaged copies the reset created (name config.damaged-<date>.json, AppPaths.swift:2062-2072), then restore the previous config.json (or remove ours/the reset default).
    rm -f "$DATA"/config.damaged-*.json
    if [[ -e "$BAK" ]]; then mv -f "$BAK" "$C"; elif [[ -e "$NONE" ]]; then rm -f "$C" "$NONE"; fi
    exit 0 ;;
  *) echo "usage: $0 seed|unseed" >&2; exit 2 ;;
esac
