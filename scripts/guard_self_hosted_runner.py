#!/usr/bin/env python3
"""Origin check for defense in depth; NOT an admission security boundary.

Install a reviewed copy outside both the checkout and the runner application.
Called by ACTIONS_RUNNER_HOOK_JOB_STARTED behind independently enforced admission.
Runner v2.338.0 can execute always()/failure() steps after a hook exits nonzero.
Never expose the owner's Mac to a public repository relying only on this hook.
"""
import json
import os
import re
import sys
from pathlib import Path

REPOSITORY = "blancmathis/goalong-history"
WORKFLOWS = {"macos.yml", "continuous-release.yml"}


def allowed(env, event):
    if env.get("GITHUB_REPOSITORY") != REPOSITORY:
        return False
    if event.get("repository", {}).get("full_name") != REPOSITORY:
        return False
    match = re.fullmatch(
        re.escape(REPOSITORY) + r"/\.github/workflows/([^/@]+)@(.+)",
        env.get("GITHUB_WORKFLOW_REF", ""),
    )
    if not match or match[1] not in WORKFLOWS:
        return False
    ref = env.get("GITHUB_REF", "")
    if match[2] != ref:
        return False
    name = env.get("GITHUB_EVENT_NAME")
    if name == "push":
        return (
            ref == "refs/heads/main"
            and event.get("ref") == ref
            and not event.get("deleted", False)
            and event.get("after") == env.get("GITHUB_SHA")
            and bool(re.fullmatch(r"[0-9a-f]{40}", env.get("GITHUB_SHA", "")))
        )
    if name == "workflow_dispatch":
        return ref == "refs/heads/main" and event.get("ref") == "main"
    if name == "pull_request":
        pr = event.get("pull_request", {})
        head, base = pr.get("head", {}), pr.get("base", {})
        number = event.get("number")
        return (
            isinstance(number, int) and number > 0
            and ref == f"refs/pull/{number}/merge"
            and (head.get("repo") or {}).get("full_name") == REPOSITORY
            and (base.get("repo") or {}).get("full_name") == REPOSITORY
            and base.get("ref") == "main"
            and pr.get("author_association") in {"OWNER", "MEMBER", "COLLABORATOR"}
        )
    return False


def main():
    try:
        event = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text())
        accepted = isinstance(event, dict) and allowed(os.environ, event)
    except (KeyError, OSError, ValueError, TypeError, AttributeError):
        accepted = False
    if not accepted:
        print("Origin check failed. This hook alone cannot prevent later always()/failure() steps; independent admission is required.", file=sys.stderr)
        return 1
    print("Job origin accepted by the defense-in-depth check.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
