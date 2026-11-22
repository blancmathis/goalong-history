#!/bin/bash
# One entry for the three ways to run the Swift tests on this Mac (see `make check|test|test-ui`).
#   check [FILTER]  fast loop: incremental build + filtered tests, slow tests left out
#   full [ARGS]     whole suite (ARGS go to swift test, e.g. --sanitize=thread), then the skipped-test report
#   ui              render and AX opt-ins (GOALONG_*_SNAPSHOTS, *_UI_TESTS), no visible window
# Every mode runs in a throwaway HOME, so no test can read or write the real LocalHistory folder or
# leave preference files in ~/Library/Preferences. Every mode runs under the window guard: a test
# window on screen or a focus change fails the run. Set GOALONG_TESTS_VISIBLE=1 to watch windows.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2
mode="${1:-}"; shift || true

# Slow on purpose (10k sources 48 s, compaction 19 s, 10k metadata 9 s): run by `make test`, never by `make check`.
# They compare counts and cursors, never elapsed time, so they are not flaky; they are only long.
SLOW_TESTS=(
  'AgentActivityScannerLoadTests/testTenThousandSources'
  'ComputerHistoryStoreStorageTests/testLoadRecentCompactsLegacyUnboundedAnalysisAfterValidatedRead'
  'AgentActivityMetadataPrivacyTests/testTenThousandLongMetadataEntries'
  'ComputerHistoryMemoryCompactionTests/testTenThousandActions'
  'ComputerHistoryMemoryCompactionTests/testFragmentedDay'
)
# Elapsed-time budgets: they fail under load (a busy Mac, a parallel build) and also on main. `make test` and the
# CI run them; `make check` runs them only when named (FILTER or a changed test file), so its green means green.
BUDGET_TESTS=(ViewSwitchBudgetTests)
# Always run when make check picks App test classes by type (C1): screens still render, blocking still holds.
SMOKE_TESTS=(GallerySmokeTests BlockingGuardTests)
# More App classes than this for a change: run the whole App target instead.
APP_CLASS_LIMIT=60

screen_state() {
  local locked
  locked="$(/usr/sbin/ioreg -n Root -d1 -w0 2>/dev/null | grep -o '"IOConsoleLocked" = [A-Za-z]*' | awk '{print $3}')"
  case "$locked" in
    Yes) echo locked ;;
    No) echo unlocked ;;
    *) echo unknown ;;
  esac
}

report_screen() {
  case "$(screen_state)" in
    locked) echo "SCREEN LOCKED: tests that need a window session or AX (foreground, AX, display) skip or fail. Unlock the Mac and run again." ;;
    unlocked) echo "Screen: unlocked (AX and window-session tests can run)." ;;
    *) echo "Screen: lock state unknown (could not read IOConsoleLocked)." ;;
  esac
}

