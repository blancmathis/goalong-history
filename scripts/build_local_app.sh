#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Compatibility entry point: it deliberately builds the same single public app.
export LOCALHISTORY_APP_NAME="Goalong History"
export LOCALHISTORY_EXECUTABLE_NAME="Goalong History"
export LOCALHISTORY_BUNDLE_ID="ai.goalong.localhistory"
export LOCALHISTORY_DISPLAY_NAME="Goalong History"

# shellcheck source=preserve_package_resolved.sh
source "$ROOT_DIR/scripts/preserve_package_resolved.sh"
goalong_preserve_package_resolved "$ROOT_DIR"

"$ROOT_DIR/scripts/build_app.sh" "$@"
