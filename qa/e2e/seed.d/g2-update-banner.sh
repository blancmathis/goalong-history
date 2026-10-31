#!/bin/bash
# G2 (J-0997): « Goalong a été mis à jour » banner. SoftwareUpdateManager.swift:105-107,236-248 (noteLaunchedVersion: older lastSeenVersion at launch => updatedFromVersion).
# UNVERIFIED: whether noteLaunchedVersion runs in the Dev channel (Sparkle off there). If the banner does not show, this is the cause. Exit 3.
set -u
K="goalong.updates.lastSeenVersion.v1"
case "${1:-}" in
seed) pkill -KILL -x "Goalong History Dev" 2>/dev/null; sleep 2; defaults write "$BUNDLE" goalong.runtime.sessionOpen.v1 -bool false
  defaults write "$BUNDLE" "$K" -string "0.0.1"; exit 3 ;;
unseed) pkill -KILL -x "Goalong History Dev" 2>/dev/null; sleep 2; defaults write "$BUNDLE" goalong.runtime.sessionOpen.v1 -bool false
  defaults delete "$BUNDLE" "$K" 2>/dev/null; exit 3 ;;
*) exit 2 ;;
esac
