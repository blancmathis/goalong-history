#!/bin/bash
# Self test of clean_leaked_test_prefs.sh in a throwaway folder (never the real Preferences).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
dir="$(mktemp -d /tmp/goalong-prefs-selftest-XXXXXX)"
trap 'rm -rf "$dir"' EXIT
u=1B2C3D4E-0000-4000-8000-0123456789AB
touch "$dir/goalong-auto-consent-$u.plist" "$dir/menubar-model-$u.plist" "$dir/goalong.support.tests.$u.plist" \
  "$dir/ai.goalong.localhistory.plist" "$dir/com.apple.finder.plist" "$dir/$u.plist"
# T-043 T1 tour 3: the gallery, r4d3, identity and permission suites are listed by name in the default dry run.
leaks="goalong-gallery-$u.plist goalong-gallery-standard-$u.plist r4d3-$u.plist goalong-identity-test-$u.plist goalong-permission-tests-$u.plist"
for f in $leaks; do touch "$dir/$f"; done
touch "$dir/r4d3-not-a-uuid.plist" "$dir/goalong-gallery-standard.plist"
total=13
out="$(GOALONG_PREFS_DIR="$dir" "$ROOT/scripts/clean_leaked_test_prefs.sh")"
[[ "$(tail -n 1 <<<"$out")" == "would remove 6 "* ]] || { echo "dry run reported: $out" >&2; exit 1; }
for f in goalong-auto-consent-$u.plist $leaks; do
  grep -qxF "$f" <<<"$out" || { echo "dry run did not list $f: $out" >&2; exit 1; }
done
[[ "$(ls "$dir" | wc -l | tr -d ' ')" == $total ]] || { echo "dry run deleted files" >&2; exit 1; }
out="$(GOALONG_PREFS_DIR="$dir" "$ROOT/scripts/clean_leaked_test_prefs.sh" --include-other-test-suites)"
[[ "$(tail -n 1 <<<"$out")" == "would remove 8 "* ]] || { echo "wide dry run reported: $out" >&2; exit 1; }
[[ "$(ls "$dir" | wc -l | tr -d ' ')" == $total ]] || { echo "wide dry run deleted files" >&2; exit 1; }
GOALONG_PREFS_DIR="$dir" "$ROOT/scripts/clean_leaked_test_prefs.sh" --delete >/dev/null
left="$(ls "$dir" | sort | tr '\n' ' ')"
[[ "$left" == "$u.plist ai.goalong.localhistory.plist com.apple.finder.plist goalong-gallery-standard.plist goalong.support.tests.$u.plist menubar-model-$u.plist r4d3-not-a-uuid.plist " ]] || { echo "unexpected files left: $left" >&2; exit 1; }
echo "clean_leaked_test_prefs self test passed"
