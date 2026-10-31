#!/usr/bin/env bash
# seed:ambiance-packs (J-0884 J-0886 J-0887 J-0888): both packs installed, so « Supprimer », volume and play controls exist. Env: DATA. Exit 3 = scanned at launch.
# Throwaway CI runner only. Files are placeholders: the app checks names and sizes only (isInstalled), not audio content.
set -u
ROOT="$DATA/Ambiance"; MARK="$DATA/.t046-ambiance-packs"
case "${1:-}" in
  seed)
    # Store root = <support>/Ambiance (AmbiancePackStore.swift:33); pack folder = <root>/<id> (:40), id in orchestra|textures (:35), bytes/sha256 from
    # AmbiancePackCatalog.swift:5-6. isInstalled (:41-53): regular dir + .installed.json {id, sha256, bytes (== catalog), files:[regular files]}.
    # Contents expected by install (:140-141): LICENSE.txt, orchestra: manifest.json, textures: <rain ocean brown pink aube>.wav (AmbianceSource.swift:29).
    # The controller scans at start (AmbianceController.swift:258-272) -> keptPacks (AmbiancePage.swift:257) shows ambiance-remove-<id> (:210).
    [[ -d "$ROOT" ]] || echo root > "$MARK"
    mkdir -p "$ROOT"; chmod 700 "$ROOT"
    python3 - "$ROOT" <<'PY' || exit 1
import json, os, sys, struct
root = sys.argv[1]
packs = {"orchestra": (77158400, "d8535aa60dbbb9b8b44897a3de0ef26c532b9e3f2a368a5fbe9c4f62462c2489", ["LICENSE.txt", "manifest.json"]),
         "textures": (83363840, "eee48c8c039e50d1e23f824c3de4151252c5e66e8c42d1264c3daa3b2f5da3a2", ["LICENSE.txt"] + [n + ".wav" for n in ("rain","ocean","brown","pink","aube")])}
wav = b"RIFF" + struct.pack("<I", 36 + 8000) + b"WAVEfmt " + struct.pack("<IHHIIHH", 16, 1, 1, 8000, 8000, 1, 8) + b"data" + struct.pack("<I", 8000) + b"\x80" * 8000
for pid, (size, sha, files) in packs.items():
    d = os.path.join(root, pid)
    if os.path.exists(d): continue  # never touch a real pack; unseed only removes what the marker lists
    os.makedirs(d, mode=0o700)
    for n in files:
        with open(os.path.join(d, n), "wb") as f: f.write(wav if n.endswith(".wav") else (b"{}" if n.endswith(".json") else b"T-046 placeholder\n"))
        os.chmod(os.path.join(d, n), 0o600)
    with open(os.path.join(d, ".installed.json"), "w") as f: json.dump({"id": pid, "sha256": sha, "bytes": size, "files": sorted(files)}, f)
    open(os.path.join(d, ".t046"), "w").close()
PY
    exit 3 ;;
  unseed)
    # Remove only pack folders this seed made (.t046 marker); then the root if the seed created it.
    for p in orchestra textures; do [[ -e "$ROOT/$p/.t046" ]] && rm -rf "${ROOT:?}/$p"; done
    if [[ -e "$MARK" ]]; then rmdir "$ROOT" 2>/dev/null; rm -f "$MARK"; fi
    exit 0 ;;
  *) echo "usage: $0 seed|unseed" >&2; exit 2 ;;
esac
