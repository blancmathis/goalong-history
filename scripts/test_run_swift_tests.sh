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
exit "$fail"
