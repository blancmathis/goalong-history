#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$ROOT_DIR/.github/workflows/continuous-release.yml"
STABLE_WORKFLOW="$ROOT_DIR/.github/workflows/release.yml"
INSTALLER="$ROOT_DIR/install.sh"

/usr/bin/grep -Fq 'LOCALHISTORY_CODESIGN_IDENTITY:' "$WORKFLOW"
/usr/bin/grep -Fq 'bash scripts/verify_release_bundle.sh "dist/Goalong History.app"' "$WORKFLOW"
/usr/bin/grep -Fq 'bash scripts/verify_release_bundle.sh "dist/Goalong History.app"' "$ROOT_DIR/.github/workflows/prepare-candidate-release.yml"
/usr/bin/grep -Fq "'scripts/verify_release_bundle.sh'" "$ROOT_DIR/scripts/promote_prepared_release.py"
/usr/bin/grep -Fq '/verify_release_identity.sh" "$APP"' "$ROOT_DIR/scripts/verify_release_bundle.sh"
/usr/bin/grep -Fq 'bash scripts/verify_release_identity.sh "$APP"' "$STABLE_WORKFLOW"
/usr/bin/grep -Fq 'Sigstore-backed build-provenance attestation' "$ROOT_DIR/Distribution/rolling-release-notes.md"
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
/usr/bin/grep -Fq 'LOCALHISTORY_REQUIRE_SPARKLE_CONFIGURED=1' "$ROOT_DIR/scripts/verify_release_bundle.sh"
/usr/bin/grep -Fq 'Publish immutable update archive' "$WORKFLOW"
/usr/bin/grep -Fq 'Publish authenticated feed last' "$WORKFLOW"
# Deltas are optional and published in the immutable release, never in latest-main.
/usr/bin/grep -Fq 'LOCALHISTORY_DELTA_BASES_DIR:' "$WORKFLOW"
/usr/bin/grep -Fq 'deltas=(dist/Goalong-History-macOS-universal-from-*.delta)' "$WORKFLOW"

echo "Release policy tests passed: stable pinned identity; authenticated updates; no ad-hoc public fallback."

for file in "$WORKFLOW" "$STABLE_WORKFLOW"; do
  grep -Fq 'bash scripts/import_release_signing_identity.sh' "$file"
  if grep -Fq "LOCALHISTORY_CODESIGN_IDENTITY: '-'" "$file"; then
    echo 'Public releases must not force ad-hoc signing.' >&2; exit 1
  fi
done

# The local-signing path must give the app (only) its entitlements, and the verifier must check them.
PUBLISH_LOCAL="$ROOT_DIR/scripts/publish_local_release.sh"
/usr/bin/grep -Eq 'codesign "\$\{SIGN\[@\]\}" --identifier ai\.goalong\.localhistory --entitlements "\$ROOT/Distribution/GoalongHistory\.entitlements" "\$APP"$' "$PUBLISH_LOCAL"
/usr/bin/grep -Fq 'com.apple.security.personal-information.calendars' "$ROOT_DIR/scripts/verify_local_bundle.sh"

# A manual release builds main's exact commit, and the tag is created at that commit.
/usr/bin/grep -Fq 'target_commitish: ${{ github.sha }}' "$STABLE_WORKFLOW"
/usr/bin/grep -Fq 'Manual releases must run from main' "$STABLE_WORKFLOW"

# Whole runs serialize so a deferred-delta job cannot cancel a pending main publication.
/usr/bin/grep -Eq '^concurrency:$' "$WORKFLOW"
/usr/bin/grep -Fq 'group: goalong-history-main-publication' "$WORKFLOW"

# The monotonic check runs before the public immutable archive is created.
MONOTONIC_LINE="$(/usr/bin/grep -n 'name: Require monotonic authenticated release state' "$WORKFLOW" | /usr/bin/head -n 1 | /usr/bin/cut -d: -f1)"
ARCHIVE_LINE="$(/usr/bin/grep -n 'name: Publish immutable update archive' "$WORKFLOW" | /usr/bin/head -n 1 | /usr/bin/cut -d: -f1)"
test -n "$MONOTONIC_LINE" && test -n "$ARCHIVE_LINE" && test "$MONOTONIC_LINE" -lt "$ARCHIVE_LINE"
# Fast path: the final main/successor rechecks run before the rolling assets and manifest are replaced.
PROMOTE="$ROOT_DIR/scripts/promote_prepared_release.py"
RECHECK_LINE="$(/usr/bin/grep -n "require_successor(authenticated_state(WORK / 'current-public')" "$PROMOTE" | /usr/bin/head -n 1 | /usr/bin/cut -d: -f1)"
ROLLING_LINE="$(/usr/bin/grep -n 'background.submit(rolling_release' "$PROMOTE" | /usr/bin/head -n 1 | /usr/bin/cut -d: -f1)"
test -n "$RECHECK_LINE" && test -n "$ROLLING_LINE" && test "$RECHECK_LINE" -lt "$ROLLING_LINE"
echo "Release publication ordering policy tests passed."
