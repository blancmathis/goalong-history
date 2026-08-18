#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=sparkle_release.env
source "$ROOT_DIR/scripts/sparkle_release.env"
TOOLS_DIR="$($ROOT_DIR/scripts/fetch_sparkle_tools.sh)"
EXPORT_PATH="${1:-}"

"$TOOLS_DIR/generate_keys" --account "$SPARKLE_KEY_ACCOUNT"
PUBLIC_KEY="$($TOOLS_DIR/generate_keys --account "$SPARKLE_KEY_ACCOUNT" -p)"

echo
echo "Sparkle public key:"
printf '%s\n' "$PUBLIC_KEY"
echo

if [[ -n "$EXPORT_PATH" ]]; then
  if [[ -e "$EXPORT_PATH" ]]; then
    echo "Refusing to overwrite existing private-key export: $EXPORT_PATH" >&2
    exit 1
  fi
  "$TOOLS_DIR/generate_keys" --account "$SPARKLE_KEY_ACCOUNT" -x "$EXPORT_PATH"
  chmod 600 "$EXPORT_PATH"
  echo "Private key exported to: $EXPORT_PATH"
  echo "Treat this file like a production signing credential and delete the temporary copy after storing it securely."
else
  echo "The private key remains in your login Keychain."
  echo "To export it temporarily for GitHub Actions, rerun:"
  echo "  ./scripts/setup_sparkle_keys.sh /secure/temporary/path/sparkle-private-key"
fi
