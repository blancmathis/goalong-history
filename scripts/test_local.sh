#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
# Compatibility entry point: there is only one package graph and one public app.
# A bare `swift test` skips the runner's throwaway HOME and window guard (a window on screen, a slower and
# different run: T-044 C9-02), so this goes through the same runner as `make test`.
exec "$ROOT_DIR/scripts/run_swift_tests.sh" full "$@"
