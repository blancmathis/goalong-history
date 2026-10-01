#!/bin/bash
# Full-page native design audit of every destination, in an isolated home.
# Usage: scripts/verify_design_audit.sh [output] (GOALONG_DESIGN_AUDIT_ONLY=page-work,settings to filter)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
OUTPUT="${1:-$ROOT/qa/design-audit}"
mkdir -p "$OUTPUT"
OUTPUT="$(cd "$OUTPUT" && pwd)"
swift build --build-tests -j 4
SAFE_HOME="$(mktemp -d /tmp/goalong-brand-XXXXXX)"
HOME="$SAFE_HOME" CFFIXED_USER_HOME="$SAFE_HOME" LANG=fr_FR.UTF-8 \
GOALONG_BRAND_TEST_HOME="$SAFE_HOME" GOALONG_DESIGN_AUDIT="$OUTPUT" \
swift test --skip-build --filter GoalongDesignAuditRenderingTests 2>&1 | tee "$OUTPUT/native-render.log"
