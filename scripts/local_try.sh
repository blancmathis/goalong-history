#!/bin/bash
# make local: build this checkout as the owner's real Goalong, signed like a release, without GitHub.
# It replaces /Applications/Goalong History.app (same bundle ID, pinned certificate, release
# entitlements, Sparkle on), so permissions carry over. Its build number is the try slot of the
# newest release this Mac knows (scripts/build_number_policy.sh): Sparkle never reinstalls that
# release over it, and the next published release upgrades it as usual.
#   NO_INSTALL=1      build, sign and verify only; stop before any install or quit (agents, dry runs)
#   OUT=/abs/dir      output folder (default .build/goalong-local/out)
#   PERSO=1           make perso: also record this commit; the app then installs only a release that
#                     contains it (PersoReleaseGate). Needs a committed tree; push it so GitHub knows it.
# Tests are not run here: make check / make test before, CI on the PR.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Goalong History"
WORK="$ROOT/.build/goalong-local"
OUT="${GOALONG_LOCAL_OUT:-$WORK/out}"
NO_INSTALL="${GOALONG_LOCAL_NO_INSTALL:-0}"
PERSO="${GOALONG_LOCAL_PERSO:-0}"
MANIFEST_URL="https://github.com/blancmathis/goalong-history/releases/download/latest-main/release-manifest.json"
# Test hooks, honored only with NO_INSTALL=1: a fixture manifest (file path) and app folders.
TEST_MANIFEST="${GOALONG_LOCAL_TEST_MANIFEST:-}"
APP_DIRS=("/Applications" "$HOME/Applications")
if [[ "$NO_INSTALL" == 1 && -n "${GOALONG_LOCAL_TEST_APP_DIRS:-}" ]]; then
  IFS=: read -r -a APP_DIRS <<<"$GOALONG_LOCAL_TEST_APP_DIRS"
fi
# shellcheck source=build_number_policy.sh
source "$ROOT/scripts/build_number_policy.sh"

