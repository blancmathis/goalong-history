#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=sparkle_release.env
source "$ROOT_DIR/scripts/sparkle_release.env"

VERSION="${1:-}"
ARCHIVE="${2:-$ROOT_DIR/dist/Goalong-History-macOS-universal.zip}"
OUTPUT="${3:-$ROOT_DIR/dist/appcast.xml}"
RELEASE_TAG="${4:-v$VERSION}"
APP_INFO="${LOCALHISTORY_UPDATE_APP_INFO:-$ROOT_DIR/dist/Goalong History.app/Contents/Info.plist}"
PRIVATE_KEY="${SPARKLE_PRIVATE_ED_KEY:-}"

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]]; then
  echo "Usage: SPARKLE_PRIVATE_ED_KEY=... $0 <version> [archive] [output] [release-tag]" >&2
  exit 1
fi
if [[ ! "$RELEASE_TAG" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "Invalid release tag: $RELEASE_TAG" >&2
  exit 1
fi
if [[ "$RELEASE_TAG" == "latest-main" ]]; then
  echo "Update downloads must use an immutable per-build release tag." >&2
  exit 1
fi
if [[ ! -s "$ARCHIVE" ]]; then
  echo "Update archive not found: $ARCHIVE" >&2
  exit 1
fi
if [[ -z "$PRIVATE_KEY" ]]; then
  echo "SPARKLE_PRIVATE_ED_KEY is required to sign the update and signed feed." >&2
  exit 1
fi

TOOLS_DIR="$($ROOT_DIR/scripts/fetch_sparkle_tools.sh)"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/localhistory-appcast.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

ARCHIVE_NAME="Goalong-History-macOS-universal.zip"
cp "$ARCHIVE" "$WORK_DIR/$ARCHIVE_NAME"
cat > "$WORK_DIR/Goalong-History-macOS-universal.html" <<'NOTES'
<h2>Goalong History — analyses et mises à jour</h2>
<p>Analyses locales : focus observé, courbes horaires, vues sur 7 et 28 jours, projets et évolution.</p>
<p>Les mises à jour sont vérifiées par signature Ed25519, sans abonnement Apple. Cette version conserve la signature de distribution existante et ne remplace aucun historique ni réglage de partage.</p>
<p>La première installation d’une version sans updater doit être faite une fois manuellement. Une ancienne signature différente peut demander une nouvelle validation des autorisations macOS. La mise à jour ne doit jamais être présentée comme une nouvelle autorisation de collecte.</p>
NOTES
DOWNLOAD_PREFIX="$SPARKLE_RELEASE_DOWNLOAD_ROOT/$RELEASE_TAG/"

# generate_appcast signs the archive enclosure with EdDSA. Because the embedded app
# opts into SURequireSignedFeed, Sparkle 2.9+ also signs the appcast itself.
printf '%s' "$PRIVATE_KEY" | "$TOOLS_DIR/generate_appcast" \
  --ed-key-file - \
  --download-url-prefix "$DOWNLOAD_PREFIX" \
  --maximum-deltas 0 \
  --embed-release-notes \
  -o "$WORK_DIR/appcast.xml" \
  "$WORK_DIR"

if [[ ! -s "$WORK_DIR/appcast.xml" ]]; then
  echo "Sparkle did not generate an appcast." >&2
  exit 1
fi

mkdir -p "$(dirname "$OUTPUT")"
cp "$WORK_DIR/appcast.xml" "$OUTPUT"

# Fail closed if the output unexpectedly lacks the security and release metadata we rely on.
grep -q 'sparkle:edSignature=' "$OUTPUT"
grep -Fq "$DOWNLOAD_PREFIX$ARCHIVE_NAME" "$OUTPUT"

# Verify both the embedded feed signature and the enclosure using the shipped key.
printf '%s' "$PRIVATE_KEY" | "$TOOLS_DIR/sign_update" --ed-key-file - --verify "$OUTPUT"
xcrun swift "$ROOT_DIR/scripts/verify_update_archive.swift" "$APP_INFO" "$ARCHIVE" "$OUTPUT"
echo "Generated and verified signed Sparkle appcast: $OUTPUT"
