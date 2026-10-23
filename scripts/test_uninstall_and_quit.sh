#!/bin/bash
# Safe to run anywhere: sources uninstall.sh (which then returns before any effect), uses a
# temporary HOME, and only signals processes it started itself.
set -euo pipefail
trap 'echo "Uninstall/quit test failed at line $LINENO." >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../uninstall.sh
source "$SCRIPT_DIR/../uninstall.sh"
set +e
trap - ERR

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"; /usr/bin/pkill -KILL -x "$STUBBORN_NAME" >/dev/null 2>&1; /usr/bin/pkill -KILL -x "$POLITE_NAME" >/dev/null 2>&1' EXIT
fail() { echo "$1" >&2; exit 1; }

# 1. CLI link removal
BIN="$WORK/home/.local/bin"
mkdir -p "$BIN" "$WORK/other"
APP_EXE="$WORK/Applications/Goalong History.app/Contents/MacOS/goalong"
mkdir -p "$(dirname "$APP_EXE")"; : > "$APP_EXE"; chmod +x "$APP_EXE"
ln -s "$APP_EXE" "$BIN/goalong"
remove_goalong_cli_link "$BIN/goalong"
[[ ! -e "$BIN/goalong" && ! -L "$BIN/goalong" ]] || fail "A Goalong link was not removed."

: > "$WORK/other/tool"
ln -s "$WORK/other/tool" "$BIN/goalong"
remove_goalong_cli_link "$BIN/goalong"
[[ -L "$BIN/goalong" ]] || fail "An unrelated link was removed."
rm -f "$BIN/goalong"

echo "regular" > "$BIN/goalong"
remove_goalong_cli_link "$BIN/goalong"
[[ -f "$BIN/goalong" ]] || fail "A regular file was removed."
remove_goalong_cli_link "$WORK/missing" || fail "A missing link must not fail."

# 2. Bounded wait: a polite process exits on SIGTERM, a stubborn one is forced after the wait.
# The test processes are built here: a re-signed copy of a system binary (arm64e) does not run on
# macOS 15. Names stay under 16 characters (MAXCOMLEN), the part of the name every pgrep -x sees.
POLITE_NAME="GLPolite$$"
STUBBORN_NAME="GLStubborn$$"
printf '%s\n' '#include <signal.h>' '#include <string.h>' '#include <unistd.h>' \
  'int main(int argc, char **argv) {' \
  '  if (argc > 1 && strcmp(argv[1], "probe") == 0) return 0;' \
  '  if (argc > 1 && strcmp(argv[1], "stubborn") == 0) signal(SIGTERM, SIG_IGN);' \
  '  for (int i = 0; i < 60; i++) sleep(1);' \
  '  return 0;' \
  '}' > "$WORK/quit-test.c"
/usr/bin/cc -o "$WORK/$POLITE_NAME" "$WORK/quit-test.c" || fail "Could not build the test processes."
cp "$WORK/$POLITE_NAME" "$WORK/$STUBBORN_NAME"
"$WORK/$POLITE_NAME" probe || fail "The test process cannot run (status $?)."
"$WORK/$POLITE_NAME" & disown
"$WORK/$STUBBORN_NAME" stubborn & disown
started() { # NAME: waits up to 10 s, a busy CI runner can be slow to start a new binary
  local tries=0
  until /usr/bin/pgrep -x "$1" >/dev/null; do (( ++tries <= 100 )) || return 1; /bin/sleep 0.1; done
}
started "$POLITE_NAME" || fail "Polite process did not start."
started "$STUBBORN_NAME" || fail "Stubborn process did not start."

