#!/usr/bin/env python3
"""Prepare authenticated deltas separately; commit through the sole feed writer."""
import hashlib
import json
import os
import plistlib
import re
import subprocess
import sys
import tempfile
from pathlib import Path
from prepare_presigned_release import validate_archive
from generate_security_artifacts import tree_digest

REPO = "blancmathis/goalong-history"
ROOT = Path(__file__).resolve().parents[1]
ZIP = "Goalong-History-macOS-universal.zip"


def run(*args, **kwargs):
    return subprocess.run(list(args), check=True, **kwargs)


def digest(path):
    with path.open("rb") as stream:
        value = hashlib.sha256()
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def attest(path, source):
    run("gh", "attestation", "verify", str(path), "--repo", REPO, "--source-digest", source,
        "--signer-workflow", f"{REPO}/.github/workflows/continuous-release.yml", "--deny-self-hosted-runners")


def extract(archive, destination):
    validate_archive(archive)
    destination.mkdir(parents=True, exist_ok=True)
    run("ditto", "-x", "-k", str(archive), str(destination))
    app = destination / "Goalong History.app"
    run("bash", "scripts/verify_release_identity.sh", str(app))
    run(sys.executable, "scripts/verify_cli_plist.py", str(app))
    return app


def verified_feed(path, verifier):
    return json.loads(subprocess.check_output([str(verifier), "--feed-only",
        (ROOT / "Distribution/sparkle-public-ed-key.txt").read_text().strip(), str(path)], text=True))


def current_main():
    return subprocess.check_output(["git", "ls-remote", "origin", "refs/heads/main"], text=True).split()[0]


