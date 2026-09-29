#!/bin/bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=build_number_policy.sh
source "$ROOT_DIR/scripts/build_number_policy.sh"

accept() { ( "$@" ) 2>/dev/null || { echo "Expected acceptance: $*" >&2; exit 1; }; }
reject() { if ( "$@" ) 2>/dev/null; then echo "Expected rejection: $*" >&2; exit 1; fi; }

unset GITHUB_ACTIONS GITHUB_RUN_ID GITHUB_RUN_ATTEMPT

# Published formula is unchanged: staging run 36557503315, attempt 1 shipped as 0.6.50.
test "$(localhistory_release_build_number 36557503315 1)" = "30000000.3655750.331501"

# Local builds stay below the release namespace.
accept localhistory_validate_build_number 1
accept localhistory_validate_build_number 20260929.123456
accept localhistory_validate_build_number 29999999.9.9

# The build that blocked updates on the owner's Mac, and any other local use of the namespace.
reject localhistory_validate_build_number 30000000.20260926.1822
reject localhistory_validate_build_number 30000000.3655750.331501
reject localhistory_validate_build_number 99999999
reject localhistory_validate_build_number 1.2.3.4
reject localhistory_validate_build_number abc

# CI may use exactly its own run's number, nothing else.
export GITHUB_ACTIONS=true GITHUB_RUN_ID=36557503315 GITHUB_RUN_ATTEMPT=1
accept localhistory_validate_build_number 30000000.3655750.331501
reject localhistory_validate_build_number 30000000.3655750.331502
reject localhistory_validate_build_number 30000000.20260926.1822
GITHUB_RUN_ATTEMPT=2 accept localhistory_validate_build_number 30000000.3655750.331502

# resolve_rolling_version.sh emits a number the build accepts in the same run.
build="$(GOALONG_VERSION_FLOOR=0.6.0 GOALONG_CURRENT_ROLLING_VERSION=0.6.50 \
  bash "$ROOT_DIR/scripts/resolve_rolling_version.sh" 1 2>/dev/null | sed -n 's/^build=//p')"
test "$build" = "30000000.3655750.331501"
accept localhistory_validate_build_number "$build"

echo "Build number policy passed."
