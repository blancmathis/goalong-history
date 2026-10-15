#!/bin/bash
# Delta-mode verification must not pass on a stale same-build feed (stubbed curl and verifier).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d /tmp/goalong-feed-wait-test.XXXXXX)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/dist/Goalong History.app/Contents" "$T/feeds"
BUILD=30000000.1.1
/usr/bin/plutil -create xml1 "$T/dist/Goalong History.app/Contents/Info.plist"
/usr/bin/plutil -insert CFBundleVersion -string "$BUILD" "$T/dist/Goalong History.app/Contents/Info.plist"
/usr/bin/plutil -insert CFBundleShortVersionString -string 1.0.0 "$T/dist/Goalong History.app/Contents/Info.plist"
echo zip > "$T/dist/Goalong-History-macOS-universal.zip"
echo delta > "$T/dist/Goalong-History-macOS-universal-from-1.delta"
U=https://github.com/blancmathis/goalong-history/releases/download/main-1-1
printf '{"version":"%s","url":"%s/Goalong-History-macOS-universal.zip","signature":"x","deltas":[]}' "$BUILD" "$U" > "$T/full.json"
printf '{"version":"%s","url":"%s/Goalong-History-macOS-universal.zip","signature":"x","deltas":[{"url":"%s/Goalong-History-macOS-universal-from-1.delta"}]}' "$BUILD" "$U" "$U" > "$T/delta.json"
printf '{"version":"%s","url":"%s/Goalong-History-macOS-universal.zip","signature":"y","deltas":[]}' "$BUILD" "$U" > "$T/other.json"
cat > "$T/bin/curl" <<'STUB'
#!/bin/bash
out=""; url=""
while [[ $# -gt 0 ]]; do case "$1" in -o) out="$2"; shift 2;; https://*) url="$1"; shift;; *) shift;; esac; done
case "$url" in
  *community-appcast.xml)
    n=$(cat "$STUB_DIR/count" 2>/dev/null || echo 0); echo $((n+1)) > "$STUB_DIR/count"
    f="$STUB_DIR/feeds/$n"; [[ -f "$f" ]] || f="$(ls "$STUB_DIR"/feeds/* | tail -n 1)"; cp "$f" "$out";;
  *.delta) cp "$STUB_DIR/dist/Goalong-History-macOS-universal-from-1.delta" "$out";;
  *) cp "$STUB_DIR/dist/Goalong-History-macOS-universal.zip" "$out";;
esac
STUB
cat > "$T/verify" <<'STUB'
#!/bin/bash
[[ "$1" == "--feed-only" ]] && cat "$3"
exit 0
STUB
chmod +x "$T/bin/curl" "$T/verify"
sha() { shasum -a 256 "$1" | cut -d' ' -f1; }
run() { # attempts files...
  rm -f "$T/count" "$T"/feeds/*; local i=0
  for f in "$@"; do cp "$T/$f" "$T/feeds/$i"; i=$((i+1)); done
  STUB_DIR="$T" PATH="$T/bin:$PATH" LOCALHISTORY_UPDATE_VERIFIER="$T/verify" LOCALHISTORY_VERIFY_RETRY_SECONDS=0 \
    LOCALHISTORY_EXPECTED_FEED_SHA256="$(sha "$T/delta.json")" LOCALHISTORY_PREVIOUS_FEED_SHA256="$(sha "$T/full.json")" \
    bash "$ROOT/scripts/verify_published_update.sh" "$T/dist" >/dev/null 2>"$T/err"
}
# Stale same-build full feed, then the delta feed: retries, then passes.
run full.json full.json delta.json
# The stale feed for the whole window fails.
if run full.json; then echo 'Stale same-build feed must fail.' >&2; exit 1; fi
/usr/bin/grep -Fq 'not visible' "$T/err"
# An unknown same-build digest fails at once.
if run other.json delta.json; then echo 'Unknown same-build feed must fail.' >&2; exit 1; fi
/usr/bin/grep -Fq 'neither the expected delta generation' "$T/err"
echo 'Delta feed verification tests passed.'
