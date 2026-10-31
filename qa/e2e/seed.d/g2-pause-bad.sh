#!/bin/bash
# G2 (J-0940): damaged global-pause.json. GoalongGlobalPause.swift:20 (file), :85-87 (damaged file renamed global-pause.damaged-*.json, state read at launch).
# Not JSON on purpose. Exit 3: pause state is read at launch. Unseed also removes the renamed copies.
set -u
stop_app() { pkill -KILL -x "Goalong History Dev" 2>/dev/null; sleep 2; defaults write "$BUNDLE" goalong.runtime.sessionOpen.v1 -bool false; }  # BackgroundContinuityPolicy.swift:62
bak() { mkdir -p "$BAK"; for f in "$@"; do n=$(echo "$f" | tr / _); [[ -e $BAK/$n || -e $BAK/$n.absent ]] && continue; [[ -e $DATA/$f ]] && cp -p "$DATA/$f" "$BAK/$n" || : > "$BAK/$n.absent"; done; }
rest() { for f in "$@"; do n=$(echo "$f" | tr / _); if [[ -e $BAK/$n ]]; then mkdir -p "$DATA/$(dirname "$f")"; cp -p "$BAK/$n" "$DATA/$f"; else rm -f "$DATA/$f"; fi; done; }
BAK="$DATA/.g2-pause-bad-bak"
case "${1:-}" in
seed) stop_app; bak global-pause.json; printf '{ not json t046-g2' > "$DATA/global-pause.json"; chmod 600 "$DATA/global-pause.json"; exit 3 ;;
unseed) stop_app; rm -f "$DATA"/global-pause.damaged-*.json; rest global-pause.json; rm -rf "$BAK"; exit 3 ;;
*) exit 2 ;;
esac
