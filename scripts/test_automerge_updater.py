#!/usr/bin/env python3
"""Unit tests for the auto-merge updater decision (no network)."""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from automerge_updater import check_outcomes, decide  # noqa: E402

REQ = {"build-test-package", "verify"}


def pr(n, enabled="2026-11-10T10:00:00Z", draft=False, fork=False, base="main", auto=True,
       checks=(), mergeable="MERGEABLE"):
    return {"number": n, "headRefName": f"b{n}", "headRefOid": f"{n:040d}", "isDraft": draft,
            "isCrossRepository": fork, "baseRefName": base, "createdAt": "2026-11-01T00:00:00Z",
            "mergeable": mergeable, "autoMergeRequest": {"enabledAt": enabled} if auto else None,
            "statusCheckRollup": list(checks)}


def run(name, conclusion="SUCCESS", status="COMPLETED"):
    return {"__typename": "CheckRun", "name": name, "status": status, "conclusion": conclusion}


class Decide(unittest.TestCase):
    def test_picks_oldest_behind(self):
        prs = [pr(2, "2026-11-10T12:00:00Z"), pr(1, "2026-11-10T11:00:00Z")]
        action, chosen, _ = decide(prs, REQ, lambda p: 3)
        self.assertEqual((action, chosen["number"]), ("update", 1))

    def test_waits_when_one_in_flight(self):
        prs = [pr(1, "2026-11-10T11:00:00Z"), pr(2, "2026-11-10T12:00:00Z", checks=[run("verify", "", "IN_PROGRESS")])]
        action, chosen, _ = decide(prs, REQ, lambda p: 0 if p["number"] == 2 else 1)
        self.assertEqual((action, chosen["number"]), ("wait", 2))

    def test_skips_draft_fork_no_automerge_other_base(self):
        prs = [pr(1, draft=True), pr(2, fork=True), pr(3, auto=False), pr(4, base="dev")]
        self.assertEqual(decide(prs, REQ, lambda p: 5)[0], "idle")

    def test_skips_failed_required_and_conflicts(self):
        prs = [pr(1, "2026-11-10T09:00:00Z", checks=[run("verify", "FAILURE")]),
               pr(2, "2026-11-10T10:00:00Z", mergeable="CONFLICTING"),
               pr(3, "2026-11-10T11:00:00Z", checks=[run("advisory", "FAILURE")])]
        action, chosen, reasons = decide(prs, REQ, lambda p: 1)
        self.assertEqual((action, chosen["number"]), ("update", 3))
        self.assertTrue(any("#1 skipped" in r for r in reasons))

    def test_failed_in_flight_does_not_block(self):
        prs = [pr(1, "2026-11-10T09:00:00Z", checks=[run("verify", "FAILURE")]), pr(2, "2026-11-10T10:00:00Z")]
        action, chosen, _ = decide(prs, REQ, lambda p: 0 if p["number"] == 1 else 2)
        self.assertEqual((action, chosen["number"]), ("update", 2))

    def test_outcomes(self):
        out = check_outcomes([run("a"), run("b", "", "QUEUED"), {"__typename": "StatusContext", "context": "c", "state": "ERROR"}])
        self.assertEqual(out, {"a": "passed", "b": "pending", "c": "failed"})


if __name__ == "__main__":
    unittest.main()
