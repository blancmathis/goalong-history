#!/bin/bash
# L1 (T-057) and L1L2-04/05: after the quit request, every exit of install_from_source.sh reopens the app in the
# background (open -g -j); a failed open of the new app puts the old one back and opens it; a quit after the
# password timeout reopens the app with no time limit, unless a newer run took that duty over.
# No real Goalong, no /Applications, no window: pgrep/pkill/open are shell functions; "Goalong" is a sleep.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_ROOT="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/goalong-relaunch-test.XXXXXX")"
APP_PIDS=()
trap 'for p in "${APP_PIDS[@]:-}"; do [[ -z "$p" ]] || kill "$p" 2>/dev/null || true; done; /bin/rm -rf "$TEST_ROOT"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# Each case: HOME, a target app holding a marker file, OPEN_LOG lines "open <args> marker=<marker seen>".
# The fake open fails when OPEN_FAILS_FOR equals the marker it sees.
run_case() { # NAME BODY [LATE_DIR]
  local name="$1" body="$2" dir="$TEST_ROOT/$1"
  /bin/mkdir -p "$dir/Home/Library/Logs" "$dir/Applications/Goalong History.app"
  echo new >"$dir/Applications/Goalong History.app/marker"
  HOME="$dir/Home" OPEN_LOG="$dir/open.log" TARGET="$dir/Applications/Goalong History.app" \
    GOALONG_LATE_QUIT_DIR="${3:-$dir/late}" GOALONG_LATE_RELAUNCH_WAIT_SECONDS=1 /bin/bash -c '
    source "$1"; shift
    LOG_FILE="$HOME/Library/Logs/i.log"; : >"$LOG_FILE"
    /usr/bin/open() {
      local seen; seen="$(/bin/cat "${@: -1}/marker" 2>/dev/null || echo none)"
      echo "open $* marker=$seen" >>"$OPEN_LOG"
      [[ "$seen" != "${OPEN_FAILS_FOR:-}" ]]
    }
    /bin/sleep() { command /bin/sleep 0.02; }
    TARGET_APP="$TARGET"
    trap cleanup EXIT
    eval "$1"' _ "$SCRIPT_DIR/install_from_source.sh" "$body" >"$dir/out.log" 2>&1 && echo 0 >"$dir/status" || echo $? >"$dir/status"
}
opens() { /bin/cat "$TEST_ROOT/$1/open.log" 2>/dev/null || true; }
status_of() { /bin/cat "$TEST_ROOT/$1/status"; }
marker_of() { /bin/cat "$TEST_ROOT/$1/Applications/Goalong History.app/marker" 2>/dev/null || echo none; }
wait_for_open() { # LOG_NAME TENTHS: 0 when an open appears
  local i; for (( i = 0; i < $2; i++ )); do [[ -s "$TEST_ROOT/$1/open.log" ]] && return 0; /bin/sleep 0.1; done; return 1
}
start_app() { /bin/sleep 300 & APP_PID=$!; APP_PIDS+=("$APP_PID"); }
# Replacement in progress: the old app is the backup (marker old), the new one is at the target (marker new).
REPLACED='/usr/bin/pgrep() { return 1; }; /usr/bin/pkill() { return 0; }
  quit_running_goalong "Goalong History"
  BACKUP_APP="$TARGET.bak"; INSTALL_STAGE_ROOT="$(dirname "$TARGET")/stage"; /bin/mkdir -p "$INSTALL_STAGE_ROOT" "$BACKUP_APP"
  echo old >"$BACKUP_APP/marker"; ORIGINAL_TARGET_PRESENT=1; REPLACEMENT_ACTIVE=1'

# 1. A step fails after the quit (under set -e): the app is reopened with -g -j, status kept.
run_case fail_after_quit '/usr/bin/pgrep() { return 1; }; /usr/bin/pkill() { return 0; }
  quit_running_goalong "Goalong History"; false'
grep -F -- 'open -g -j' <<<"$(opens fail_after_quit)" >/dev/null || fail "no background reopen after a failure post-quit: $(opens fail_after_quit)"
[[ "$(status_of fail_after_quit)" != 0 ]] || fail "failure status was swallowed"
[[ "$(opens fail_after_quit | wc -l | tr -d ' ')" == 1 ]] || fail "open called more than once"

# 2. Failure before the quit: no reopen (nothing was closed).
run_case fail_before_quit 'false'
[[ -z "$(opens fail_before_quit)" ]] || fail "reopened although Goalong was never asked to quit"

