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
echo "Uninstall and quit tests passed."
