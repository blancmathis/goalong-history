#!/bin/bash
# make local: build this checkout as the owner's real Goalong, signed like a release, without GitHub.
# It replaces /Applications/Goalong History.app (same bundle ID, pinned certificate, release
# entitlements, Sparkle on), so permissions carry over. Its build number is the try slot of the
# newest release this Mac knows (scripts/build_number_policy.sh): Sparkle never reinstalls that
# release over it, and the next published release upgrades it as usual.
#   NO_INSTALL=1      build, sign and verify only; stop before any install or quit (agents, dry runs)
#   OUT=/abs/dir      output folder (default .build/goalong-local/out)
#   PERSO=1           make perso: also record this commit; the app then installs only a release that
#                     contains it (PersoReleaseGate). Needs a committed tree. It runs make check (tests
#                     of the files changed since the installed build, throwaway HOME, window guard) in
#                     parallel with the build: a failure stops before install. Then it pushes the branch
#                     `perso` if GitHub lacks the commit, and hands the build to Goalong.
#   GOALONG_PERSO_TEST_FILTER=Regex   with PERSO=1: passed to make check as FILTER.
# make local runs no tests: make check / make test before, CI on the PR.
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
PERSO_COMMIT="" PERSO_BRANCH="" ON_REMOTE=1
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
  # Remote-tracking refs may cover main only (narrow fetch refspec): also accept a pushed branch tip.
  if [[ -z "$(git -C "$ROOT" branch -r --contains "$PERSO_COMMIT" 2>/dev/null)" ]] \
    && ! git -C "$ROOT" ls-remote --heads origin 2>/dev/null | grep -q "^${PERSO_COMMIT}[[:space:]]"; then
    ON_REMOTE=0
  fi
fi

started_all="$(date +%s)"
step() { printf '%-28s %4s s\n' "$1" "$(( $(date +%s) - $2 ))"; }

mkdir -p "$WORK"
if ! mkdir "$WORK/lock" 2>/dev/null; then
  echo "Another make local or make perso runs in this checkout. If interrupted, remove $WORK/lock after checking it." >&2
  exit 1
fi
tests_pid="" build_pid=""
# Tests and build run in their own process groups: an early exit stops them (swift test, its window guard,
# swift build).
stop_jobs() { local g; for g in "$tests_pid" "$build_pid"; do [[ -z "$g" ]] || { kill -TERM -- "-$g" && wait "$g"; } 2>/dev/null || true; done; }
trap 'stop_jobs; rmdir "$WORK/lock" 2>/dev/null || true' EXIT
tests_done() { # wait for make check (perso), stop at once if it failed
  local rc; set +e; wait "$tests_pid"; rc=$?; set -e; tests_pid=""
  if [[ "$rc" != 0 ]]; then
    grep -vE '^ok: ' "$WORK/tests.out" | tail -40 >&2
    echo "Tests failed (exit $rc): nothing installed. Full log: $WORK/tests.log" >&2
    exit 1
  fi
  echo "Tests: $(sed -n 's/^Tests executed: //p' "$WORK/tests.out" | tail -1) passed in $(sed -n 's/^Duration: //p' "$WORK/tests.out" | tail -1); summary: $WORK/tests.out"
}
if [[ "$PERSO" == 1 ]]; then
  set -m
  env -u GOALONG_LOCAL_PERSO -u GOALONG_LOCAL_NO_INSTALL -u GOALONG_LOCAL_OUT GOALONG_CHECK_LOG="$WORK/tests.log" \
    "$ROOT/scripts/run_swift_tests.sh" check "${GOALONG_PERSO_TEST_FILTER:-}" </dev/null >"$WORK/tests.out" 2>&1 &
  tests_pid=$!
  set +m
  echo "Tests (make check) run beside the build; summary: $WORK/tests.out"
