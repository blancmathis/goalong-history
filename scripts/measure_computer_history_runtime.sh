#!/bin/bash
set -euo pipefail

APP_EXECUTABLE="/Applications/Goalong History.app/Contents/MacOS/Goalong History"
DATA_ROOT="$HOME/Library/Application Support/LocalHistory"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROCESS_SAMPLER="$SCRIPT_DIR/sample_macos_process.swift"
PROCESS_ID=""
SAMPLE_COUNT=600
WARMUP_SECONDS=60
OUTPUT=""
ENFORCE_TARGETS=0

usage() {
  cat <<'USAGE'
Usage: measure_computer_history_runtime.sh [options]

Options:
  --pid PID                  Measure an already-running process explicitly.
  --app-executable PATH      Exact installed executable used for PID discovery.
  --data-root PATH           Goalong History Application Support directory.
  --samples COUNT            One-second samples; 600 by default.
  --warmup-seconds COUNT     Closed-window settling period; 60 by default.
  --output PATH              New or empty metadata output directory; /tmp by default.
  --enforce-targets          Fail unless the Computer History resource targets pass.
  -h, --help                 Show this help.

The script never launches or controls the app, changes permissions, or reads history
bodies. Close the Goalong dashboard before running it. It records only process resource
counters, storage byte totals, environment metadata, and numeric one-second samples.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pid)
      [[ $# -ge 2 ]] || { echo "Missing value for --pid" >&2; exit 64; }
      PROCESS_ID="$2"; shift 2 ;;
    --app-executable)
      [[ $# -ge 2 ]] || { echo "Missing value for --app-executable" >&2; exit 64; }
      APP_EXECUTABLE="$2"; shift 2 ;;
    --data-root)
      [[ $# -ge 2 ]] || { echo "Missing value for --data-root" >&2; exit 64; }
      DATA_ROOT="$2"; shift 2 ;;
    --samples)
      [[ $# -ge 2 ]] || { echo "Missing value for --samples" >&2; exit 64; }
      SAMPLE_COUNT="$2"; shift 2 ;;
    --warmup-seconds)
      [[ $# -ge 2 ]] || { echo "Missing value for --warmup-seconds" >&2; exit 64; }
      WARMUP_SECONDS="$2"; shift 2 ;;
    --output)
      [[ $# -ge 2 ]] || { echo "Missing value for --output" >&2; exit 64; }
      OUTPUT="$2"; shift 2 ;;
    --enforce-targets)
      ENFORCE_TARGETS=1; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 64 ;;
  esac
done

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This measurement requires macOS." >&2
  exit 69
fi
if [[ ! "$SAMPLE_COUNT" =~ ^[1-9][0-9]*$ ]] || (( SAMPLE_COUNT > 86400 )); then
  echo "--samples must be an integer from 1 through 86400." >&2
  exit 64
fi
if [[ ! "$WARMUP_SECONDS" =~ ^[0-9]+$ ]] || (( WARMUP_SECONDS > 3600 )); then
  echo "--warmup-seconds must be an integer from 0 through 3600." >&2
  exit 64
fi
if [[ -n "$PROCESS_ID" && ! "$PROCESS_ID" =~ ^[1-9][0-9]*$ ]]; then
  echo "--pid must be a positive integer." >&2
  exit 64
fi

if [[ -z "$PROCESS_ID" ]]; then
  DISCOVERED_PIDS=()
  while IFS= read -r candidate; do
    [[ -n "$candidate" ]] && DISCOVERED_PIDS+=("$candidate")
  done < <(
    /bin/ps -axo pid=,command= | /usr/bin/awk -v expected="$APP_EXECUTABLE" '
      {
        pid = $1
        $1 = ""
        sub(/^ +/, "")
        if ($0 == expected) print pid
      }
    '
  )
  if [[ ${#DISCOVERED_PIDS[@]} -ne 1 ]]; then
    echo "Expected exactly one running process at $APP_EXECUTABLE; found ${#DISCOVERED_PIDS[@]}." >&2
    exit 69
  fi
  PROCESS_ID="${DISCOVERED_PIDS[0]}"
fi
if ! /bin/kill -0 "$PROCESS_ID" 2>/dev/null; then
  echo "Process $PROCESS_ID is not running." >&2
  exit 69
fi

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
if [[ -z "$OUTPUT" ]]; then
  OUTPUT="$(/usr/bin/mktemp -d "/tmp/goalong-computer-history-runtime-$STAMP.XXXXXX")"
fi
umask 077
if [[ -L "$OUTPUT" ]]; then
  echo "Measurement output must not be a symlink." >&2
  exit 73
fi
if [[ -d "$OUTPUT" && -n "$(find "$OUTPUT" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
  echo "Measurement output must be a new or empty directory." >&2
  exit 73
fi
mkdir -p "$OUTPUT"
chmod 700 "$OUTPUT"

CPU_SAMPLES="$OUTPUT/cpu.samples"
RSS_SAMPLES="$OUTPUT/rss-kib.samples"
CHILD_SAMPLES="$OUTPUT/children.samples"
STORAGE_BEFORE="$OUTPUT/storage-before.tsv"
STORAGE_AFTER="$OUTPUT/storage-after.tsv"
STORAGE_DELTA="$OUTPUT/storage-delta.tsv"
RUSAGE_BEFORE="$OUTPUT/rusage-before.tsv"
RUSAGE_AFTER="$OUTPUT/rusage-after.tsv"
SUMMARY="$OUTPUT/summary.txt"

storage_bytes() {
  local storage_item="$1"
  if [[ ! -e "$storage_item" ]]; then
    echo 0
  elif [[ -f "$storage_item" && ! -L "$storage_item" ]]; then
    stat -f %z "$storage_item"
  elif [[ -d "$storage_item" && ! -L "$storage_item" ]]; then
    find "$storage_item" -type f -exec stat -f %z {} \; \
      | /usr/bin/awk '{ total += $1 } END { print total + 0 }'
  else
    echo 0
  fi
}

storage_snapshot() {
  local destination="$1"
  : >"$destination"
  local category
  for category in \
    computer-history events semantic analysis memories seals agent-activity-v2 apple-screen-time
  do
    printf '%s\t%s\n' "$category" "$(storage_bytes "$DATA_ROOT/$category")" \
      >>"$destination"
  done
}

onscreen_primary_window_count() {
  xcrun swift -e "
    import CoreGraphics
    let pid: Int = $PROCESS_ID
    let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
        as? [[String: Any]] ?? []
    let count = rows.filter { row in
        guard let bounds = row[kCGWindowBounds as String] as? [String: Any],
            let width = bounds[\"Width\"] as? Double,
            let height = bounds[\"Height\"] as? Double
        else { return false }
        return (row[kCGWindowOwnerPID as String] as? Int) == pid
            && (row[kCGWindowLayer as String] as? Int) == 0
            && (row[kCGWindowIsOnscreen as String] as? Int) == 1
            && width >= 640 && height >= 480
    }.count
    print(count)
  "
}

PROCESS_COMMAND="$(/bin/ps -p "$PROCESS_ID" -o command=)"
WINDOWS_AT_START="$(onscreen_primary_window_count)"
{
  echo "generated_at_utc=$STAMP"
  echo "pid=$PROCESS_ID"
  echo "process_command=$PROCESS_COMMAND"
  echo "samples=$SAMPLE_COUNT"
  echo "sample_interval_seconds=1"
  echo "cpu_measurement=Per-interval proc_pid_rusage CPU-time delta divided by mach_continuous_time; not ps decaying average."
  echo "warmup_seconds=$WARMUP_SECONDS"
  echo "onscreen_substantial_layer_zero_windows_before_warmup=$WINDOWS_AT_START"
  echo "macos=$(sw_vers -productVersion) ($(sw_vers -buildVersion))"
  echo "architecture=$(uname -m)"
  echo "safety=No app launch, UI action, permission change, history-body read, history mutation, install, commit, or publication performed."
} >"$OUTPUT/environment.txt"

if [[ "$WINDOWS_AT_START" -ne 0 ]]; then
  echo "Goalong has a substantial on-screen primary window. Close it before measuring." >&2
  exit 65
fi

storage_snapshot "$STORAGE_BEFORE"
if (( WARMUP_SECONDS > 0 )); then
  sleep "$WARMUP_SECONDS"
fi
if [[ "$(onscreen_primary_window_count)" -ne 0 ]]; then
  echo "A substantial Goalong window appeared during warmup; measurement refused." >&2
  exit 65
fi
if [[ ! -f "$PROCESS_SAMPLER" ]]; then
  echo "Missing process sampler: $PROCESS_SAMPLER" >&2
  exit 69
fi
xcrun swift "$PROCESS_SAMPLER" \
  "$PROCESS_ID" "$SAMPLE_COUNT" \
  "$CPU_SAMPLES" "$RSS_SAMPLES" "$CHILD_SAMPLES" \
  "$RUSAGE_BEFORE" "$RUSAGE_AFTER"
storage_snapshot "$STORAGE_AFTER"
WINDOWS_AT_END="$(onscreen_primary_window_count)"
if [[ "$WINDOWS_AT_END" -ne 0 ]]; then
  echo "A substantial Goalong window was on screen at the end; closed-window results are invalid." >&2
  exit 65
fi

CPU_SORTED="$OUTPUT/.cpu.sorted"
RSS_SORTED="$OUTPUT/.rss.sorted"
sort -n "$CPU_SAMPLES" >"$CPU_SORTED"
sort -n "$RSS_SAMPLES" >"$RSS_SORTED"
MEDIAN_RANK=$(( (SAMPLE_COUNT + 1) / 2 ))
P95_RANK=$(( (95 * SAMPLE_COUNT + 99) / 100 ))
CPU_MEDIAN="$(sed -n "${MEDIAN_RANK}p" "$CPU_SORTED")"
CPU_P95="$(sed -n "${P95_RANK}p" "$CPU_SORTED")"
CPU_MAX="$(tail -n 1 "$CPU_SORTED")"
RSS_MEDIAN_KIB="$(sed -n "${MEDIAN_RANK}p" "$RSS_SORTED")"
RSS_P95_KIB="$(sed -n "${P95_RANK}p" "$RSS_SORTED")"
RSS_MAX_KIB="$(tail -n 1 "$RSS_SORTED")"
CHILD_MAX="$(sort -nr "$CHILD_SAMPLES" | head -n 1)"
read -r CPU_OVER_15 MAX_RUN_OVER_15 < <(
  /usr/bin/awk '
    BEGIN { run = 0; longest = 0; total = 0 }
    {
      if ($1 > 15) {
        run += 1
        total += 1
        if (run > longest) longest = run
      } else {
        run = 0
      }
    }
    END { print total + 0, longest + 0 }
  ' "$CPU_SAMPLES"
)

read -r BEFORE_USER BEFORE_SYSTEM BEFORE_IDLE BEFORE_INTERRUPT BEFORE_READ BEFORE_WRITE \
  BEFORE_FOOTPRINT BEFORE_PEAK <"$RUSAGE_BEFORE"
read -r AFTER_USER AFTER_SYSTEM AFTER_IDLE AFTER_INTERRUPT AFTER_READ AFTER_WRITE \
  AFTER_FOOTPRINT AFTER_PEAK <"$RUSAGE_AFTER"

/usr/bin/awk -F '\t' '
  NR == FNR { before[$1] = $2; next }
  { print $1 "\t" $2 - before[$1] }
' "$STORAGE_BEFORE" "$STORAGE_AFTER" >"$STORAGE_DELTA"

{
  echo "cpu_median_percent=$CPU_MEDIAN"
  echo "cpu_p95_percent=$CPU_P95"
  echo "cpu_max_percent=$CPU_MAX"
  echo "cpu_samples_above_15_percent=$CPU_OVER_15"
  echo "cpu_longest_run_above_15_seconds=$MAX_RUN_OVER_15"
  echo "rss_median_kib=$RSS_MEDIAN_KIB"
  echo "rss_p95_kib=$RSS_P95_KIB"
  echo "rss_max_kib=$RSS_MAX_KIB"
  echo "physical_footprint_bytes=$AFTER_FOOTPRINT"
  echo "lifetime_peak_physical_footprint_bytes=$AFTER_PEAK"
  echo "child_process_max=$CHILD_MAX"
  echo "process_user_time_delta_nanoseconds=$(( AFTER_USER - BEFORE_USER ))"
  echo "process_system_time_delta_nanoseconds=$(( AFTER_SYSTEM - BEFORE_SYSTEM ))"
  echo "idle_wakeup_delta=$(( AFTER_IDLE - BEFORE_IDLE ))"
  echo "interrupt_wakeup_delta=$(( AFTER_INTERRUPT - BEFORE_INTERRUPT ))"
  echo "disk_read_delta_bytes=$(( AFTER_READ - BEFORE_READ ))"
  echo "disk_write_delta_bytes=$(( AFTER_WRITE - BEFORE_WRITE ))"
  echo "onscreen_substantial_layer_zero_windows_after=$WINDOWS_AT_END"
  echo "storage_delta_file=$STORAGE_DELTA"
} >"$SUMMARY"

rm -f "$CPU_SORTED" "$RSS_SORTED"
cat "$OUTPUT/environment.txt"
cat "$SUMMARY"
echo "storage_deltas_begin"
cat "$STORAGE_DELTA"
echo "storage_deltas_end"
echo "measurement_output=$OUTPUT"

if [[ "$ENFORCE_TARGETS" -eq 1 ]]; then
  FAILED=0
  /usr/bin/awk -v value="$CPU_MEDIAN" 'BEGIN { exit !(value <= 1.0) }' || FAILED=1
  /usr/bin/awk -v value="$CPU_P95" 'BEGIN { exit !(value <= 5.0) }' || FAILED=1
  (( MAX_RUN_OVER_15 <= 5 )) || FAILED=1
  (( AFTER_FOOTPRINT <= 100 * 1024 * 1024 )) || FAILED=1
  (( AFTER_PEAK <= 300 * 1024 * 1024 )) || FAILED=1
  (( CHILD_MAX == 0 )) || FAILED=1
  if [[ "$FAILED" -ne 0 ]]; then
    echo "One or more Computer History resource targets failed." >&2
    exit 1
  fi
  echo "Computer History resource targets passed."
fi
