#!/bin/bash
# Self test of skip_report.py on a fixture log (no swift, no build).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
dir="$(mktemp -d /tmp/goalong-skip-selftest-XXXXXX)"
trap 'rm -rf "$dir"' EXIT
printf '%s\n' "# fixture" "Mod.Known/testOptIn  # opt-in" "Mod.Wild/*" > "$dir/allow.txt"
log="$dir/ok.log"
cat > "$log" <<'LOG'
/x/A.swift:1: -[Mod.Known testOptIn] : Test skipped - Set GOALONG_SOMETHING to run it.
Test Case '-[Mod.Known testOptIn]' skipped (0.001 seconds).
Test Case '-[Mod.Wild testAnything]' skipped (0.001 seconds).
	 Executed 3 tests, with 2 tests skipped and 0 failures (0 unexpected) in 0.1 (0.1) seconds
LOG
out="$(python3 "$ROOT/scripts/skip_report.py" "$log" --allowlist "$dir/allow.txt")"
[[ "$out" == *"2 skipped of 3 executed"* && "$out" == *"GOALONG_SOMETHING"* ]] || { echo "bad report: $out" >&2; exit 1; }
cp "$log" "$dir/bad.log"
sed -i.bak 's/^\t Executed.*$/Test Case '"'"'-[Mod.Rogue testNew]'"'"' skipped (0.001 seconds).\n\t Executed 4 tests, with 3 tests skipped and 0 failures (0 unexpected) in 0.1 (0.1) seconds/' "$dir/bad.log"
if python3 "$ROOT/scripts/skip_report.py" "$dir/bad.log" --allowlist "$dir/allow.txt" >"$dir/bad.out"; then
  echo "an unknown skip did not fail" >&2; exit 1
fi
grep -q "Mod.Rogue/testNew" "$dir/bad.out" || { echo "unknown skip not named" >&2; exit 1; }
python3 "$ROOT/scripts/skip_report.py" "$dir/bad.log" --allowlist "$dir/allow.txt" --report-only >/dev/null
# XCTest prints no "tests skipped" part when nothing was skipped: that run is valid and green.
cat > "$dir/noskip.log" <<'LOG'
	 Executed 5 tests, with 0 failures (0 unexpected) in 0.1 (0.1) seconds
LOG
out="$(python3 "$ROOT/scripts/skip_report.py" "$dir/noskip.log" --allowlist "$dir/allow.txt")" || { echo "zero-skip summary rejected" >&2; exit 1; }
[[ "$out" == *"0 skipped of 5 executed"* ]] || { echo "bad zero-skip report: $out" >&2; exit 1; }
printf '\t Executed 1 test, with 1 failure (0 unexpected) in 0.1 (0.1) seconds\n' > "$dir/one.log"
python3 "$ROOT/scripts/skip_report.py" "$dir/one.log" --allowlist "$dir/allow.txt" | grep -q "0 skipped of 1 executed (1 failures)" || { echo "singular summary not parsed" >&2; exit 1; }
echo "incomplete run" > "$dir/short.log"
if python3 "$ROOT/scripts/skip_report.py" "$dir/short.log" --allowlist "$dir/allow.txt" 2>/dev/null; then
  echo "a log without a summary was accepted" >&2; exit 1
fi
# the committed allowlist must parse and name only Module.Class/test entries
grep -vE '^\s*(#|$)' "$ROOT/scripts/expected_skips.txt" | awk '{print $1}' | grep -vqE '^[A-Za-z0-9_]+\.[A-Za-z0-9_]+/[A-Za-z0-9_*]+$' && { echo "malformed allowlist entry" >&2; exit 1; }
echo "skip_report self test passed"
