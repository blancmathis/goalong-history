#!/usr/bin/env python3
"""Accept an explicitly supplied, pinned-certificate local build without exporting its key."""
import hashlib, json, os, plistlib, posixpath, re, stat, subprocess, sys, zipfile
from pathlib import Path

def validate_archive(path: Path) -> None:
    if path.stat().st_size > 350_000_000:
        raise ValueError("Archive too large")
    with zipfile.ZipFile(path) as archive:
        entries = archive.infolist()
        if len(entries) > 10000 or sum(e.file_size for e in entries) > 1_000_000_000:
            raise ValueError("Expanded archive too large")
        names, links = set(), set()
        for entry in entries:
            name = entry.filename.rstrip("/")
            if name in names or name.startswith("/") or "\\" in name or ".." in name.split("/"):
                raise ValueError("Unsafe or duplicate archive path")
            if not (name == "Goalong History.app" or name.startswith("Goalong History.app/")):
                raise ValueError("Unexpected archive root")
            names.add(name)
            mode = entry.external_attr >> 16
            if stat.S_ISLNK(mode):
                if entry.file_size > 4096:
                    raise ValueError("Oversized symbolic link")
                target = archive.read(entry).decode("utf-8")
                resolved = posixpath.normpath(posixpath.join(posixpath.dirname(name), target))
                if target.startswith("/") or not resolved.startswith("Goalong History.app/"):
                    raise ValueError("External symbolic link")
                links.add(name)
            elif stat.S_IFMT(mode) not in (0, stat.S_IFREG, stat.S_IFDIR):
                raise ValueError("Unsupported archive entry")
        for name in names:
            parts = name.split("/")
            if any("/".join(parts[:i]) in links for i in range(1, len(parts))):
                raise ValueError("Archive writes through a symbolic link")

def main() -> None:
    tag, checksum = sys.argv[1:]
    revision = os.environ["GITHUB_SHA"]
    if not re.fullmatch(r"presigned-[0-9a-f]{12}-[0-9]+\.[0-9]+\.[0-9]+", tag):
        raise ValueError("Invalid staging tag")
    if not re.fullmatch(r"[0-9a-f]{64}", checksum):
        raise ValueError("Invalid pinned archive hash")
    if os.environ["GITHUB_REPOSITORY"] != "blancmathis/goalong-history" or os.environ["GITHUB_REF"] != "refs/heads/main":
        raise ValueError("Only the official main branch can publish a supplied build")
    directory = Path(os.environ["RUNNER_TEMP"]) / "goalong-presigned"
    directory.mkdir(exist_ok=False)
    name = "Goalong-History-macOS-universal.zip"
    subprocess.run(["gh", "release", "download", tag, "--repo", "blancmathis/goalong-history", "--pattern", name, "--dir", str(directory)], check=True)
    archive = directory / name
    if hashlib.sha256(archive.read_bytes()).hexdigest() != checksum:
        raise ValueError("Supplied archive hash does not match")
    validate_archive(archive)
    Path("dist").mkdir(exist_ok=True)
    subprocess.run(["ditto", "-x", "-k", str(archive), "dist"], check=True)
    app = Path("dist/Goalong History.app")
    with (app / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    if info.get("GoalongSourceRevision") != revision:
        raise ValueError("Supplied build is not bound to this main revision")
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", info.get("CFBundleShortVersionString", "")):
        raise ValueError("Invalid supplied version")
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+){1,3}", info.get("CFBundleVersion", "")):
        raise ValueError("Invalid supplied build number")
    subprocess.run(["bash", "scripts/verify_release_identity.sh", str(app)], check=True)
    print("Validated explicitly supplied signed build; private signing key stays with its owner.")

if __name__ == "__main__":
    main()
