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
scripts_for() { GOALONG_CHECK_DRY_RUN=1 GOALONG_CHECK_CHANGED="$1" ./scripts/run_swift_tests.sh check 2>&1 | sed -n 's/^script-checks: //p'; }
expect_scripts() { # changed-files expected-script-checks (and no Swift filter)
  local got re; got="$(scripts_for "$1")"; re="$(regex_for "$1")"
  if [[ "$got" == "$2" && -z "$re" ]]; then echo "ok: '$1' runs $2 only"
  else echo "FAIL: '$1' runs scripts '$got', Swift filter '$re' (want '$2' only)" >&2; fail=1; fi
}
# Unmapped change: the fallback must really select Core and App tests.
expect_match "Sources/GoalongMenuBarHelper/X.swift" "LocalHistoryAppTests.Foo/testBar"
expect_match "Sources/GoalongMenuBarHelper/X.swift" "LocalHistoryCoreTests.Foo/testBar"
# A script runs its own shell tests, not the Swift suite; no test of its own: a syntax check.
expect_scripts "scripts/local_try.sh" "scripts/test_local_try.sh"
expect_scripts "scripts/install_from_source.sh" "scripts/test_install_from_source_safety.sh"
expect_scripts "scripts/window_guard.swift" "scripts/test_run_swift_tests.sh"
expect_scripts "scripts/test_dev_app.sh" "scripts/test_dev_app.sh"
expect_scripts "scripts/audit_privacy_boundaries.sh" "syntax:scripts/audit_privacy_boundaries.sh"
expect_scripts "scripts/build_app_core.sh" "syntax:scripts/build_app_core.sh scripts/test_build_number_policy.sh"
# Time budgets: left out when only picked by type (a changed source), run when their test file changes.
budget_for() { GOALONG_CHECK_DRY_RUN=1 GOALONG_CHECK_CHANGED="$1" ./scripts/run_swift_tests.sh check 2>&1 | sed -n 's/^budget-skips: //p'; }
for pair in "Sources/LocalHistoryApp/Concentration/ConcentrationController.swift:ViewSwitchBudgetTests" \
            "Tests/LocalHistoryAppTests/ViewSwitchBudgetTests.swift:"; do
  got="$(budget_for "${pair%%:*}")"
  if [[ "$got" == "${pair#*:}" ]]; then echo "ok: '${pair%%:*}' leaves out budgets '$got'"
  else echo "FAIL: '${pair%%:*}' leaves out budgets '$got' (want '${pair#*:}')" >&2; fail=1; fi
done
expect_scripts "Makefile" "make:Makefile"
expect_scripts "scripts/expected_skips.txt scripts/local_try.sh" "scripts/test_local_try.sh"
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
# C1: an app source runs the test classes that name its types, plus the smoke set; not the whole target.
expect_match "Sources/LocalHistoryApp/MenuBar/MenuBarPanelPresenter.swift" "LocalHistoryAppTests.MenuBarPanelHeightTweenTests/testX"
expect_match "Sources/LocalHistoryApp/MenuBar/MenuBarPanelPresenter.swift" "LocalHistoryAppTests.GallerySmokeTests/testX"
expect_match "Sources/LocalHistoryApp/MenuBar/MenuBarPanelPresenter.swift" "LocalHistoryAppTests.BlockingGuardTests/testX"
re="$(regex_for "Sources/LocalHistoryApp/MenuBar/MenuBarPanelPresenter.swift")"
if echo "LocalHistoryAppTests.GoalongProfileStudioTests/testX" | grep -Eq "$re"; then echo "FAIL: app source widened to its whole target" >&2; fail=1; else echo "ok: app source keeps unrelated classes out"; fi
# Deleted app file: whole App target. Docs only: smoke set only.
expect_match "Sources/LocalHistoryApp/NoSuchFileForTest.swift" "LocalHistoryAppTests.Anything/testX"
expect_match "README.md" "LocalHistoryAppTests.GallerySmokeTests/testX"
re="$(regex_for "README.md")"
if echo "LocalHistoryCoreTests.Foo/testX" | grep -Eq "$re"; then echo "FAIL: docs change runs Core tests" >&2; fail=1; else echo "ok: docs change runs the smoke set only"; fi
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
