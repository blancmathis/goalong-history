#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=sparkle_release.env
source "$ROOT_DIR/scripts/sparkle_release.env"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Sparkle tooling requires macOS." >&2
  exit 1
fi
if ! command -v xcrun >/dev/null 2>&1; then
  echo "Xcode Command Line Tools are required." >&2
  exit 1
fi

# Resolving the exact SwiftPM dependency downloads Sparkle's signed binary artifact and
# its release tools into .build/artifacts. Package.swift pins the exact version.
(
  cd "$ROOT_DIR"
  xcrun swift package resolve >/dev/null
)

TOOLS_DIR="$(find "$ROOT_DIR/.build/artifacts" -type d -path '*/sparkle/Sparkle/bin' -print -quit 2>/dev/null || true)"
if [[ -z "$TOOLS_DIR" || ! -x "$TOOLS_DIR/generate_appcast" || ! -x "$TOOLS_DIR/generate_keys" ]]; then
  echo "Sparkle $SPARKLE_VERSION tools were not found after SwiftPM resolution." >&2
  exit 1
fi

printf '%s\n' "$TOOLS_DIR"
