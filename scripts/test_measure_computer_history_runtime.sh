#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE_ROOT="$(/usr/bin/mktemp -d /tmp/goalong-runtime-measurement-test.XXXXXX)"
SLEEP_PID=""
BUSY_PID=""

cleanup() {
  if [[ -n "$SLEEP_PID" ]]; then
    /bin/kill "$SLEEP_PID" 2>/dev/null || true
    wait "$SLEEP_PID" 2>/dev/null || true
  fi
  if [[ -n "$BUSY_PID" ]]; then
    /bin/kill "$BUSY_PID" 2>/dev/null || true
    wait "$BUSY_PID" 2>/dev/null || true
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
grep -Fq 'cpu_measurement=Per-interval proc_pid_rusage' "$FIXTURE_ROOT/output/environment.txt"
grep -Fq 'onscreen_substantial_layer_zero_windows_before_warmup=0' \
  "$FIXTURE_ROOT/output/environment.txt"
grep -Fq 'child_process_max=0' "$FIXTURE_ROOT/output/summary.txt"
grep -Fq 'onscreen_substantial_layer_zero_windows_after=0' \
  "$FIXTURE_ROOT/output/summary.txt"
grep -Fq $'computer-history\t0' "$FIXTURE_ROOT/output/storage-delta.tsv"
grep -Fq 'safety=No app launch' "$FIXTURE_ROOT/output/environment.txt"
grep -Fq 'width >= 640 && height >= 480' \
  "$ROOT_DIR/scripts/measure_computer_history_runtime.sh"
[[ "$(wc -l <"$FIXTURE_ROOT/output/cpu.samples" | tr -d ' ')" == 2 ]]
/usr/bin/awk 'NF != 1 || $1 !~ /^[0-9]+([.][0-9]+)?$/ { exit 1 }' \
  "$FIXTURE_ROOT/output/cpu.samples"

if "$ROOT_DIR/scripts/measure_computer_history_runtime.sh" \
  --pid invalid --samples 1 --warmup-seconds 0 >/dev/null 2>&1; then
  echo "Invalid PID was accepted." >&2
  exit 1
fi

mkdir "$FIXTURE_ROOT/busy-output"
/usr/bin/yes >/dev/null &
BUSY_PID=$!
"$ROOT_DIR/scripts/measure_computer_history_runtime.sh" \
  --pid "$BUSY_PID" \
  --data-root "$FIXTURE_ROOT/data" \
  --samples 2 \
  --warmup-seconds 0 \
  --output "$FIXTURE_ROOT/busy-output" \
  >"$FIXTURE_ROOT/busy-result.log"
/bin/kill "$BUSY_PID" 2>/dev/null || true
wait "$BUSY_PID" 2>/dev/null || true
BUSY_PID=""

busy_cpu_median="$(sed -n 's/^cpu_median_percent=//p' "$FIXTURE_ROOT/busy-output/summary.txt")"
busy_user_nanoseconds="$(
  sed -n 's/^process_user_time_delta_nanoseconds=//p' \
    "$FIXTURE_ROOT/busy-output/summary.txt"
)"
/usr/bin/awk -v value="$busy_cpu_median" 'BEGIN { exit !(value > 50) }'
(( busy_user_nanoseconds > 1000000000 ))

echo "Computer History runtime measurement tests passed: bounded kernel-delta CPU samples, Mach nanoseconds, rusage, storage deltas, substantial-window gate, and invalid-input refusal."
