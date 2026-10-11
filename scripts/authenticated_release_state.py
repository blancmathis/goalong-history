#!/usr/bin/env python3
"""Authenticate the current feed and bind its ZIP to an attested manifest."""
import hashlib
import json
import subprocess
import sys
from pathlib import Path

REPO = "blancmathis/goalong-history"
ROOT = Path(__file__).resolve().parents[1]


def numeric(value):
    parts = value.split(".")
    if not 1 <= len(parts) <= 4 or any(not p.isdigit() for p in parts):
        raise ValueError("Invalid numeric version/build")
    return tuple(map(int, parts)) + (0,) * (4 - len(parts))


def authenticated_state(directory):
    directory.mkdir(parents=True, exist_ok=True)
    feed = directory / "feed.xml"
    subprocess.run(["curl", "--fail", "--location", "--silent", "--show-error", "--retry", "3",
                    "--connect-timeout", "15", "--max-time", "90", "--proto", "=https", "--proto-redir", "=https",
                    f"https://github.com/{REPO}/releases/download/latest-main/community-appcast.xml", "-o", str(feed)], check=True)
    verifier = directory / "verify"
    subprocess.run(["xcrun", "swiftc", str(ROOT / "scripts/verify_update_archive.swift"), "-o", str(verifier)], check=True)
    data = json.loads(subprocess.check_output([str(verifier), "--feed-only",
                      (ROOT / "Distribution/sparkle-public-ed-key.txt").read_text().strip(), str(feed)], text=True))
    tag = data["url"].split("/")[-2]
    manifest = directory / "release-manifest.json"
    subprocess.run(["gh", "release", "download", tag, "--repo", REPO, "--pattern", manifest.name,
                    "--dir", str(directory), "--clobber"], check=True)
    contents = json.loads(manifest.read_text())
    workflow = "continuous-release.yml" if tag.startswith("main-") else "release.yml"
    subprocess.run(["gh", "attestation", "verify", str(manifest), "--repo", REPO,
                    "--signer-workflow", f"{REPO}/.github/workflows/{workflow}",
                    "--source-digest", contents["sourceCommit"], "--deny-self-hosted-runners"], check=True, stdout=sys.stderr)
    if contents["product"]["build"] != data["version"]:
        raise ValueError("Authenticated feed and attested manifest disagree on build")
    entries = [a for a in contents["artifacts"] if a["path"] == "Goalong-History-macOS-universal.zip"]
    if len(entries) != 1 or int(data["length"]) != entries[0]["sizeBytes"]:
        raise ValueError("Attested manifest does not describe the feed archive")
    # The immutable full manifest binds the ZIP. A deferred signed feed may
    # enrich that same enclosure with independently attested deltas.
    data.update(versionName=contents["product"]["version"], sourceCommit=contents["sourceCommit"],
                sha256=entries[0]["sha256"], feedSHA256=hashlib.sha256(feed.read_bytes()).hexdigest(), tag=tag)
    return data


if __name__ == "__main__":
    state = authenticated_state(Path(sys.argv[1]))
    if len(sys.argv) == 3:
        import plistlib
        info = plistlib.loads(Path(sys.argv[2]).read_bytes())
        if numeric(info["CFBundleVersion"]) <= numeric(state["version"]):
            raise ValueError("Refusing a non-monotonic public build")
        current = list(map(int, state["versionName"].split(".")))
        current[2] += 1
        expected = max(tuple(current), tuple(map(int, (ROOT / "VERSION").read_text().strip().split("."))))
        if tuple(map(int, info["CFBundleShortVersionString"].split("."))) != expected:
            raise ValueError("Candidate version no longer matches authenticated public state")
    print(json.dumps(state))
