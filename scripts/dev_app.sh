#!/bin/bash
# Local debug iteration only. All build/signing writes stay under this worktree's .build.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$ROOT"
MODE="${1:-}"
if [[ $# != 1 || ( "$MODE" != dev && "$MODE" != stop ) ]]; then
  echo "Usage: $0 dev|stop" >&2; exit 2
fi
[[ "$(uname -s)" == Darwin ]] || { echo 'Local iteration requires macOS.' >&2; exit 1; }
INSTALLED_APP='/Applications/Goalong History.app'
DEV_ROOT="$ROOT/.build/dev"
DEV_APP="$DEV_ROOT/Goalong History.app"
STAGING="$DEV_ROOT/staging"
CONTROL="$DEV_ROOT/dev-app-control"
STARTED="$(python3 -c 'import time; print(time.monotonic())')"

# Refuse redirected output before creating/removing anything or quitting an app.
python3 - "$ROOT" "$INSTALLED_APP" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
for relative in ('.build', '.build/dev', '.build/dev/staging',
                 '.build/dev/Goalong History.app', '.build/dev/staging/Goalong History.app'):
    path = root / relative
    if path.is_symlink() or path.resolve() != path:
        raise SystemExit(f'Refusing redirected development output: {path}')
installed = Path(sys.argv[2])
if not installed.is_dir() or installed.is_symlink():
    raise SystemExit(f'Installed app is missing or redirected: {installed}')
PY
mkdir -p "$DEV_ROOT"
if ! mkdir "$DEV_ROOT/lock" 2>/dev/null; then
  echo "Another dev/dev-stop is running. If interrupted, remove $DEV_ROOT/lock after checking it." >&2
  exit 1
fi
trap 'rmdir "$DEV_ROOT/lock"' EXIT

if [[ ! -x "$CONTROL" || "$ROOT/scripts/dev_app.swift" -nt "$CONTROL" ]]; then
  xcrun swiftc "$ROOT/scripts/dev_app.swift" -o "$CONTROL"
fi

if [[ "$MODE" == dev ]]; then
  # Reuse the exact release wrapper, identity resolver, entitlements and signature checks.
  source "$ROOT/scripts/source_codesign_identity.sh"
  LOCALHISTORY_CODESIGN_IDENTITY="$(localhistory_resolve_source_codesign_identity)"
  export LOCALHISTORY_CODESIGN_IDENTITY
  if [[ "$LOCALHISTORY_CODESIGN_IDENTITY" == '-' ]]; then
    echo 'make dev requires the release Apple Development identity; ad-hoc signing is refused.' >&2
    exit 1
  fi
  export LOCALHISTORY_APP_NAME='Goalong History'
  export LOCALHISTORY_EXECUTABLE_NAME='Goalong History'
  export LOCALHISTORY_DISPLAY_NAME='Goalong History'
  export LOCALHISTORY_BUNDLE_ID='ai.goalong.localhistory'
  export LOCALHISTORY_APP_ENTITLEMENTS="$ROOT/Distribution/GoalongHistory.entitlements"
  export LOCALHISTORY_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INSTALLED_APP/Contents/Info.plist")"
  export LOCALHISTORY_BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INSTALLED_APP/Contents/Info.plist")"
  export LOCALHISTORY_BUILD_CONFIGURATION=debug LOCALHISTORY_DEVELOPMENT_BUILD=1
  export LOCALHISTORY_DISABLE_UPDATES=1 LOCALHISTORY_REQUIRE_SPARKLE_CONFIGURED=0
  export LOCALHISTORY_RUN_TESTS=0 LOCALHISTORY_PARALLEL_ARCHS=0
  export LOCALHISTORY_ARCHS="$(uname -m)"
  export LOCALHISTORY_BUILD_JOBS="${LOCALHISTORY_BUILD_JOBS:-8}"
  export LOCALHISTORY_SCRATCH_ROOT="$DEV_ROOT/swiftpm"
  export LOCALHISTORY_RUNTIME_CACHE="$ROOT/.build/goalong-runtime-cache"
  export LOCALHISTORY_OUTPUT_DIR="$STAGING"
  echo "Incremental debug build ($LOCALHISTORY_ARCHS); log: $DEV_ROOT/build.log"
  if ! "$ROOT/scripts/build_app.sh" >"$DEV_ROOT/build.log" 2>&1; then
    cat "$DEV_ROOT/build.log" >&2; exit 1
  fi
  if ! "$ROOT/scripts/verify_release_identity.sh" "$STAGING/Goalong History.app" >"$DEV_ROOT/identity.log" 2>&1; then
    cat "$DEV_ROOT/identity.log" >&2; exit 1
  fi
  INSTALLED_REQUIREMENT="$(codesign -d -r- "$INSTALLED_APP" 2>&1 | sed -n 's/^designated => //p')"
  codesign --verify --strict "-R=$INSTALLED_REQUIREMENT" "$STAGING/Goalong History.app"
  "$CONTROL" quit-all "$DEV_APP" "$INSTALLED_APP"
  # Never replace files beneath a running process. Compilation/signing failures leave it running.
  rm -rf -- "$DEV_APP"
  mv "$STAGING/Goalong History.app" "$DEV_APP"
  "$CONTROL" launch "$DEV_APP" "$INSTALLED_APP"
else
  "$CONTROL" quit-dev "$DEV_APP" "$INSTALLED_APP"
  "$CONTROL" launch "$INSTALLED_APP" "$DEV_APP"
fi
python3 - "$MODE" "$STARTED" <<'PY'
import sys, time
print(f'make dev{ "-stop" if sys.argv[1] == "stop" else "" }: {time.monotonic() - float(sys.argv[2]):.3f} s')
PY
