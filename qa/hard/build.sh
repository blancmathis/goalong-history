#!/bin/bash
# T-046 hard cases: release-identity app (ai.goalong.localhistory) built from this checkout with the
# macos.yml recipe, ad-hoc signed, then the .dmg. Version above 0.6.163 so the update case is an upgrade.
# Usage: qa/hard/build.sh DIST_DIR
set -euo pipefail
DIST="$1"; mkdir -p "$DIST"
export LOCALHISTORY_VERSION=0.6.165 LOCALHISTORY_BUILD_NUMBER="30000000.9999999.${GITHUB_RUN_NUMBER:-1}"
export LOCALHISTORY_APP_ENTITLEMENTS=Distribution/GoalongHistory.entitlements LOCALHISTORY_RUN_TESTS=0
LOCALHISTORY_ARCHS="$(uname -m)"
export LOCALHISTORY_ARCHS LOCALHISTORY_OUTPUT_DIR="$DIST" LOCALHISTORY_BUILD_JOBS=4
./scripts/build_app.sh > "$DIST/build.log" 2>&1 || { tail -n 80 "$DIST/build.log"; exit 1; }
LOCALHISTORY_APP_PATH="$DIST/Goalong History.app" LOCALHISTORY_PACKAGE_STANDARD_DMG=1 ./scripts/package_release.sh >> "$DIST/build.log" 2>&1 \
  || { tail -n 40 "$DIST/build.log"; exit 1; }
codesign -dv "$DIST/Goalong History.app" 2>&1 | head -4
ls -la "$DIST"
