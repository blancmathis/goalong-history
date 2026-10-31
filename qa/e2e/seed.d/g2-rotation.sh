#!/bin/bash
# G2 (J-0653): « La clé de cet appareil a changé » notice. DeviceIdentity.swift:125-151 (load: "epoch|prevTier|newTier"), :236 (acknowledgeRotation removes the key).
# Exit 3: the notice is read at launch / on change notification.
set -u
K="goalong.deviceIdentity.rotation.v1"
case "${1:-}" in
seed) pkill -KILL -x "Goalong History Dev" 2>/dev/null; sleep 2; defaults write "$BUNDLE" goalong.runtime.sessionOpen.v1 -bool false
  defaults write "$BUNDLE" "$K" -string "$(date +%s)|keychain_software|local_software"; exit 3 ;;
unseed) pkill -KILL -x "Goalong History Dev" 2>/dev/null; sleep 2; defaults write "$BUNDLE" goalong.runtime.sessionOpen.v1 -bool false
  defaults delete "$BUNDLE" "$K" 2>/dev/null; exit 3 ;;
*) exit 2 ;;
esac
