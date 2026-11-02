#!/bin/bash
# Lists, then (only with --delete) removes the test preference files that old bare `swift test` and
# gallery runs left in ~/Library/Preferences: goalong-auto-consent-*.plist, and the UUID-named suites
# goalong-gallery-<UUID>, goalong-gallery-standard-<UUID>, r4d3-<UUID>, goalong-identity-test-<UUID> and
# goalong-permission-tests-<UUID> (T-043 T1 tour 3). Dry run by default: it prints each name and the count.
# --include-other-test-suites also matches the other test suites that leaked, only names of the form
# <test suite prefix>-<UUID>.plist (goalong*, menubar-model, jev-scope, ambiance-module, r4d3).
# Goalong's own preferences (no UUID suffix) and every other app's files are never listed.
# Override the folder with GOALONG_PREFS_DIR (used by the self test).
set -euo pipefail
mode=dry
others=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) mode=dry ;;
    --delete) mode=delete ;;
    --include-other-test-suites) others=1 ;;
    -h|--help) sed -n 2,10p "$0"; exit 0 ;;
    *) echo "usage: $0 [--dry-run|--delete] [--include-other-test-suites]" >&2; exit 2 ;;
  esac
done
dir="${GOALONG_PREFS_DIR:-$HOME/Library/Preferences}"
uuid='[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}'
known="(goalong-gallery-|goalong-gallery-standard-|r4d3-|goalong-identity-test-|goalong-permission-tests-)${uuid}"
if [[ $others == 1 ]]; then
  pattern="^((goalong[A-Za-z0-9._-]*[.-])|menubar-model-|jev-scope-|ambiance-module-|r4d3-)${uuid}\\.plist\$"
else
  pattern="^(goalong-auto-consent-.*|${known})\\.plist\$"
fi
count=0
while IFS= read -r -d '' file; do
  name="$(basename "$file")"
  [[ "$name" =~ $pattern ]] || continue
  count=$((count + 1))
  if [[ "$mode" == delete ]]; then rm -f -- "$file"; else echo "$name"; fi
done < <(find "$dir" -maxdepth 1 -type f -name '*.plist' -print0 2>/dev/null)
if [[ "$mode" == delete ]]; then echo "removed $count leaked test preference file(s) from $dir"
else echo "would remove $count leaked test preference file(s) from $dir (run with --delete to remove them)"; fi
