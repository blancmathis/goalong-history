#!/bin/bash
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
DATA_ROOT="$HOME/Library/Application Support/LocalHistory"
DAY="$(date +%F)"
OUTPUT=""
REQUIRE_REAL_CONTEXT=0
MINIMUM_PAIR_RATIO=""
CODEX_EVENT_ROOT=""
START_UTC=""
END_UTC=""
CONFIRM_PHYSICAL_USER_INPUT=0

usage() {
  cat <<'USAGE'
Usage: validate_computer_history_parity.sh [options]

Options:
  --repo PATH                 Goalong History git checkout.
  --data-root PATH            Goalong History Application Support directory.
  --day YYYY-MM-DD            Local day to validate; today by default.
  --output PATH               Validation output directory; /tmp by default.
  --require-real-context      Require actions, resources, and before/after context.
  --minimum-pair-ratio VALUE  Require 0..1 fraction of actions with semantic pairs.
  --codex-event-root PATH     Opt in to the bounded Codex↔Goalong metadata probe.
  --start-utc ISO-8601        Inclusive UTC start for that controlled probe.
  --end-utc ISO-8601          Exclusive UTC end for that controlled probe.
  --confirm-physical-user-input
                              Attest that the probe interval contains only a
                              controlled sequence physically performed by the user.
  -h, --help                  Show this help.

The script is read-only with respect to recorded history. It never installs or
launches the app, changes macOS permissions, publishes data, commits, or pushes.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      [[ $# -ge 2 ]] || { echo "Missing value for --repo" >&2; exit 64; }
      REPO="$2"; shift 2 ;;
    --data-root)
      [[ $# -ge 2 ]] || { echo "Missing value for --data-root" >&2; exit 64; }
      DATA_ROOT="$2"; shift 2 ;;
    --day)
      [[ $# -ge 2 ]] || { echo "Missing value for --day" >&2; exit 64; }
      DAY="$2"; shift 2 ;;
    --output)
      [[ $# -ge 2 ]] || { echo "Missing value for --output" >&2; exit 64; }
      OUTPUT="$2"; shift 2 ;;
    --require-real-context)
      REQUIRE_REAL_CONTEXT=1; shift ;;
    --minimum-pair-ratio)
      [[ $# -ge 2 ]] || { echo "Missing value for --minimum-pair-ratio" >&2; exit 64; }
      MINIMUM_PAIR_RATIO="$2"; shift 2 ;;
    --codex-event-root)
      [[ $# -ge 2 ]] || { echo "Missing value for --codex-event-root" >&2; exit 64; }
      CODEX_EVENT_ROOT="$2"; shift 2 ;;
    --start-utc)
      [[ $# -ge 2 ]] || { echo "Missing value for --start-utc" >&2; exit 64; }
      START_UTC="$2"; shift 2 ;;
    --end-utc)
      [[ $# -ge 2 ]] || { echo "Missing value for --end-utc" >&2; exit 64; }
      END_UTC="$2"; shift 2 ;;
    --confirm-physical-user-input)
      CONFIRM_PHYSICAL_USER_INPUT=1; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 64 ;;
  esac
done

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This validator requires macOS." >&2
  exit 69
fi
if [[ ! "$DAY" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
  echo "Invalid --day: $DAY" >&2
  exit 64
fi
if [[ -n "$CODEX_EVENT_ROOT" || -n "$START_UTC" || -n "$END_UTC" || "$CONFIRM_PHYSICAL_USER_INPUT" -eq 1 ]]; then
  if [[ -z "$CODEX_EVENT_ROOT" || -z "$START_UTC" || -z "$END_UTC" ]]; then
    echo "The physical probe requires --codex-event-root, --start-utc and --end-utc together." >&2
    exit 64
  fi
  if [[ "$CONFIRM_PHYSICAL_USER_INPUT" -ne 1 ]]; then
    echo "The physical probe requires --confirm-physical-user-input." >&2
    echo "Synthetic or Computer Use actions are not valid evidence." >&2
    exit 64
  fi
fi
if [[ ! -d "$REPO/.git" || ! -f "$REPO/Package.swift" ]]; then
  echo "Not a Goalong History git checkout: $REPO" >&2
  exit 66
fi
if [[ ! -f "$REPO/scripts/check_computer_history_memory.py" ]]; then
  echo "Causal memory checker is missing." >&2
  exit 66
fi
for helper in \
  "$REPO/scripts/check_computer_history_answer.py" \
  "$REPO/scripts/probe_computer_history_parity.py" \
  "$REPO/scripts/test_probe_computer_history_parity.sh" \
  "$REPO/scripts/sample_macos_process.swift" \
  "$REPO/scripts/test_measure_computer_history_runtime.sh" \
  "$REPO/scripts/codesign_policy.sh" \
  "$REPO/scripts/test_codesign_policy.sh"
do
  if [[ ! -f "$helper" ]]; then
    echo "A metadata-only parity helper is missing." >&2
    exit 66
  fi
done

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
if [[ -z "$OUTPUT" ]]; then
  OUTPUT="/tmp/goalong-computer-history-parity-$STAMP"
fi
umask 077
if [[ -L "$OUTPUT" ]]; then
  echo "Validation output must not be a symlink." >&2
  exit 73
fi
if [[ -d "$OUTPUT" && -n "$(find "$OUTPUT" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
  echo "Validation output must be a new or empty directory." >&2
  exit 73
fi
mkdir -p "$OUTPUT"
chmod 700 "$OUTPUT"

run_logged() {
  local name="$1"
  shift
  echo
  echo "== $name =="
  "$@" 2>&1 | tee "$OUTPUT/$name.log"
}

{
  echo "generated_at_utc=$STAMP"
  echo "repo=$REPO"
  echo "data_root=$DATA_ROOT"
  echo "day=$DAY"
  echo "require_real_context=$REQUIRE_REAL_CONTEXT"
  echo "minimum_pair_ratio=${MINIMUM_PAIR_RATIO:-none}"
  echo "physical_probe_requested=$([[ -n "$CODEX_EVENT_ROOT" ]] && echo 1 || echo 0)"
  echo "physical_user_input_attested=$CONFIRM_PHYSICAL_USER_INPUT"
  echo "git_head=$(git -C "$REPO" rev-parse HEAD)"
  echo "git_branch=$(git -C "$REPO" branch --show-current)"
  echo "macos=$(sw_vers -productVersion) ($(sw_vers -buildVersion))"
  echo "architecture=$(uname -m)"
  echo "swift_version_begin"
  swift --version 2>&1 || true
  echo "swift_version_end"
  echo "safety=No app launch, installation, permission change, history mutation, publication, commit, or push performed."
} >"$OUTPUT/environment.txt"
cat "$OUTPUT/environment.txt"

run_logged parity-unit-tests bash -lc \
  "cd \"$REPO\" && swift test --filter ComputerHistoryParityTests && swift test --filter ComputerHistoryEpisodeQualityTests && swift test --filter ComputerHistoryAgentContextTests"
run_logged privacy-boundary-audit bash -lc \
  "cd \"$REPO\" && ./scripts/audit_privacy_boundaries.sh"
run_logged checker-regression bash "$REPO/scripts/test_check_computer_history_memory.sh"
run_logged metadata-probe-regression bash "$REPO/scripts/test_probe_computer_history_parity.sh"
run_logged runtime-measurement-regression bash "$REPO/scripts/test_measure_computer_history_runtime.sh"
run_logged signing-network-policy-regression bash "$REPO/scripts/test_codesign_policy.sh"
run_logged query-cli-build bash -lc \
  "cd \"$REPO\" && swift build -c release --product goalong-history-query"

BIN_PATH="$(cd "$REPO" && swift build -c release --show-bin-path)"
QUERY_CLI="$BIN_PATH/goalong-history-query"
if [[ ! -x "$QUERY_CLI" ]]; then
  echo "Read-only query CLI was not produced: $QUERY_CLI" >&2
  exit 70
fi

CHECK_ARGS=(
  python3 "$REPO/scripts/check_computer_history_memory.py"
  -
  --quiet-errors
)
if [[ "$REQUIRE_REAL_CONTEXT" -eq 1 ]]; then
  CHECK_ARGS+=(--require-actions --require-resources --require-semantic-pairs)
fi
if [[ -n "$MINIMUM_PAIR_RATIO" ]]; then
  CHECK_ARGS+=(--minimum-pair-ratio "$MINIMUM_PAIR_RATIO")
fi

run_causal_invariants() {
  if ! "$QUERY_CLI" --root "$DATA_ROOT" computer-history "$DAY" 2>/dev/null \
    | "${CHECK_ARGS[@]}"
  then
    echo "Causal invariant validation failed; source-derived diagnostics were suppressed." >&2
    return 1
  fi
}
run_logged causal-invariants run_causal_invariants

run_answer_metadata_check() {
  local prompt="$1"
  if ! "$QUERY_CLI" --root "$DATA_ROOT" ask --days 30 "$prompt" 2>/dev/null \
    | python3 "$REPO/scripts/check_computer_history_answer.py"
  then
    echo "Natural question validation failed; source-derived diagnostics were suppressed." >&2
    return 1
  fi
}
run_logged ask-resume-metadata run_answer_metadata_check \
  "Where was I before my most recent observable break?"
run_logged ask-resource-metadata run_answer_metadata_check \
  "Which source document or file was I working on most recently?"
run_logged ask-status-metadata run_answer_metadata_check \
  "What work is completed, in progress, blocked, or waiting?"
run_logged ask-workflows-metadata run_answer_metadata_check \
  "Which repeated workflows could become a skill or automation?"

if [[ -n "$CODEX_EVENT_ROOT" ]]; then
  run_logged physical-input-metadata-probe \
    python3 "$REPO/scripts/probe_computer_history_parity.py" \
      --codex "$CODEX_EVENT_ROOT" \
      --goalong "$DATA_ROOT/events" \
      --start-utc "$START_UTC" \
      --end-utc "$END_UTC"
fi

cat >"$OUTPUT/MANUAL_REAL_SESSION_CHECKLIST.txt" <<'TXT'
Real-session evidence is required before claiming observed parity within tolerance on a Mac:

1. Use the signed Goalong History build with Accessibility and any required Input
   Monitoring permission granted to that exact installed application identity.
2. Enable Full Computer History context during onboarding or in Activity → Day recap.
3. In a non-sensitive document, capture:
   - a visible before state;
   - typing or a click;
   - a visibly changed after state;
   - a saved/completed state.
4. Use at least two unrelated browser tasks in the same browser and confirm they become
   distinct episodes rather than one generic browser block.
5. Visit a reopenable file, document, conversation, and issue; confirm every locator
   opens the expected source.
6. Create a visible failure, retry, then success; confirm the latest successful state
   wins while the earlier failure remains in the action evidence.
7. Perform five actions inside one minute; confirm all five interactions remain.
8. Verify private browsing, an excluded source, Secure Input, and a protected control
   expose only coverage gaps and never hidden titles, URLs, text, or input details.
9. Ask the four validation questions and manually verify each cited source.
10. Re-run this script with:

   bash scripts/validate_computer_history_parity.sh \
     --day YYYY-MM-DD \
     --require-real-context \
     --minimum-pair-ratio 0.80 \
     --codex-event-root /path/from/computer_history_status \
     --start-utc YYYY-MM-DDTHH:MM:SSZ \
     --end-utc YYYY-MM-DDTHH:MM:SSZ \
     --confirm-physical-user-input

Passing this checklist validates the documented analysis behavior on the tested apps
and macOS build. It cannot prove undocumented private implementation equivalence or
complete observability of every third-party application.
TXT

printf '\nComputer History parity artifacts: %s\n' "$OUTPUT"
printf 'Review MANUAL_REAL_SESSION_CHECKLIST.txt before making a measured parity claim.\n'
