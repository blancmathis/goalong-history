#!/bin/bash
# Downloads from the actual public channel; uses only the committed PUBLIC trust anchor.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="${1:-$ROOT/dist}"
WORK="$(mktemp -d /tmp/goalong-published-update.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
if [[ -n "${LOCALHISTORY_UPDATE_VERIFIER:-}" ]]; then cp "$LOCALHISTORY_UPDATE_VERIFIER" "$WORK/verify"; else xcrun swiftc "$ROOT/scripts/verify_update_archive.swift" -o "$WORK/verify"; fi
source "$ROOT/scripts/sparkle_release.env"
for feed_digest in "${LOCALHISTORY_EXPECTED_FEED_SHA256:-}" "${LOCALHISTORY_PREVIOUS_FEED_SHA256:-}"; do
  [[ -z "$feed_digest" || "$feed_digest" =~ ^[0-9a-f]{64}$ ]] || { echo 'Invalid expected feed digest.' >&2; exit 1; }
done
EXPECTED_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$DIST/Goalong History.app/Contents/Info.plist")"
# GitHub may serve the previous authenticated generation for minutes after replacement
# (45 s was too short on 2026-10-11), so wait up to about 5 minutes.
# Retry only a VALID older feed, at the unchanged client URL. Malformed/unsigned
# feeds and a newer unexpected generation fail immediately. Check before any ZIP.
for ((attempt=0; attempt<60; attempt++)); do
  if [[ "${LOCALHISTORY_FEED_SOURCE:-public}" == api ]]; then
    # Same asset as $SPARKLE_FEED_URL, read through the authenticated API (no download cache).
    FEED_REPO="$(echo "$SPARKLE_FEED_URL" | cut -d/ -f4-5)"
    FEED_TAG="$(echo "$SPARKLE_FEED_URL" | cut -d/ -f8)"
    FEED_ASSET="$(gh api "repos/$FEED_REPO/releases/tags/$FEED_TAG" --jq ".assets[] | select(.name == \"${SPARKLE_FEED_URL##*/}\") | .id")"
    gh api -H 'Accept: application/octet-stream' "repos/$FEED_REPO/releases/assets/$FEED_ASSET" > "$WORK/feed.xml"
  else
    curl --fail --location --silent --show-error --retry 3 --connect-timeout 15 --max-time 90 \
      --header 'Cache-Control: no-cache' --header 'Pragma: no-cache' \
      --proto '=https' --proto-redir '=https' "$SPARKLE_FEED_URL" -o "$WORK/feed.xml"
  fi
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
  if [[ "$STATUS" == 0 && -n "${LOCALHISTORY_EXPECTED_FEED_SHA256:-}" ]]; then
    # Delta mode: the build number alone cannot tell the delta feed from the same-build full feed.
    # Only the previous (full) generation may still be served; any other digest fails at once.
    FEED_SHA256="$(shasum -a 256 "$WORK/feed.xml" | cut -d' ' -f1)"
    if [[ "$FEED_SHA256" != "$LOCALHISTORY_EXPECTED_FEED_SHA256" ]]; then
      if [[ -n "${LOCALHISTORY_PREVIOUS_FEED_SHA256:-}" && "$FEED_SHA256" != "$LOCALHISTORY_PREVIOUS_FEED_SHA256" ]]; then
        echo 'Public feed is neither the expected delta generation nor the previous full generation.' >&2
        exit 1
      fi
      STATUS=2
    fi
  fi
  if [[ "$STATUS" == 0 ]]; then break; fi
  [[ "$STATUS" == 2 && "$attempt" -lt 59 ]] || { echo 'Expected authenticated public build is not visible.' >&2; exit 1; }
  sleep "${LOCALHISTORY_VERIFY_RETRY_SECONDS:-5}"
done
if [[ -n "${LOCALHISTORY_EXPECTED_FEED_SHA256:-}" ]]; then
  # The served delta feed must list exactly the delta files that were uploaded from $DIST.
  python3 - "$WORK/feed.json" "$DIST" <<'PY'
import json,sys
from pathlib import Path
served=sorted(Path(d['url']).name for d in json.load(open(sys.argv[1]))['deltas'])
uploaded=sorted(p.name for p in Path(sys.argv[2]).glob('Goalong-History-macOS-universal-from-*.delta'))
assert served and served==uploaded, 'Published delta list differs from the uploaded deltas'
PY
fi
URL="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["url"])' "$WORK/feed.json")"
PUBLIC_GET_STARTED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
if [[ -n "${LOCALHISTORY_PUBLIC_RECEIPT:-}" ]]; then
  test -z "${LOCALHISTORY_PREFETCHED_ARCHIVE:-}"
fi
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
export PUBLIC_GET_STARTED
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
print('PUBLIC_UPDATE_VERIFIED',info['CFBundleShortVersionString'],info['CFBundleVersion'],'tree',info.get('GoalongSourceRevision','unknown'))
import os
if os.environ.get('LOCALHISTORY_PUBLIC_RECEIPT'):
 from datetime import datetime,timezone
 feed=json.loads((work/'feed.json').read_text())
 import subprocess
 commit=subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip()
 tree=subprocess.check_output(['git','rev-parse','HEAD^{tree}'],text=True).strip()
 assert info['GoalongSourceRevision']==tree, 'Published bundle tree differs from the publisher checkout'
 receipt={'schemaVersion':1,'sourceCommit':commit,'sourceTree':tree,'tag':feed['url'].split('/')[-2],
  'runId':int(os.environ['GITHUB_RUN_ID']),'runAttempt':int(os.environ['GITHUB_RUN_ATTEMPT']),
  'version':info['CFBundleShortVersionString'],'build':info['CFBundleVersion'],
  'manifestSha256':digest(dist/'release-manifest.json'),'feedSha256':digest(work/'feed.xml'),
  'archive':{'url':feed['url'],'sizeBytes':(work/'update.zip').stat().st_size,
             'sha256':digest(work/'update.zip'),'edSignature':feed['signature']},
  'publicGET':{'authenticated':os.environ.get('LOCALHISTORY_FEED_SOURCE')=='api','complete':True,'startedAt':os.environ['PUBLIC_GET_STARTED']},
  'verification':'PUBLIC_UPDATE_VERIFIED','verifiedAt':datetime.now(timezone.utc).isoformat()}
 Path(os.environ['LOCALHISTORY_PUBLIC_RECEIPT']).write_text(json.dumps(receipt,indent=2)+'\n')
PY
