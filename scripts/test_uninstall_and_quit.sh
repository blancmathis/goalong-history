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
POLITE_NAME="GoalongQuitPolite$$"
STUBBORN_NAME="GoalongQuitStubborn$$"
cp /bin/sleep "$WORK/$POLITE_NAME"
cp /bin/bash "$WORK/$STUBBORN_NAME"
# Copies of system binaries need a fresh ad-hoc signature to run on Apple silicon.
/usr/bin/codesign --force --sign - "$WORK/$POLITE_NAME" "$WORK/$STUBBORN_NAME" >/dev/null 2>&1
"$WORK/$POLITE_NAME" 60 & disown
"$WORK/$STUBBORN_NAME" -c 'trap "" TERM; while :; do /bin/sleep 1; done' & disown
/bin/sleep 0.5
/usr/bin/pgrep -x "$POLITE_NAME" >/dev/null || fail "Polite process did not start."
/usr/bin/pgrep -x "$STUBBORN_NAME" >/dev/null || fail "Stubborn process did not start."

start=$SECONDS
GOALONG_QUIT_WAIT_TENTHS=5 quit_running_goalong "$POLITE_NAME" "$STUBBORN_NAME"
/usr/bin/pgrep -x "$POLITE_NAME" >/dev/null && fail "Polite process survived."
/usr/bin/pgrep -x "$STUBBORN_NAME" >/dev/null && fail "Stubborn process was not forced after the wait."
(( SECONDS - start < 10 )) || fail "Quit wait was not bounded."
for needle in '--uninstall-agent-integrations' 'reset SystemPolicyAllFiles' 'reset Calendar' 'reset Reminders'; do
  grep -qF -- "$needle" "$SCRIPT_DIR/../uninstall.sh" || fail "uninstall.sh does not run: $needle"
done
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
echo "Uninstall and quit tests passed."
