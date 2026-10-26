#!/bin/bash
# Auto-test of the file -> filter mapping of `make check` (no swift build, no test run).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2
fail=0
regex_for() { GOALONG_CHECK_DRY_RUN=1 GOALONG_CHECK_CHANGED="$1" ./scripts/run_swift_tests.sh check 2>&1 | sed -n 's/^filter-regex: //p'; }
expect_match() { # changed-files sample-test-id
  local re; re="$(regex_for "$1")"
  if [[ -n "$re" ]] && echo "$2" | grep -Eq "$re"; then echo "ok: '$1' selects $2"
  else echo "FAIL: '$1' (regex '$re') does not select $2" >&2; fail=1; fi
}
# Unmapped change: the fallback must really select Core and App tests.
expect_match "Makefile" "LocalHistoryAppTests.Foo/testBar"
expect_match "scripts/x.sh" "LocalHistoryCoreTests.Foo/testBar"
# A test file whose name differs from its classes runs those classes.
expect_match "Tests/LocalHistoryAppTests/GoalongQualityRegressionTests.swift" "LocalHistoryAppTests.GoalongAnalyticsLoadRequestTests/testX"
# A test file that declares no class of its own (extension only) runs its whole target.
expect_match "Tests/LocalHistoryAppTests/SoftwareUpdateWindowRenderingTests.swift" "LocalHistoryAppTests.Any/testX"
# A Core source change reaches the App and query CLI tests.
expect_match "Sources/LocalHistoryCore/Foo.swift" "LocalHistoryAppTests.Foo/testBar"
expect_match "Sources/LocalHistoryCore/Foo.swift" "LocalHistoryQueryCLITests.Foo/testBar"
expect_match "Package.swift" "LocalHistoryAppTests.Foo/testBar"
# Features and the query CLI reach the targets that import them.
expect_match "Features/Braise/Sources/X.swift" "LocalHistoryAppTests.Foo/testBar"
expect_match "Features/Braise/Sources/X.swift" "LocalHistoryQueryCLITests.Foo/testBar"
expect_match "Features/AgentActivity/Sources/X.swift" "LocalHistoryAppTests.Foo/testBar"
expect_match "Features/AppleScreenTime/Sources/X.swift" "LocalHistoryQueryCLITests.Foo/testBar"
expect_match "Features/AppleSystemScreenTime/Sources/X.swift" "LocalHistoryAppTests.Foo/testBar"
expect_match "Features/Ambiance/Sources/X.swift" "LocalHistoryAppTests.Foo/testBar"
expect_match "Sources/LocalHistoryQueryCLI/X.swift" "LocalHistoryAppTests.Foo/testBar"
expect_match "Sources/LocalHistoryCore/X.swift" "AgentActivityTests.Foo/testBar"
# A class declared with @MainActor stays selected by name, not by its whole target.
expect_match "Tests/LocalHistoryAppTests/GoalongProfileStudioTests.swift" "LocalHistoryAppTests.GoalongProfileStudioTests/testX"
re="$(regex_for "Tests/LocalHistoryAppTests/GoalongProfileStudioTests.swift")"
if echo "LocalHistoryAppTests.Unrelated/testX" | grep -Eq "$re"; then echo "FAIL: @MainActor class widened to its whole target" >&2; fail=1; fi
# classes_in understands attributes and access modifiers.
tmp="$(mktemp -d /tmp/goalong-classes-in-XXXXXX)"
cat > "$tmp/F.swift" <<'SWIFT'
@MainActor final class A: XCTestCase {}
private final class B: XCTestCase {}
fileprivate class C : XCTestCase {}
@available(macOS 13, *) public final class D: XCTestCase {}
    final class E: XCTestCase {}
class NotATest: NSObject {}
SWIFT
got="$(./scripts/run_swift_tests.sh classes-in "$tmp/F.swift" | tr '\n' ' ')"
rm -rf "$tmp"
if [[ "$got" == "A B C D E " ]]; then echo "ok: classes_in finds A B C D E"; else echo "FAIL: classes_in returned '$got'" >&2; fail=1; fi
# make test-ui: skips are never a pass, locked screen or not.
for state in locked unlocked unknown; do
  if ./scripts/run_swift_tests.sh ui-verdict 2 "$state" >/dev/null 2>&1; then echo "FAIL: ui skips on a $state screen exited 0" >&2; fail=1
  else echo "ok: ui skips on a $state screen fail"; fi
done
if ./scripts/run_swift_tests.sh ui-verdict 0 locked >/dev/null 2>&1; then echo "ok: ui with 0 skips passes"; else echo "FAIL: ui with 0 skips failed" >&2; fail=1; fi
# Window guard: one look at this shell finds nothing; one look at the Dock (always on screen, never
# killed: report-only mode) finds a visible window. Proves the guard sees windows without showing one.
guard_bin="$(./scripts/run_swift_tests.sh window-guard-bin)"
if [[ -z "$guard_bin" ]]; then echo "FAIL: scripts/window_guard.swift did not compile" >&2; fail=1
else
  if "$guard_bin" check $$ >/dev/null; then echo "ok: window guard finds no window in a shell"; else echo "FAIL: window guard flagged a shell" >&2; fail=1; fi
  dock="$(pgrep -x Dock | head -1)"
  if [[ -z "$dock" ]]; then echo "skip: no Dock in this session, window guard positive check not run"
  elif [[ "$(WINDOW_GUARD_NO_KILL=1 "$guard_bin" check "$dock")" == *"VIOLATION visible window"* ]]; then echo "ok: window guard sees the Dock's on-screen window"
  else echo "FAIL: window guard missed the Dock's on-screen window" >&2; fail=1; fi
fi
exit "$fail"
