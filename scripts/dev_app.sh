#!/bin/bash
# Goalong Dev: the current worktree built as a separate app (ai.goalong.localhistory.dev) that runs
# BESIDE the installed Goalong. The installed Goalong is never quit, launched or modified.
#   dev_app.sh dev | stop | status
# Settings (environment). The Makefile maps make's command-line DATA=… to GOALONG_DEV_DATA=… and so on,
# so a shell-wide DATA, SERVER or NO_LAUNCH never leaks in:
#   GOALONG_DEV_DATA=clone|keep|fresh   dev data in ~/Library/Application Support/LocalHistory-Dev (default clone)
#   GOALONG_DEV_BLOCKING=empty|copy     dev Blocking starts empty, or with a snapshot of the real lists (no lock)
#   GOALONG_DEV_SERVER=off|on           Goalong Dev talks to Goalong's servers only with on
#   GOALONG_DEV_NO_LAUNCH=1             build, sign and install only: no data step, no quit, no launch (agents)
#   GOALONG_DEV_APP_DIR=DIR             install folder (default ~/Applications)
#   GOALONG_DEV_VALIDATE_ONLY=1         stop after the settings checks (scripts/test_dev_app.sh)
#   GOALONG_DEV_RELEASE_APP=APP         installed release to compare with (default /Applications/Goalong History.app)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$ROOT"
MODE="${1:-}"
if [[ $# -ne 1 || ( "$MODE" != dev && "$MODE" != stop && "$MODE" != status ) ]]; then
  echo "Usage: $0 dev|stop|status  (make dev settings: DATA, BLOCKING, SERVER, NO_LAUNCH, DEV_APP_DIR)" >&2; exit 2
fi
refuse() { echo "$1" >&2; exit 2; }
[[ "$(uname -s)" == Darwin ]] || { echo 'Goalong Dev requires macOS.' >&2; exit 1; }
DEV_APP_DIR="${GOALONG_DEV_APP_DIR:-$HOME/Applications}"
DEV_APP="$DEV_APP_DIR/Goalong Dev.app"
DEV_ROOT="$ROOT/.build/goalong-dev"
STAGING="$DEV_ROOT/staging"
CONTROL="$DEV_ROOT/dev-app-control"
REAL_DATA="$HOME/Library/Application Support/LocalHistory"
DEV_DATA="$HOME/Library/Application Support/LocalHistory-Dev"
RELEASE_APP="${GOALONG_DEV_RELEASE_APP:-/Applications/Goalong History.app}"
# The install folder and LocalHistory-Dev are global: one install/data/quit step at a time across
# every worktree. The per-worktree lock below only protects this worktree's .build.
GLOBAL_LOCK="$HOME/Library/Caches/goalong-dev-install.flock"

# Releases built before Goalong Dev do not know ai.goalong.localhistory.dev: they record Goalong Dev's
# windows and text, and an allow-only block list blocks it. Read-only check of the installed binary.
warn_old_release() {
  local binary executable='Goalong History'
  if [[ -f "$RELEASE_APP/Contents/Info.plist" ]]; then
    executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$RELEASE_APP/Contents/Info.plist" 2>/dev/null || echo "$executable")"
  fi
  binary="$RELEASE_APP/Contents/MacOS/$executable"
  [[ -f "$binary" ]] || return 0
  if ! LC_ALL=C grep -aqF 'ai.goalong.localhistory.dev' "$binary"; then
    echo "WARNING: the installed Goalong predates Goalong Dev. It records Goalong Dev's windows and text in the real" >&2
    echo "         LocalHistory, and an allow-only block list blocks Goalong Dev. A release with the Goalong family rules fixes it." >&2
  fi
}

# Settings only matter for make dev: stop and status ignore them.
if [[ "$MODE" == dev ]]; then
  DATA_GIVEN="${GOALONG_DEV_DATA:-}" BLOCKING_GIVEN="${GOALONG_DEV_BLOCKING:-}"
  DATA="${DATA_GIVEN:-clone}"
  BLOCKING="${BLOCKING_GIVEN:-empty}"
  SERVER="${GOALONG_DEV_SERVER:-off}"
  NO_LAUNCH="${GOALONG_DEV_NO_LAUNCH:-0}"
  if [[ "$DATA" == real || "$DATA" == isolated ]]; then
    refuse "DATA=$DATA no longer exists: Goalong Dev runs beside the installed Goalong and never uses its real data.
Use DATA=clone (default, APFS clone of the real data), DATA=keep or DATA=fresh."
  fi
  [[ "$DATA" == clone || "$DATA" == keep || "$DATA" == fresh ]] || refuse 'DATA must be clone, keep or fresh.'
  [[ "$BLOCKING" == empty || "$BLOCKING" == copy ]] || refuse 'BLOCKING must be empty or copy.'
  [[ "$SERVER" == off || "$SERVER" == on ]] || refuse 'SERVER must be off or on.'
  [[ "$NO_LAUNCH" == 0 || "$NO_LAUNCH" == 1 ]] || refuse 'NO_LAUNCH must be 0 or 1.'
  if [[ "$NO_LAUNCH" == 1 && ( -n "$DATA_GIVEN" || -n "$BLOCKING_GIVEN" ) ]]; then
    refuse 'NO_LAUNCH=1 prepares no data: DATA and BLOCKING are refused with it.'
  fi
  [[ "$DEV_APP_DIR" == /* ]] || refuse 'DEV_APP_DIR must be absolute.'
  # Refuse redirected or protected install folders before creating or removing anything.
  python3 - "$ROOT" "$DEV_APP_DIR" <<'PY' || exit 2
from pathlib import Path
import sys
root, app_dir = Path(sys.argv[1]), Path(sys.argv[2])
def fail(message):
    print(message, file=sys.stderr)
    raise SystemExit(2)
# Only a link on the final component redirects the install or the build output. A link higher up
# (/tmp -> /private/tmp, a linked ~/Applications) is followed: the protected-folder check below uses
# both the literal and the resolved path, so the same DEV_APP_DIR gives the same answer on every run.
for path in [root / '.build', root / '.build/goalong-dev', root / '.build/goalong-dev/staging',
             root / '.build/goalong-dev/staging/Goalong Dev.app', app_dir, app_dir / 'Goalong Dev.app']:
    if path.is_symlink():
        fail(f'Refusing redirected Goalong Dev path: {path}')
for candidate in (app_dir.absolute(), app_dir.resolve()):
    for protected in (Path('/Applications'), Path('/System'), Path('/Library')):
        if candidate == protected or protected in candidate.parents:
            fail(f'Goalong Dev never goes into {protected} (Sparkle or a sealed bundle): {app_dir}')
    if any(part.endswith('.app') for part in candidate.parts):
        fail(f'Goalong Dev never goes inside an app bundle: {app_dir}')
PY
  warn_old_release
  if [[ "${GOALONG_DEV_VALIDATE_ONLY:-0}" == 1 ]]; then
    echo "Settings accepted: data $DATA, blocking $BLOCKING, server $SERVER, no launch $NO_LAUNCH, $DEV_APP"
    exit 0
  fi
fi

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

HAVE_WORKTREE_LOCK=0 HAVE_GLOBAL_LOCK=0 NEW_APP='' OLD_APP=''
cleanup() {
  [[ -z "$NEW_APP" ]] || rm -rf -- "$NEW_APP" || true
  # The lock itself is released by the kernel when this shell exits; only the PID note is removed.
  [[ "$HAVE_GLOBAL_LOCK" == 0 ]] || rm -f -- "$GLOBAL_LOCK.pid" || true
  [[ "$HAVE_WORKTREE_LOCK" == 0 ]] || rmdir "$DEV_ROOT/lock" 2>/dev/null || true
}
trap cleanup EXIT
mkdir -p "$DEV_ROOT"
if ! mkdir "$DEV_ROOT/lock" 2>/dev/null; then
  echo "Another make dev/dev-stop is running in this worktree. If interrupted, remove $DEV_ROOT/lock after checking it." >&2
  exit 1
fi
HAVE_WORKTREE_LOCK=1

source "$ROOT/scripts/dev_app_lock.sh"

if [[ "$MODE" == stop ]]; then
  build_control
  acquire_global_lock
  "$CONTROL" quit-dev
  exit 0
fi

echo "Goalong Dev (data $DATA, blocking $BLOCKING, server $SERVER$([[ "$NO_LAUNCH" == 1 ]] && echo ', no launch, no data step'))"
mkdir -p "$DEV_APP_DIR"
build_control
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
# NO_LAUNCH prepares no data: the banner says "données non préparées" instead of a mode it never applied.
if [[ "$NO_LAUNCH" == 1 ]]; then LOCALHISTORY_DEV_DATA_MODE=none; else LOCALHISTORY_DEV_DATA_MODE="$DATA"; fi
export LOCALHISTORY_DEV_DATA_MODE LOCALHISTORY_DEV_SERVER="$SERVER"
LOCALHISTORY_DEV_SOURCE_BRANCH="$(git -C "$ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
LOCALHISTORY_DEV_SOURCE_COMMIT="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
# Dirty: any tracked change, or an untracked file SwiftPM or the bundle build would pick up.
if [[ -n "$(git -C "$ROOT" status --porcelain --untracked-files=no 2>/dev/null)" ||
      -n "$(git -C "$ROOT" status --porcelain --untracked-files=all -- Sources Features Package.swift Package.resolved Distribution scripts 2>/dev/null)" ]]; then
  LOCALHISTORY_DEV_SOURCE_COMMIT+='+dirty'
fi
export LOCALHISTORY_DEV_SOURCE_BRANCH LOCALHISTORY_DEV_SOURCE_COMMIT
"$CONTROL" badge-icon "$ROOT/Distribution/AppIcon.png" "$DEV_ROOT/AppIcon-dev.png"
export LOCALHISTORY_DEV_ICON_SOURCE="$DEV_ROOT/AppIcon-dev.png"
export LOCALHISTORY_APP_ENTITLEMENTS="$ROOT/Distribution/GoalongHistory.entitlements"
# Display only (Sparkle is off in Goalong Dev): the banner shows branch and commit.
INSTALLED_PLIST="$RELEASE_APP/Contents/Info.plist"
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

acquire_global_lock
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
# Move the new bundle next to the target first (same volume), then swap by rename: the target name
# never holds a half-copied bundle, and a bundle is never moved inside another one.
NEW_APP="$DEV_APP_DIR/.Goalong Dev.app.new-$$"
OLD_APP="$DEV_APP_DIR/.Goalong Dev.app.old-$$"
rm -rf -- "$NEW_APP" "$OLD_APP"
mv "$STAGING/Goalong Dev.app" "$NEW_APP"
if [[ -e "$DEV_APP" || -L "$DEV_APP" ]]; then mv "$DEV_APP" "$OLD_APP"; fi
if [[ -e "$DEV_APP" || -L "$DEV_APP" ]]; then
  echo "Refusing to install: $DEV_APP still exists after moving it aside." >&2; exit 1
fi
mv "$NEW_APP" "$DEV_APP"
NEW_APP=''
rm -rf -- "$OLD_APP"
step_done 'install'
if [[ "$NO_LAUNCH" == 1 ]]; then
  echo "Installed (not launched, dev data not prepared): $DEV_APP"
else
  # open(1) launches through Launch Services, so the menu bar item belongs to Goalong Dev itself.
  /usr/bin/open "$DEV_APP" 9>&-
  "$CONTROL" wait-running "$DEV_APP"
  step_done 'launch'
  echo "Dev data: $DEV_DATA. The installed Goalong keeps recording and blocking."
fi
/usr/bin/awk -v a="$STARTED" -v b="$(now)" 'BEGIN { printf "make dev: %.1f s\n", b - a }'
