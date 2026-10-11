#!/usr/bin/env python3
"""Reuse only successful official hosted gates for the identical source tree."""
import json
import re
import subprocess
import sys
from pathlib import Path

REPO = "blancmathis/goalong-history"
GATES = {
    "build-test-package": ".github/workflows/macos.yml",
    "verify": ".github/workflows/motion-integration.yml",
    "native-sharing": ".github/workflows/sharing-acceptance.yml",
}


def api(path):
    return json.loads(subprocess.check_output(["gh", "api", f"repos/{REPO}/{path}"], text=True))


def git(*args):
    return subprocess.check_output(["git", *args], text=True).strip()


def source_gates(revision):
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise ValueError("Full source SHA required")
    if git("ls-remote", "origin", "refs/heads/main").split()[0] != revision:
        raise ValueError("Source has been superseded")
    tree = git("rev-parse", f"{revision}^{{tree}}")
    candidates = [(revision, None)]
    for pr in api(f"commits/{revision}/pulls?per_page=100"):
        if (pr["merged_at"] and pr["merge_commit_sha"] == revision
                and pr["base"]["ref"] == "main" and pr["head"]["repo"]
                and pr["head"]["repo"]["full_name"] == REPO):
            head = pr["head"]["sha"]
            if git("rev-parse", f"{head}^{{tree}}") == tree:
                candidates.append((head, pr["merged_at"]))
    for tested, merged_at in candidates:
        checks = api(f"commits/{tested}/check-runs?per_page=100")["check_runs"]
        runs = {}
        for name, path in GATES.items():
            matching = [c for c in checks if c["name"] == name and c["app"]["slug"] == "github-actions"]
            if not matching:
                break
            check = max(matching, key=lambda c: c["id"])
            match = re.fullmatch(r"https://github\.com/blancmathis/goalong-history/actions/runs/([0-9]+)/job/[0-9]+", check["details_url"] or "")
            if check["conclusion"] != "success" or check["status"] != "completed" or not match:
                break
            run = api(f"actions/runs/{match[1]}")
            if (run["conclusion"] != "success" or run["head_sha"] != tested
                    or run["path"].split("@")[0] != path
                    or run["head_repository"]["full_name"] != REPO
                    or run["event"] not in {"pull_request", "push", "workflow_dispatch"}):
                break
            runs[name] = run["id"]
        if set(runs) == set(GATES):
            return {"sourceCommit": revision, "tree": tree, "testedCommit": tested,
                    "runs": runs, "buildRunId": runs["build-test-package"], "mergedAt": merged_at}
    raise ValueError("All three official hosted gates must pass for the exact main tree")


if __name__ == "__main__":
    proof = source_gates(sys.argv[1])
    if len(sys.argv) == 3:
        Path(sys.argv[2]).write_text(json.dumps(proof, indent=2) + "\n")
    else:
        print(json.dumps(proof))
