#!/usr/bin/env python3
"""Outbound-only owner-Mac deploy coordinator. No GitHub runner or feed writes."""
import argparse
import concurrent.futures
import fcntl
import hashlib
import json
import os
import plistlib
import shutil
import signal
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

REPO = "blancmathis/goalong-history"
DEFAULT_STATE = Path.home() / "Library/Application Support/GoalongDeploy"


def atomic_json(path, value):
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(value, indent=2) + "\n")
    tmp.replace(path)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", type=Path, required=True)
    parser.add_argument("--state-dir", type=Path, default=DEFAULT_STATE)
    parser.add_argument("--sha", help="Exact commit for a build-only measurement")
    parser.add_argument("--run-id", type=int, help="CI run ID namespace for build-only measurement")
    parser.add_argument("--build-only", action="store_true")
    parser.add_argument("--retry", action="store_true", help="Explicitly retry a previously attempted main SHA")
    args = parser.parse_args()
    if sys.platform != "darwin" or os.getuid() == 0:
        parser.error("Requires the current non-root Mac user")
    if (args.sha or args.run_id) and not args.build_only:
        parser.error("Explicit SHA/run ID is only permitted without publication")
    repo = args.repository.resolve(strict=True)
    state = args.state_dir.expanduser().absolute()
    if state.is_symlink():
        parser.error("Refusing symlinked state directory")
    state.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.umask(0o077)
    lock = (state / "deploy.lock").open("a")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        print("Another local deployment owns the lock; no work started.")
        return
    # A crashed run may leave fixture files. Only this controller's private
    # run directories are reclaimed, after its inherited process lock clears.
    for old in (state / "runs").glob("*"):
        for name in ("test-home", "tmp"):
            fixture = old / name
            if fixture.is_dir() and not fixture.is_symlink():
                shutil.rmtree(fixture)
    def output(argv, cwd=repo):
        return subprocess.check_output(argv, cwd=cwd, text=True).strip()
    if output(["git", "remote", "get-url", "origin"]) != f"https://github.com/{REPO}.git":
        raise ValueError("Unexpected source repository")
    remote = output(["git", "ls-remote", "origin", "refs/heads/main"]).split()[0]
    revision = args.sha or remote
    import re
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        parser.error("Expected a complete source SHA")
    state_file = state / "state.json"
    previous = json.loads(state_file.read_text()) if state_file.exists() else {}
    if not args.build_only and not args.retry and previous.get("lastAttempted") == revision:
        print(f"Already attempted {revision}; see {state_file}.")
        return
    began = time.monotonic()
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    run = state / "runs" / f"{stamp}-{revision[:12]}"
    run.mkdir(parents=True, exist_ok=False)
    metrics = {"sha": revision, "startedAt": datetime.now(timezone.utc).isoformat(),
               "buildOnly": args.build_only, "stages": {}, "status": "running"}
    processes = []
    def save():
        atomic_json(run / "timings.json", metrics)
    def command(stage, argv, cwd=repo, env=None):
        started = time.monotonic()
        with (run / f"{stage}.log").open("w") as log:
            process = subprocess.Popen(argv, cwd=cwd, env=env, stdout=log, stderr=subprocess.STDOUT,
                                       start_new_session=True, pass_fds=(lock.fileno(),))
            processes.append(process)
            status = process.wait()
        metrics["stages"][stage] = {"seconds": round(time.monotonic()-started, 3), "exitCode": status}
        print(f"{stage}: {metrics['stages'][stage]['seconds']} s, exit {status}", flush=True)
        if status:
            raise RuntimeError(f"{stage} failed ({status}); full output: {run / (stage+'.log')}")
    def interrupted(signum, frame):
        raise KeyboardInterrupt(f"Interrupted by signal {signum}")
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    if not args.build_only:
        atomic_json(state_file, {"lastAttempted": revision, "status": "running", "run": str(run)})
    checkout = state / "checkout"
    try:
        if checkout.is_symlink():
            raise ValueError("Refusing symlinked checkout")
        if not checkout.exists():
            command("clone", ["git", "clone", "--no-checkout", f"https://github.com/{REPO}.git", str(checkout)])
        command("fetch", ["git", "fetch", "origin", "main"], cwd=checkout)
        if args.build_only:
            command("fetch-measurement", ["git", "fetch", str(repo), revision], cwd=checkout)
        command("checkout", ["git", "checkout", "--force", "--detach", revision], cwd=checkout)
        # This dedicated checkout contains no user work; scratch and logs are external.
        command("clean", ["git", "clean", "-fdx"], cwd=checkout)
        proof = run / "source-gates.json"
        if not args.build_only:
            command("hosted-gates", [sys.executable, "scripts/local_deploy_policy.py", revision, str(proof)], cwd=checkout)
            gates = json.loads(proof.read_text())
            run_id = gates["buildRunId"]
            metrics["gates"] = gates
        else:
            if not args.run_id or args.run_id <= 0:
                raise ValueError("A real CI run ID is required for build-only metadata")
            run_id = args.run_id
        command("authenticated-public-state", [sys.executable, "scripts/authenticated_release_state.py", str(run / "public")], cwd=checkout)
        # stdout contains gh tool progress only on stderr; the last JSON is retained.
        public = json.loads((run / "authenticated-public-state.log").read_text().splitlines()[-1])
        attempt = 1 if args.build_only else gates["buildRunAttempt"]
        env = {**os.environ, "GITHUB_RUN_ID": str(run_id), "GITHUB_RUN_ATTEMPT": str(attempt),
               "GOALONG_CURRENT_ROLLING_VERSION": public["versionName"]}
        version_output = subprocess.check_output(
            ["bash", "scripts/resolve_rolling_version.sh", str(run_id)], cwd=checkout, env=env, text=True)
        resolved = dict(line.split("=", 1) for line in version_output.splitlines())
        sys.path.insert(0, str(checkout / "scripts"))
        from authenticated_release_state import numeric
        if numeric(resolved["build"]) <= numeric(public["version"]):
            raise ValueError("Producer run build is not newer than the authenticated public build")
        metrics.update(version=resolved["value"], build=resolved["build"], buildRunId=run_id)
        # Source edits invalidate SwiftPM normally; cache ABI/tools/dependencies/flags
        # have an explicit namespace. Metadata changes force only the required relink.
        fingerprint = hashlib.sha256()
        for argv in (["xcrun", "swift", "--version"], ["xcrun", "--show-sdk-path"], ["xcrun", "--show-sdk-version"]):
            fingerprint.update(output(argv).encode())
        for filename in ("Package.resolved", "scripts/build_app_core.sh", "scripts/codesign_policy.sh"):
            fingerprint.update((checkout / filename).read_bytes())
        fingerprint.update(b"goalong-local-cache-v1:release-j4:debug-j4")
        cache = state / "cache" / fingerprint.hexdigest()[:20]
        cache.mkdir(parents=True, exist_ok=True)
        dist = checkout / "dist"
        dist.mkdir()
        pin = json.loads((checkout / "Distribution/release-signing.json").read_text())
        env.update(LOCALHISTORY_VERSION=resolved["value"], LOCALHISTORY_BUILD_NUMBER=resolved["build"],
                   LOCALHISTORY_CODESIGN_IDENTITY=pin["certificateSHA1"], LOCALHISTORY_RUN_TESTS="0",
                   LOCALHISTORY_REQUIRE_SPARKLE_CONFIGURED="1", LOCALHISTORY_ARCHS="arm64 x86_64",
                   LOCALHISTORY_SCRATCH_ROOT=str(cache), LOCALHISTORY_PARALLEL_ARCHS="1", LOCALHISTORY_BUILD_JOBS="4",
                   LOCALHISTORY_RUNTIME_CACHE=str(state / "runtime-cache"),
                   LOCALHISTORY_SPARKLE_PUBLIC_ED_KEY=(checkout / "Distribution/sparkle-public-ed-key.txt").read_text().strip())
        temporary = run / "tmp"
        temporary.mkdir()
        env["TMPDIR"] = str(temporary) + "/"
        # No P12 import or keychain search-list/default mutation is used anywhere.
        command("signing-preflight", ["bash", "-c", 'source scripts/source_codesign_identity.sh; localhistory_verify_source_codesign_identity "$LOCALHISTORY_CODESIGN_IDENTITY"'], cwd=checkout, env=env)
        fixture = run / "test-home"
        fixture.mkdir()
        test_env = {**env, "HOME": str(fixture), "CFFIXED_USER_HOME": str(fixture)}
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            futures = [pool.submit(command, "tests", ["xcrun", "swift", "test", "-j", "4", "--scratch-path", str(cache / "tests")], checkout, test_env),
                       pool.submit(command, "build-sign-verify", ["bash", "scripts/build_app.sh"], checkout, env)]
            results = []
            for future in futures:
                try:
                    future.result()
                except BaseException as error:
                    results.append(error)
            if results:
                raise results[0]
        for file in dist.glob("build-*-timing.json"):
            timing = json.loads(file.read_text())
            metrics["stages"][timing["stage"]] = {"seconds": timing["seconds"], "exitCode": 0}
        command("final-identity", ["bash", "scripts/verify_release_identity.sh", str(dist / "Goalong History.app")], cwd=checkout)
        if args.build_only:
            command("staging-archive", ["ditto", "-c", "-k", "--keepParent", "--norsrc", str(dist / "Goalong History.app"), str(dist / "Goalong-History-macOS-universal.zip")], cwd=checkout)
        if not args.build_only:
            command("handoff", ["bash", "scripts/publish_local_release.sh", "--dist", str(dist), "--publish"], cwd=checkout, env=env)
            handoff = (run / "handoff.log").read_text()
            stage = next(line.split("=", 1)[1] for line in handoff.splitlines() if line.startswith("SIGNED_STAGE="))
            # Wait for the exact request, not an unrelated run with the same main SHA.
            deadline = time.monotonic() + 3600
            publisher = None
            def wait_for_step(name):
                nonlocal publisher
                started = time.monotonic()
                while time.monotonic() < deadline:
                    rows = json.loads(output(["gh", "run", "list", "--repo", REPO, "--workflow", "continuous-release.yml", "--limit", "30", "--json", "databaseId,headSha,displayTitle,status,conclusion"]))
                    matches = [r for r in rows if r["headSha"] == revision and r["displayTitle"] == f"Publish {stage}"]
                    if matches:
                        publisher = matches[0]
                        jobs = json.loads(output(["gh", "run", "view", str(publisher["databaseId"]), "--repo", REPO, "--json", "jobs"]))["jobs"]
                        steps = [s for j in jobs if j["name"] == "publish-latest-main" for s in j["steps"] if s["name"] == name]
                        if steps and steps[0]["conclusion"] == "success":
                            (run / "publisher-jobs.json").write_text(json.dumps(jobs, indent=2) + "\n")
                            metrics["stages"][f"await-{name}"] = {"seconds": round(time.monotonic()-started, 3), "exitCode": 0}
                            return steps[0]["completedAt"]
                        if (steps and steps[0]["conclusion"] == "failure") or (publisher["status"] == "completed" and publisher["conclusion"] != "success"):
                            raise RuntimeError(f"Publisher {name} did not succeed: {publisher}")
                    time.sleep(5)
                raise RuntimeError(f"Publisher {name} timed out: {publisher}")

            wait_for_step("Publish immutable update archive")
            metrics["publisherRunId"] = publisher["databaseId"]
            # Bind the expected digest to the exact hosted publisher/source, then
            # let the unchanged-URL verifier download/authenticate the archive once.
            final = run / "final-manifest"
            final.mkdir()
            command("download-final-manifest", ["gh", "release", "download", f"main-{publisher['databaseId']}-1", "--repo", REPO,
                                      "--pattern", "release-manifest.json", "--dir", str(final)], cwd=checkout)
            manifest_path = final / "release-manifest.json"
            command("verify-final-provenance", ["gh", "attestation", "verify", str(manifest_path), "--repo", REPO,
                    "--source-digest", revision, "--source-ref", "refs/heads/main", "--deny-self-hosted-runners",
                    "--signer-workflow", f"{REPO}/.github/workflows/continuous-release.yml"], cwd=checkout)
            manifest = json.loads(manifest_path.read_text())
            if manifest["sourceCommit"] != revision or manifest["product"]["build"] != resolved["build"]:
                raise ValueError("Final attested inventory differs from the tested source/build")
            entries = [a for a in manifest["artifacts"] if a["path"] == "Goalong-History-macOS-universal.zip"]
            if len(entries) != 1:
                raise ValueError("Expected one final attested archive")
            # Download the same immutable public URL while the hosted writer finishes
            # rolling assets/feed. The verifier still authenticates every byte and
            # requires the signed enclosure to name this exact URL.
            archive_url = f"https://github.com/{REPO}/releases/download/main-{publisher['databaseId']}-1/Goalong-History-macOS-universal.zip"
            archive = final / "Goalong-History-macOS-universal.zip"
            command("download-public-archive", ["curl", "--fail", "--location", "--silent", "--show-error", "--retry", "3",
                    "--connect-timeout", "15", "--max-time", "300", "--max-filesize", "350000000",
                    "--proto", "=https", "--proto-redir", "=https", archive_url, "-o", str(archive)], cwd=checkout)
            metrics["feedVerifiedAt"] = wait_for_step("Publish authenticated feed last")
            verify_env = {**env, "LOCALHISTORY_EXPECTED_ARCHIVE_SHA256": entries[0]["sha256"],
                          "LOCALHISTORY_PREFETCHED_ARCHIVE": str(archive), "LOCALHISTORY_PREFETCHED_ARCHIVE_URL": archive_url}
            command("verify-published", ["bash", "scripts/verify_published_update.sh", str(dist)], cwd=checkout, env=verify_env)
        metrics["status"] = "built" if args.build_only else "published-verified"
    except BaseException as error:
        metrics["status"] = "failed"
        metrics["error"] = str(error)
        raise
    finally:
        for process in processes:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
        for name in ("test-home", "tmp"):
            fixture = run / name
            if fixture.exists():
                shutil.rmtree(fixture)
        metrics["totalSeconds"] = round(time.monotonic()-began, 3)
        if metrics.get("gates", {}).get("mergedAt"):
            merged = datetime.fromisoformat(metrics["gates"]["mergedAt"].replace("Z", "+00:00"))
            key = "mergeToVerifiedSeconds" if metrics["status"] == "published-verified" else "mergeToStopSeconds"
            metrics[key] = round((datetime.now(timezone.utc)-merged).total_seconds(), 3)
        save()
        if not args.build_only:
            atomic_json(state_file, {"lastAttempted": revision, "status": metrics["status"], "run": str(run)})
        print(f"Status: {metrics['status']}; timings/logs: {run}", flush=True)


if __name__ == "__main__":
    main()