# 3. Rollback after a failed step: the OLD app is back at the target and it is the one opened.
run_case rollback "$REPLACED"'; false'
[[ "$(marker_of rollback)" == old ]] || fail "rollback left marker '$(marker_of rollback)' at the target"
[[ "$(opens rollback)" == *"-g -j"*"marker=old" ]] || fail "rollback did not open the old app: $(opens rollback)"

# 4. L1L2-05: the new app cannot be opened (3 tries): exit 1, old app put back and opened.
run_case open_fails "$REPLACED"'; OPEN_FAILS_FOR=new; complete_installation'
[[ "$(status_of open_fails)" == 1 ]] || fail "failed open of the new app did not fail the install: $(status_of open_fails)"
[[ "$(marker_of open_fails)" == old ]] || fail "failed open kept the new app (marker '$(marker_of open_fails)')"
[[ -d "$TEST_ROOT/open_fails/Applications/Goalong History.app.bak" ]] && fail "backup consumed but not restored"
[[ "$(opens open_fails | grep -c 'marker=new')" == 3 ]] || fail "new app not tried 3 times: $(opens open_fails)"
[[ "$(opens open_fails | tail -n 1)" == *"marker=old" ]] || fail "old app not reopened last: $(opens open_fails)"

# 5. Success: the new app is opened once, the backup removed, no rollback.
run_case success "$REPLACED"'; safe_remove_backup_bundle() { /bin/rm -rf "$1"; }
  remove_verified_legacy_bundle() { return 1; }; complete_installation'
[[ "$(status_of success)" == 0 ]] || fail "success path failed: $(cat "$TEST_ROOT/success/out.log")"
[[ "$(opens success)" == *"-g -j"*"marker=new" && "$(opens success | wc -l | tr -d ' ')" == 1 ]] || fail "success open: $(opens success)"
[[ "$(marker_of success)" == new ]] || fail "success rolled back"

# Password timeout: "Goalong" ignores SIGTERM. Exit 1, never SIGKILL, no reopen while it still runs.
TIMEOUT='export GOALONG_LOCAL_TRY=1 GOALONG_QUIT_WAIT_TENTHS=1 GOALONG_QUIT_PROMPT_WAIT_TENTHS=1
  /usr/bin/pgrep() { kill -0 "$APP_PID" 2>/dev/null && echo "$APP_PID"; }
  /usr/bin/pkill() { [[ "$1" != -KILL ]] || echo KILLED; return 0; }
  quit_running_goalong "Goalong History"'

# 6. L1L2-04: Goalong quits long after the old 120 s cap (here: cap set to 1 s, quit after 2 s): still reopened.
start_app; export APP_PID
run_case late_quit "$TIMEOUT"
[[ "$(status_of late_quit)" == 1 ]] || fail "timeout path did not exit 1"
grep -F KILLED "$TEST_ROOT/late_quit/out.log" >/dev/null && fail "timeout path force-killed Goalong"
[[ -z "$(opens late_quit)" ]] || fail "reopened while Goalong still runs: $(opens late_quit)"
/bin/sleep 2; [[ -z "$(opens late_quit)" ]] || fail "reopened while Goalong still runs (late)"
kill "$APP_PID"
wait_for_open late_quit 50 || fail "late quit after the old cap was not reopened"
[[ "$(opens late_quit)" == *"-g -j"* ]] || fail "late reopen not in background"

# 7. L1L2-04: a newer run takes the pending quit over; the old watcher never opens, the newer run does.
start_app; export APP_PID
run_case watcher_a "$TIMEOUT" "$TEST_ROOT/shared-late"
run_case run_b 'take_late_quit_obligation; [[ "$INHERITED_PIDS" == *"$APP_PID"* ]] || { echo no-inherit; exit 9; }
  kill "$APP_PID"; command /bin/sleep 1
  /usr/bin/pgrep() { return 1; }; /usr/bin/pkill() { return 0; }
  quit_running_goalong "Goalong History"; false' "$TEST_ROOT/shared-late"
[[ "$(status_of run_b)" == 1 ]] || fail "run B: $(cat "$TEST_ROOT/run_b/out.log")"
[[ -z "$(opens watcher_a)" ]] || fail "the superseded watcher reopened during run B: $(opens watcher_a)"
[[ "$(opens run_b | wc -l | tr -d ' ')" == 1 ]] || fail "run B must reopen exactly once: $(opens run_b)"

