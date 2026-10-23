#!/bin/bash
# Self test of scripts/gallery.py (spec C §8) on fake runs of tiny PNGs: no xctest, no window, no real base.
# Covers: accept, diff (same, changed with box, new, missing, size), env cause, refusals (dirty tree, non-ok,
# scale), FORCE, partial accept, base lock, base-key pruning, index.html, clean.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
dir="$(mktemp -d /tmp/goalong-gallery-selftest-XXXXXX)"
trap 'rm -rf "$dir"' EXIT
export GALLERY_ROOT="$dir/qa" GALLERY_CACHE="$dir/cache"
unset GALLERY_BASELINE GALLERY_ENVKEY ONLY || true
G=(python3 "$ROOT/scripts/gallery.py")
fail() { echo "test_gallery_script: $*" >&2; exit 1; }

# make_run NAME KEY CLEAN SCALE "key:colour[:status[:WxH]]"...
make_run() {
  python3 - "$GALLERY_ROOT/runs/$1" "$2" "$3" "$4" "${@:5}" <<'PY'
import hashlib, json, os, struct, sys, zlib
run, key, clean, scale, specs = sys.argv[1], sys.argv[2], sys.argv[3] == "1", float(sys.argv[4]), sys.argv[5:]
def png(path, w, h, colour, dot):
    rows = b""
    for y in range(h):
        row = bytearray(b"\x00")
        for x in range(w):
            row += bytes(dot if (x, y) == (2, 1) else colour) + b"\xff"
        rows += bytes(row)
    chunk = lambda t, d: struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
                + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))
    return hashlib.sha256(rows).hexdigest()
images = []
for spec in specs:
    parts = spec.split(":")
    name, colour = parts[0], parts[1]
    status = parts[2] if len(parts) > 2 and parts[2] else "ok"
    w, h = map(int, parts[3].split("x")) if len(parts) > 3 else (6, 4)
    base = (40, 90, 160)
    dot = base if colour == "same" else (255, 0, 0) if colour == "dot" else (0, 255, 0)
    surface, rest = name.split("/")
    state, theme = rest.split("--")
    rel = f"png/{name}.png"
    digest = png(os.path.join(run, rel), w, h, base, dot)
    images.append({"key": f"{name}.png", "id": f"{surface}/{state}", "surface": surface, "state": state,
                   "theme": theme, "size": "", "file": rel, "points": [w // 2, h // 2], "pixels": [w, h],
                   "scale": scale, "sha256": digest, "status": status, "detail": "", "ms": 1,
                   "source": "Fake.swift", "note": ""})
manifest = {"schema": 2, "run": os.path.basename(run), "commit": "abc1234", "branch": "test", "clean": clean,
            "date": "2026-10-23T09:41:00+02:00", "envKey": key, "screen": {"width": 1728, "height": 1117, "scale": scale},
            "windowScale": scale, "locale": "fr_FR", "timeZone": "Europe/Paris", "clock": 1792741260,
            "shards": 1, "only": "", "duration": 1.0, "problems": [], "images": images}
os.makedirs(run, exist_ok=True)
with open(os.path.join(run, "manifest.json"), "w") as f:
    json.dump(manifest, f)
PY
  ln -sfn "runs/$1" "$GALLERY_ROOT/latest"
}

K=25F71-17E202-arm64-2x
# 1. No base yet: diff names the missing key and fails; accept fills the base.
make_run r1 $K 1 2 "a/x--light:same" "a/x--dark:same" "b/y--light:same"
out="$("${G[@]}" diff 2>&1)" && fail "diff without base passed"
[[ "$out" == *"pas de base pour $K"* && "$out" == *"BASE_ENV="* ]] || fail "no-base message: $out"
"${G[@]}" accept >/dev/null
[[ -f "$GALLERY_CACHE/$K/baseline/png/a/x--light.png" && -f "$GALLERY_CACHE/$K/baseline/accept.log" ]] || fail "base not written"
"${G[@]}" diff >/dev/null || fail "diff of the accepted run is not empty"

# 2. One pixel changed, one image new, one gone, one resized: listed with box, cause "code", exit 1.
make_run r2 $K 1 2 "a/x--light:dot" "a/x--dark:same:ok:8x4" "c/z--light:same"
out="$("${G[@]}" diff 2>&1)" && fail "diff with changes passed"
[[ "$out" == *"changé          a/x--light.png"* && "$out" == *"boîte 2,1 1×1 px"* ]] || fail "changed line: $out"
[[ "$out" == *"taille changée  a/x--dark.png  6×4 → 8×4 px"* ]] || fail "resized line: $out"
[[ "$out" == *"nouveau         c/z--light.png"* && "$out" == *"disparu         b/y--light.png"* ]] || fail "new/missing: $out"
[[ "$out" == *"cause probable : code"* ]] || fail "cause: $out"
[[ -f "$GALLERY_ROOT/runs/r2/diff/a/x--light.png" ]] || fail "diff image missing"
"${G[@]}" diff --maxpx 1 >/dev/null 2>&1 && fail "MAXPX hid new and missing images"
python3 - "$GALLERY_ROOT/runs/r2/index.html" <<'PY' || fail "index.html invalid"
import html.parser, sys
text = open(sys.argv[1], encoding="utf-8").read()
html.parser.HTMLParser().feed(text)
assert "a/x--light.png" in text and "<script src" not in text and "http" not in text.replace("http-equiv", ""), "index content"
PY

