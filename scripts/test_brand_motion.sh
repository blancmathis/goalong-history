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
"$BUILD/GoalongMotionProbe" "$OUTPUT"
