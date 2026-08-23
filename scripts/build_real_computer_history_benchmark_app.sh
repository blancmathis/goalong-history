#!/bin/bash
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="${LOCALHISTORY_APP_PATH:-$REPO/dist/Goalong History.app}"
MANIFEST="${LOCALHISTORY_BENCHMARK_BUILD_MANIFEST:-$REPO/dist/goalong-real-benchmark-build.json}"
INSTALL=0

usage() {
  cat <<'USAGE'
Usage: build_real_computer_history_benchmark_app.sh [--install]

Required environment:
  LOCALHISTORY_CODESIGN_IDENTITY='Developer ID Application: NAME (TEAMID)'

The script builds the exact clean HEAD, verifies the Developer ID signature, records the
binary hash and code-signing identity in a local manifest, and optionally installs that
exact bundle at /Applications/Goalong History.app. It never resets or changes TCC.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install) INSTALL=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 64 ;;
  esac
done

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This benchmark build must run on macOS." >&2
  exit 69
fi
if [[ ! -d "$REPO/.git" || ! -f "$REPO/Package.swift" ]]; then
  echo "Not a Goalong History checkout: $REPO" >&2
  exit 66
fi

DIRTY="$(git -C "$REPO" status --porcelain)"
if [[ -n "$DIRTY" ]]; then
  echo "Use a clean checkout before producing parity evidence:" >&2
  echo "$DIRTY" >&2
  exit 65
fi

HEAD_SHA="$(git -C "$REPO" rev-parse HEAD)"
BRANCH="$(git -C "$REPO" branch --show-current)"
SIGN_IDENTITY="${LOCALHISTORY_CODESIGN_IDENTITY:-}"
if [[ -z "$SIGN_IDENTITY" ]]; then
  echo "LOCALHISTORY_CODESIGN_IDENTITY is required." >&2
  /usr/bin/security find-identity -v -p codesigning >&2 || true
  exit 77
fi
case "$SIGN_IDENTITY" in
  "Developer ID Application: "*) ;;
  *)
    echo "A Developer ID Application identity is required, not: $SIGN_IDENTITY" >&2
    exit 77
    ;;
esac

printf 'Building exact source commit %s on %s\n' "$HEAD_SHA" "$BRANCH"
LOCALHISTORY_CODESIGN_IDENTITY="$SIGN_IDENTITY" \
  "$REPO/scripts/build_app.sh"

if [[ ! -d "$APP_PATH" ]]; then
  echo "Build did not produce $APP_PATH" >&2
  exit 70
fi
/usr/bin/codesign --verify --strict --verbose=2 "$APP_PATH"

CODESIGN_DETAILS="$(/usr/bin/codesign -d --verbose=4 "$APP_PATH" 2>&1)"
if ! /usr/bin/grep -q '^Authority=Developer ID Application:' <<<"$CODESIGN_DETAILS"; then
  echo "Built app does not carry a Developer ID Application authority." >&2
  echo "$CODESIGN_DETAILS" >&2
  exit 70
fi

BUNDLE_ID="$(/usr/bin/defaults read "$APP_PATH/Contents/Info" CFBundleIdentifier)"
if [[ "$BUNDLE_ID" != "ai.goalong.localhistory" ]]; then
  echo "Unexpected bundle identifier: $BUNDLE_ID" >&2
  exit 70
fi

BINARY="$APP_PATH/Contents/MacOS/Goalong History"
if [[ ! -x "$BINARY" ]]; then
  echo "Missing app executable: $BINARY" >&2
  exit 70
fi
BINARY_SHA256="$(/usr/bin/shasum -a 256 "$BINARY" | /usr/bin/awk '{print $1}')"
TEAM_ID="$(/usr/bin/sed -n 's/^TeamIdentifier=//p' <<<"$CODESIGN_DETAILS" | /usr/bin/head -1)"
CDHASH="$(/usr/bin/sed -n 's/^CDHash=//p' <<<"$CODESIGN_DETAILS" | /usr/bin/head -1)"
AUTHORITY="$(/usr/bin/sed -n 's/^Authority=//p' <<<"$CODESIGN_DETAILS" | /usr/bin/head -1)"
DESIGNATED_REQUIREMENT="$(/usr/bin/codesign -d -r- "$APP_PATH" 2>&1 | /usr/bin/tail -1)"
BUILT_AT="$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)"

mkdir -p "$(dirname "$MANIFEST")"
HEAD_SHA="$HEAD_SHA" \
BRANCH="$BRANCH" \
BUILT_AT="$BUILT_AT" \
APP_PATH="$APP_PATH" \
BUNDLE_ID="$BUNDLE_ID" \
BINARY_SHA256="$BINARY_SHA256" \
TEAM_ID="$TEAM_ID" \
CDHASH="$CDHASH" \
AUTHORITY="$AUTHORITY" \
DESIGNATED_REQUIREMENT="$DESIGNATED_REQUIREMENT" \
/usr/bin/python3 - "$MANIFEST" <<'PY'
from __future__ import annotations

import json
import os
import pathlib
import sys

keys = [
    "HEAD_SHA",
    "BRANCH",
    "BUILT_AT",
    "APP_PATH",
    "BUNDLE_ID",
    "BINARY_SHA256",
    "TEAM_ID",
    "CDHASH",
    "AUTHORITY",
    "DESIGNATED_REQUIREMENT",
]
payload = {key.lower(): os.environ.get(key) for key in keys}
payload.update(
    {
        "schema": 1,
        "type": "goalong-real-benchmark-build",
        "developer_id_application": payload["authority"].startswith(
            "Developer ID Application:"
        ),
    }
)
path = pathlib.Path(sys.argv[1])
path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
PY
chmod 600 "$MANIFEST"

printf 'Build manifest: %s\n' "$MANIFEST"
printf 'Binary SHA-256: %s\n' "$BINARY_SHA256"
printf 'Team ID: %s\n' "$TEAM_ID"

if [[ "$INSTALL" -eq 1 ]]; then
  INSTALLED_APP="/Applications/Goalong History.app"
  echo "Installing the exact verified bundle at $INSTALLED_APP"
  /usr/bin/sudo /usr/bin/ditto "$APP_PATH" "$INSTALLED_APP"
  /usr/bin/codesign --verify --strict --verbose=2 "$INSTALLED_APP"
  INSTALLED_BINARY="$INSTALLED_APP/Contents/MacOS/Goalong History"
  INSTALLED_SHA256="$(/usr/bin/shasum -a 256 "$INSTALLED_BINARY" | /usr/bin/awk '{print $1}')"
  if [[ "$INSTALLED_SHA256" != "$BINARY_SHA256" ]]; then
    echo "Installed binary does not match the recorded benchmark build." >&2
    exit 70
  fi
  /usr/bin/open "$INSTALLED_APP"
  echo "Installed binary matches exact HEAD $HEAD_SHA."
fi
