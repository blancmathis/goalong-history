#!/bin/bash
# Self test of clean_leaked_test_prefs.sh in a throwaway folder (never the real Preferences).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
dir="$(mktemp -d /tmp/goalong-prefs-selftest-XXXXXX)"
trap 'rm -rf "$dir"' EXIT
u=1B2C3D4E-0000-4000-8000-0123456789AB
touch "$dir/goalong-auto-consent-$u.plist" "$dir/menubar-model-$u.plist" "$dir/goalong.support.tests.$u.plist" \
  "$dir/ai.goalong.localhistory.plist" "$dir/com.apple.finder.plist" "$dir/$u.plist"
out="$(GOALONG_PREFS_DIR="$dir" "$ROOT/scripts/clean_leaked_test_prefs.sh")"
[[ "$out" == "would remove 1 "* ]] || { echo "dry run reported: $out" >&2; exit 1; }
[[ "$(ls "$dir" | wc -l | tr -d ' ')" == 6 ]] || { echo "dry run deleted files" >&2; exit 1; }
out="$(GOALONG_PREFS_DIR="$dir" "$ROOT/scripts/clean_leaked_test_prefs.sh" --include-other-test-suites)"
[[ "$out" == "would remove 3 "* ]] || { echo "wide dry run reported: $out" >&2; exit 1; }
GOALONG_PREFS_DIR="$dir" "$ROOT/scripts/clean_leaked_test_prefs.sh" --delete >/dev/null
left="$(ls "$dir" | sort | tr '\n' ' ')"
[[ "$left" == "$u.plist ai.goalong.localhistory.plist com.apple.finder.plist goalong.support.tests.$u.plist menubar-model-$u.plist " ]] || { echo "unexpected files left: $left" >&2; exit 1; }
echo "clean_leaked_test_prefs self test passed"
