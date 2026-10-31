#!/bin/bash
# G2 (J-0464): activity export fails. BEST EFFORT: the save panel opens in a read-only folder (NSNavLastRootDirectory),
# so saving there fails (GoalongActivityExport.swift:41-66). The pilot must still confirm the NSSavePanel is driven.
# Touches only DATA/.g2-export-ro and one defaults key of the Dev domain. No restart needed.
set -u
D="$DATA/.g2-export-ro"
case "${1:-}" in
seed) mkdir -p "$D"; chmod 500 "$D"; defaults write "$BUNDLE" NSNavLastRootDirectory -string "$D"; exit 0 ;;
unseed) defaults delete "$BUNDLE" NSNavLastRootDirectory 2>/dev/null; chmod 700 "$D" 2>/dev/null; rm -rf "$D"; exit 0 ;;
*) exit 2 ;;
esac