home="$(mktemp -d /tmp/goalong-test-XXXXXX)"
log="$(mktemp /tmp/goalong-test-log-XXXXXX)"
cleanup() { rm -rf "$home" "$log"; }
trap cleanup EXIT
start=$SECONDS
export GOALONG_TEST_HOME="$home" CFFIXED_USER_HOME="$home"
# --disable-keychain: under the isolated HOME, SwiftPM misses its shared cache. A fresh worktree then downloads
# the Sparkle artifact, and the keychain lookup for github.com opens a modal prompt that waits forever.
swift_test() { guarded xcrun swift test --disable-keychain "$@" 2>&1 | tee -a "$log"; return "${PIPESTATUS[0]}"; }
# Window guard (scripts/window_guard.swift): no test may show a window or take the focus on this Mac.
# It watches the command and its children through the window server every 50 ms; a visible window
# or a focus change kills the offender at once and fails the run. GOALONG_TESTS_VISIBLE=1 turns it off.
window_guard_bin() {
  local bin="$ROOT/.build/window-guard/window_guard" src="$ROOT/scripts/window_guard.swift"
  if [[ ! -x "$bin" || "$src" -nt "$bin" ]]; then
    mkdir -p "${bin%/*}" && xcrun swiftc -O "$src" -o "$bin.$$" && mv "$bin.$$" "$bin" || return 1
  fi
  echo "$bin"
}
guarded() { # command...
  if [[ "$(printenv GOALONG_TESTS_VISIBLE)" == 1 ]]; then "$@"; return; fi
  local bin pid gpid status
  bin="$(window_guard_bin)" || { echo "error: scripts/window_guard.swift did not compile" >&2; return 1; }
  "$@" & pid=$!
  "$bin" watch "$pid" & gpid=$!
  wait "$pid"; status=$?
  if ! wait "$gpid"; then
    echo "error: a test window was visible or took the focus (window guard)" >&2
    [[ $status -eq 0 ]] && status=1
  fi
  return "$status"
}
# Highest "Executed N test(s)" in a log: the final XCTest total. 0 also when nothing ran at all.
executed_count() {
  grep -oE 'Executed [0-9]+ tests?' "$1" 2>/dev/null | awk '{ if ($2 > max) max = $2 } END { print max + 0 }'
}
# Classes declared in a test file (a file name often differs from its classes).
classes_in() {
  # Optional attributes (@MainActor) and modifiers (final, private, fileprivate, ...) before `class`.
  grep -oE '^[[:space:]]*(@[A-Za-z0-9_]+(\([^)]*\))?[[:space:]]+)*((final|public|open|internal|private|fileprivate)[[:space:]]+)*class [A-Za-z0-9_]+[[:space:]]*:[[:space:]]*[A-Za-z0-9_.]*(XCTestCase|TestCase|Tests)' "$1" 2>/dev/null \
    | sed -E 's/^.*class ([A-Za-z0-9_]+).*$/\1/'
}
# The last verdict of `make test-ui`: skips on a locked screen are not a pass (exit 1), they only
# explain themselves. Skips on an unlocked screen are a failure too. 0 skips: pass.
# Top-level types a Swift file declares for other files (private and nested types left out).
declared_types() {
  grep -oE '^[[:space:]]*(@[A-Za-z0-9_]+(\([^)]*\))?[[:space:]]+)*((public|internal|package|final|open|indirect|nonisolated)[[:space:]]+)*(class|struct|enum|actor|protocol)[[:space:]]+[A-Z][A-Za-z0-9_]*' \
    | sed -E 's/.*(class|struct|enum|actor|protocol)[[:space:]]+//'
}
# App test classes for changed app sources: the tests that name a type the file declares (or extends,
# when the type is ours) or the file's own name. Exit 1 = cannot map (deleted file, no type): whole target.
app_test_classes() { # source files...
  local f t tf ours types=() re
  ours="$(cat Sources/LocalHistoryApp/*.swift Sources/LocalHistoryApp/*/*.swift Sources/LocalHistoryApp/*/*/*.swift Sources/GoalongGuardCore/*.swift 2>/dev/null | declared_types | sort -u)"
  for f in "$@"; do
    [[ -f "$f" ]] || return 1
    local found
    found="$( { declared_types <"$f"; grep -oE '^[[:space:]]*((public|internal)[[:space:]]+)?extension[[:space:]]+[A-Z][A-Za-z0-9_]*' "$f" | sed -E 's/.*extension[[:space:]]+//' | grep -Fx "$ours"; } | sort -u)"
    [[ -n "$found" ]] || return 1
    while IFS= read -r t; do types+=("$t"); done <<<"$found"
    t="${f##*/}"; types+=("${t%.swift}")
  done
  re="$(printf '%s\n' "${types[@]}" | sort -u | paste -sd'|' -)"
  grep -rlwE --include='*.swift' "($re)" Tests/LocalHistoryAppTests | while IFS= read -r tf; do
    classes_in "$tf"
    grep -oE '^extension [A-Za-z0-9_]+Tests\b' "$tf" | awk '{print $2}'
  done | sort -u
  return 0 # a grep without match in the loop is not a failure
}
ui_verdict() { # skips screen-state
  local skips="$1" state="$2"
  if [[ "$skips" -gt 0 ]]; then
    if [[ "$state" == locked ]]; then
      echo "error: $skips opt-in UI test(s) skipped while the screen was locked: this is not a proof. Unlock the Mac and run again." >&2
    else
      echo "error: opt-in UI tests skipped although their variables are set" >&2
    fi
    return 1
  fi
  return 0
}
elapsed() { echo "Duration: $((SECONDS - start)) s"; }
# make check prints only what matters (build errors, failed tests, window guard, totals); the whole log stays on disk.
summarize_log() { # log
  grep -E "error:|: error|' failed \(|Fatal error|fatal error|\[headless-tests\] VISIBLE|window guard" "$1" | head -60
  # The highest total (the last line may be a bundle with 0 tests).
  grep -E 'Executed [0-9]+ tests?' "$1" | awk '{ n = $2 + 0; if (n >= max) { max = n; line = $0 } } END { if (line != "") print line }'
}

