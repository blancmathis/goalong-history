#!/bin/bash
set -euo pipefail

DEFAULT_REPO="/Users/mathisblanc/Documents/ChatGPT/be-productive/localhistory"
DEFAULT_DATA_ROOT="$HOME/Library/Application Support/LocalHistory"
REPO="$DEFAULT_REPO"
DATA_ROOT="$DEFAULT_DATA_ROOT"
DAY=""
OUTPUT=""
REQUIRE_REAL_EVENTS=0

usage() {
  cat <<'USAGE'
Usage: validate_computer_history_upgrade.sh [options]

Options:
  --repo PATH                 Goalong History git checkout.
  --data-root PATH            Goalong History Application Support directory.
  --day YYYY-MM-DD            Day to inspect; newest event file by default.
  --output PATH               Validation output directory; /tmp by default.
  --require-real-events       Fail unless click, scroll, shortcut, typing,
                              window, focus, URL and semantic events are non-zero.
  -h, --help                  Show this help.

The script does not install or launch the app, request/change TCC permissions,
publish a release, commit, or push. It builds and reads local files only.
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
    --require-real-events)
      REQUIRE_REAL_EVENTS=1; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 64 ;;
  esac
done

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This validation script requires macOS." >&2
  exit 69
fi
if [[ ! -d "$REPO/.git" || ! -f "$REPO/Package.swift" ]]; then
  echo "Not a Goalong History git checkout: $REPO" >&2
  exit 66
fi
if [[ ! -x "$REPO/scripts/audit_privacy_boundaries.sh" || ! -x "$REPO/scripts/build_app.sh" ]]; then
  echo "Official repository validation/build scripts are missing or not executable." >&2
  exit 66
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSPECTOR="$SCRIPT_DIR/inspect_capture.py"
if [[ ! -x "$INSPECTOR" ]]; then
  echo "Capture inspector is missing or not executable: $INSPECTOR" >&2
  exit 66
fi

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
if [[ -z "$OUTPUT" ]]; then
  OUTPUT="/tmp/goalong-history-validation-$STAMP"
fi
mkdir -p "$OUTPUT"

run_logged() {
  local name="$1"
  shift
  echo
  echo "== $name =="
  "$@" 2>&1 | tee "$OUTPUT/$name.log"
}

capture_nonfatal() {
  local name="$1"
  shift
  echo
  echo "== $name (non-fatal) =="
  set +e
  "$@" >"$OUTPUT/$name.log" 2>&1
  local status=$?
  set -e
  cat "$OUTPUT/$name.log"
  printf '\nexit_status=%s\n' "$status" >>"$OUTPUT/$name.log"
  return 0
}

{
  echo "generated_at_utc=$STAMP"
  echo "repo=$REPO"
  echo "data_root=$DATA_ROOT"
  echo "requested_day=${DAY:-newest}"
  echo "require_real_events=$REQUIRE_REAL_EVENTS"
  echo "uname=$(uname -a)"
  echo "macos=$(sw_vers -productVersion) ($(sw_vers -buildVersion))"
  echo "architecture=$(uname -m)"
  echo "xcode_select=$(xcode-select -p 2>/dev/null || true)"
  echo "swift_version_begin"
  swift --version 2>&1 || true
  echo "swift_version_end"
  echo "git_head=$(git -C "$REPO" rev-parse HEAD)"
  echo "git_branch=$(git -C "$REPO" branch --show-current)"
  echo "git_status_begin"
  git -C "$REPO" status --short
  echo "git_status_end"
  echo "safety=No install, launch, TCC change, commit, push, release or publication performed."
} >"$OUTPUT/environment.txt"
cat "$OUTPUT/environment.txt"

run_logged swift-test bash -lc "cd \"$REPO\" && swift test"
run_logged privacy-boundary-audit bash -lc "cd \"$REPO\" && ./scripts/audit_privacy_boundaries.sh"
run_logged official-app-build bash -lc "cd \"$REPO\" && ./scripts/build_app.sh"
run_logged query-cli-build bash -lc "cd \"$REPO\" && swift build -c release --product goalong-history-query"

