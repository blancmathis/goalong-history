#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT="${1:-$ROOT/qa/brand-motion}"
BUILD="$(mktemp -d "${TMPDIR:-/tmp}/goalong-motion.XXXXXX")"
trap 'rm -rf "$BUILD"' EXIT
mkdir -p "$OUTPUT"
xcrun swiftc -parse-as-library -swift-version 5 \
  "$ROOT/Sources/LocalHistoryApp/GoalongTheme.swift" \
  "$ROOT/Sources/LocalHistoryApp/GoalongMotionModel.swift" \
  "$ROOT/Sources/LocalHistoryApp/GoalongMotionView.swift" \
  "$ROOT/scripts/GoalongMotionProbe.swift" \
  -framework AppKit -framework SwiftUI -o "$BUILD/GoalongMotionProbe"
# Window guard: a visible window or a focus change kills the probe and fails the run.
if [[ "$(printenv GOALONG_TESTS_VISIBLE)" == 1 ]]; then
  "$BUILD/GoalongMotionProbe" "$OUTPUT"
  exit $?
fi
GUARD="$("$ROOT/scripts/run_swift_tests.sh" window-guard-bin)"
"$BUILD/GoalongMotionProbe" "$OUTPUT" & pid=$!
"$GUARD" watch "$pid" & gpid=$!
status=0; wait "$pid" || status=$?
if ! wait "$gpid"; then
  echo "error: the probe showed a window or took the focus (window guard)" >&2
  [[ $status -eq 0 ]] && status=1
fi
exit "$status"
