#!/bin/bash
# One entry for the three ways to run the Swift tests on this Mac (see `make check|test|test-ui`).
#   check [FILTER]  fast loop: incremental build + filtered tests, slow tests left out
#   full            whole suite, then the skipped-test report (unknown skip = failure)
#   ui              render and AX opt-ins (GOALONG_*_SNAPSHOTS, *_UI_TESTS), no visible window
# Every mode runs in a throwaway HOME, so no test can read or write the real LocalHistory folder or
# leave preference files in ~/Library/Preferences. Set GOALONG_TESTS_VISIBLE=1 to watch windows.
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
swift_test() { xcrun swift test --disable-keychain "$@" 2>&1 | tee -a "$log"; return "${PIPESTATUS[0]}"; }
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

case "$mode" in
  check)
    filter="${1:-${FILTER:-}}"
    args=()
    if [[ -n "$filter" ]]; then
      args+=(--filter "$filter")
      echo "make check: tests matching '$filter'"
    else
      targets=(); classes=(); fast=0
      # The loop looks at what you are changing now (uncommitted + untracked). With a clean tree it
      # falls back to the whole branch vs origin/main (large on a long branch: then use FILTER=).
      changed="$( { git diff --name-only HEAD 2>/dev/null; git ls-files --others --exclude-standard 2>/dev/null; } | sort -u)"
      scope="uncommitted files"
      if [[ -n "${GOALONG_CHECK_CHANGED+x}" ]]; then   # test hook: a fixed list of changed files
        changed="$(printf '%s\n' $GOALONG_CHECK_CHANGED)"; scope="GOALONG_CHECK_CHANGED"
      elif [[ -z "$changed" ]]; then
        changed="$(git diff --name-only origin/main...HEAD 2>/dev/null | sort -u)"; scope="files changed vs origin/main"
      fi
      add() { [[ " ${targets[*]-} " == *" $1 "* ]] || targets+=("$1"); }
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
          Package.swift|Package.resolved|Makefile|scripts/*) fast=1 ;;
          Tests/LocalHistoryCoreTests/*) add LocalHistoryCoreTests ;;
          Tests/LocalHistoryAppTests/*|Sources/LocalHistoryApp/*) add LocalHistoryAppTests ;;
          Tests/LocalHistoryQueryCLITests/*) add LocalHistoryQueryCLITests ;;
          Sources/LocalHistoryQueryCLI/*) add LocalHistoryQueryCLITests; add LocalHistoryAppTests ;;
          Features/AgentActivity/*) add AgentActivityTests; add LocalHistoryQueryCLITests; add LocalHistoryAppTests ;;
          Features/AppleScreenTime/*) add AppleScreenTimeTests; add LocalHistoryQueryCLITests; add LocalHistoryAppTests ;;
          Features/AppleSystemScreenTime/*) add LocalHistoryQueryCLITests; add LocalHistoryAppTests ;;
          Features/Ambiance/*) add AmbianceTests; add LocalHistoryAppTests ;;
          Features/Braise/*) add BraiseCoreTests; add LocalHistoryQueryCLITests; add LocalHistoryAppTests ;;
        esac
      done <<< "$changed"
      if [[ $fast -eq 1 ]]; then add LocalHistoryCoreTests; add LocalHistoryAppTests; fi
      patterns=()
      [[ ${#targets[@]} -gt 0 ]] && patterns+=("^($(IFS='|'; echo "${targets[*]}"))\\.")
      [[ ${#classes[@]} -gt 0 ]] && patterns+=("\\.($(IFS='|'; echo "${classes[*]}"))/")
      if [[ ${#patterns[@]} -eq 0 ]]; then
        patterns=('^(LocalHistoryCoreTests|LocalHistoryAppTests)\.')
        echo "make check: no mapped change, running the fast Core and App tests"
      else
        echo "make check: from the $scope. targets: ${targets[*]-none}; test classes: ${classes[*]-none}"
      fi
      regex="$(IFS='|'; echo "${patterns[*]}")"
      args+=(--filter "$regex")
      if [[ -n "${GOALONG_CHECK_DRY_RUN:-}" ]]; then echo "filter-regex: $regex"; exit 0; fi
    fi
    for slow in "${SLOW_TESTS[@]}"; do args+=(--skip "$slow"); done
    echo "Slow tests left out (run by make test): ${#SLOW_TESTS[@]}"
    report_screen
    swift_test "${args[@]}"; status=$?
    elapsed
    [[ $status -ne 0 ]] && exit "$status"
    ran="$(executed_count "$log")"
    echo "Tests executed: $ran"
    if [[ "$ran" -eq 0 ]]; then
      echo "error: make check ran 0 tests: the filter matched nothing. Use FILTER=<Class> or make test." >&2
      exit 1
    fi
    exit 0
    ;;
  full)
    report_screen
    swift_test; status=$?
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
        xcrun swift test --disable-keychain --filter "$classes" 2>&1 | tee -a "$log" "$group_log"; exit "${PIPESTATUS[0]}"
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
  *) echo "usage: $0 check [FILTER] | full | ui" >&2; exit 2 ;;
esac
