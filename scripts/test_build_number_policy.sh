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

# make dev: a development bundle (debug, updates off) shows the installed release's number.
accept localhistory_validate_build_number 30000000.3655750.331501 1
reject localhistory_validate_build_number 30000000.3655750.331501 0
reject localhistory_validate_build_number abc 1
# build_app_core.sh checks after its development-bundle guard, which enforces debug + updates off.
# shellcheck disable=SC2016 # literal source text, not an expansion
grep -q 'localhistory_validate_build_number "$BUILD_NUMBER" "$DEVELOPMENT_BUILD"' \
  "$ROOT_DIR/scripts/build_app_core.sh"

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

# make local: exactly the try slot (attempt 99) of a published release, above it, below the next run.
test "$(localhistory_local_try_build_number 30000000.4266167.303702)" = "30000000.4266167.303799"
test "$(localhistory_local_try_build_number 30000000.4266167.1201)" = "30000000.4266167.1299"
reject localhistory_local_try_build_number 30000000.4266167.303799
reject localhistory_local_try_build_number 20260929.123456
reject localhistory_local_try_build_number 30000000.4266167
(
  unset GITHUB_ACTIONS GITHUB_RUN_ID GITHUB_RUN_ATTEMPT
  export LOCALHISTORY_LOCAL_TRY_BASE=30000000.4266167.303702
  accept localhistory_validate_build_number 30000000.4266167.303799
  reject localhistory_validate_build_number 30000000.4266167.303798
  reject localhistory_validate_build_number 30000000.4266168.1
  reject localhistory_validate_build_number 30000000.99999999.99
  GITHUB_ACTIONS=true reject localhistory_validate_build_number 30000000.4266167.303799
)
# CI attempt 99 is reserved for the local try: the validator refuses it even for the exact run number.
(
  export GITHUB_ACTIONS=true GITHUB_RUN_ID=42661670000
  GITHUB_RUN_ATTEMPT=98 accept localhistory_validate_build_number "$(localhistory_release_build_number 42661670000 98)"
  GITHUB_RUN_ATTEMPT=99 reject localhistory_validate_build_number "$(localhistory_release_build_number 42661670000 99)"
)
# Manifest base cap: near the installed build and under the time ceiling (now = 2026-11-11).
now=1794355200
accept localhistory_manifest_base_plausible 30000000.4266170.101 30000000.4266167.303702 "$now"
reject localhistory_manifest_base_plausible 30000000.4290000.101 30000000.4266167.303702 "$now"
accept localhistory_manifest_base_plausible 30000000.4268000.101 "" "$now"
reject localhistory_manifest_base_plausible 30000000.9999999.101 "" "$now"
reject localhistory_manifest_base_plausible 20260929.123456 "" "$now"
# Sparkle (numeric per component) orders: release < its try < the next run's release.
sorted="$(printf '%s\n' 30000000.4266168.1 30000000.4266167.303799 30000000.4266167.303702 \
  | sort -t. -k1,1n -k2,2n -k3,3n | tr '\n' ' ')"
test "$sorted" = "30000000.4266167.303702 30000000.4266167.303799 30000000.4266168.1 "
test "$(localhistory_local_try_build_number 30000000.4266167.999901)" = "30000000.4266167.999999"

# R10 O1: the local deploy controller builds in the release namespace with the hosted run's real ID, so it must
# declare GITHUB_ACTIONS=true next to GITHUB_RUN_ID, or the policy above refuses its own number (the launchd
# agent stays disabled; this keeps the path correct when it is switched back on).
grep -q '"GITHUB_ACTIONS": "true"' "$ROOT_DIR/scripts/local_auto_deploy.py" || {
  echo "local_auto_deploy.py must set GITHUB_ACTIONS=true with GITHUB_RUN_ID" >&2; exit 1; }

echo "Build number policy passed."
