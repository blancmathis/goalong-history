#!/bin/bash
# G2 (J-0658): « événements récents » in Diagnostics d'accès. Rewrites TODAY's events file with 720 events up to 12 h before now
# (seed_events.py --days 0 --today, same generator as the shard). Unseed puts the old file back. Exit 3: journal read at launch.
set -u
stop_app() { pkill -KILL -x "Goalong History Dev" 2>/dev/null; sleep 2; defaults write "$BUNDLE" goalong.runtime.sessionOpen.v1 -bool false; }  # BackgroundContinuityPolicy.swift:62
bak() { mkdir -p "$BAK"; for f in "$@"; do n=$(echo "$f" | tr / _); [[ -e $BAK/$n || -e $BAK/$n.absent ]] && continue; [[ -e $DATA/$f ]] && cp -p "$DATA/$f" "$BAK/$n" || : > "$BAK/$n.absent"; done; }
rest() { for f in "$@"; do n=$(echo "$f" | tr / _); if [[ -e $BAK/$n ]]; then mkdir -p "$DATA/$(dirname "$f")"; cp -p "$BAK/$n" "$DATA/$f"; else rm -f "$DATA/$f"; fi; done; }
BAK="$DATA/.g2-recent-events-bak"; T="events/$(date +%F).jsonl"
case "${1:-}" in
seed) stop_app; bak "$T"; python3 -I "$(dirname "$0")/../seed_events.py" "$DATA" --days 0 --per-day 720 --today >/dev/null || exit 1; exit 3 ;;
unseed) stop_app; rest "$T"; rm -rf "$BAK"; exit 3 ;;
*) exit 2 ;;
esac
