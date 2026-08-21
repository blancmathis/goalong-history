#!/bin/bash
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
DATA_ROOT="$HOME/Library/Application Support/LocalHistory"
DAY="$(date +%F)"
OUTPUT=""
REQUIRE_REAL_CONTEXT=0
MINIMUM_PAIR_RATIO=""

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
if [[ ! -d "$REPO/.git" || ! -f "$REPO/Package.swift" ]]; then
  echo "Not a Goalong History git checkout: $REPO" >&2
  exit 66
fi
if [[ ! -f "$REPO/scripts/check_computer_history_memory.py" ]]; then
  echo "Causal memory checker is missing." >&2
  exit 66
fi

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
if [[ -z "$OUTPUT" ]]; then
  OUTPUT="/tmp/goalong-computer-history-parity-$STAMP"
fi
mkdir -p "$OUTPUT"

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
  "cd \"$REPO\" && swift test --filter ComputerHistoryParityTests && swift test --filter ComputerHistoryEpisodeQualityTests"
run_logged privacy-boundary-audit bash -lc \
  "cd \"$REPO\" && ./scripts/audit_privacy_boundaries.sh"
run_logged query-cli-build bash -lc \
  "cd \"$REPO\" && swift build -c release --product goalong-history-query"

BIN_PATH="$(cd "$REPO" && swift build -c release --show-bin-path)"
QUERY_CLI="$BIN_PATH/goalong-history-query"
if [[ ! -x "$QUERY_CLI" ]]; then
  echo "Read-only query CLI was not produced: $QUERY_CLI" >&2
  exit 70
fi

MEMORY_JSON="$OUTPUT/$DAY.computer-history.json"
run_logged causal-memory "$QUERY_CLI" --root "$DATA_ROOT" computer-history "$DAY"
cp "$OUTPUT/causal-memory.log" "$MEMORY_JSON"

CHECK_ARGS=(
  python3 "$REPO/scripts/check_computer_history_memory.py"
  "$MEMORY_JSON"
)
if [[ "$REQUIRE_REAL_CONTEXT" -eq 1 ]]; then
  CHECK_ARGS+=(--require-actions --require-resources --require-semantic-pairs)
fi
if [[ -n "$MINIMUM_PAIR_RATIO" ]]; then
  CHECK_ARGS+=(--minimum-pair-ratio "$MINIMUM_PAIR_RATIO")
fi
run_logged causal-invariants "${CHECK_ARGS[@]}"

run_logged ask-resume "$QUERY_CLI" --root "$DATA_ROOT" ask --days 30 \
  "Where was I before my most recent observable break?"
run_logged ask-resource "$QUERY_CLI" --root "$DATA_ROOT" ask --days 30 \
  "Which source document or file was I working on most recently?"
run_logged ask-status "$QUERY_CLI" --root "$DATA_ROOT" ask --days 30 \
  "What work is completed, in progress, blocked, or waiting?"
run_logged ask-workflows "$QUERY_CLI" --root "$DATA_ROOT" ask --days 30 \
  "Which repeated workflows could become a skill or automation?"

python3 - "$OUTPUT" <<'PY'
from __future__ import annotations

import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
errors: list[str] = []
for name in ("ask-resume", "ask-resource", "ask-status", "ask-workflows"):
    path = root / f"{name}.log"
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:
        errors.append(f"{name}: invalid JSON: {exc}")
        continue
    answer = payload.get("answer", {})
    if not isinstance(answer.get("answer"), str) or not answer["answer"].strip():
        errors.append(f"{name}: missing answer text")
    hits = answer.get("hits")
    if not isinstance(hits, list):
        errors.append(f"{name}: hits must be an array")
    limitations = answer.get("limitations")
    if not isinstance(limitations, list) or not limitations:
        errors.append(f"{name}: evidence limitations are missing")

if errors:
    print("Natural question validation FAILED", file=sys.stderr)
    for error in errors:
        print(f"- {error}", file=sys.stderr)
    raise SystemExit(1)
print(json.dumps({"valid": True, "questions_checked": 4}, sort_keys=True))
PY

cat >"$OUTPUT/MANUAL_REAL_SESSION_CHECKLIST.txt" <<'TXT'
Real-session evidence still required before claiming measured 100% parity on a Mac:

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
     --minimum-pair-ratio 0.80

Passing this checklist validates the documented analysis behavior on the tested apps
and macOS build. It cannot prove undocumented private implementation equivalence or
complete observability of every third-party application.
TXT

printf '\nComputer History parity artifacts: %s\n' "$OUTPUT"
printf 'Review MANUAL_REAL_SESSION_CHECKLIST.txt before making a measured parity claim.\n'