fi

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
set -m
env LOCALHISTORY_VERSION="$VERSION" LOCALHISTORY_BUILD_NUMBER="$TRY_BUILD" \
    LOCALHISTORY_PERSO_SOURCE_COMMIT="$PERSO_COMMIT" LOCALHISTORY_PERSO_SOURCE_BRANCH="$PERSO_BRANCH" \
    LOCALHISTORY_ARCHS="$(uname -m)" LOCALHISTORY_BUILD_CONFIGURATION=release \
    LOCALHISTORY_BUILD_JOBS="${LOCALHISTORY_BUILD_JOBS:-$(sysctl -n hw.ncpu)}" \
    LOCALHISTORY_RUN_TESTS=0 LOCALHISTORY_REQUIRE_SPARKLE_CONFIGURED=1 LOCALHISTORY_FINAL_VERIFY_ONLY=1 \
    LOCALHISTORY_APP_ENTITLEMENTS="$ROOT/Distribution/GoalongHistory.entitlements" \
    LOCALHISTORY_OUTPUT_DIR="$OUT" LOCALHISTORY_SCRATCH_ROOT="$WORK/scratch" \
    "$ROOT/scripts/build_app.sh" </dev/null >"$WORK/build.log" 2>&1 &
build_pid=$!
set +m
# A failing test stops the build at once; otherwise wait for the build.
while kill -0 "$build_pid" 2>/dev/null; do
  if [[ -n "$tests_pid" ]] && ! kill -0 "$tests_pid" 2>/dev/null; then tests_done; fi
  sleep 0.5
done
set +e; wait "$build_pid"; build_rc=$?; set -e; build_pid=""
if [[ "$build_rc" != 0 ]]; then
  tail -20 "$WORK/build.log" >&2
  echo "Build failed; full log: $WORK/build.log" >&2
  exit 1
fi
step "Build and sign" "$started"

started="$(date +%s)"
APP="$OUT/$APP_NAME.app"
bash "$ROOT/scripts/verify_release_identity.sh" "$APP" >>"$WORK/build.log" 2>&1 \
  || { echo "Release identity check failed; see $WORK/build.log" >&2; exit 1; }
# The bundle check (verify_local_bundle.sh, Sparkle required) already ran on this final bundle in build_app.sh.
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")" == "$TRY_BUILD" ]]
recorded="$(/usr/libexec/PlistBuddy -c 'Print :GoalongPersoSourceCommit' "$APP/Contents/Info.plist" 2>/dev/null || true)"
[[ "$recorded" == "$PERSO_COMMIT" ]] || { echo "Perso commit in the bundle ($recorded) differs from $PERSO_COMMIT." >&2; exit 1; }
step "Verify (identity, commit)" "$started"

if [[ "$PERSO" == 1 ]]; then
  started="$(date +%s)"
  [[ -z "$tests_pid" ]] || { tests_done; step "Wait for tests" "$started"; }
  # The delivered commit must be the tested one.
  [[ "$(git -C "$ROOT" rev-parse HEAD)" == "$PERSO_COMMIT" && -z "$(git -C "$ROOT" status --porcelain --untracked-files=normal)" ]] \
    || { echo "The checkout changed during make perso (HEAD or files): nothing installed. Run it again." >&2; exit 1; }
fi

if [[ "$NO_INSTALL" == 1 ]]; then
  step "Total" "$started_all"
  echo "NO_INSTALL=1: stopped before install. App: $APP"
  exit 0
fi