# 8. Run B takes the quit over but stops before quitting while Goalong still runs: it hands the duty back.
start_app; export APP_PID
run_case watcher_c "$TIMEOUT" "$TEST_ROOT/handback-late"
run_case run_d 'take_late_quit_obligation; false' "$TEST_ROOT/handback-late"
[[ -z "$(opens run_d)" ]] || fail "run D reopened while Goalong still runs"
kill "$APP_PID"
wait_for_open run_d 50 || fail "handed-back quit was not reopened"
[[ -z "$(opens watcher_c)" ]] || fail "superseded watcher C reopened"

# 10. F2: the duty taken over stays on disk (this run's own owner file): a run killed by SIGKILL after the
#     takeover leaves it to the next installation, which still reopens Goalong when it quits.
start_app; export APP_PID
run_case watcher_e "$TIMEOUT" "$TEST_ROOT/killed-late"
run_case run_f 'take_late_quit_obligation; kill -KILL $$' "$TEST_ROOT/killed-late"
run_case run_g 'take_late_quit_obligation; [[ "$INHERITED_PIDS" == *"$APP_PID"* ]] || { echo lost; exit 9; }; false' "$TEST_ROOT/killed-late"
[[ "$(status_of run_g)" == 1 ]] || fail "the duty of a run killed after the takeover was lost: $(cat "$TEST_ROOT/run_g/out.log")"
kill "$APP_PID"
wait_for_open run_g 50 || fail "the inherited quit was not reopened by the next run"
[[ -z "$(opens watcher_e)$(opens run_f)" ]] || fail "superseded watcher or killed run reopened"

# 11. F2: the takeover happens right before the quit, never before the build (a password typed during the build
#     is reopened by its own watcher).
awk '/^main\(\) \{/{m=1} m && /take_late_quit_obligation/{t=NR} m && /refuse_install_during_severe_block$/{r=NR}
  m && /^  quit_running_goalong /{q=NR} m && /run_step "Testing and building/{b=NR}
  END{exit !(t > r && t > b && t < q && q - t <= 2)}' "$SCRIPT_DIR/install_from_source.sh" \
  || fail "take_late_quit_obligation must sit right before quit_running_goalong, after the build and block check"

# 12. F3: a watcher that renames its owner file to `firing` during the takeover finishes its reopen before the
#     takeover returns; `firing` is never removed under it.
run_case firing_race '/bin/mkdir -p "$LATE_QUIT_DIR"; echo 1 >"$LATE_QUIT_DIR/owner.w"
  /bin/mv() { if [[ "$1" == */owner.w ]]; then command /bin/mv "$1" "$LATE_QUIT_DIR/firing"
      ( command /bin/sleep 1; command /bin/rm -f "$LATE_QUIT_DIR/firing" ) & return 1; fi; command /bin/mv "$@"; }
  take_late_quit_obligation
  [[ ! -e "$LATE_QUIT_DIR/firing" ]] || { echo still-firing; exit 9; }; exit 0'
[[ "$(status_of firing_race)" == 0 ]] || fail "takeover returned while a reopen was still firing: $(cat "$TEST_ROOT/firing_race/out.log")"

# 13. F6: a TERM while the new app opens never puts the old bundle back under the running new app.
run_case term_during_open "$REPLACED"'; safe_remove_backup_bundle() { /bin/rm -rf "$1"; }
  remove_verified_legacy_bundle() { return 1; }; trap "exit 143" TERM
  /usr/bin/open() { echo "open $* marker=$(/bin/cat "${@: -1}/marker")" >>"$OPEN_LOG"; kill -TERM $$; return 0; }
  complete_installation'
[[ "$(marker_of term_during_open)" == new ]] || fail "TERM during the open put the old app back (marker '$(marker_of term_during_open)')"
[[ "$(status_of term_during_open)" == 143 ]] || fail "deferred TERM not honoured: status $(status_of term_during_open)"
[[ "$(opens term_during_open | wc -l | tr -d ' ')" == 1 ]] || fail "TERM during open: $(opens term_during_open)"

# bugs-mise-a-jour-04: a perso build (Info.plist GoalongPersoBuiltAt) must prove its start: health.json written by
# the app this run opened, with a live Goalong pid and the bundle's build time. "Goalong" is APP_PID.
PERSO='/bin/mkdir -p "$TARGET/Contents" "$HOME/Library/Application Support/LocalHistory/PersoUpdate"
  printf "%s\n" "<?xml version=\"1.0\" encoding=\"UTF-8\"?>" "<plist version=\"1.0\"><dict><key>GoalongPersoBuiltAt</key><string>B1</string></dict></plist>" >"$TARGET/Contents/Info.plist"
  HEALTH="$HOME/Library/Application Support/LocalHistory/PersoUpdate/health.json"
  write_health() { printf "%s%s%s\n" "{\"pid\":" "$1" ",\"builtAt\":\"B1\"}" >"$HEALTH"; }
  safe_remove_backup_bundle() { /bin/rm -rf "$1"; }; remove_verified_legacy_bundle() { return 1; }
  /usr/bin/pgrep() { kill -0 "$APP_PID" 2>/dev/null && echo "$APP_PID"; }
  /usr/bin/pkill() { [[ "$1" != -KILL ]] || echo KILLED; return 0; }
  export GOALONG_INSTALL_HEALTH_TENTHS=5 GOALONG_QUIT_WAIT_TENTHS=2'