[[ "$(uname -s)" == Darwin && "$(id -u)" != 0 ]] || { echo "make local needs the current non-root Mac user." >&2; exit 1; }
[[ "$NO_INSTALL" == 0 || "$NO_INSTALL" == 1 ]] || { echo "NO_INSTALL must be 0 or 1." >&2; exit 2; }
[[ "$OUT" == /* ]] || { echo "OUT must be an absolute path." >&2; exit 2; }
[[ "${GITHUB_ACTIONS:-}" != true ]] || { echo "make local is for the owner's Mac, not CI." >&2; exit 1; }
[[ "$PERSO" == 0 || "$PERSO" == 1 ]] || { echo "PERSO must be 0 or 1." >&2; exit 2; }
MODE="make local"
PERSO_COMMIT="" PERSO_BRANCH=""
if [[ "$PERSO" == 1 ]]; then
  MODE="make perso"
  # The recorded commit must be exactly what is built: a release "contains this build" only then.
  if [[ -n "$(git -C "$ROOT" status --porcelain --untracked-files=normal)" ]]; then
    echo "make perso builds a commit: commit (or stash) your changes first. git status:" >&2
    git -C "$ROOT" status --short >&2
    exit 1
  fi
  PERSO_COMMIT="$(git -C "$ROOT" rev-parse HEAD)"
  PERSO_BRANCH="$(git -C "$ROOT" rev-parse --abbrev-ref HEAD)"
  if [[ -z "$(git -C "$ROOT" branch -r --contains "$PERSO_COMMIT" 2>/dev/null)" ]]; then
    echo "Note: commit ${PERSO_COMMIT:0:8} is on no remote branch yet. Push it: until GitHub knows it, every release is skipped." >&2
  fi
fi

started_all="$(date +%s)"
step() { printf '%-28s %4s s\n' "$1" "$(( $(date +%s) - $2 ))"; }

mkdir -p "$WORK"
if ! mkdir "$WORK/lock" 2>/dev/null; then
  echo "Another make local or make perso runs in this checkout. If interrupted, remove $WORK/lock after checking it." >&2
  exit 1
fi
trap 'rmdir "$WORK/lock" 2>/dev/null || true' EXIT

# Base: the newest release build among the installed app and the public manifest (best effort,
# plain HTTPS). Offline, only the installed app counts; a newer public release then replaces the try.
release_builds=()
installed_build="" installed_version=""
for candidate in "${APP_DIRS[@]/%//$APP_NAME.app}"; do
  if [[ -d "$candidate" && ! -L "$candidate" ]]; then
    installed_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$candidate/Contents/Info.plist" 2>/dev/null || true)"
    installed_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$candidate/Contents/Info.plist" 2>/dev/null || true)"
    break
  fi
done
[[ -z "$installed_build" ]] || release_builds+=("$installed_build|$installed_version")
manifest_proto='=https'
if [[ "$NO_INSTALL" == 1 && -n "$TEST_MANIFEST" ]]; then MANIFEST_URL="file://$TEST_MANIFEST"; manifest_proto='=https,file'; fi
if public="$(/usr/bin/curl --fail --location --silent --max-time 20 --proto "$manifest_proto" "$MANIFEST_URL" 2>/dev/null \
    | /usr/bin/python3 -c 'import json,sys; p=json.load(sys.stdin)["product"]; print(p["build"]+"|"+p["version"])' 2>/dev/null)"; then
  if localhistory_manifest_base_plausible "${public%%|*}" "$installed_build"; then
    release_builds+=("$public")
  else
    echo "Warning: public manifest build ${public%%|*} is implausibly far ahead; ignored. Base is the installed app only." >&2
  fi
else
  echo "Warning: public release manifest unreachable; base is the installed app only." >&2
fi
base_line=""
for line in "${release_builds[@]+"${release_builds[@]}"}"; do
  localhistory_local_try_build_number "${line%%|*}" >/dev/null 2>&1 || continue
  base_line="$(printf '%s\n%s\n' "$base_line" "$line" | sed '/^$/d' | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)"
done
if [[ -z "$base_line" && "$installed_build" =~ ^${LOCALHISTORY_RELEASE_BUILD_EPOCH}\.[0-9]+\.[0-9]*99$ ]]; then
  echo "Installed build $installed_build is already a local try and the public release is unreachable (offline?). Reconnect, then run make local again." >&2
  exit 1
fi
[[ -n "$base_line" ]] || { echo "No published Goalong release found (installed or public); make local needs one as its base." >&2; exit 1; }
BASE_BUILD="${base_line%%|*}"
VERSION="${base_line#*|}"
TRY_BUILD="$(localhistory_local_try_build_number "$BASE_BUILD")"
if [[ "$PERSO" == 1 ]]; then
  echo "Perso build $VERSION ($TRY_BUILD) of $PERSO_BRANCH @ ${PERSO_COMMIT:0:8}, above release $BASE_BUILD; only a release that contains this commit replaces it."
else
  echo "Local try $VERSION ($TRY_BUILD), above release $BASE_BUILD; the next release replaces it."
fi

started="$(date +%s)"
rm -rf "$OUT"
mkdir -p "$OUT" "$WORK/scratch"
export LOCALHISTORY_LOCAL_TRY_BASE="$BASE_BUILD"
if ! env LOCALHISTORY_VERSION="$VERSION" LOCALHISTORY_BUILD_NUMBER="$TRY_BUILD" \
    LOCALHISTORY_PERSO_SOURCE_COMMIT="$PERSO_COMMIT" LOCALHISTORY_PERSO_SOURCE_BRANCH="$PERSO_BRANCH" \
    LOCALHISTORY_ARCHS="$(uname -m)" LOCALHISTORY_BUILD_CONFIGURATION=release \
    LOCALHISTORY_RUN_TESTS=0 LOCALHISTORY_REQUIRE_SPARKLE_CONFIGURED=1 \
    LOCALHISTORY_APP_ENTITLEMENTS="$ROOT/Distribution/GoalongHistory.entitlements" \
    LOCALHISTORY_OUTPUT_DIR="$OUT" LOCALHISTORY_SCRATCH_ROOT="$WORK/scratch" \
    "$ROOT/scripts/build_app.sh" >"$WORK/build.log" 2>&1; then
  tail -20 "$WORK/build.log" >&2
  echo "Build failed; full log: $WORK/build.log" >&2
  exit 1
fi
step "Build and sign" "$started"

started="$(date +%s)"
APP="$OUT/$APP_NAME.app"
bash "$ROOT/scripts/verify_release_identity.sh" "$APP" >>"$WORK/build.log" 2>&1 \
  || { echo "Release identity check failed; see $WORK/build.log" >&2; exit 1; }
LOCALHISTORY_APP_PATH="$APP" LOCALHISTORY_REQUIRE_SPARKLE_CONFIGURED=1 bash "$ROOT/scripts/verify_local_bundle.sh" >>"$WORK/build.log" 2>&1 \
  || { echo "Bundle check failed; see $WORK/build.log" >&2; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")" == "$TRY_BUILD" ]]
recorded="$(/usr/libexec/PlistBuddy -c 'Print :GoalongPersoSourceCommit' "$APP/Contents/Info.plist" 2>/dev/null || true)"
[[ "$recorded" == "$PERSO_COMMIT" ]] || { echo "Perso commit in the bundle ($recorded) differs from $PERSO_COMMIT." >&2; exit 1; }
step "Verify (identity, Sparkle)" "$started"

if [[ "$NO_INSTALL" == 1 ]]; then
  step "Total" "$started_all"
  echo "NO_INSTALL=1: stopped before install. App: $APP"
  exit 0
fi

# The installer re-verifies the bundle, refuses a different signing identity, a newer installed build
# (read from the folder it will really replace), any active or scheduled block, quits Goalong cleanly
# (never SIGKILL) and replaces it with rollback. The lock override is never passed through.
unset GOALONG_INSTALL_DURING_LOCK
started="$(date +%s)"
GOALONG_LOCAL_TRY=1 LOCALHISTORY_PREBUILT_APP="$APP" "$ROOT/scripts/install_from_source.sh"
step "Install" "$started"
step "Total" "$started_all"
