#!/bin/bash
set -euo pipefail
# The probe orders a real window to the front and activates the app (it checks live motion in it): it is not
# invisible. Never on Mathis's Mac unless asked (GOALONG_TESTS_VISIBLE=1); CI runs it (motion-integration.yml).
if [[ "${GITHUB_ACTIONS:-}" != true && "${GOALONG_TESTS_VISIBLE:-}" != 1 ]]; then
  echo "refused: this probe shows a window and takes the focus. Set GOALONG_TESTS_VISIBLE=1 to watch it, or run it in CI." >&2
  exit 2
fi
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$(mktemp -d "${TMPDIR:-/tmp}/goalong-motion.XXXXXX")"
# Default output is outside the repository: a run must leave the work tree clean (make gallery-accept refuses a dirty one).
OUTPUT="${1:-$BUILD/output}"
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