# 3. Other env key: same pixels compared to an old base through BASE_ENV, cause "environnement".
make_run r3 26A1-18A1-arm64-2x 1 2 "a/x--light:dot" "a/x--dark:same" "b/y--light:same"
out="$("${G[@]}" diff 2>&1)" && fail "diff on a new key passed"
[[ "$out" == *"pas de base pour 26A1-18A1-arm64-2x"* && "$out" == *"$K"* ]] || fail "known keys not shown: $out"
out="$("${G[@]}" diff --base-env $K 2>&1)" && fail "diff BASE_ENV passed"
[[ "$out" == *"cause probable : environnement"* && "$out" == *"1 écart(s)"* ]] || fail "env cause: $out"
"${G[@]}" diff --base-env $K --maxpx 1 >/dev/null || fail "MAXPX=1 did not absorb one pixel"

# 4. Refusals: dirty tree, non-ok entry in the filter, scale change (FORCE=1 passes).
make_run r4 $K 0 2 "a/x--light:dot"
out="$("${G[@]}" accept 2>&1)" && fail "dirty run accepted"
[[ "$out" == *"arbre non propre"* ]] || fail "dirty message: $out"
make_run r5 $K 1 2 "a/x--light:dot" "b/y--light:same:leaky"
out="$("${G[@]}" accept 2>&1)" && fail "non-ok run accepted"
[[ "$out" == *"b/y--light.png (leaky)"* ]] || fail "non-ok message: $out"
# A filter that leaves out the leaky entry is a partial accept: b/y keeps its base image, a/x--dark (gone
# from the filtered run) leaves the base.
"${G[@]}" accept --only a/ >/dev/null || fail "partial accept refused"
python3 - "$GALLERY_CACHE/$K/baseline/manifest.json" <<'PY' || fail "partial accept lost images"
import json, sys
keys = sorted(i["key"] for i in json.load(open(sys.argv[1]))["images"])
assert keys == ["a/x--light.png", "b/y--light.png"], keys
PY
make_run r6 $K 1 1 "a/x--light:dot"
out="$("${G[@]}" accept 2>&1)" && fail "scale change accepted"
[[ "$out" == *"échelle"* && "$out" == *"FORCE=1"* ]] || fail "scale message: $out"
"${G[@]}" accept --force >/dev/null || fail "FORCE=1 refused"

# 5. Lock: a second accept waits, then refuses while another holds the base.
make_run r7 $K 1 1 "a/x--light:same"
python3 -c "import fcntl,sys,time;f=open(sys.argv[1],'a+');fcntl.flock(f,fcntl.LOCK_EX);open(sys.argv[2],'w').close();time.sleep(30)" \
  "$GALLERY_CACHE/$K/baseline.lock" "$dir/locked" &
holder=$!
for _ in $(seq 50); do [[ -f "$dir/locked" ]] && break; python3 -c "import time;time.sleep(0.1)"; done
out="$(GALLERY_LOCK_TIMEOUT=1 "${G[@]}" accept 2>&1)" && { kill $holder; fail "accept ran under a held lock"; }
kill $holder; wait $holder 2>/dev/null || true
[[ "$out" == *"verrouillée"* ]] || fail "lock message: $out"
"${G[@]}" accept >/dev/null || fail "accept after the lock was freed"
[[ "$(ls -A "$GALLERY_CACHE/$K" | grep -c '^\.')" == 0 ]] || fail "temporary base folder left behind"

# 6. Base keys pruned to 3, the current one kept.
for k in k1 k2 k3 k4; do
  make_run "p-$k" "$k" 1 2 "a/x--light:same"
  "${G[@]}" accept >/dev/null
  python3 -c "import time;time.sleep(0.05)"
done
[[ "$(ls "$GALLERY_CACHE" | grep -vc '\.lock$')" == 3 && -d "$GALLERY_CACHE/k4" ]] || fail "base keys not pruned: $(ls "$GALLERY_CACHE")"

# 7. Clean removes the runs and the link, never the base.
"${G[@]}" clean >/dev/null
[[ ! -e "$GALLERY_ROOT/runs" && ! -L "$GALLERY_ROOT/latest" && -d "$GALLERY_CACHE/k4/baseline" ]] || fail "clean"
echo "test_gallery_script: ok"
