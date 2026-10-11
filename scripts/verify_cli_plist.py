#!/usr/bin/env python3
"""Check TCC identity and version/build in every Mach-O CLI slice."""
import plistlib
import re
import subprocess
import sys
from pathlib import Path


def verify(app: Path) -> None:
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    binary = app / "Contents/MacOS/goalong"
    archs = subprocess.check_output(["lipo", "-archs", str(binary)], text=True).split()
    if not archs or any(arch not in {"arm64", "x86_64"} for arch in archs):
        raise ValueError("Unexpected CLI architecture")
    for arch in archs:
        dump = subprocess.check_output(
            ["otool", "-arch", arch, "-X", "-s", "__TEXT", "__info_plist", str(binary)], text=True)
        payload = bytearray()
        for line in dump.splitlines():
            words = line.split()
            if not words or not re.fullmatch(r"[0-9a-f]{16}", words[0]):
                continue
            for word in words[1:]:
                if not re.fullmatch(r"(?:[0-9a-f]{2}){1,4}", word):
                    raise ValueError("Malformed embedded plist dump")
                payload.extend(int(word, 16).to_bytes(len(word) // 2, "little"))
        embedded = plistlib.loads(bytes(payload).rstrip(b"\0"))
        for key in ("CFBundleIdentifier", "CFBundleShortVersionString", "CFBundleVersion"):
            if embedded.get(key) != info.get(key) or not info.get(key):
                raise ValueError(f"CLI {arch} {key} differs from app")
    print("CLI identity/version/build agree with the app in every architecture.")


if __name__ == "__main__":
    verify(Path(sys.argv[1]))