start=$SECONDS
GOALONG_QUIT_WAIT_TENTHS=5 quit_running_goalong "$POLITE_NAME" "$STUBBORN_NAME"
/usr/bin/pgrep -x "$POLITE_NAME" >/dev/null && fail "Polite process survived."
/usr/bin/pgrep -x "$STUBBORN_NAME" >/dev/null && fail "Stubborn process was not forced after the wait."
(( SECONDS - start < 10 )) || fail "Quit wait was not bounded."
grep -qF -- '--uninstall-agent-integrations' "$SCRIPT_DIR/../uninstall.sh" || fail "uninstall.sh does not run: --uninstall-agent-integrations"
for service in SystemPolicyAllFiles Calendar Reminders; do
  [[ " ${TCC_SERVICES[*]} " == *" $service "* ]] || fail "uninstall.sh does not reset: $service"
done
grep -qF -- 'tccutil reset "$service" "$BUNDLE_ID"' "$SCRIPT_DIR/../uninstall.sh" || fail "uninstall.sh does not reset the permissions."
grep -qF -- "grep -qaF -- '--uninstall-agent-integrations'" "$SCRIPT_DIR/../uninstall.sh" || fail "uninstall.sh does not guard the flag call."
# Behavior of the guard: a stub without the flag must not be run; a stub with the flag must be.
printf '#!/bin/bash\ntouch "%s/ran-old"\n' "$WORK" > "$WORK/old-stub"
printf '#!/bin/bash\n# --uninstall-agent-integrations\ntouch "%s/ran-new"\n' "$WORK" > "$WORK/new-stub"
chmod +x "$WORK/old-stub" "$WORK/new-stub"
for stub in old-stub new-stub; do
  if /usr/bin/grep -qaF -- '--uninstall-agent-integrations' "$WORK/$stub"; then "$WORK/$stub"; fi
done
[[ ! -e "$WORK/ran-old" ]] || fail "Stub without the flag was run."
[[ -e "$WORK/ran-new" ]] || fail "Stub with the flag was not run."
# 3. Spec K: lock markers and the blocking guard. Fake bundle id and executable name: launchctl only
# ever sees a label that does not exist, and no Goalong copy is run.
BLOCKING="$WORK/blocking"; mkdir -p "$BLOCKING"
[[ "$(goalong_severe_block_until "$BLOCKING")" == 0 ]] || fail "No marker must mean no block."
now_epoch="$(date +%s)"
echo "$((now_epoch - 10))" > "$BLOCKING/locked-until"
[[ "$(goalong_severe_block_until "$BLOCKING")" == 0 ]] || fail "An ended lock still counts."
echo "$((now_epoch + 300))" > "$BLOCKING/guard-until"
[[ "$(goalong_severe_block_until "$BLOCKING")" == "$((now_epoch + 300))" ]] || fail "guard-until alone (freeze, program) must count."
echo "$((now_epoch + 900))" > "$BLOCKING/locked-until"
[[ "$(goalong_severe_block_until "$BLOCKING")" == "$((now_epoch + 900))" ]] || fail "The latest end must win."
rm "$BLOCKING/locked-until" "$BLOCKING/guard-until"
echo "$((now_epoch + 900))" > "$WORK/elsewhere"; ln -s "$WORK/elsewhere" "$BLOCKING/guard-until"
[[ "$(goalong_severe_block_until "$BLOCKING")" == 0 ]] || fail "A linked marker must be ignored."
grep -qF 'release_blocking_guard "/Applications/$APP_NAME.app" "$HOME/Applications/$APP_NAME.app"' "$SCRIPT_DIR/../uninstall.sh" \
  || fail "uninstall.sh does not release the blocking guard."
(
  BUNDLE_ID="ai.goalong.test.absent.$$" EXECUTABLE_NAME="GoalongGuardStub$$"
  for kind in old new; do
    mkdir -p "$WORK/$kind.app/Contents/MacOS"
    if [[ "$kind" == new ]]; then flag='# --unregister-guard'; else flag='#'; fi
    printf '#!/bin/bash\n%s\necho "$1" > "%s/guard-%s"\n' "$flag" "$WORK" "$kind" > "$WORK/$kind.app/Contents/MacOS/$EXECUTABLE_NAME"
    chmod +x "$WORK/$kind.app/Contents/MacOS/$EXECUTABLE_NAME"
  done
  release_blocking_guard "$WORK/old.app" "$WORK/new.app" "$WORK/missing.app"
)
[[ ! -e "$WORK/guard-old" ]] || fail "A build without --unregister-guard was run."
release_body="$(declare -f release_blocking_guard)"
[[ "${release_body%%launchctl bootout*}" == *'--unregister-guard'* ]] \
  || fail "--unregister-guard must run before the bootout (it leaves the override token for the running app)."
