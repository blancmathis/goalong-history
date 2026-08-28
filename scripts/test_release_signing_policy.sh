#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$ROOT_DIR/.github/workflows/continuous-release.yml"
INSTALLER="$ROOT_DIR/install.sh"

/usr/bin/grep -Fq 'Missing required Apple release value:' "$WORKFLOW"
/usr/bin/grep -Fq 'refuses to publish an ad-hoc signed update' "$WORKFLOW"
/usr/bin/grep -Fq 'Developer ID signed and notarized by Apple' "$WORKFLOW"

if /usr/bin/grep -Eq 'apple_enabled=false|Sparkle EdDSA \(free mode\)|This build is ad-hoc code signed' "$WORKFLOW"; then
  echo "The public release workflow still contains an ad-hoc publication path." >&2
  exit 1
fi

/usr/bin/grep -Fq 'The release is not Developer ID signed and notarized by Apple.' "$INSTALLER"
if /usr/bin/grep -Fq 'verified by Sparkle (Apple verification pending)' "$INSTALLER"; then
  echo "The public installer still accepts a release that Apple has not verified." >&2
  exit 1
fi

echo "Release signing policy tests passed: public updates require Developer ID, notarization, and Apple verification."
