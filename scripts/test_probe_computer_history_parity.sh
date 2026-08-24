#!/bin/bash
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
BYTECODE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/goalong-parity-bytecode.XXXXXX")"
trap 'rm -rf "$BYTECODE_DIR"' EXIT
export PYTHONPYCACHEPREFIX="$BYTECODE_DIR"

python3 -m py_compile \
  "$REPO/scripts/probe_computer_history_parity.py" \
  "$REPO/scripts/check_computer_history_answer.py" \
  "$REPO/scripts/test_probe_computer_history_parity.py"
bash -n "$REPO/scripts/validate_computer_history_parity.sh"
python3 -m unittest "$REPO/scripts/test_probe_computer_history_parity.py"
