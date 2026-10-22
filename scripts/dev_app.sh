#!/bin/bash
# Goalong Dev: the current worktree built as a separate app (ai.goalong.localhistory.dev) that runs
# BESIDE the installed Goalong. The installed Goalong is never quit, launched or modified.
#   dev_app.sh dev | stop | status
# Settings (environment, passed by the Makefile):
#   DATA=clone|keep|fresh   dev data in ~/Library/Application Support/LocalHistory-Dev (default clone)
#   BLOCKING=empty|copy     dev Blocking starts empty, or with a snapshot of the real lists (no lock)
#   SERVER=off|on           Goalong Dev talks to Goalong's servers only with on
#   NO_LAUNCH=1             build, sign and install only: no data step, no quit, no launch (agents)
#   DEV_APP_DIR=DIR         install folder (default ~/Applications)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$ROOT"
MODE="${1:-}"
if [[ $# -ne 1 || ( "$MODE" != dev && "$MODE" != stop && "$MODE" != status ) ]]; then
  echo "Usage: $0 dev|stop|status  (settings: DATA, BLOCKING, SERVER, NO_LAUNCH, DEV_APP_DIR)" >&2; exit 2
fi
DATA="${DATA:-clone}"
BLOCKING="${BLOCKING:-empty}"
SERVER="${SERVER:-off}"
NO_LAUNCH="${NO_LAUNCH:-0}"
if [[ "$DATA" == real || "$DATA" == isolated ]]; then
  echo "DATA=$DATA no longer exists: Goalong Dev runs beside the installed Goalong and never uses its real data." >&2
  echo "Use DATA=clone (default, APFS clone of the real data), DATA=keep or DATA=fresh." >&2
  exit 2
fi
[[ "$DATA" == clone || "$DATA" == keep || "$DATA" == fresh ]] || { echo "DATA must be clone, keep or fresh." >&2; exit 2; }
[[ "$BLOCKING" == empty || "$BLOCKING" == copy ]] || { echo "BLOCKING must be empty or copy." >&2; exit 2; }
[[ "$SERVER" == off || "$SERVER" == on ]] || { echo "SERVER must be off or on." >&2; exit 2; }
[[ "$NO_LAUNCH" == 0 || "$NO_LAUNCH" == 1 ]] || { echo "NO_LAUNCH must be 0 or 1." >&2; exit 2; }
[[ "$(uname -s)" == Darwin ]] || { echo 'Goalong Dev requires macOS.' >&2; exit 1; }

DEV_APP_DIR="${DEV_APP_DIR:-$HOME/Applications}"
[[ "$DEV_APP_DIR" == /* ]] || { echo "DEV_APP_DIR must be absolute." >&2; exit 2; }
DEV_APP="$DEV_APP_DIR/Goalong Dev.app"
DEV_ROOT="$ROOT/.build/goalong-dev"
STAGING="$DEV_ROOT/staging"
CONTROL="$DEV_ROOT/dev-app-control"
REAL_DATA="$HOME/Library/Application Support/LocalHistory"
DEV_DATA="$HOME/Library/Application Support/LocalHistory-Dev"
now() { /usr/bin/perl -MTime::HiRes=time -e 'printf "%.3f", time'; }
STARTED="$(now)"
STEP_STARTED="$STARTED"
step_done() {
  local end; end="$(now)"
  /usr/bin/awk -v name="$1" -v a="$STEP_STARTED" -v b="$end" 'BEGIN { printf "  %-28s %6.1f s\n", name, b - a }'
  STEP_STARTED="$end"
}

# The control tool is rebuilt only when its source changes.
build_control() {
  mkdir -p "$DEV_ROOT"
  if [[ ! -x "$CONTROL" || "$ROOT/scripts/dev_app.swift" -nt "$CONTROL" ]]; then
    xcrun swiftc "$ROOT/scripts/dev_app.swift" -o "$CONTROL"
  fi
}

if [[ "$MODE" == status ]]; then
  build_control
  if [[ -d "$DEV_APP" ]]; then
    plist="$DEV_APP/Contents/Info.plist"
    read_key() { /usr/libexec/PlistBuddy -c "Print :$1" "$plist" 2>/dev/null || echo '?'; }
    echo "Goalong Dev installed: $DEV_APP"
    echo "  branch $(read_key GoalongDevSourceBranch), commit $(read_key GoalongDevSourceCommit), built $(read_key GoalongDevBuiltAt)"
    echo "  data $(read_key GoalongDevDataMode), server $(read_key GoalongDevServer)"
  else
    echo "Goalong Dev is not installed at $DEV_APP"
  fi
  "$CONTROL" status
  exit 0
fi

# Refuse redirected output before creating or removing anything.
mkdir -p "$DEV_APP_DIR"
python3 - "$ROOT" "$DEV_APP_DIR" <<'PY'
from pathlib import Path
import sys
root, app_dir = Path(sys.argv[1]), Path(sys.argv[2])
for path in [root / '.build', root / '.build/goalong-dev', root / '.build/goalong-dev/staging',
             root / '.build/goalong-dev/staging/Goalong Dev.app', app_dir, app_dir / 'Goalong Dev.app']:
    if path.is_symlink() or (path.exists() and path.resolve() != path.absolute()):
        raise SystemExit(f'Refusing redirected Goalong Dev path: {path}')
if app_dir.resolve() in (Path('/Applications'), Path('/System/Applications')):
    raise SystemExit('Goalong Dev never goes into /Applications (Sparkle would replace it).')
PY
mkdir -p "$DEV_ROOT"
if ! mkdir "$DEV_ROOT/lock" 2>/dev/null; then
  echo "Another make dev/dev-stop is running. If interrupted, remove $DEV_ROOT/lock after checking it." >&2
  exit 1
fi
trap 'rmdir "$DEV_ROOT/lock"' EXIT
build_control

if [[ "$MODE" == stop ]]; then
  "$CONTROL" quit-dev
  exit 0
fi

echo "Goalong Dev (data $DATA, blocking $BLOCKING, server $SERVER$([[ "$NO_LAUNCH" == 1 ]] && echo ', no launch'))"
step_done 'checks and control tool'

# Same certificate and entitlements as the release; distinct bundle ID and process name.
source "$ROOT/scripts/source_codesign_identity.sh"
LOCALHISTORY_CODESIGN_IDENTITY="$(localhistory_resolve_source_codesign_identity)"
export LOCALHISTORY_CODESIGN_IDENTITY
if [[ "$LOCALHISTORY_CODESIGN_IDENTITY" == '-' ]]; then
  echo 'make dev requires the release Apple Development identity; ad-hoc signing is refused.' >&2
  exit 1
fi
export LOCALHISTORY_APP_NAME='Goalong Dev'
export LOCALHISTORY_EXECUTABLE_NAME='Goalong History Dev'
export LOCALHISTORY_DISPLAY_NAME='Goalong Dev' LOCALHISTORY_BUNDLE_NAME='Goalong Dev'
export LOCALHISTORY_BUNDLE_ID='ai.goalong.localhistory.dev'
export LOCALHISTORY_DEV_DATA_MODE="$DATA" LOCALHISTORY_DEV_SERVER="$SERVER"
LOCALHISTORY_DEV_SOURCE_BRANCH="$(git -C "$ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
LOCALHISTORY_DEV_SOURCE_COMMIT="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
if [[ -n "$(git -C "$ROOT" status --porcelain --untracked-files=no 2>/dev/null)" ]]; then
  LOCALHISTORY_DEV_SOURCE_COMMIT+='+dirty'
fi
export LOCALHISTORY_DEV_SOURCE_BRANCH LOCALHISTORY_DEV_SOURCE_COMMIT
"$CONTROL" badge-icon "$ROOT/Distribution/AppIcon.png" "$DEV_ROOT/AppIcon-dev.png"
export LOCALHISTORY_DEV_ICON_SOURCE="$DEV_ROOT/AppIcon-dev.png"
export LOCALHISTORY_APP_ENTITLEMENTS="$ROOT/Distribution/GoalongHistory.entitlements"
# Display only (Sparkle is off in Goalong Dev): the banner shows branch and commit.
INSTALLED_PLIST='/Applications/Goalong History.app/Contents/Info.plist'
export LOCALHISTORY_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INSTALLED_PLIST" 2>/dev/null || echo 0.6.0)"
export LOCALHISTORY_BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INSTALLED_PLIST" 2>/dev/null || echo 1)"
export LOCALHISTORY_BUILD_CONFIGURATION=debug LOCALHISTORY_DEVELOPMENT_BUILD=1
export LOCALHISTORY_DISABLE_UPDATES=1 LOCALHISTORY_REQUIRE_SPARKLE_CONFIGURED=0
export LOCALHISTORY_RUN_TESTS=0 LOCALHISTORY_PARALLEL_ARCHS=0
export LOCALHISTORY_ARCHS="$(uname -m)"
export LOCALHISTORY_BUILD_JOBS="${LOCALHISTORY_BUILD_JOBS:-8}"
# One build tree per worktree: the same .build as make test / swift build.
export LOCALHISTORY_SCRATCH_PATH="$ROOT/.build"
export LOCALHISTORY_SCRATCH_ROOT="$DEV_ROOT/swiftpm-meta"
export LOCALHISTORY_RUNTIME_CACHE="$ROOT/.build/goalong-runtime-cache"
export LOCALHISTORY_OUTPUT_DIR="$STAGING"
step_done 'identity and icon'
echo "Incremental debug build ($LOCALHISTORY_ARCHS); log: $DEV_ROOT/build.log"
if ! "$ROOT/scripts/build_app.sh" >"$DEV_ROOT/build.log" 2>&1; then
  tail -n 60 "$DEV_ROOT/build.log" >&2; exit 1
fi
step_done 'build and sign'
if ! "$ROOT/scripts/verify_release_identity.sh" "$STAGING/Goalong Dev.app" dev >"$DEV_ROOT/identity.log" 2>&1; then
  cat "$DEV_ROOT/identity.log" >&2; exit 1
fi
step_done 'verify signature'

if [[ "$NO_LAUNCH" == 1 ]]; then
  # Agents: never quit or replace a running Goalong Dev, never touch any data folder.
  if "$CONTROL" running-at "$DEV_APP"; then
    echo "Goalong Dev is running from $DEV_APP: NO_LAUNCH=1 does not replace it. Use another DEV_APP_DIR." >&2
    exit 1
  fi
else
  "$CONTROL" quit-dev
  step_done 'quit Goalong Dev'
  "$CONTROL" seed-data "$DATA" "$REAL_DATA" "$DEV_DATA"
  if [[ "$BLOCKING" == copy ]]; then "$CONTROL" copy-blocking "$REAL_DATA" "$DEV_DATA"; fi
  step_done "dev data ($DATA)"
fi
rm -rf -- "$DEV_APP"
mv "$STAGING/Goalong Dev.app" "$DEV_APP"
step_done 'install'
if [[ "$NO_LAUNCH" == 1 ]]; then
  echo "Installed (not launched): $DEV_APP"
else
  # open(1) launches through Launch Services, so the menu bar item belongs to Goalong Dev itself.
  /usr/bin/open "$DEV_APP"
  "$CONTROL" wait-running "$DEV_APP"
  step_done 'launch'
  echo "Dev data: $DEV_DATA. The installed Goalong keeps recording and blocking."
fi
/usr/bin/awk -v a="$STARTED" -v b="$(now)" 'BEGIN { printf "make dev: %.1f s\n", b - a }'
