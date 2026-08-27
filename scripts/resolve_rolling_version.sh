#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=sparkle_release.env
source "$ROOT_DIR/scripts/sparkle_release.env"

RUN_SEQUENCE="${1:-${GITHUB_RUN_NUMBER:-}}"
VERSION_FLOOR_FILE="${GOALONG_VERSION_FLOOR_FILE:-$ROOT_DIR/VERSION}"
VERSION_FLOOR="${GOALONG_VERSION_FLOOR:-}"
CURRENT_VERSION="${GOALONG_CURRENT_ROLLING_VERSION:-}"

if [[ ! "$RUN_SEQUENCE" =~ ^[1-9][0-9]*$ ]]; then
  echo "A positive GitHub run number is required." >&2
  exit 1
fi

if [[ -z "$VERSION_FLOOR" ]]; then
  if [[ ! -f "$VERSION_FLOOR_FILE" ]]; then
    echo "Version floor file not found: $VERSION_FLOOR_FILE" >&2
    exit 1
  fi
  VERSION_FLOOR="$(tr -d '[:space:]' < "$VERSION_FLOOR_FILE")"
fi

validate_version() {
  local value="$1"
  local label="$2"
  if [[ ! "$value" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
    echo "$label must be a numeric three-part version such as 0.5.2; got: $value" >&2
    exit 1
  fi
}

version_is_greater() {
  local left="$1"
  local right="$2"
  local left_major left_minor left_patch
  local right_major right_minor right_patch
  IFS=. read -r left_major left_minor left_patch <<< "$left"
  IFS=. read -r right_major right_minor right_patch <<< "$right"

  local left_parts=("$left_major" "$left_minor" "$left_patch")
  local right_parts=("$right_major" "$right_minor" "$right_patch")
  local index left_number right_number
  for index in 0 1 2; do
    left_number=$((10#${left_parts[$index]}))
    right_number=$((10#${right_parts[$index]}))
    if (( left_number > right_number )); then
      return 0
    fi
    if (( left_number < right_number )); then
      return 1
    fi
  done
  return 1
}

validate_version "$VERSION_FLOOR" "VERSION"

if [[ -z "$CURRENT_VERSION" ]]; then
  APPCAST="$(curl --fail --location --silent --show-error --retry 3 "$SPARKLE_FEED_URL")"
  VERSIONS="$(printf '%s\n' "$APPCAST" | sed -nE 's|.*<sparkle:shortVersionString>([^<]+)</sparkle:shortVersionString>.*|\1|p')"
  VERSION_COUNT="$(printf '%s\n' "$VERSIONS" | awk 'NF { count += 1 } END { print count + 0 }')"
  if [[ "$VERSION_COUNT" != "1" ]]; then
    echo "Expected exactly one rolling version in $SPARKLE_FEED_URL; found $VERSION_COUNT." >&2
    exit 1
  fi
  CURRENT_VERSION="$(printf '%s\n' "$VERSIONS" | awk 'NF { print; exit }')"
fi

validate_version "$CURRENT_VERSION" "Current rolling version"

IFS=. read -r CURRENT_MAJOR CURRENT_MINOR CURRENT_PATCH <<< "$CURRENT_VERSION"
AUTOMATIC_VERSION="${CURRENT_MAJOR}.${CURRENT_MINOR}.$((10#$CURRENT_PATCH + 1))"
if version_is_greater "$VERSION_FLOOR" "$AUTOMATIC_VERSION"; then
  NEXT_VERSION="$VERSION_FLOOR"
else
  NEXT_VERSION="$AUTOMATIC_VERSION"
fi

# Apple requires numeric bundle versions. Reserve the 5000.x.y range for rolling
# builds and encode the monotonic GitHub workflow run number in it.
BUILD_MAJOR=$((5000 + RUN_SEQUENCE / 10000))
BUILD_MINOR=$(((RUN_SEQUENCE / 100) % 100))
BUILD_PATCH=$((RUN_SEQUENCE % 100))
BUILD_NUMBER="${BUILD_MAJOR}.${BUILD_MINOR}.${BUILD_PATCH}"

printf 'value=%s\n' "$NEXT_VERSION"
printf 'build=%s\n' "$BUILD_NUMBER"
printf 'Resolved Goalong History %s (%s) from published %s with floor %s.\n' \
  "$NEXT_VERSION" "$BUILD_NUMBER" "$CURRENT_VERSION" "$VERSION_FLOOR" >&2
