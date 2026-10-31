#!/bin/bash
# G2 (J-0991): « arrêt non propre » notice. BackgroundContinuityPolicy.swift:61-90 (runningKey still true at launch = last exit unclean),
# PrivacyPage.swift:528-534 (Dernière session). Kill -9 here, leave the flag true, restart.
set -u
case "${1:-}" in
seed) pkill -KILL -x "Goalong History Dev" 2>/dev/null; sleep 2; defaults write "$BUNDLE" goalong.runtime.sessionOpen.v1 -bool true; exit 3 ;;
unseed) pkill -KILL -x "Goalong History Dev" 2>/dev/null; sleep 2; defaults write "$BUNDLE" goalong.runtime.sessionOpen.v1 -bool false; exit 3 ;;
*) exit 2 ;;
esac
