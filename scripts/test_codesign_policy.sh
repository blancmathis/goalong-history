#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=codesign_policy.sh
source "$SCRIPT_DIR/codesign_policy.sh"
# shellcheck source=source_codesign_identity.sh
source "$SCRIPT_DIR/source_codesign_identity.sh"

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

fixture_one='  1) AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA "Apple Development: Example (TEAMONE)"'
fixture_two="$fixture_one
  2) BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB \"Apple Development: Other (TEAMTWO)\""
[[ "$(localhistory_choose_source_codesign_identity "$fixture_one")" == 'Apple Development: Example (TEAMONE)' ]]
[[ "$(localhistory_choose_source_codesign_identity "$fixture_two" 'Apple Development: Other (TEAMTWO)')" == 'Apple Development: Other (TEAMTWO)' ]]
[[ "$(localhistory_choose_source_codesign_identity '     0 valid identities found')" == '-' ]]
if localhistory_choose_source_codesign_identity "$fixture_two" >/dev/null 2>&1; then
  echo "Ambiguous local signing identities did not fail closed." >&2
  exit 1
fi
[[ "$(LOCALHISTORY_CODESIGN_IDENTITY='Explicit Local Identity' localhistory_resolve_source_codesign_identity)" == 'Explicit Local Identity' ]]
localhistory_verify_source_codesign_identity '-'
if localhistory_verify_source_codesign_identity 'Missing Goalong Test Identity' >/dev/null 2>&1; then
  echo "An unusable local signing identity did not fail closed." >&2
  exit 1
fi

echo "Code-signing policy tests passed: stable local identity selection, ambiguity refusal, offline local timestamps, and Developer ID trusted timestamps."
