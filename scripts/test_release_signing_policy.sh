#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$ROOT_DIR/.github/workflows/continuous-release.yml"
STABLE_WORKFLOW="$ROOT_DIR/.github/workflows/release.yml"
INSTALLER="$ROOT_DIR/install.sh"

/usr/bin/grep -Fq 'LOCALHISTORY_CODESIGN_IDENTITY:' "$WORKFLOW"
/usr/bin/grep -Fq 'bash scripts/verify_release_identity.sh "$APP"' "$WORKFLOW"
/usr/bin/grep -Fq 'bash scripts/verify_release_identity.sh "$APP"' "$STABLE_WORKFLOW"
/usr/bin/grep -Fq 'Sigstore-backed build-provenance attestation' "$WORKFLOW"
/usr/bin/grep -Fq 'actions/attest@1e69f48acb82d1966a394da916b4c1698aa569d6' "$WORKFLOW"
/usr/bin/grep -Fq 'actions/attest@1e69f48acb82d1966a394da916b4c1698aa569d6' "$STABLE_WORKFLOW"
/usr/bin/grep -Fq 'Remove retired rolling-release assets' "$WORKFLOW"
/usr/bin/grep -Fq 'LocalHistory-macOS-universal.dmg' "$WORKFLOW"
/usr/bin/grep -Fq 'appcast.xml' "$WORKFLOW"

if /usr/bin/grep -Eq 'APPLE_API_|notarytool|stapler' "$WORKFLOW" "$STABLE_WORKFLOW"; then
  echo "The free Community release workflow still depends on paid Apple release credentials." >&2
  exit 1
fi

/usr/bin/grep -Fq 'The public artifact does not have Goalong’s pinned stable signing identity.' "$INSTALLER"
/usr/bin/grep -Fq 'Never disable Gatekeeper globally' "$INSTALLER"
/usr/bin/grep -Fq 'Migrating from an old ad-hoc build to the pinned stable identity' "$INSTALLER"

# Authenticated updates are mandatory now; an unsigned fallback must never be published.
/usr/bin/grep -Fq 'SPARKLE_PRIVATE_ED_KEY:' "$WORKFLOW"
/usr/bin/grep -Fq 'LOCALHISTORY_SPARKLE_PUBLIC_ED_KEY:' "$WORKFLOW"
/usr/bin/grep -Fq 'LOCALHISTORY_REQUIRE_SPARKLE_CONFIGURED: 1' "$WORKFLOW"
/usr/bin/grep -Fq 'Publish immutable update archive' "$WORKFLOW"
/usr/bin/grep -Fq 'Publish authenticated feed last' "$WORKFLOW"

echo "Release policy tests passed: stable pinned identity; authenticated updates; no ad-hoc public fallback."

for file in "$WORKFLOW" "$STABLE_WORKFLOW"; do
  grep -Fq 'bash scripts/import_release_signing_identity.sh' "$file"
  if grep -Fq "LOCALHISTORY_CODESIGN_IDENTITY: '-'" "$file"; then
    echo 'Public releases must not force ad-hoc signing.' >&2; exit 1
  fi
done
