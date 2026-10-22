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
swift_test() { xcrun swift test "$@" 2>&1 | tee -a "$log"; return "${PIPESTATUS[0]}"; }
elapsed() { echo "Duration: $((SECONDS - start)) s"; }

case "$mode" in
  check)
    filter="${1:-${FILTER:-}}"
    args=()
    if [[ -n "$filter" ]]; then
      args+=(--filter "$filter")
      echo "make check: tests matching '$filter'"
    else
      targets=(); classes=()
      # The loop looks at what you are changing now (uncommitted + untracked). With a clean tree it
      # falls back to the whole branch vs origin/main (large on a long branch: then use FILTER=).
      changed="$( { git diff --name-only HEAD 2>/dev/null; git ls-files --others --exclude-standard 2>/dev/null; } | sort -u)"
      scope="uncommitted files"
      if [[ -z "$changed" ]]; then
        changed="$(git diff --name-only origin/main...HEAD 2>/dev/null | sort -u)"; scope="files changed vs origin/main"
      fi
      add() { [[ " ${targets[*]-} " == *" $1 "* ]] || targets+=("$1"); }
      while IFS= read -r file; do
        case "$file" in
          Tests/LocalHistoryCoreTests/*Tests.swift|Tests/LocalHistoryAppTests/*Tests.swift|Tests/LocalHistoryQueryCLITests/*Tests.swift|Features/*/Tests/*Tests.swift)
            classes+=("$(basename "$file" .swift)") ;;  # a changed test file runs its own class
          Tests/LocalHistoryCoreTests/*|Sources/LocalHistoryCore/*) add LocalHistoryCoreTests ;;
          Tests/LocalHistoryAppTests/*|Sources/LocalHistoryApp/*) add LocalHistoryAppTests ;;
          Tests/LocalHistoryQueryCLITests/*|Sources/LocalHistoryQueryCLI/*) add LocalHistoryQueryCLITests ;;
          Features/AgentActivity/*) add AgentActivityTests ;;
          Features/AppleScreenTime/*) add AppleScreenTimeTests ;;
          Features/Ambiance/*) add AmbianceTests ;;
          Features/Braise/*) add BraiseCoreTests ;;
        esac
      done <<< "$changed"
      patterns=()
      [[ ${#targets[@]} -gt 0 ]] && patterns+=("^($(IFS='|'; echo "${targets[*]}"))\\.")
      [[ ${#classes[@]} -gt 0 ]] && patterns+=("\\.($(IFS='|'; echo "${classes[*]}"))/")
      if [[ ${#patterns[@]} -eq 0 ]]; then
        patterns=('^(LocalHistoryCoreTests|LocalHistoryAppTests)\\.')
        echo "make check: no mapped change, running the fast Core and App tests"
      else
        echo "make check: from the $scope. targets: ${targets[*]-none}; test classes: ${classes[*]-none}"
      fi
      regex="$(IFS='|'; echo "${patterns[*]}")"
      args+=(--filter "$regex")
    fi
    for slow in "${SLOW_TESTS[@]}"; do args+=(--skip "$slow"); done
    echo "Slow tests left out (run by make test): ${#SLOW_TESTS[@]}"
    report_screen
    swift_test "${args[@]}"; status=$?
    elapsed
    exit "$status"
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
      local name="$1" prefix="$2" classes="$3" group_home
      group_home="$(mktemp -d "/tmp/$prefix-XXXXXX")"
      echo "---- make test-ui group $name"
      (
        export GOALONG_TEST_HOME="$group_home" CFFIXED_USER_HOME="$group_home" HOME="$group_home"
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
        xcrun swift test --filter "$classes" 2>&1 | tee -a "$log"; exit "${PIPESTATUS[0]}"
      ) || status=$?
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
    if [[ "$skips" -gt 0 ]]; then
      if [[ "$state" == locked ]]; then
        echo "Screen was locked: the skips above are expected; unlock and run again for the full proof."
      else
        echo "error: opt-in UI tests skipped although their variables are set" >&2
        exit 1
      fi
    fi
    exit 0
    ;;
  *) echo "usage: $0 check [FILTER] | full | ui" >&2; exit 2 ;;
esac