APP_OUTPUT_DIR="${LOCALHISTORY_OUTPUT_DIR:-$REPO/dist}"
BUILT_APP="$APP_OUTPUT_DIR/Goalong History.app"
if [[ ! -d "$BUILT_APP" ]]; then
  echo "Official build did not produce $BUILT_APP" >&2
  exit 70
fi

run_logged built-app-codesign-details /usr/bin/codesign -d --verbose=4 "$BUILT_APP"
run_logged built-app-designated-requirement /usr/bin/codesign -d -r- "$BUILT_APP"
capture_nonfatal built-app-gatekeeper /usr/sbin/spctl --assess --type execute --verbose=4 "$BUILT_APP"

INSTALLED_APP="/Applications/Goalong History.app"
if [[ -d "$INSTALLED_APP" ]]; then
  run_logged installed-app-codesign-details /usr/bin/codesign -d --verbose=4 "$INSTALLED_APP"
  run_logged installed-app-designated-requirement /usr/bin/codesign -d -r- "$INSTALLED_APP"
  capture_nonfatal installed-app-gatekeeper /usr/sbin/spctl --assess --type execute --verbose=4 "$INSTALLED_APP"
else
  echo "Installed app not found at $INSTALLED_APP" | tee "$OUTPUT/installed-app-missing.log"
fi

BIN_PATH="$(cd "$REPO" && swift build -c release --show-bin-path)"
QUERY_CLI="$BIN_PATH/goalong-history-query"
if [[ ! -x "$QUERY_CLI" ]]; then
  echo "Read-only query CLI was not produced: $QUERY_CLI" >&2
  exit 70
fi
run_logged query-status "$QUERY_CLI" --root "$DATA_ROOT" status

INSPECT_ARGS=("$INSPECTOR" --data-root "$DATA_ROOT" --json)
if [[ -n "$DAY" ]]; then
  INSPECT_ARGS+=(--day "$DAY")
fi
if [[ "$REQUIRE_REAL_EVENTS" -eq 1 ]]; then
  INSPECT_ARGS+=(--require-real-events)
fi
run_logged capture-inspection "${INSPECT_ARGS[@]}"

LATEST_FILE=""
if [[ -z "$DAY" && -d "$DATA_ROOT/events" ]]; then
  LATEST_FILE="$(find "$DATA_ROOT/events" -maxdepth 1 -type f -name '????-??-??.jsonl' -print | sort | tail -1)"
  if [[ -n "$LATEST_FILE" ]]; then
    DAY="$(basename "$LATEST_FILE" .jsonl)"
  fi
elif [[ -n "$DAY" ]]; then
  LATEST_FILE="$DATA_ROOT/events/$DAY.jsonl"
fi
if [[ -n "$LATEST_FILE" && -f "$LATEST_FILE" ]]; then
  run_logged repository-jsonl-verifier python3 "$REPO/scripts/verify_jsonl.py" "$LATEST_FILE"
fi
if [[ -n "$DAY" ]]; then
  DAY_END="$(python3 - "$DAY" <<'PYDATE'
from datetime import date, timedelta
import sys
print((date.fromisoformat(sys.argv[1]) + timedelta(days=1)).isoformat())
PYDATE
)"
  run_logged day-summary "$QUERY_CLI" --root "$DATA_ROOT" summary "$DAY"
  run_logged day-gaps "$QUERY_CLI" --root "$DATA_ROOT" gaps --start "$DAY" --end "$DAY_END"
fi

cat >"$OUTPUT/NEXT_MANUAL_VALIDATION.txt" <<'TXT'
Controlled validation still requiring a foreground user session:
1. Launch the newly built or installed app manually.
2. Do not change Accessibility/Input Monitoring until the app explicitly reports the need.
3. In non-private, non-sensitive apps: switch app/window, click, scroll, use a shortcut,
   type and correct a harmless sentence, and navigate to a sanitized URL.
4. Explicitly enable Rich Context, then wait for a semantic snapshot.
5. Verify a secure field, excluded app/domain and private browser produce no details.
6. Re-run this script with --require-real-events for the same local day.
7. Open the rendered Timeline and inspect source events/provenance visually.

A non-zero event count proves only that an observation was stored. It does not prove
human identity, attention, productivity, or complete machine honesty.
TXT

printf '\nValidation artifacts: %s\n' "$OUTPUT"
printf 'No install, launch, permission change, commit, push, release or publication was performed.\n'
