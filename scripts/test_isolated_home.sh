#!/bin/bash
# Runs the tests that write real config files inside a throwaway HOME.
# They skip themselves under the real HOME, so a normal `swift test` never runs them.
# Fails when any of them is skipped, so a silent skip cannot ship green.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
SAFE_HOME="$(mktemp -d /tmp/goalong-isolated-XXXXXX)"
LOG="$(mktemp)"
trap 'rm -rf "$SAFE_HOME" "$LOG"' EXIT
set +e
HOME="$SAFE_HOME" CFFIXED_USER_HOME="$SAFE_HOME" \
  xcrun swift test --disable-keychain "$@" --filter 'GoalongRecordingDefaultsTests|GoalongUXOptimizationTests' 2>&1 | tee "$LOG"
STATUS=${PIPESTATUS[0]}
set -e
[[ $STATUS -eq 0 ]] || exit "$STATUS"
if grep -Eq "skipped|XCTSkip" "$LOG"; then
  echo "error: isolated-home tests were skipped" >&2
  exit 1
fi