perso_open() { # what the fake open of the new app does: BODY run once the open is logged
  echo '/usr/bin/open() { local seen; seen="$(/bin/cat "${@: -1}/marker")"; echo "open $* marker=$seen" >>"$OPEN_LOG"; [[ "$seen" != new ]] || { '"$1"'; }; return 0; }'
}

# 14. The new app writes its health: installation finalized, backup removed.
start_app; export APP_PID
run_case perso_healthy "$REPLACED; $PERSO; $(perso_open 'write_health "$APP_PID"'); complete_installation"
[[ "$(status_of perso_healthy)" == 0 ]] || fail "healthy perso install failed: $(cat "$TEST_ROOT/perso_healthy/out.log")"
[[ "$(marker_of perso_healthy)" == new && ! -d "$TEST_ROOT/perso_healthy/Applications/Goalong History.app.bak" ]] || fail "healthy perso install not finalized"
kill "$APP_PID"

# 15. A stale health (live pid, same build) from before the open does not count; no new health, the new app
#     quits on SIGTERM: old app put back and opened, never SIGKILL.
start_app; export APP_PID
run_case perso_stale "$REPLACED; $PERSO"'; write_health "$APP_PID"
  /usr/bin/pkill() { [[ "$1" != -KILL ]] || echo KILLED; : >"$HOME/quit"; return 0; }
  /usr/bin/pgrep() { [[ ! -e "$HOME/quit" ]] && echo "$APP_PID"; }'"; $(perso_open ':'); complete_installation"
[[ "$(status_of perso_stale)" == 1 ]] || fail "stale health accepted: $(cat "$TEST_ROOT/perso_stale/out.log")"
[[ "$(marker_of perso_stale)" == old ]] || fail "unproven perso install kept the new app: $(cat "$TEST_ROOT/perso_stale/out.log"; opens perso_stale)"
[[ "$(opens perso_stale | tail -n 1)" == *"marker=old" ]] || fail "old app not reopened: $(opens perso_stale)"
grep -F KILLED "$TEST_ROOT/perso_stale/out.log" >/dev/null && fail "unhealthy new app force-killed"
kill "$APP_PID"

# 16. The new app dies at start (no Goalong left, no health): old app put back and opened.
run_case perso_died "$REPLACED; $PERSO; APP_PID=99999999; GOALONG_INSTALL_HEALTH_TENTHS=200; $(perso_open ':'); complete_installation"
[[ "$(status_of perso_died)" == 1 && "$(marker_of perso_died)" == old ]] || fail "dead new app kept: $(cat "$TEST_ROOT/perso_died/out.log")"
[[ "$(opens perso_died | tail -n 1)" == *"marker=old" ]] || fail "old app not reopened after a dead start: $(opens perso_died)"

# 17. No health and the new app refuses to quit (a protection): it keeps running, never forced; the backup stays
#     beside it and the old app is never put back under it.
start_app; export APP_PID
run_case perso_stays "$REPLACED; $PERSO; $(perso_open ':'); complete_installation"
[[ "$(status_of perso_stays)" == 1 && "$(marker_of perso_stays)" == new ]] || fail "running new app replaced: $(cat "$TEST_ROOT/perso_stays/out.log")"
[[ -d "$TEST_ROOT/perso_stays/Applications/Goalong History.app.bak" ]] || fail "backup removed although the start was never proven"
[[ "$(opens perso_stays | wc -l | tr -d ' ')" == 1 ]] || fail "old app opened over the running new one: $(opens perso_stays)"
grep -F KILLED "$TEST_ROOT/perso_stays/out.log" >/dev/null && fail "refusing new app force-killed"
kill "$APP_PID"

# 9. No plain `open` left in the installer.
grep -nE '/usr/bin/open( |$)' "$SCRIPT_DIR/install_from_source.sh" | grep -v -- '-g -j' && fail "foreground open in installer"
echo "test_install_relaunch: OK"
