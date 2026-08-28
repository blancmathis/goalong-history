#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=install_cli_link.sh
source "$SCRIPT_DIR/install_cli_link.sh"

TEST_ROOT="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/goalong-cli-link.XXXXXX")"
trap '/bin/rm -rf -- "$TEST_ROOT"' EXIT
APP="$TEST_ROOT/Goalong History.app"
BIN="$TEST_ROOT/bin"
/bin/mkdir -p "$APP/Contents/MacOS" "$BIN"
/bin/cp /usr/bin/true "$APP/Contents/MacOS/goalong"

install_goalong_cli_link "$APP" "$BIN"
[[ -L "$BIN/goalong" ]]
[[ "$(/usr/bin/readlink "$BIN/goalong")" == "$APP/Contents/MacOS/goalong" ]]

/bin/rm "$BIN/goalong"
/usr/bin/printf '%s\n' 'owned by user' > "$BIN/goalong"
install_goalong_cli_link "$APP" "$BIN" 2>/dev/null
[[ ! -L "$BIN/goalong" ]]
[[ "$(<"$BIN/goalong")" == 'owned by user' ]]

echo "Goalong CLI link tests passed: atomic link creation and unrelated-command preservation."
