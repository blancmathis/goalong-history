#!/bin/bash
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/goalong-upgrade-validator-test.XXXXXX")"
cleanup() {
  if [[ -d "$TEST_ROOT" && ! -L "$TEST_ROOT" ]]; then
    /bin/rm -r -- "$TEST_ROOT"
  fi
}
trap cleanup EXIT HUP INT TERM

DATA_ROOT="$TEST_ROOT/data"
OUTPUT="$TEST_ROOT/output"
mkdir -p "$DATA_ROOT"
printf '%s\n' 'validator-private-sentinel' >"$DATA_ROOT/source.txt"

LOCALHISTORY_VALIDATE_SETUP_ONLY=1 \
  "$REPO/scripts/validate_computer_history_upgrade.sh" \
  --repo "$REPO" \
  --data-root "$DATA_ROOT" \
  --output "$OUTPUT" >/dev/null

[[ "$(stat -f '%Lp' "$OUTPUT")" == "700" ]]
[[ -f "$OUTPUT/environment.txt" ]]
if grep -R -F 'validator-private-sentinel' "$OUTPUT" >/dev/null; then
  echo "Validator copied source-sensitive content into its output." >&2
  exit 1
fi

NONEMPTY="$TEST_ROOT/nonempty"
mkdir -p "$NONEMPTY"
printf 'owned\n' >"$NONEMPTY/keep"
set +e
LOCALHISTORY_VALIDATE_SETUP_ONLY=1 \
  "$REPO/scripts/validate_computer_history_upgrade.sh" \
  --repo "$REPO" --data-root "$DATA_ROOT" --output "$NONEMPTY" >/dev/null 2>&1
NONEMPTY_STATUS=$?
set -e
[[ "$NONEMPTY_STATUS" -eq 73 ]]
[[ "$(cat "$NONEMPTY/keep")" == "owned" ]]

SYMLINK_TARGET="$TEST_ROOT/symlink-target"
mkdir -p "$SYMLINK_TARGET"
ln -s "$SYMLINK_TARGET" "$TEST_ROOT/output-link"
set +e
LOCALHISTORY_VALIDATE_SETUP_ONLY=1 \
  "$REPO/scripts/validate_computer_history_upgrade.sh" \
  --repo "$REPO" --data-root "$DATA_ROOT" --output "$TEST_ROOT/output-link" >/dev/null 2>&1
SYMLINK_STATUS=$?
set -e
[[ "$SYMLINK_STATUS" -eq 73 ]]
[[ -z "$(find "$SYMLINK_TARGET" -mindepth 1 -maxdepth 1 -print -quit)" ]]

OVERLAP="$DATA_ROOT/validation-output"
set +e
LOCALHISTORY_VALIDATE_SETUP_ONLY=1 \
  "$REPO/scripts/validate_computer_history_upgrade.sh" \
  --repo "$REPO" --data-root "$DATA_ROOT" --output "$OVERLAP" >/dev/null 2>&1
OVERLAP_STATUS=$?
set -e
[[ "$OVERLAP_STATUS" -eq 73 ]]
[[ ! -e "$OVERLAP" ]]

echo "Computer History upgrade validator safety tests passed."
