#!/bin/bash
# G2 (J-0734): unreadable config.json. Written as non-JSON; the app reads it at launch and shows its fallback notice. Exit 3.
set -u
stop_app() { pkill -KILL -x "Goalong History Dev" 2>/dev/null; sleep 2; defaults write "$BUNDLE" goalong.runtime.sessionOpen.v1 -bool false; }  # BackgroundContinuityPolicy.swift:62 (no « arrêt non propre » banner)
# bak FILE...: copy each file (or marker .absent) into $BAK once; rest FILE...: put it back.
bak() { mkdir -p "$BAK"; for f in "$@"; do n=$(echo "$f" | tr / _); [[ -e $BAK/$n || -e $BAK/$n.absent ]] && continue; [[ -e $DATA/$f ]] && { mkdir -p "$BAK/$(dirname "$n")"; cp -p "$DATA/$f" "$BAK/$n"; } || : > "$BAK/$n.absent"; done; }
rest() { for f in "$@"; do n=$(echo "$f" | tr / _); if [[ -e $BAK/$n ]]; then mkdir -p "$DATA/$(dirname "$f")"; cp -p "$BAK/$n" "$DATA/$f"; else rm -f "$DATA/$f"; fi; done; }
BAK="$DATA/.g2-config-bad-bak"
case "${1:-}" in
seed) stop_app; bak config.json; printf '{ not json t046-g2' > "$DATA/config.json"; chmod 600 "$DATA/config.json"; exit 3 ;;
unseed) stop_app; rest config.json; rm -rf "$BAK"; exit 3 ;;
*) exit 2 ;;
esac
