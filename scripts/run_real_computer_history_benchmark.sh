#!/bin/bash
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This benchmark must run in Mathis's foreground macOS session." >&2
  exit 69
fi

cat <<'NOTICE'
Goalong Computer History — REAL foreground benchmark

This is not the deterministic 4/4 fixture. It measures physical input, the exact
installed app identity, TCC evidence, causal before/after coverage, privacy leakage,
resource search/reopening, resume accuracy, Codex comparison and timeline performance.

The script never resets TCC and never grants permissions automatically. It creates only
disposable benchmark files/pages plus a report folder on the Desktop.
NOTICE

exec /usr/bin/python3 "$REPO/scripts/real_computer_history_benchmark.py" run \
  --repo "$REPO" \
  "$@"