[[ "$(cat "$WORK/guard-new")" == --unregister-guard ]] || fail "The guard was not unregistered."
# 4. --purge-data and Goalong Dev: its lock refuses the purge (not a plain uninstall), and the purge
# releases its guard, then quits it, then removes its app and data. Every system command is a stub.
(
  DATA_DIR="$WORK/purge/LocalHistory" DEV_DATA_DIR="$WORK/purge/LocalHistory-Dev"
  mkdir -p "$DATA_DIR/Blocking" "$DEV_DATA_DIR/Blocking"
  [[ "$(uninstall_locked_until true)" == 0 ]] || fail "No lock must allow the purge."
  echo "$(( $(date +%s) + 600 ))" > "$DEV_DATA_DIR/Blocking/guard-until"
  (( $(uninstall_locked_until true) > 0 )) || fail "A Goalong Dev lock must refuse --purge-data."
  [[ "$(uninstall_locked_until false)" == 0 ]] || fail "A Goalong Dev lock must not refuse a plain uninstall."
) || exit 1
(
  LOG="$WORK/purge-log"; : > "$LOG"
  DEV_APP_PATH="$WORK/purge/Goalong Dev.app" DEV_DATA_DIR="$WORK/purge/LocalHistory-Dev" HOME="$WORK/purge-home"
  mkdir -p "$DEV_APP_PATH" "$DEV_DATA_DIR"
  goalong_dev_app_candidates() { :; } # hermetic: no running copy or Spotlight result from this Mac
  release_blocking_guard() { echo "guard $BUNDLE_ID $EXECUTABLE_NAME $*" >> "$LOG"; }
  quit_running_goalong() { [[ -d "$DEV_DATA_DIR" ]] && echo "quit $*" >> "$LOG"; }
  defaults() { echo "defaults $*" >> "$LOG"; }
  tccutil() { echo "tccutil $*" >> "$LOG"; }
  security() { echo "security $*" >> "$LOG"; return 1; }
  purge_goalong_dev
  [[ ! -e "$DEV_APP_PATH" && ! -e "$DEV_DATA_DIR" ]] || fail "The purge left Goalong Dev or its data."
  [[ "$(sed -n 1p "$LOG")" == "guard ai.goalong.localhistory.dev Goalong History Dev $DEV_APP_PATH" ]] || fail "The Goalong Dev guard must go first: $(cat "$LOG")"
  [[ "$(sed -n 2p "$LOG")" == "quit Goalong History Dev" ]] || fail "Goalong Dev must quit before its data goes: $(cat "$LOG")"
  grep -qx 'defaults delete ai.goalong.localhistory.dev' "$LOG" || fail "Goalong Dev preferences were kept."
  grep -qx 'tccutil reset Accessibility ai.goalong.localhistory.dev' "$LOG" || fail "Goalong Dev permissions were kept."
  grep -qx 'security delete-generic-password -s goalong.evidence.v1.dev' "$LOG" || fail "The Goalong Dev evidence key was kept."
  ! grep -q 'ai.goalong.localhistory ' "$LOG" || fail "The Goalong Dev purge touched the release identity."
  [[ "$(goalong_dev_purge_summary)" == "Goalong Dev ($DEV_APP_PATH), its data"* ]] || fail "A removed Goalong Dev must be reported."
) || exit 1
# Never installed (every end user): the purge does not claim it removed Goalong Dev.
(
  DEV_APP_PATH="$WORK/never/Goalong Dev.app" DEV_DATA_DIR="$WORK/never/LocalHistory-Dev" HOME="$WORK/never-home"
  release_blocking_guard() { :; }; quit_running_goalong() { :; }; goalong_dev_app_candidates() { :; }
  defaults() { :; }; tccutil() { :; }; security() { return 1; }
  purge_goalong_dev
  [[ "$DEV_REMOVED" == false && -z "$(goalong_dev_purge_summary)" ]] || fail "A Goalong Dev never installed was reported removed: $(goalong_dev_purge_summary)"
) || exit 1
# A Goalong Dev installed elsewhere (DEV_APP_DIR) loses its guard and is listed as kept; build products,
# swap leftovers, the release app and the ~/Applications copy are never in that list.
(
  LOG="$WORK/purge-elsewhere-log"; : > "$LOG"
  P="$WORK/dev-elsewhere"; DEV_APP_PATH="$P/home-apps/Goalong Dev.app" DEV_DATA_DIR="$P/LocalHistory-Dev" HOME="$P/home"
  make_bundle() { # PATH BUNDLE_ID
    mkdir -p "$1/Contents"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $2" "$1/Contents/Info.plist" >/dev/null
  }
  make_bundle "$DEV_APP_PATH" ai.goalong.localhistory.dev
  make_bundle "$P/Dev/Goalong Dev.app" ai.goalong.localhistory.dev
  make_bundle "$P/repo/.build/goalong-dev/Goalong Dev.app" ai.goalong.localhistory.dev
  make_bundle "$P/Dev/.Goalong Dev.app.old-12" ai.goalong.localhistory.dev
  make_bundle "$P/Release/Goalong History.app" ai.goalong.localhistory
  mkdir -p "$DEV_DATA_DIR"
  goalong_dev_app_candidates() {
    printf '%s\n' "$P/Dev/Goalong Dev.app" "$DEV_APP_PATH" "$P/repo/.build/goalong-dev/Goalong Dev.app" \
      "$P/Dev/.Goalong Dev.app.old-12" "$P/Release/Goalong History.app" "$P/missing/Goalong Dev.app" "$P/Dev/Goalong Dev.app"
  }
  release_blocking_guard() { echo "guard $BUNDLE_ID $*" >> "$LOG"; }
  quit_running_goalong() { :; }
  defaults() { :; }; tccutil() { :; }; security() { return 1; }
  purge_goalong_dev
  [[ "${#DEV_KEPT_APPS[@]}" == 1 && "${DEV_KEPT_APPS[0]}" == "$P/Dev/Goalong Dev.app" ]] || fail "Kept Goalong Dev copies: ${DEV_KEPT_APPS[*]-}"
  [[ "$(cat "$LOG")" == "guard ai.goalong.localhistory.dev $DEV_APP_PATH $P/Dev/Goalong Dev.app" ]] || fail "The guard of a Goalong Dev installed elsewhere was kept: $(cat "$LOG")"
  [[ -d "$P/Dev/Goalong Dev.app" && ! -e "$DEV_APP_PATH" ]] || fail "Only the ~/Applications copy of Goalong Dev may be removed."
  [[ "$(goalong_dev_purge_summary)" == *"was kept"*"  $P/Dev/Goalong Dev.app" ]] || fail "A kept Goalong Dev must be listed: $(goalong_dev_purge_summary)"
) || exit 1
grep -qx '  goalong_dev_purge_summary' "$SCRIPT_DIR/../uninstall.sh" || fail "A kept Goalong Dev must be reported."
purge_line="$(grep -n '^  purge_goalong_dev$' "$SCRIPT_DIR/../uninstall.sh" | cut -d: -f1)"
data_line="$(grep -n '^  rm -rf "$DATA_DIR"$' "$SCRIPT_DIR/../uninstall.sh" | cut -d: -f1)"
[[ -n "$purge_line" && -n "$data_line" ]] && (( purge_line < data_line )) || fail "--purge-data must handle Goalong Dev first."
echo "Uninstall and quit tests passed."
