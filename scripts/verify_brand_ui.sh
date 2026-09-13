#!/bin/bash
# Builds and renders actual native views, without starting the production app.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
OUTPUT="${1:-$ROOT/qa/brand-alignment}"
mkdir -p "$OUTPUT"
OUTPUT="$(cd "$OUTPUT" && pwd)"
swift build --build-tests -j 4
SAFE_HOME="$(mktemp -d /tmp/goalong-brand-XXXXXX)"
printf '%s\n' "$SAFE_HOME" > "$OUTPUT/isolated-home.txt"
# The test independently checks Foundation's resolved paths before creating stores.
HOME="$SAFE_HOME" CFFIXED_USER_HOME="$SAFE_HOME" \
GOALONG_BRAND_TEST_HOME="$SAFE_HOME" GOALONG_BRAND_SNAPSHOTS="$OUTPUT" \
swift test --skip-build --filter GoalongBrandRenderingTests 2>&1 | tee "$OUTPUT/native-render.log"
