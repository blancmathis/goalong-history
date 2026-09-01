#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$ROOT_DIR/.github/workflows/continuous-release.yml"
INSTALLER="$ROOT_DIR/install.sh"

/usr/bin/grep -Fq 'Missing required Apple release value:' "$WORKFLOW"
/usr/bin/grep -Fq 'refuses to publish an ad-hoc signed update' "$WORKFLOW"
/usr/bin/grep -Fq 'Developer ID signed and notarized by Apple' "$WORKFLOW"
/usr/bin/grep -Fq 'Public release skipped; missing Apple value:' "$WORKFLOW"
/usr/bin/grep -Fq "needs.release-readiness.outputs.apple_enabled == 'true'" "$WORKFLOW"
/usr/bin/grep -Fq 'Remove retired rolling-release assets' "$WORKFLOW"
/usr/bin/grep -Fq 'LocalHistory-macOS-universal.dmg' "$WORKFLOW"
/usr/bin/grep -Fq 'appcast.xml' "$WORKFLOW"

if /usr/bin/grep -Eq 'Sparkle EdDSA \(free mode\)|This build is ad-hoc code signed' "$WORKFLOW"; then
  echo "The public release workflow still contains an ad-hoc publication path." >&2
  exit 1
fi

/usr/bin/grep -Fq 'The release is not Developer ID signed and notarized by Apple.' "$INSTALLER"
if /usr/bin/grep -Fq 'verified by Sparkle (Apple verification pending)' "$INSTALLER"; then
  echo "The public installer still accepts a release that Apple has not verified." >&2
  exit 1
fi

if /usr/bin/grep -Eq 'SUFeedURL|SUPublicEDKey|SPARKLE_' "$WORKFLOW"; then
  echo "The public release workflow still contains an automatic-update trust path." >&2
  exit 1
fi

echo "Release signing policy tests passed: public releases require Developer ID, notarization, Apple verification, and no in-app updater."