# make perso with a running perso Goalong that reported health: hand the bundle to it (it installs itself, also
# during a locked block, at most once per 10 minutes then). It re-checks the signature against its own, swaps in
# a few seconds and rolls back unless the new build starts. Any other case uses the installer below.
perso_handoff() {
  local root="$HOME/Library/Application Support/LocalHistory/PersoUpdate" installed="/Applications/$APP_NAME.app"
  local exe pid id tmp request state="" reason="" t0
  exe="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$installed/Contents/Info.plist" 2>/dev/null)" || return 10
  /usr/libexec/PlistBuddy -c 'Print :GoalongPersoBuiltAt' "$installed/Contents/Info.plist" >/dev/null 2>&1 || return 10
  pid="$(pgrep -x "$exe" | head -1)"; [[ -n "$pid" ]] || return 10
  [[ "$(ps -o comm= -p "$pid")" == "$installed/Contents/MacOS/$exe" ]] || return 10
  # Only a build with self-update writes health.json with its pid (older perso builds lack it).
  [[ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["pid"])' "$root/health.json" 2>/dev/null)" == "$pid" ]] || return 10
  [[ -d "$root/inbox" ]] || return 10
  id="$(date -u +%Y%m%d-%H%M%S)-$$"; tmp="$root/inbox/.tmp-$id"; request="$root/inbox/$id"
  mkdir -m 700 "$tmp" && cp -c -R "$APP" "$tmp/" && echo '{}' >"$tmp/request.json" && mv "$tmp" "$request" \
    || { rm -rf "$tmp"; return 10; }
  t0="$(date +%s)"
  read_state() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["state"]+"\t"+(d.get("reason") or ""))' "$request/result.json" 2>/dev/null || true; }
  local deadline=$((t0 + 20)) accepted=""
  while :; do
    IFS=$'\t' read -r state reason <<<"$(read_state)"
    case "$state" in
      refused|installed|rolled_back) break ;;
      # Accepted: the swap, the restart and the health check (the relauncher gives up after 120 s).
      accepted) [[ -n "$accepted" ]] || { accepted=1; step "Hand-off checks (Goalong)" "$t0"; deadline=$(( $(date +%s) + 150 )); } ;;
    esac
    # A request Goalong claimed (file `claimed`, written before the slow copy) is being installed: never fall back
    # to the classic installer (two installs at once) and never delete the request. Wait for a final result.
    if [[ -z "$accepted" && -e "$request/claimed" ]]; then
      accepted=1; step "Hand-off checks (Goalong)" "$t0"; deadline=$(( $(date +%s) + 150 ))
    fi
    if (( $(date +%s) >= deadline )); then
      [[ -n "$accepted" ]] && break
      rm -rf "$request"; echo "Goalong did not answer the hand-off; using the installer." >&2; return 10
    fi
    sleep 0.2
  done
  # Final answer, or Goalong still working on a claimed request: keep the request in the second case.
  case "$state" in refused|installed|rolled_back) rm -rf "$request" ;; esac
  case "$state" in
    installed) step "Self-update (swap, restart)" "$t0"; return 0 ;;
    refused) echo "Goalong refused this build: $reason" >&2; return 3 ;;
    rolled_back) echo "The new build did not start; Goalong rolled back: $reason" >&2; return 1 ;;
    *) echo "No result from Goalong after the swap; check /Applications/$APP_NAME.app." >&2; return 1 ;;
  esac
}
if [[ "$PERSO" == 1 && "$ON_REMOTE" == 0 ]]; then
  started="$(date +%s)"
  if [[ "$PERSO_BRANCH" == perso ]] && git -C "$ROOT" push -q origin "$PERSO_COMMIT:refs/heads/perso"; then
    step "Push perso" "$started"
  else
    echo "Note: commit ${PERSO_COMMIT:0:8} is on no remote branch. Push it: until GitHub knows it, every release is skipped." >&2
  fi
fi
if [[ "$PERSO" == 1 ]]; then
  started="$(date +%s)"
  set +e; perso_handoff; handoff=$?; set -e
  if [[ "$handoff" != 10 ]]; then step "Total" "$started_all"; exit "$handoff"; fi
fi

# The installer re-verifies the bundle, refuses a different signing identity, a newer installed build
# (read from the folder it will really replace), any active or scheduled block, quits Goalong cleanly
# (never SIGKILL) and replaces it with rollback. The lock override is never passed through.
unset GOALONG_INSTALL_DURING_LOCK
started="$(date +%s)"
GOALONG_LOCAL_TRY=1 LOCALHISTORY_PREBUILT_APP="$APP" "$ROOT/scripts/install_from_source.sh"
step "Install" "$started"
step "Total" "$started_all"