case "$mode" in
  check)
    filter="${1:-${FILTER:-}}"
    args=(); classes=()
    # The whole log stays on disk (make perso passes its own path); the screen gets a short summary.
    check_log="${GOALONG_CHECK_LOG:-$ROOT/.build/goalong-check/last.log}"
    # A dry run (the selector self-test calls this script many times) never touches the log.
    [[ -n "${GOALONG_CHECK_DRY_RUN:-}" ]] || { mkdir -p "${check_log%/*}" && : >"$check_log"; } || exit 2
    if [[ -n "$filter" ]]; then
      args+=(--filter "$filter")
      echo "make check: tests matching '$filter'"
    else
      targets=(); script_checks=(); app_sources=(); fast=0
      # The loop looks at what you are changing now (uncommitted + untracked). With a clean tree it
      # looks at the commits since a base: GOALONG_CHECK_BASE, else the commit of the installed perso
      # build (GoalongPersoSourceCommit, already tested and installed) when HEAD descends from it,
      # else origin/main.
      changed="$( { git diff --name-only HEAD 2>/dev/null; git ls-files --others --exclude-standard 2>/dev/null; } | sort -u)"
      scope="uncommitted files"
      if [[ -n "${GOALONG_CHECK_CHANGED+x}" ]]; then   # test hook: a fixed list of changed files
        changed="$(printf '%s\n' $GOALONG_CHECK_CHANGED)"; scope="GOALONG_CHECK_CHANGED"
      elif [[ -z "$changed" ]]; then
        base="${GOALONG_CHECK_BASE:-}" base_name="GOALONG_CHECK_BASE"
        if [[ -z "$base" ]]; then
          base="origin/main" base_name="origin/main"
          for app in "/Applications/Goalong History.app" "$HOME/Applications/Goalong History.app"; do
            installed="$(/usr/libexec/PlistBuddy -c 'Print :GoalongPersoSourceCommit' "$app/Contents/Info.plist" 2>/dev/null || true)"
            if [[ -n "$installed" ]] && git merge-base --is-ancestor "$installed" HEAD 2>/dev/null; then
              base="$installed" base_name="installed perso build ${installed:0:8}"; break
            fi
          done
        fi
        changed="$(git diff --name-only "$base...HEAD" 2>/dev/null | sort -u)"; scope="files changed since $base_name"
      fi
      add() { [[ " ${targets[*]-} " == *" $1 "* ]] || targets+=("$1"); }
      add_script() { [[ " ${script_checks[*]-} " == *" $1 "* ]] || script_checks+=("$1"); }
      # A script change runs its own shell tests (scripts/test_<name>*.sh|py), not the Swift suite.
      # No test of its own: a syntax check. The PR to main still runs everything in CI.
      map_script() { # path
        local f="$1" name stem t found=0
        [[ -e "$f" ]] || return 0   # deleted
        name="${f##*/}"
        case "$name" in test_*.sh|test_*.py) add_script "$f"; return ;; esac
        stem="${name%.*}"; stem="${stem#test_}"
        [[ "$stem" == window_guard ]] && stem=run_swift_tests
        for t in scripts/test_"$stem"*.sh scripts/test_"$stem"*.py; do
          [[ -f "$t" ]] && { add_script "$t"; found=1; }
        done
        [[ $found -eq 1 ]] || add_script "syntax:$f"
      }
      while IFS= read -r file; do
        case "$file" in
          Tests/LocalHistoryCoreTests/*Tests.swift|Tests/LocalHistoryAppTests/*Tests.swift|Tests/LocalHistoryQueryCLITests/*Tests.swift|Features/*/Tests/*Tests.swift)
            # A changed test file runs the classes it declares; no class found: its whole target.
            found="$(classes_in "$file")"
            if [[ -n "$found" ]]; then
              while IFS= read -r cls; do classes+=("$cls"); done <<< "$found"
            else
              case "$file" in
                Tests/LocalHistoryCoreTests/*) add LocalHistoryCoreTests ;;
                Tests/LocalHistoryAppTests/*) add LocalHistoryAppTests ;;
                Tests/LocalHistoryQueryCLITests/*) add LocalHistoryQueryCLITests ;;
                Features/AgentActivity/*) add AgentActivityTests ;;
                Features/AppleScreenTime/*) add AppleScreenTimeTests ;;
                Features/Ambiance/*) add AmbianceTests ;;
                Features/Braise/*) add BraiseCoreTests ;;
              esac
            fi ;;
          # A source change runs its own tests and the tests of every target that imports it
          # (Package.swift graph: Core <- AgentActivity <- QueryCLI <- App; features <- App).
          Sources/LocalHistoryCore/*) add LocalHistoryCoreTests; add AgentActivityTests; add LocalHistoryAppTests; add LocalHistoryQueryCLITests ;;
          Package.swift|Package.resolved) fast=1 ;;
          Makefile) add_script "make:Makefile" ;;
          scripts/expected_skips.txt) ;;   # data of make test (skip allowlist)
          scripts/*) map_script "$file" ;;
          Sources/GoalongGuardCore/*.swift) add GoalongGuardCoreTests; app_sources+=("$file") ;;
          Sources/GoalongRelauncher/*|Sources/GoalongGuard/*|Sources/GoalongGuardTestHost/*) add GoalongGuardCoreTests ;;
          Tests/LocalHistoryCoreTests/*) add LocalHistoryCoreTests ;;
          Sources/LocalHistoryApp/*.swift) app_sources+=("$file") ;;   # App classes by type, below
          Tests/LocalHistoryAppTests/*|Sources/LocalHistoryApp/*) add LocalHistoryAppTests ;;
          Tests/LocalHistoryQueryCLITests/*) add LocalHistoryQueryCLITests ;;
          Sources/LocalHistoryQueryCLI/*) add LocalHistoryQueryCLITests; add LocalHistoryAppTests ;;
          Features/AgentActivity/*) add AgentActivityTests; add LocalHistoryQueryCLITests; add LocalHistoryAppTests ;;
          Features/AppleScreenTime/*) add AppleScreenTimeTests; add LocalHistoryQueryCLITests; add LocalHistoryAppTests ;;
          Features/AppleSystemScreenTime/*) add LocalHistoryQueryCLITests; add LocalHistoryAppTests ;;
          Features/Ambiance/*) add AmbianceTests; add LocalHistoryAppTests ;;
          Features/Braise/*) add BraiseCoreTests; add LocalHistoryQueryCLITests; add LocalHistoryAppTests ;;
          Tests/GoalongGuardCoreTests/*) add GoalongGuardCoreTests ;;
          Sources/*|Tests/*|Features/*) fast=1 ;;   # not mapped: the fast Core and App tests
        esac
      done <<< "$changed"
      if [[ $fast -eq 1 ]]; then add LocalHistoryCoreTests; add LocalHistoryAppTests; fi
      if [[ ${#app_sources[@]} -gt 0 && " ${targets[*]-} " != *" LocalHistoryAppTests "* ]]; then
        if mapped="$(app_test_classes "${app_sources[@]}")"; then
          count="$(grep -c . <<<"$mapped")"
          if [[ "$count" -gt "$APP_CLASS_LIMIT" ]]; then
            echo "make check: $count App test classes name the changed types (> $APP_CLASS_LIMIT): whole App target"
            add LocalHistoryAppTests
          else
            while IFS= read -r cls; do [[ -n "$cls" ]] && classes+=("$cls"); done <<<"$mapped"
            classes+=("${SMOKE_TESTS[@]}")
          fi
        else
          echo "make check: a changed App source is deleted or declares no type: whole App target"
          add LocalHistoryAppTests
        fi
      fi
      [[ ${#classes[@]} -gt 0 ]] && classes=($(printf '%s\n' "${classes[@]}" | sort -u))
      patterns=()
      [[ ${#targets[@]} -gt 0 ]] && patterns+=("^($(IFS='|'; echo "${targets[*]}"))\\.")
      [[ ${#classes[@]} -gt 0 ]] && patterns+=("\\.($(IFS='|'; echo "${classes[*]}"))/")
      if [[ ${#patterns[@]} -eq 0 && ${#script_checks[@]} -eq 0 ]]; then
        # Nothing that builds into the app changed (docs, notes, or nothing since the installed build).
        classes=("${SMOKE_TESTS[@]}")
        patterns=("\\.($(IFS='|'; echo "${classes[*]}"))/")
        echo "make check: no code change in the $scope: smoke tests only (${classes[*]})"
      else
        echo "make check: from the $scope. targets: ${targets[*]-none}; test classes: ${classes[*]-none}; script checks: ${script_checks[*]-none}"
      fi
      regex=""
      if [[ ${#patterns[@]} -gt 0 ]]; then regex="$(IFS='|'; echo "${patterns[*]}")"; args+=(--filter "$regex"); fi
      if [[ -n "${GOALONG_CHECK_DRY_RUN:-}" ]]; then echo "filter-regex: $regex"; echo "script-checks: ${script_checks[*]-}"; exit 0; fi
      if [[ ${#script_checks[@]} -gt 0 ]]; then
        echo "Full log: $check_log"
        sstatus=0
        # Like make test: the real environment, not the throwaway test home of the Swift run, and none of
        # the settings of this run or of make perso (a nested make local fixture would inherit them).
        clean_env=(env -u GOALONG_TEST_HOME -u CFFIXED_USER_HOME -u GOALONG_CHECK_LOG -u GOALONG_CHECK_BASE
          -u GOALONG_CHECK_CHANGED -u GOALONG_LOCAL_PERSO -u GOALONG_LOCAL_NO_INSTALL -u GOALONG_LOCAL_OUT
          -u GOALONG_PERSO_TEST_FILTER -u LOCALHISTORY_LOCAL_TRY_BASE)
        for chk in "${script_checks[@]}"; do
          echo "---- script check $chk" >>"$check_log"; from_line="$(wc -l <"$check_log")"
          case "$chk" in
            make:*) make -n -f "${chk#make:}" check test perso >>"$check_log" 2>&1 ;;
            syntax:*.sh) bash -n "${chk#syntax:}" >>"$check_log" 2>&1 ;;
            syntax:*.py) python3 -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' "${chk#syntax:}" >>"$check_log" 2>&1 ;;
            syntax:*) echo "not checked (no test, no syntax check): ${chk#syntax:}"; continue ;;
            *.py) "${clean_env[@]}" python3 "$chk" >>"$check_log" 2>&1 ;;
            *) "${clean_env[@]}" bash "$chk" >>"$check_log" 2>&1 ;;
          esac
          if [[ $? -eq 0 ]]; then echo "script check ok: $chk"
          else
            echo "script check FAILED: $chk" >&2; sstatus=1
            tail -n "+$((from_line + 1))" "$check_log" | grep -vE '^ok: ' | tail -15 >&2
          fi
        done
        if [[ -z "$regex" ]]; then
          elapsed
          [[ $sstatus -ne 0 ]] && { echo "make check FAILED. Full log: $check_log" >&2; exit 1; }
          exit 0
        fi
        [[ $sstatus -ne 0 ]] && { elapsed; echo "make check FAILED. Full log: $check_log" >&2; exit 1; }
      fi
    fi
    for slow in "${SLOW_TESTS[@]}"; do args+=(--skip "$slow"); done
    budget_out=()
    for cls in "${BUDGET_TESTS[@]}"; do
      [[ " ${classes[*]-} " == *" $cls "* || "$filter" == *"$cls"* ]] && continue
      args+=(--skip "$cls"); budget_out+=("$cls")
    done
    echo "Left out (run by make test): ${#SLOW_TESTS[@]} slow tests; time budgets: ${budget_out[*]-none}"
    report_screen
    echo "Full log: $check_log"
    guarded xcrun swift test --disable-keychain "${args[@]}" >>"$check_log" 2>&1; status=$?
    summarize_log "$check_log"
    elapsed
    [[ $status -ne 0 ]] && { echo "make check FAILED (exit $status). Full log: $check_log" >&2; exit "$status"; }
    ran="$(executed_count "$check_log")"
    echo "Tests executed: $ran"
    if [[ "$ran" -eq 0 ]]; then
      echo "error: make check ran 0 tests: the filter matched nothing. Use FILTER=<Class> or make test." >&2
      exit 1
    fi
    exit 0
    ;;
  full)
    report_screen
    swift_test "$@"; status=$?   # extra swift test flags, e.g. --sanitize=thread --scratch-path .build-tsan
    echo "----"
    python3 scripts/skip_report.py "$log"; report=$?
    elapsed
    [[ $status -ne 0 ]] && exit "$status"
    exit "$report"
    ;;
  ui)
    out="$(mktemp -d /tmp/goalong-test-ui-XXXXXX)"
    report_screen
    state="$(screen_state)"
    status=0
    # Three groups, each in its own throwaway home: the brand and design-audit renders refuse any
    # home that is not /tmp/goalong-brand-*, and the sharing render wants /tmp/goalong-sharing-home-*.
    run_group() { # name home-prefix classes
      local name="$1" prefix="$2" classes="$3" group_home group_log="$(mktemp /tmp/goalong-test-group-XXXXXX)"
      group_home="$(mktemp -d "/tmp/$prefix-XXXXXX")"
      echo "---- make test-ui group $name"
      (
        # No HOME override (it would invalidate the SwiftPM and clang caches): CFFIXED_USER_HOME is enough.
        export GOALONG_TEST_HOME="$group_home" CFFIXED_USER_HOME="$group_home"
        export -n GOALONG_TESTS_VISIBLE  # this target promises no visible window
        export GOALONG_BRAND_TEST_HOME="$group_home" GOALONG_SHARING_TEST_HOME="$group_home"
        export GOALONG_BRAND_SNAPSHOTS="$out/brand" GOALONG_DESIGN_AUDIT="$out/design-audit"
        export GOALONG_SHARING_SNAPSHOTS="$out/sharing"
        for pair in BRAISE:braise AMBIANCE:ambiance CONCENTRATION_HUB:concentration-hub BLOCKING:blocking \
          ANALYTICS:analytics JEV_CONTEXT:jev-context JEV_EFFECTS:jev-effects MENUBAR:menubar \
          CONCENTRATION:concentration TIMER:timer; do
          mkdir -p "$out/${pair#*:}"; export "GOALONG_${pair%%:*}_SNAPSHOTS=$out/${pair#*:}"
        done
        mkdir -p "$out/brand" "$out/design-audit" "$out/sharing" "$out/focus-ui"
        export GOALONG_FOCUS_UI_TESTS=1 GOALONG_FOCUS_UI_SNAPSHOT="$out/focus-ui/disclosures-expanded.png" GOALONG_BLOCKING_UI_TESTS=1
        guarded xcrun swift test --disable-keychain --filter "$classes" 2>&1 | tee -a "$log" "$group_log"; exit "${PIPESTATUS[0]}"
      ) || status=$?
      # A group must really have run: some tests, and every expected class in its log.
      if [[ "$(executed_count "$group_log")" -eq 0 ]]; then
        echo "error: make test-ui group $name executed 0 tests" >&2; status=1
      fi
      local cls
      for cls in ${classes//|/ }; do
        grep -q "Test Suite '$cls' started" "$group_log" || { echo "error: make test-ui group $name: class $cls never ran (renamed or removed?)" >&2; status=1; }
      done
      rm -f "$group_log"
      rm -rf "$group_home"
    }
    run_group brand goalong-brand 'GoalongBrandRenderingTests|GoalongTrustRenderingTests|GoalongDesignAuditRenderingTests|GoalongControlsInteractionTests'
    run_group sharing goalong-sharing-home 'GoalongWebsiteSharingRenderingTests'
    run_group other goalong-test 'BraisePageRenderingTests|AmbiancePageRenderingTests|ConcentrationHubRenderingTests|BlockingPageRenderingTests|GoalongAnalyticsRenderingTests|JevProcrastinationRenderingTests|JevEffectsRenderingTests|GoalongDisclosureInteractionTests|MenuBarPanelRenderingTests|BlockingActivationRegressionTests|ConcentrationRenderingTests|BlockingTimerTests'
    echo "----"
    skips="$(grep -c "' skipped (" "$log" || true)"
    echo "Render output: $out"
    echo "Skipped inside make test-ui: $skips"
    if [[ "$skips" -gt 0 ]]; then grep "Test skipped" "$log" | sed 's/^.*-\[/  -[/'; fi
    elapsed
    [[ $status -ne 0 ]] && exit "$status"
    ui_verdict "$skips" "$state"
    exit $?
    ;;
  classes-in) classes_in "${1:?file}"; exit 0 ;;   # test hook
  ui-verdict) ui_verdict "${1:?skips}" "${2:?state}"; exit $? ;;   # test hook
  window-guard-bin) window_guard_bin; exit $? ;;   # test hook
  *) echo "usage: $0 check [FILTER] | full | ui" >&2; exit 2 ;;
esac
