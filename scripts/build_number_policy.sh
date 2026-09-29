#!/bin/bash

# Sparkle offers an update only when the feed's CFBundleVersion compares higher than the
# installed one. Published releases own the namespace starting at 30000000 (see
# docs/FREE-UPDATES.md). A local build that borrows that namespace can outrank every future
# release and silently stop "Check for Updates" on that Mac, so only the exact number derived
# from the current GitHub run may use it. Local builds stay below and always upgrade.

LOCALHISTORY_RELEASE_BUILD_EPOCH=30000000

localhistory_release_build_number() {
  local run_id="$1"
  local attempt="$2"
  printf '%s.%s.%s\n' "$LOCALHISTORY_RELEASE_BUILD_EPOCH" \
    "$((run_id / 10000))" "$(((run_id % 10000) * 100 + attempt))"
}

localhistory_validate_build_number() {
  local build="$1"
  if [[ ! "$build" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
    echo "Build number must be one to three numeric components; got: $build" >&2
    return 1
  fi
  local first="${build%%.*}"
  if (( 10#$first < LOCALHISTORY_RELEASE_BUILD_EPOCH )); then
    return 0
  fi
  local run_id="${GITHUB_RUN_ID:-}"
  local attempt="${GITHUB_RUN_ATTEMPT:-1}"
  if [[ "${GITHUB_ACTIONS:-}" == "true" && "$run_id" =~ ^[1-9][0-9]*$ && "$attempt" =~ ^[1-9][0-9]?$ ]] \
     && [[ "$build" == "$(localhistory_release_build_number "$run_id" "$attempt")" ]]; then
    return 0
  fi
  echo "Build number $build is in the release namespace (>= $LOCALHISTORY_RELEASE_BUILD_EPOCH)." >&2
  echo "Only the GitHub run that publishes it may use that namespace; a local build numbered" >&2
  echo "this way would outrank future releases and block Check for Updates. Omit" >&2
  echo "LOCALHISTORY_BUILD_NUMBER or use a value below $LOCALHISTORY_RELEASE_BUILD_EPOCH." >&2
  return 1
}
