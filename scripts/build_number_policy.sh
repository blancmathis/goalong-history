#!/bin/bash

# Sparkle offers an update only when the feed's CFBundleVersion compares higher than the
# installed one. Published releases own the namespace starting at 30000000 (see
# docs/FREE-UPDATES.md). A local build that borrows that namespace can outrank every future
# release and silently stop "Check for Updates" on that Mac, so only the exact number derived
# from the current GitHub run may use it. Local builds stay below and always upgrade.

LOCALHISTORY_RELEASE_BUILD_EPOCH=30000000
# make local (owner try, signed like a release): the base release's run slot with this attempt.
LOCALHISTORY_LOCAL_TRY_ATTEMPT=99

localhistory_release_build_number() {
  local run_id="$1"
  local attempt="$2"
  printf '%s.%s.%s\n' "$LOCALHISTORY_RELEASE_BUILD_EPOCH" \
    "$((run_id / 10000))" "$(((run_id % 10000) * 100 + attempt))"
}

# A local try installed beside nothing (it replaces Goalong in /Applications) must outrank the
# release it replaces, or Sparkle reinstalls that release at once, and must stay below every later
# release, or it blocks updates. It reuses the base release's run slot with attempt 99 (hosted
# attempts stop far earlier): a later run has a larger ID, so the next release still upgrades it.
localhistory_local_try_build_number() {
  local base="$1"
  if [[ ! "$base" =~ ^${LOCALHISTORY_RELEASE_BUILD_EPOCH}\.([1-9][0-9]*)\.([1-9][0-9]*)$ ]]; then
    echo "A local try needs a published release build as its base; got: $base" >&2
    return 1
  fi
  local high="${BASH_REMATCH[1]}" low="${BASH_REMATCH[2]}"
  local slot=$((10#$low / 100)) attempt=$((10#$low % 100))
  if (( attempt < 1 || attempt >= LOCALHISTORY_LOCAL_TRY_ATTEMPT || slot > 9999 )); then
    echo "Base build $base has no free local-try slot." >&2
    return 1
  fi
  printf '%s.%s.%s\n' "$LOCALHISTORY_RELEASE_BUILD_EPOCH" "$high" "$((slot * 100 + LOCALHISTORY_LOCAL_TRY_ATTEMPT))"
}

localhistory_validate_build_number() {
  local build="$1"
  local development="${2:-0}"
  if [[ ! "$build" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
    echo "Build number must be one to three numeric components; got: $build" >&2
    return 1
  fi
  local first="${build%%.*}"
  if (( 10#$first < LOCALHISTORY_RELEASE_BUILD_EPOCH )); then
    return 0
  fi
  # A development bundle (make dev: debug, updates disabled, enforced by build_app_core.sh)
  # only displays the installed release's number and never asks Sparkle, so it may carry it.
  if [[ "$development" == 1 ]]; then
    return 0
  fi
  # make local: exactly the try number of the release it replaces; never inside CI.
  if [[ "${GITHUB_ACTIONS:-}" != "true" && -n "${LOCALHISTORY_LOCAL_TRY_BASE:-}" ]] \
     && [[ "$build" == "$(localhistory_local_try_build_number "$LOCALHISTORY_LOCAL_TRY_BASE" 2>/dev/null)" ]]; then
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
