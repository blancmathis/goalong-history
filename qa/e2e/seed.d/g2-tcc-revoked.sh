#!/bin/bash
# G2 (J-0379): a permission revoked while the app runs. Deletes the Accessibility row of BUNDLE in the RUNNER's system TCC.db
# (same sudo sqlite3 as t046_shard.sh:316-321); unseed replays the saved row. Refuses outside a CI runner (exit 4).
# Exit 3: the permission state is read again at launch.
set -u
[[ -n ${GITHUB_ACTIONS:-}${RUNNER_TEMP:-} ]] || exit 4
DB="/Library/Application Support/com.apple.TCC/TCC.db"; BAK="$DATA/.g2-tcc-bak"; S=kTCCServiceAccessibility
case "${1:-}" in
seed) pkill -KILL -x "Goalong History Dev" 2>/dev/null; sleep 2; defaults write "$BUNDLE" goalong.runtime.sessionOpen.v1 -bool false
  mkdir -p "$BAK"; [[ -e $BAK/row.sql ]] || sudo sqlite3 -cmd ".mode insert access" "$DB" "SELECT * FROM access WHERE client='$BUNDLE' AND service='$S';" > "$BAK/row.sql" 2>/dev/null
  sudo sqlite3 "$DB" "DELETE FROM access WHERE client='$BUNDLE' AND service='$S';" || exit 1
  sudo killall tccd 2>/dev/null; sleep 2; exit 3 ;;
unseed) pkill -KILL -x "Goalong History Dev" 2>/dev/null; sleep 2; defaults write "$BUNDLE" goalong.runtime.sessionOpen.v1 -bool false
  sudo sqlite3 "$DB" "DELETE FROM access WHERE client='$BUNDLE' AND service='$S';"
  [[ -s $BAK/row.sql ]] && sudo sqlite3 "$DB" < "$BAK/row.sql"
  sudo killall tccd 2>/dev/null; sleep 2; rm -rf "$BAK"; exit 3 ;;
*) exit 2 ;;
esac
