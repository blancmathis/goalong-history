#!/bin/bash
# L1 (T-057): after the quit request, every exit of install_from_source.sh reopens the app in the background
# (open -g -j). No real Goalong, no /Applications, no window: pgrep/pkill/open are shell functions.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_ROOT="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/goalong-relaunch-test.XXXXXX")"
trap '/bin/rm -rf "$TEST_ROOT"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

run_case() { # NAME BODY  -> prints OPEN_CALLS lines and STATUS
  local name="$1" body="$2" dir="$TEST_ROOT/$1"
  /bin/mkdir -p "$dir/Home/Library/Logs" "$dir/Applications/Goalong History.app"
  HOME="$dir/Home" OPEN_LOG="$dir/open.log" TARGET="$dir/Applications/Goalong History.app" \
    GOALONG_LATE_RELAUNCH_WAIT_SECONDS=5 /bin/bash -c '
    source "$1"; shift
    LOG_FILE="$HOME/Library/Logs/i.log"; : >"$LOG_FILE"
    /usr/bin/open() { echo "open $*" >>"$OPEN_LOG"; }
    /bin/sleep() { :; }
    TARGET_APP="$TARGET"
    trap cleanup EXIT
    eval "$1"' _ "$SCRIPT_DIR/install_from_source.sh" "$body" >"$dir/out.log" 2>&1 && echo 0 >"$dir/status" || echo $? >"$dir/status"
}
opens() { /bin/cat "$TEST_ROOT/$1/open.log" 2>/dev/null || true; }

# 1. A step fails after the quit (under set -e): the app is reopened with -g -j, status kept.
run_case fail_after_quit 'pgrep() { :; }; /usr/bin/pgrep() { return 1; }; /usr/bin/pkill() { return 0; }
  quit_running_goalong "Goalong History"; false'
grep -Fq -- 'open -g -j' <<<"$(opens fail_after_quit)" || fail "no background reopen after a failure post-quit: $(opens fail_after_quit)"
[[ "$(/bin/cat "$TEST_ROOT/fail_after_quit/status")" != 0 ]] || fail "failure status was swallowed"
[[ "$(opens fail_after_quit | wc -l | tr -d ' ')" == 1 ]] || fail "open called more than once"

# 2. Failure before the quit: no reopen (nothing was closed).
run_case fail_before_quit 'false'
[[ -z "$(opens fail_before_quit)" ]] || fail "reopened although Goalong was never asked to quit"

# 3. Rollback after a failed replacement: old app restored, then reopened in background.
run_case rollback '/usr/bin/pgrep() { return 1; }; /usr/bin/pkill() { return 0; }
  BACKUP_APP="$TARGET.bak"; INSTALL_STAGE_ROOT="$(dirname "$TARGET")/stage"; /bin/mkdir -p "$INSTALL_STAGE_ROOT" "$BACKUP_APP"
  /bin/rm -rf "$TARGET"; /bin/mkdir -p "$TARGET"
  quit_running_goalong "Goalong History"; ORIGINAL_TARGET_PRESENT=1; REPLACEMENT_ACTIVE=1; false'
grep -Fq -- 'open -g -j' <<<"$(opens rollback)" || fail "no reopen after rollback"
[[ -d "$TEST_ROOT/rollback/Applications/Goalong History.app" ]] || fail "old app not restored by rollback"

# 4. 120 s password timeout (never quits): exit 1, never SIGKILL, background reopen; and a late quit reopens.
run_case timeout 'export GOALONG_LOCAL_TRY=1 GOALONG_QUIT_WAIT_TENTHS=1 GOALONG_QUIT_PROMPT_WAIT_TENTHS=1 GOALONG_LATE_RELAUNCH_SYNC=1
  N=0; /usr/bin/pgrep() { N=$((N+1)); (( N <= 4 )); }   # running through both waits, gone afterwards
  /usr/bin/pkill() { [[ "$1" != -KILL ]] || echo KILLED; return 0; }
  quit_running_goalong "Goalong History"'
[[ "$(/bin/cat "$TEST_ROOT/timeout/status")" == 1 ]] || fail "timeout path did not exit 1"
grep -Fq KILLED "$TEST_ROOT/timeout/out.log" && fail "timeout path force-killed Goalong"
grep -Fq 'open -g -j' <<<"$(opens timeout)" || fail "no reopen after the password timeout / late quit"

# 5. Success path: finalize never rolls back, cleanup warnings are not exits, one background open.
run_case success '/usr/bin/pgrep() { return 1; }; /usr/bin/pkill() { return 0; }
  quit_running_goalong "Goalong History"
  BACKUP_APP="$TARGET.none"; REPLACEMENT_ACTIVE=1; ORIGINAL_TARGET_PRESENT=1
  safe_remove_backup_bundle() { return 1; }
  finalize_replacement; [[ "$REPLACEMENT_ACTIVE" == 0 ]]
  remove_verified_legacy_bundle() { return 1; }; post_install_cleanup
  relaunch_installed_app'
[[ "$(/bin/cat "$TEST_ROOT/success/status")" == 0 ]] || fail "cleanup warning became an exit: $(cat "$TEST_ROOT/success/out.log")"
[[ "$(opens success | wc -l | tr -d ' ')" == 1 ]] || fail "success path should open exactly once"
grep -Fq -- 'open -g -j' <<<"$(opens success)" || fail "success open is not background"

# 6. No plain `open` left in the installer, and local_try keeps a claimed request.
grep -nE '/usr/bin/open( |$)' "$SCRIPT_DIR/install_from_source.sh" | grep -v -- '-g -j' && fail "foreground open in installer"
grep -Fq 'request/claimed' "$SCRIPT_DIR/local_try.sh" || fail "local_try ignores the claimed marker"
echo "test_install_relaunch: OK"
