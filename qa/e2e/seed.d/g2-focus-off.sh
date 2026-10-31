#!/bin/bash
# G2 (J-0382): menu-bar panel « Activez Concentration dans Réglages. » + fix button (focus-fix).
# MenuBarPanelModel.swift:270-276 (focusUnavailableFix = .modules when the module is off), MenuBarPanelView.swift:336. Module key: GoalongModules.swift:13. Exit 3: modules load at launch.
set -u
K="goalong.module.concentration.enabled"; BAK="$DATA/.g2-focus-off-bak"
case "${1:-}" in
seed) pkill -KILL -x "Goalong History Dev" 2>/dev/null; sleep 2; defaults write "$BUNDLE" goalong.runtime.sessionOpen.v1 -bool false
  mkdir -p "$BAK"; [[ -e $BAK/v ]] || { defaults read "$BUNDLE" "$K" > "$BAK/v" 2>/dev/null || echo none > "$BAK/v"; }
  defaults write "$BUNDLE" "$K" -bool false; exit 3 ;;
unseed) pkill -KILL -x "Goalong History Dev" 2>/dev/null; sleep 2; defaults write "$BUNDLE" goalong.runtime.sessionOpen.v1 -bool false
  v=$(cat "$BAK/v" 2>/dev/null); if [[ $v == none || -z $v ]]; then defaults delete "$BUNDLE" "$K" 2>/dev/null; else defaults write "$BUNDLE" "$K" -bool "$([[ $v == 1 ]] && echo true || echo false)"; fi
  rm -rf "$BAK"; exit 3 ;;
*) exit 2 ;;
esac
