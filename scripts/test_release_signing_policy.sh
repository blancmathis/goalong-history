#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$ROOT_DIR/.github/workflows/continuous-release.yml"
STABLE_WORKFLOW="$ROOT_DIR/.github/workflows/release.yml"
INSTALLER="$ROOT_DIR/install.sh"

/usr/bin/grep -Fq 'LOCALHISTORY_CODESIGN_IDENTITY:' "$WORKFLOW"
/usr/bin/grep -Fq "Community releases must not depend on a certificate-backed Apple identity." "$WORKFLOW"
/usr/bin/grep -Fq "Community releases must not be presented as Apple-notarized builds." "$WORKFLOW"
/usr/bin/grep -Fq 'Sigstore-backed build-provenance attestation' "$WORKFLOW"
/usr/bin/grep -Fq 'actions/attest@1e69f48acb82d1966a394da916b4c1698aa569d6' "$WORKFLOW"
/usr/bin/grep -Fq 'actions/attest@1e69f48acb82d1966a394da916b4c1698aa569d6' "$STABLE_WORKFLOW"
/usr/bin/grep -Fq 'Remove retired rolling-release assets' "$WORKFLOW"
/usr/bin/grep -Fq 'LocalHistory-macOS-universal.dmg' "$WORKFLOW"
/usr/bin/grep -Fq 'appcast.xml' "$WORKFLOW"

if /usr/bin/grep -Eq 'MACOS_CERTIFICATE|APPLE_API_|notarytool|stapler' "$WORKFLOW" "$STABLE_WORKFLOW"; then
  echo "The free Community release workflow still depends on paid Apple release credentials." >&2
  exit 1
fi

/usr/bin/grep -Fq 'The public artifact is not the expected free ad-hoc Community Build.' "$INSTALLER"
/usr/bin/grep -Fq 'Never disable Gatekeeper globally' "$INSTALLER"
/usr/bin/grep -Fq 'This free Community update has a new ad-hoc identity' "$INSTALLER"

if /usr/bin/grep -Eq 'SUFeedURL|SUPublicEDKey|SPARKLE_' "$WORKFLOW"; then
  echo "The public release workflow still contains an automatic-update trust path." >&2
  exit 1
fi

echo "Release policy tests passed: one free ad-hoc Community Build, pinned GitHub provenance attestation, explicit Gatekeeper/permission limits, and no in-app updater."
