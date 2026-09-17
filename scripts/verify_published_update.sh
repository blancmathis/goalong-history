#!/bin/bash
# Downloads from the actual public channel; uses only the committed PUBLIC trust anchor.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="${1:-$ROOT/dist}"
WORK="$(mktemp -d /tmp/goalong-published-update.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
xcrun swiftc "$ROOT/scripts/verify_update_archive.swift" -o "$WORK/verify"
source "$ROOT/scripts/sparkle_release.env"
curl --fail --location --silent --show-error --retry 3 --connect-timeout 15 --max-time 90 --proto '=https' --proto-redir '=https' "$SPARKLE_FEED_URL" -o "$WORK/feed.xml"
"$WORK/verify" --feed-only "$(cat "$ROOT/Distribution/sparkle-public-ed-key.txt")" "$WORK/feed.xml" > "$WORK/feed.json"
URL="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["url"])' "$WORK/feed.json")"
curl --fail --location --silent --show-error --retry 3 --connect-timeout 15 --max-time 300 --max-filesize 350000000 --proto '=https' --proto-redir '=https' "$URL" -o "$WORK/update.zip"
"$WORK/verify" "$DIST/Goalong History.app/Contents/Info.plist" "$WORK/update.zip" "$WORK/feed.xml"
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
assert digest(work/'update.zip')==digest(dist/'Goalong-History-macOS-universal.zip'), 'Published ZIP differs from the tested release'
print('PUBLIC_UPDATE_VERIFIED',info['CFBundleShortVersionString'],info['CFBundleVersion'],info.get('GoalongSourceRevision','unknown'))
PY
