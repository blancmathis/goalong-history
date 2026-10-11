#!/bin/bash
# Downloads from the actual public channel; uses only the committed PUBLIC trust anchor.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="${1:-$ROOT/dist}"
WORK="$(mktemp -d /tmp/goalong-published-update.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
xcrun swiftc "$ROOT/scripts/verify_update_archive.swift" -o "$WORK/verify"
source "$ROOT/scripts/sparkle_release.env"
EXPECTED_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$DIST/Goalong History.app/Contents/Info.plist")"
# GitHub may briefly serve the previous authenticated generation after replacement.
# Retry only a VALID older feed, at the unchanged client URL. Malformed/unsigned
# feeds and a newer unexpected generation fail immediately. Check before any ZIP.
for ((attempt=0; attempt<20; attempt++)); do
  curl --fail --location --silent --show-error --retry 3 --connect-timeout 15 --max-time 90 \
    --header 'Cache-Control: no-cache' --header 'Pragma: no-cache' \
    --proto '=https' --proto-redir '=https' "$SPARKLE_FEED_URL" -o "$WORK/feed.xml"
  "$WORK/verify" --feed-only "$(cat "$ROOT/Distribution/sparkle-public-ed-key.txt")" "$WORK/feed.xml" > "$WORK/feed.json"
  set +e
  python3 - "$WORK/feed.json" "$EXPECTED_BUILD" <<'PY'
import json,re,sys
def numeric(value):
 assert re.fullmatch(r'[0-9]+(?:\.[0-9]+){0,3}',value), 'Invalid authenticated build'
 parts=tuple(map(int,value.split('.')));return parts+(0,)*(4-len(parts))
actual=json.load(open(sys.argv[1]))['version'];expected=sys.argv[2]
if actual==expected:sys.exit(0)
assert numeric(actual)<numeric(expected), 'Public feed has a newer unexpected build'
sys.exit(2)
PY
  STATUS=$?
  set -e
  if [[ "$STATUS" == 0 ]]; then break; fi
  [[ "$STATUS" == 2 && "$attempt" -lt 19 ]] || { echo 'Expected authenticated public build is not visible.' >&2; exit 1; }
  sleep 2
done
URL="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["url"])' "$WORK/feed.json")"
if [[ -n "${LOCALHISTORY_PREFETCHED_ARCHIVE:-}" ]]; then
  test "$URL" = "${LOCALHISTORY_PREFETCHED_ARCHIVE_URL:-}"
  # The coordinator downloaded this immutable public URL during rolling publication.
  # The same signed feed, size, archive Ed25519 and expected digest checks follow.
  cp -c "$LOCALHISTORY_PREFETCHED_ARCHIVE" "$WORK/update.zip"
else
  curl --fail --location --silent --show-error --retry 3 --connect-timeout 15 --max-time 300 --max-filesize 350000000 --proto '=https' --proto-redir '=https' "$URL" -o "$WORK/update.zip"
fi
mkdir -p "$WORK/deltas"
while IFS= read -r DELTA_URL; do
  curl --fail --location --silent --show-error --retry 3 --connect-timeout 15 --max-time 300 --max-filesize 350000000 --proto '=https' --proto-redir '=https' "$DELTA_URL" -o "$WORK/deltas/${DELTA_URL##*/}"
done < <(python3 -c 'import json,sys;[print(d["url"]) for d in json.load(open(sys.argv[1]))["deltas"]]' "$WORK/feed.json")
"$WORK/verify" "$DIST/Goalong History.app/Contents/Info.plist" "$WORK/update.zip" "$WORK/feed.xml" "$WORK/deltas"
python3 - "$DIST" "$WORK" <<'PY'
import hashlib,json,plistlib,sys
from pathlib import Path
dist,work=map(Path,sys.argv[1:])
info=plistlib.loads((dist/'Goalong History.app/Contents/Info.plist').read_bytes())
assert json.loads((work/'feed.json').read_text())['version']==info['CFBundleVersion'], 'Public feed is serving a different build'
def digest(p):
 h=hashlib.sha256()
 with p.open('rb') as f:
  for block in iter(lambda:f.read(1024*1024),b''):h.update(block)
 return h.hexdigest()
expected=__import__('os').environ.get('LOCALHISTORY_EXPECTED_ARCHIVE_SHA256')
if expected:
 import re
 assert re.fullmatch('[0-9a-f]{64}',expected), 'Invalid expected attested archive digest'
else:expected=digest(dist/'Goalong-History-macOS-universal.zip')
assert digest(work/'update.zip')==expected, 'Published ZIP differs from the tested release'
for delta in (work/'deltas').iterdir():
 assert digest(delta)==digest(dist/delta.name), f'Published {delta.name} differs from the tested release'
print('PUBLIC_UPDATE_VERIFIED',info['CFBundleShortVersionString'],info['CFBundleVersion'],info.get('GoalongSourceRevision','unknown'))
PY
