#!/usr/bin/env python3
"""Build local CC0 packs and a pinned catalog. Never publishes or uploads."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tarfile

COMMIT = "dfa5ab747373d1eed324115db07971c4096ffc49"
ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--onde-source", type=Path, default=Path("/tmp/onde-src"))
    parser.add_argument("--output", type=Path, default=Path("/tmp/goalong-ambiance-packs"))
    parser.add_argument("--prepared-dir", type=Path)
    args = parser.parse_args()
    source = args.onde_source.resolve(strict=True)
    assert subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=source, text=True).strip() == COMMIT
    subprocess.run(["git", "diff", "--exit-code", COMMIT, "--", "Tools", "Resources"], cwd=source, check=True)
    work = args.prepared_dir.resolve(strict=True) if args.prepared_dir else ROOT / ".ambiance-work/pack-build"
    work.mkdir(parents=True, exist_ok=True)
    for directory in ("Tools", "Resources"):
        shutil.copytree(source / directory, work / directory, dirs_exist_ok=True)
    if not (work / "Assets/Orchestra/manifest.json").exists():
        subprocess.run(["bash", "Tools/prepare_orchestra.sh"], cwd=work, check=True)
    textures = work / "textures"
    if not all((textures / (name + ".wav")).exists() for name in ("rain", "ocean", "brown", "pink", "aube")):
        subprocess.run(["swiftc", "-O", "Tools/Synthesize.swift", "-o", "synthesize"], cwd=work, check=True)
        subprocess.run([str(work / "synthesize"), str(textures)], cwd=work, check=True)
    # Verify the prepared samples before building an immutable archive.
    orchestra = work / "Assets/Orchestra"
    manifest = json.loads((orchestra / "manifest.json").read_text())
    assert manifest["license"] == "CC0-1.0"
    for sample in manifest["samples"]:
        path = orchestra / sample["filename"]
        assert path.parent == orchestra
        assert hashlib.sha256(path.read_bytes()).hexdigest() == sample["processed_sha256"]
    (textures / "LICENSE.txt").write_text("Onde original synthesized recordings — CC0 1.0.\nhttps://creativecommons.org/publicdomain/zero/1.0/\n")
    args.output.mkdir(parents=True, exist_ok=True)
    catalog = []
    for pack_id, title, directory, names in (
        ("orchestra", "Orchestre acoustique", orchestra, sorted(p.name for p in orchestra.iterdir() if p.is_file())),
        ("textures", "Textures et Aube", textures, ["LICENSE.txt", "aube.wav", "brown.wav", "ocean.wav", "pink.wav", "rain.wav"]),
    ):
        archive = args.output / f"{pack_id}.tar"
        with tarfile.open(archive, "w", format=tarfile.USTAR_FORMAT) as tar:
            for name in sorted(names):
                path = directory / name
                info = tarfile.TarInfo(name)
                info.size = path.stat().st_size
                info.mode = 0o644
                info.mtime = 0
                with path.open("rb") as stream:
                    tar.addfile(info, stream)
        record = dict(id=pack_id, title=title, bytes=archive.stat().st_size,
                      sha256=hashlib.sha256(archive.read_bytes()).hexdigest(),
                      url=f"https://github.com/blancmathis/goalong-history/releases/download/ambiance-packs-v1/{pack_id}.tar")
        catalog.append(record)
        print(json.dumps(record, ensure_ascii=False))
    (args.output / "catalog.json").write_text(json.dumps(catalog, ensure_ascii=False, indent=2) + "\n")
    lines = ["import Foundation", "", "public enum AmbiancePackCatalog {", "    public static let packs: [AmbiancePack] = ["]
    for record in catalog:
        lines.append('        AmbiancePack(id: "%s", title: "%s", bytes: %d, url: URL(string: "%s")!, sha256: "%s"),' %
                     (record["id"], record["title"], record["bytes"], record["url"], record["sha256"]))
    lines += ["    ]", "}", ""]
    (ROOT / "Features/Ambiance/Sources/AmbiancePackCatalog.swift").write_text("\n".join(lines))


if __name__ == "__main__":
    main()
