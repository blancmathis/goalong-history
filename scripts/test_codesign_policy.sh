#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=codesign_policy.sh
source "$SCRIPT_DIR/codesign_policy.sh"

[[ -z "$(localhistory_codesign_timestamp_argument -)" ]]
[[ "$(localhistory_codesign_timestamp_argument 'Apple Development: Example (TEAM)')" \
  == '--timestamp=none' ]]
[[ "$(localhistory_codesign_timestamp_argument 'Developer ID Application: Example (TEAM)')" \
  == '--timestamp' ]]
[[ "$(localhistory_codesign_timestamp_argument ABCDEF0123456789)" == '--timestamp=none' ]]
[[ "$(localhistory_codesign_timestamp_argument 'Local Code Signing')" == '--timestamp=none' ]]

for build_script in "$SCRIPT_DIR/build_app.sh" "$SCRIPT_DIR/build_app_core.sh"; do
  /usr/bin/grep -Fq 'source "$CODESIGN_POLICY"' "$build_script"
  /usr/bin/grep -Fq 'localhistory_codesign_timestamp_argument "$SIGN_IDENTITY"' "$build_script"
done

echo "Code-signing policy tests passed: ad-hoc and local identities stay offline; only Developer ID requests a trusted timestamp."
