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
shopt -s nullglob

ARCHIVE_NAME="Goalong-History-macOS-universal.zip"
DELTA_PREFIX="Goalong-History-macOS-universal-from-"
DOWNLOAD_PREFIX="$SPARKLE_RELEASE_DOWNLOAD_ROOT/$RELEASE_TAG/"
# Optional: previously published archives. A delta is only an optimisation: if it cannot be
# made in time, the feed offers the full archive alone, exactly as before.
DELTA_BASES_DIR="${LOCALHISTORY_DELTA_BASES_DIR:-}"
MAXIMUM_DELTAS=3
DELTA_TIME_LIMIT_SECONDS="${LOCALHISTORY_DELTA_TIME_LIMIT_SECONDS:-1500}"

# APFS clones cost no disk space; plain copies are the fallback.
clone() { cp -c "$1" "$2" 2>/dev/null || cp "$1" "$2"; }

prepare_archives() {
  mkdir -p "$1"
  clone "$ARCHIVE" "$1/$ARCHIVE_NAME"
  cat > "$1/Goalong-History-macOS-universal.html" <<'NOTES'
<h2>Goalong History — analyses et mises à jour</h2>
<p>Analyses locales : focus observé, courbes horaires, vues sur 7 et 28 jours, projets et évolution.</p>
<p>Les mises à jour sont vérifiées par signature Ed25519, sans abonnement Apple. Cette version conserve la signature de distribution existante et ne remplace aucun historique ni réglage de partage.</p>
<p>La première installation d’une version sans updater doit être faite une fois manuellement. Une ancienne signature différente peut demander une nouvelle validation des autorisations macOS. La mise à jour ne doit jamais être présentée comme une nouvelle autorisation de collecte.</p>
NOTES
}

# generate_appcast signs the archive and each delta with EdDSA. Because the embedded app
# opts into SURequireSignedFeed, Sparkle 2.9+ also signs the appcast itself.
# Usage: generate_appcast <archives-dir> <maximum-deltas> [command prefix...]
generate_appcast() {
  local directory="$1" maximum_deltas="$2"
  shift 2
  printf '%s' "$PRIVATE_KEY" | "$@" "$TOOLS_DIR/generate_appcast" \
    --ed-key-file - \
    --download-url-prefix "$DOWNLOAD_PREFIX" \
    --maximum-deltas "$maximum_deltas" \
    --maximum-versions 1 \
    --embed-release-notes \
    -o "$directory/appcast.xml" \
    "$directory"
}

# Runs a command in its own process group and stops the whole group (with its unarchivers)
# after the given number of seconds.
with_time_limit() {
  python3 -c '
import os, signal, subprocess, sys
process = subprocess.Popen(sys.argv[2:], start_new_session=True)
try:
    sys.exit(process.wait(timeout=int(sys.argv[1])))
except subprocess.TimeoutExpired:
    os.killpg(process.pid, signal.SIGKILL)
    process.wait()
    sys.exit(f"Stopped after {sys.argv[1]} s.")
' "$@"
}

# Sparkle names a delta after the app ("Goalong History<new>-<old>.delta"). GitHub rewrites the
# space of a release asset name, which would break the signed URL: rename, then re-sign the feed.
rename_deltas() {
  python3 - "$1" "$DOWNLOAD_PREFIX" "$DELTA_PREFIX" <<'PY' || return 1
import re, sys, urllib.parse
from pathlib import Path
directory, prefix, delta_prefix = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
feed = directory / "appcast.xml"
text = feed.read_text(encoding="utf-8")
def rename(match):
    tag = match.group(0)
    attributes = dict(re.findall(r'([\w:]+)="([^"]*)"', tag))
    url, source = attributes["url"], attributes["sparkle:deltaFrom"]
    assert url.startswith(prefix) and re.fullmatch(r"[0-9]+(\.[0-9]+)*", source), url
    name = f"{delta_prefix}{source}.delta"
    (directory / urllib.parse.unquote(url[len(prefix):])).rename(directory / name)
    return tag.replace(f'url="{url}"', f'url="{prefix}{name}"')
deltas = re.compile(r"<sparkle:deltas>.*?</sparkle:deltas>", re.S)
text = deltas.sub(lambda block: re.sub(r"<enclosure\b[^>]*>", rename, block.group(0)), text)
feed.write_text(text, encoding="utf-8")
PY
  printf '%s' "$PRIVATE_KEY" | "$TOOLS_DIR/sign_update" --ed-key-file - "$1/appcast.xml" >/dev/null || return 1
}

FEED_DIR=""
bases=()
if [[ -n "$DELTA_BASES_DIR" ]]; then bases=("$DELTA_BASES_DIR"/*.zip); fi
if (( ${#bases[@]} > 0 )); then
  DELTA_DIR="$WORK_DIR/with-deltas"
  prepare_archives "$DELTA_DIR"
  for index in "${!bases[@]}"; do
    clone "${bases[$index]}" "$DELTA_DIR/Goalong-History-macOS-universal-base-$index.zip"
  done
  if generate_appcast "$DELTA_DIR" "$MAXIMUM_DELTAS" with_time_limit "$DELTA_TIME_LIMIT_SECONDS" \
      && rename_deltas "$DELTA_DIR"; then
    FEED_DIR="$DELTA_DIR"
  else
    echo "::warning::Delta updates were not generated; the feed offers the full archive only." >&2
  fi
fi
if [[ -z "$FEED_DIR" ]]; then
  FEED_DIR="$WORK_DIR/full"
  prepare_archives "$FEED_DIR"
  generate_appcast "$FEED_DIR" 0
fi

if [[ ! -s "$FEED_DIR/appcast.xml" ]]; then
  echo "Sparkle did not generate an appcast." >&2
  exit 1
fi

mkdir -p "$(dirname "$OUTPUT")"
OUTPUT_DIR="$(cd "$(dirname "$OUTPUT")" && pwd)"
stale=("$OUTPUT_DIR/$DELTA_PREFIX"*.delta)
if (( ${#stale[@]} > 0 )); then rm -f "${stale[@]}"; fi
cp "$FEED_DIR/appcast.xml" "$OUTPUT"
deltas=("$FEED_DIR/$DELTA_PREFIX"*.delta)
if (( ${#deltas[@]} > 0 )); then cp "${deltas[@]}" "$OUTPUT_DIR/"; fi

# Fail closed if the output unexpectedly lacks the security and release metadata we rely on.
grep -q 'sparkle:edSignature=' "$OUTPUT"
grep -Fq "$DOWNLOAD_PREFIX$ARCHIVE_NAME" "$OUTPUT"

# Verify the embedded feed signature, the enclosure and every delta using the shipped key.
printf '%s' "$PRIVATE_KEY" | "$TOOLS_DIR/sign_update" --ed-key-file - --verify "$OUTPUT"
xcrun swift "$ROOT_DIR/scripts/verify_update_archive.swift" "$APP_INFO" "$ARCHIVE" "$OUTPUT" "$OUTPUT_DIR"
echo "Generated and verified signed Sparkle appcast with ${#deltas[@]} delta update(s): $OUTPUT"
