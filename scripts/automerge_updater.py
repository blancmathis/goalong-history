#!/usr/bin/env python3
"""Merge-queue substitute: keep ONE auto-merge PR up to date with main.

GitHub merge queues need an organisation repository; this one belongs to a
user. Branch protection keeps `strict: true`, so a PR must contain the latest
main before auto-merge can fire. Each run:

1. Lists open PRs on `main` with auto-merge enabled, same repository, not draft.
2. If one of them is already up to date and its required checks have not
   failed, it is "in flight": wait (one PR at a time, like a queue of 1).
3. Otherwise picks the oldest (auto-merge enabled time, then creation) PR that
   is behind main, not conflicting, with no failed required check, and calls
   `update-branch` with its expected head SHA.

The call uses the owner's `gh` login, so the resulting push triggers the
workflows (a GITHUB_TOKEN push would not). It never merges and never touches
fork PRs. See docs/AUTOMERGE-UPDATER.md.
"""
import argparse
import json
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

REPO = "blancmathis/goalong-history"
BASE = "main"
FAILED = {"FAILURE", "CANCELLED", "TIMED_OUT", "ACTION_REQUIRED", "STARTUP_FAILURE", "ERROR", "STALE"}
PR_FIELDS = ("number,title,headRefName,headRefOid,isDraft,isCrossRepository,createdAt,"
             "mergeable,autoMergeRequest,baseRefName,statusCheckRollup")


def gh(*args, gh_bin="gh"):
    return subprocess.run([gh_bin, *args], check=True, capture_output=True, text=True).stdout


def check_outcomes(rollup):
    """Map check name -> 'failed' | 'pending' | 'passed' (latest per name wins on failure)."""
    out = {}
    for item in rollup or []:
        name = item.get("name") or item.get("context") or ""
        if item.get("__typename") == "StatusContext":
            state = (item.get("state") or "").upper()
            outcome = "failed" if state in FAILED else "passed" if state == "SUCCESS" else "pending"
        else:
            conclusion = (item.get("conclusion") or "").upper()
            if (item.get("status") or "").upper() != "COMPLETED":
                outcome = "pending"
            elif conclusion in FAILED:
                outcome = "failed"
            else:
                outcome = "passed"
        if out.get(name) != "failed":
            out[name] = outcome
    return out


def required_failed(pr, required):
    outcomes = check_outcomes(pr.get("statusCheckRollup"))
    return sorted(n for n in required if outcomes.get(n) == "failed")


def eligible(pr):
    return (pr.get("autoMergeRequest") is not None and not pr.get("isDraft")
            and not pr.get("isCrossRepository") and pr.get("baseRefName") == BASE)


def order_key(pr):
    enabled = (pr.get("autoMergeRequest") or {}).get("enabledAt") or pr.get("createdAt") or ""
    return (enabled, pr.get("createdAt") or "", pr["number"])


def decide(prs, required, behind_by):
    """Pure decision. `behind_by(pr) -> int` counts main commits missing from the PR.

    Returns (action, pr_or_None, reasons) where action is 'update', 'wait' or 'idle'.
    """
    reasons = []
    candidates = sorted((p for p in prs if eligible(p)), key=order_key)
    for pr in prs:
        if pr.get("autoMergeRequest") is not None and not eligible(pr):
            reasons.append(f"#{pr['number']} ignored (draft, fork or other base)")
    behind = []
    for pr in candidates:
        failed = required_failed(pr, required)
        if failed:
            reasons.append(f"#{pr['number']} skipped: required check failed {failed}")
            continue
        if pr.get("mergeable") == "CONFLICTING":
            reasons.append(f"#{pr['number']} skipped: conflicts with {BASE}")
            continue
        count = behind_by(pr)
        if count == 0:
            return "wait", pr, reasons + [f"#{pr['number']} in flight (up to date, checks running or merging)"]
        behind.append((pr, count))
    if behind:
        pr, count = behind[0]
        return "update", pr, reasons + [f"#{pr['number']} oldest behind {BASE} by {count} commit(s)"]
    return "idle", None, reasons + ["no eligible auto-merge PR"]


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--dry-run", action="store_true", help="decide and print, change nothing")
    parser.add_argument("--repo", default=REPO)
    parser.add_argument("--gh", default="gh")
    parser.add_argument("--state", type=Path, help="file remembering the last decision (quiet logs)")
    args = parser.parse_args(argv)

    def call(*a):
        return gh(*a, gh_bin=args.gh)

    prs = json.loads(call("pr", "list", "-R", args.repo, "--state", "open", "--base", BASE,
                          "--limit", "100", "--json", PR_FIELDS))
    protection = json.loads(call("api", f"repos/{args.repo}/branches/{BASE}/protection/required_status_checks"))
    required = {c["context"] for c in protection.get("checks", [])} | set(protection.get("contexts", []))

    def behind_by(pr):
        cmp = json.loads(call("api", f"repos/{args.repo}/compare/{BASE}...{pr['headRefOid']}"))
        return int(cmp.get("behind_by", 0))

    action, pr, reasons = decide(prs, required, behind_by)
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    line = f"{action}" + (f" #{pr['number']} {pr['headRefName']}@{pr['headRefOid'][:8]}" if pr else "")
    summary = f"{line} | " + "; ".join(reasons)

    previous = args.state.read_text() if args.state and args.state.exists() else None
    quiet = action != "update" and previous == summary
    if not quiet:
        print(f"{now} {'DRY-RUN ' if args.dry_run else ''}{summary}", flush=True)
    if args.state and not args.dry_run:
        args.state.write_text(summary)

    if action == "update" and not args.dry_run:
        try:
            result = call("api", "-X", "PUT", f"repos/{args.repo}/pulls/{pr['number']}/update-branch",
                          "-f", f"expected_head_sha={pr['headRefOid']}")
            print(f"{now} updated #{pr['number']}: {json.loads(result).get('message', '')}", flush=True)
        except subprocess.CalledProcessError as error:
            print(f"{now} update #{pr['number']} failed: {error.stderr.strip()}", file=sys.stderr, flush=True)
            if args.state:
                args.state.write_text("")  # retry and log on next run
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
