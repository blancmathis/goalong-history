#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

RUN_SEQUENCE="${1:-${GITHUB_RUN_NUMBER:-}}"
VERSION_FLOOR_FILE="${GOALONG_VERSION_FLOOR_FILE:-$ROOT_DIR/VERSION}"
VERSION_FLOOR="${GOALONG_VERSION_FLOOR:-}"
CURRENT_VERSION="${GOALONG_CURRENT_ROLLING_VERSION:-}"
RELEASE_MANIFEST_URL="${GOALONG_RELEASE_MANIFEST_URL:-https://github.com/blancmathis/goalong-history/releases/download/latest-main/release-manifest.json}"
RELEASE_API_URL="${GOALONG_RELEASE_API_URL:-https://api.github.com/repos/blancmathis/goalong-history/releases/tags/latest-main}"

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
    echo "$label must be a numeric three-part version such as 0.6.0; got: $value" >&2
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
  RELEASE_MANIFEST=""
  if RELEASE_MANIFEST="$(/usr/bin/curl --fail --location --silent --retry 3 "$RELEASE_MANIFEST_URL")"; then
    CURRENT_VERSION="$(printf '%s' "$RELEASE_MANIFEST" | /usr/bin/python3 -c 'import json,sys; value=json.load(sys.stdin); print(value.get("product", {}).get("version", ""))')"
  fi

  # Transitional fallback for releases produced before release-manifest.json existed.
  # The source remains GitHub's signed HTTPS API response for the exact rolling tag;
  # arbitrary asset contents or local state are never trusted as a version authority.
  if [[ -z "$CURRENT_VERSION" ]]; then
    RELEASE_METADATA="$(/usr/bin/curl --fail --location --silent --show-error --retry 3 "$RELEASE_API_URL")"
    CURRENT_VERSION="$(printf '%s' "$RELEASE_METADATA" | /usr/bin/python3 -c '
import json
import re
import sys

value = json.load(sys.stdin)
name = value.get("name", "")
match = re.search(r"(?<![0-9])([0-9]+\.[0-9]+\.[0-9]+)(?![0-9])", name)
print(match.group(1) if match else "")
')"
  fi
  if [[ -z "$CURRENT_VERSION" ]]; then
    echo "Neither the rolling manifest nor the exact-tag release name contains a version." >&2
    exit 1
  fi
fi

validate_version "$CURRENT_VERSION" "Current rolling version"

IFS=. read -r CURRENT_MAJOR CURRENT_MINOR CURRENT_PATCH <<< "$CURRENT_VERSION"
AUTOMATIC_VERSION="${CURRENT_MAJOR}.${CURRENT_MINOR}.$((10#$CURRENT_PATCH + 1))"
if version_is_greater "$VERSION_FLOOR" "$AUTOMATIC_VERSION"; then
  NEXT_VERSION="$VERSION_FLOOR"
else
  NEXT_VERSION="$AUTOMATIC_VERSION"
fi

# Apple requires numeric bundle versions. Encode the monotonic GitHub workflow run number in the
# established 5000.x.y rolling-build range.
BUILD_MAJOR=$((5000 + RUN_SEQUENCE / 10000))
BUILD_MINOR=$(((RUN_SEQUENCE / 100) % 100))
BUILD_PATCH=$((RUN_SEQUENCE % 100))
BUILD_NUMBER="${BUILD_MAJOR}.${BUILD_MINOR}.${BUILD_PATCH}"

printf 'value=%s\n' "$NEXT_VERSION"
printf 'build=%s\n' "$BUILD_NUMBER"
printf 'Resolved Goalong History %s (%s) from published %s with floor %s.\n' \
  "$NEXT_VERSION" "$BUILD_NUMBER" "$CURRENT_VERSION" "$VERSION_FLOOR" >&2