def main():
    mode, tag = sys.argv[1:]
    revision = os.environ["GITHUB_SHA"]
    if not re.fullmatch(r"main-[0-9]+-[0-9]+", tag) or os.environ["GITHUB_REF"] != "refs/heads/main":
        raise ValueError("Official main generation required")
    dist = ROOT / "dist"
    dist.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="goalong-deferred-deltas-") as work_name:
        work = Path(work_name)
        verifier = work / "verify"
        run("xcrun", "swiftc", "scripts/verify_update_archive.swift", "-o", str(verifier))
        if mode == "prepare":
            if current_main() != revision:
                print("Superseded full generation; deltas skipped.")
                return
            # Full artifacts came from this run's completed publication job.
            manifest = json.loads((dist / "release-manifest.json").read_text())
            attest(dist / "release-manifest.json", revision)
            expected = next(a["sha256"] for a in manifest["artifacts"] if a["path"] == ZIP)
            if manifest["sourceCommit"] != revision or digest(dist / ZIP) != expected:
                raise ValueError("Final full archive provenance mismatch")
            target = extract(dist / ZIP, dist)
            full_feed = verified_feed(dist / "community-appcast.xml", verifier)
            (dist / "full-appcast.xml").write_bytes((dist / "community-appcast.xml").read_bytes())
            bases = work / "bases"
            bases.mkdir()
            rows = json.loads(subprocess.check_output(["gh", "release", "list", "--repo", REPO, "--limit", "30", "--exclude-drafts", "--json", "tagName"], text=True))
            tags = [r["tagName"] for r in rows if re.fullmatch(r"main-[0-9]+-[0-9]+", r["tagName"]) and r["tagName"] != tag]
            tags.sort(key=lambda t: tuple(map(int, t.split("-")[1:])), reverse=True)
            by_build = {}
            for base_tag in tags[:3]:
                folder = work / base_tag
                folder.mkdir()
                run("gh", "release", "download", base_tag, "--repo", REPO, "--pattern", ZIP,
                    "--pattern", "release-manifest.json", "--dir", str(folder))
                prior = json.loads((folder / "release-manifest.json").read_text())
                attest(folder / "release-manifest.json", prior["sourceCommit"])
                checksum = next(a["sha256"] for a in prior["artifacts"] if a["path"] == ZIP)
                if digest(folder / ZIP) != checksum:
                    raise ValueError("Historical delta base is not the attested archive")
                base = extract(folder / ZIP, folder)
                info = plistlib.loads((base / "Contents/Info.plist").read_bytes())
                by_build[info["CFBundleVersion"]] = base
                run("cp", str(folder / ZIP), str(bases / f"{base_tag}.zip"))
            env = {**os.environ, "LOCALHISTORY_DELTA_BASES_DIR": str(bases),
                   "CFFIXED_USER_HOME": str(work / "sparkle-home")}
            (work / "sparkle-home").mkdir()
            version = plistlib.loads((target / "Contents/Info.plist").read_bytes())["CFBundleShortVersionString"]
            run("bash", "scripts/generate_sparkle_appcast.sh", version, str(dist / ZIP), str(dist / "community-appcast.xml"), tag, env=env)
            enriched = verified_feed(dist / "community-appcast.xml", verifier)
            if {k: enriched[k] for k in ("url", "length", "version")} != {k: full_feed[k] for k in ("url", "length", "version")}:
                raise ValueError("Delta generation changed the full enclosure")
            import xml.etree.ElementTree as ET
            old_enclosure = ET.parse(dist / "full-appcast.xml").find("./channel/item/enclosure")
            new_enclosure = ET.parse(dist / "community-appcast.xml").find("./channel/item/enclosure")
            if old_enclosure is None or new_enclosure is None or old_enclosure.attrib != new_enclosure.attrib:
                raise ValueError("Delta generation changed a full enclosure attribute/signature")
            tools = subprocess.check_output(["bash", "scripts/fetch_sparkle_tools.sh"], text=True).strip()
            for delta in enriched["deltas"]:
                patched = work / f"patched-{delta['from']}.app"
                run(str(Path(tools) / "BinaryDelta"), "apply", str(by_build[delta["from"]]), str(patched), str(dist / Path(delta["url"]).name))
                if tree_digest(patched) != tree_digest(target):
                    raise ValueError("Delta does not reconstruct the exact signed target bundle")
                run("bash", "scripts/verify_release_identity.sh", str(patched))
            if not enriched["deltas"]:
                print("No applicable deltas; full feed retained.")
                return
            run(sys.executable, "scripts/generate_security_artifacts.py", "--app", str(target), "--edition", "unified", "--output-dir", str(dist), "--include-release-artifacts")
            run(sys.executable, "scripts/verify_security_capabilities.py", "--manifest", str(dist / "security-capabilities.json"), "--app", str(target), "--edition", "unified")
            generation = {"sourceCommit": revision, "tag": tag, "zipSHA256": expected,
                          "expectedFeedSHA256": digest(dist / "full-appcast.xml"),
                          "feedSHA256": digest(dist / "community-appcast.xml")}
            (dist / "delta-generation.json").write_text(json.dumps(generation, indent=2) + "\n")
            (dist / "delta-release-manifest.json").write_bytes((dist / "release-manifest.json").read_bytes())
            with open(os.environ["GITHUB_OUTPUT"], "a") as output:
                output.write("ready=true\n")
        elif mode == "publish":
            generation = json.loads((dist / "delta-generation.json").read_text())
            attest(dist / "delta-generation.json", revision)
            attest(dist / "delta-release-manifest.json", revision)
            if generation["sourceCommit"] != revision or generation["tag"] != tag:
                raise ValueError("Wrong delta generation")
            if digest(dist / ZIP) != generation["zipSHA256"] or digest(dist / "community-appcast.xml") != generation["feedSHA256"]:
                raise ValueError("Delta generation bytes changed")
            extract(dist / ZIP, dist)
            current = work / "current.xml"
            run("curl", "--fail", "--location", "--silent", "--show-error", "--proto", "=https", "--proto-redir", "=https",
                f"https://github.com/{REPO}/releases/download/latest-main/community-appcast.xml", "-o", str(current))
            verified_feed(current, verifier)
            if current_main() != revision or digest(current) != generation["expectedFeedSHA256"]:
                print("Public generation changed; obsolete delta publication skipped.")
                return
            release = json.loads(subprocess.check_output(["gh", "api", f"repos/{REPO}/releases/tags/{tag}"], text=True))
            if release.get("immutable"):
                print("Release is sealed; deltas skipped without changing protection.")
                return
            deltas = sorted(dist.glob("Goalong-History-macOS-universal-from-*.delta"))
            # No clobber of an immutable archive, delta or generation manifest.
            run("gh", "release", "upload", tag, *(str(p) for p in deltas), str(dist / "delta-release-manifest.json"), str(dist / "delta-generation.json"), "--repo", REPO)
            # Compare again after immutable uploads and just before any rolling mutation.
            run("curl", "--fail", "--location", "--silent", "--show-error", "--proto", "=https", "--proto-redir", "=https",
                f"https://github.com/{REPO}/releases/download/latest-main/community-appcast.xml", "-o", str(current))
            verified_feed(current, verifier)
            if current_main() != revision or digest(current) != generation["expectedFeedSHA256"]:
                print("Superseded before feed commit; deltas left unreferenced.")
                return
            run("gh", "release", "upload", "latest-main", str(dist / "release-manifest.json"), "--repo", REPO, "--clobber")
            run("gh", "release", "upload", "latest-main", str(dist / "community-appcast.xml"), "--repo", REPO, "--clobber")
            run("bash", "scripts/verify_published_update.sh", str(dist))
        else:
            raise ValueError("Expected prepare or publish")


if __name__ == "__main__":
    main()
