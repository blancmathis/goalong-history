#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE_ROOT="$(/usr/bin/mktemp -d /tmp/goalong-runtime-measurement-test.XXXXXX)"
SLEEP_PID=""

cleanup() {
  if [[ -n "$SLEEP_PID" ]]; then
    /bin/kill "$SLEEP_PID" 2>/dev/null || true
    wait "$SLEEP_PID" 2>/dev/null || true
  fi
  if [[ -d "$FIXTURE_ROOT" && ! -L "$FIXTURE_ROOT" \
    && "$(basename "$FIXTURE_ROOT")" == goalong-runtime-measurement-test.* ]]; then
    rm -rf "$FIXTURE_ROOT"
  fi
}
trap cleanup EXIT

mkdir -p "$FIXTURE_ROOT/data/computer-history" "$FIXTURE_ROOT/output"
printf 'metadata-only fixture\n' >"$FIXTURE_ROOT/data/computer-history/day.json"
/bin/sleep 20 &
SLEEP_PID=$!

"$ROOT_DIR/scripts/measure_computer_history_runtime.sh" \
  --pid "$SLEEP_PID" \
  --data-root "$FIXTURE_ROOT/data" \
  --samples 2 \
  --warmup-seconds 0 \
  --output "$FIXTURE_ROOT/output" \
  >"$FIXTURE_ROOT/result.log"

grep -Fq 'samples=2' "$FIXTURE_ROOT/output/environment.txt"
grep -Fq 'child_process_max=0' "$FIXTURE_ROOT/output/summary.txt"
grep -Fq $'computer-history\t0' "$FIXTURE_ROOT/output/storage-delta.tsv"
grep -Fq 'safety=No app launch' "$FIXTURE_ROOT/output/environment.txt"

if "$ROOT_DIR/scripts/measure_computer_history_runtime.sh" \
  --pid invalid --samples 1 --warmup-seconds 0 >/dev/null 2>&1; then
  echo "Invalid PID was accepted." >&2
  exit 1
fi

echo "Computer History runtime measurement tests passed: bounded numeric samples, rusage, storage deltas, window gate, and invalid-input refusal."
