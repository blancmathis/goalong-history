#!/usr/bin/env python3
"""Report the tests a `swift test` run skipped, and fail on a skip nobody expected.

usage: skip_report.py LOG [--allowlist FILE] [--report-only] [--emit-allowlist]
  LOG              output of `swift test` (XCTest format)
  --allowlist FILE default scripts/expected_skips.txt: one `Module.Class/test` pattern per line
                   (fnmatch wildcards allowed), optional `# reason` after it
  --report-only    print the report, never fail on unknown skips (CI on a host we cannot see)
  --emit-allowlist print allowlist lines for every skip in LOG (used to regenerate the file)
Exit 0: every skip is on the allowlist. Exit 1: unknown skip(s). Exit 2: bad usage or no test summary
in the log (a log without an "Executed N tests" line proves nothing, so it is never green).
"""
import fnmatch
import os
import re
import sys
from collections import OrderedDict

CASE = re.compile(r"Test Case '-\[(\S+) (\S+)\]' skipped")
REASON = re.compile(r"-\[(\S+) (\S+)\] : Test skipped(?: - (.*))?$")
# XCTest omits "N tests skipped and" when nothing was skipped: that form is a valid summary.
EXECUTED = re.compile(r"Executed (\d+) tests?, with (?:(\d+) tests? skipped and )?(\d+) failures?")
ENV = re.compile(r"GOALONG_[A-Z0-9_]+")


def parse(path):
    reasons, skipped, totals = {}, [], None
    with open(path, errors="replace") as handle:
        for line in handle:
            line = line.rstrip("\n")
            match = REASON.search(line)
            if match:
                reasons[(match.group(1), match.group(2))] = (match.group(3) or "").strip()
            match = CASE.search(line)
            if match:
                key = (match.group(1), match.group(2))
                skipped.append((f"{key[0]}/{key[1]}", reasons.get(key, "(no reason given)")))
            match = EXECUTED.search(line)
            if match:
                totals = tuple(int(value or 0) for value in match.groups())  # last one is the overall total
    return skipped, totals


def group_of(reason):
    names = list(OrderedDict.fromkeys(ENV.findall(reason)))
    return " + ".join(names) if names else "other: " + (reason[:80] or "(no reason given)")


def load_allowlist(path):
    patterns = []
    with open(path) as handle:
        for line in handle:
            entry = line.split("#", 1)[0].strip()
            if entry:
                patterns.append(entry)
    return patterns


def main(argv):
    args = [a for a in argv if not a.startswith("--")]
    flags = {a for a in argv if a.startswith("--") and a != "--allowlist"}
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    allow_path = os.path.join(root, "scripts", "expected_skips.txt")
    if "--allowlist" in argv:
        index = argv.index("--allowlist")
        if index + 1 >= len(argv):
            print(__doc__, file=sys.stderr)
            return 2
        allow_path = argv[index + 1]
        args = [a for a in args if a != allow_path]
    if len(args) != 1:
        print(__doc__, file=sys.stderr)
        return 2
    skipped, totals = parse(args[0])
    if "--emit-allowlist" in flags:
        for name, reason in sorted(skipped):
            print(f"{name}  # {group_of(reason)}")
        return 0
    if totals is None:
        print("skip report: no 'Executed N tests' line in the log; the run did not finish", file=sys.stderr)
        return 2
    patterns = load_allowlist(allow_path)
    groups = OrderedDict()
    unknown = []
    for name, reason in skipped:
        groups.setdefault(group_of(reason), []).append(name)
        if not any(fnmatch.fnmatchcase(name, pattern) for pattern in patterns):
            unknown.append((name, reason))
    lines = [f"Skipped tests report: {len(skipped)} skipped of {totals[0]} executed ({totals[2]} failures)"]
    for group, names in sorted(groups.items(), key=lambda item: (-len(item[1]), item[0])):
        lines.append(f"  {len(names):3d}  {group}")
    if unknown:
        lines.append(f"UNEXPECTED skips ({len(unknown)}), not in {os.path.relpath(allow_path, root)}:")
        lines += [f"  {name}: {reason}" for name, reason in unknown]
        lines.append("Fix the test so it runs, or add the opt-in to the allowlist on purpose.")
    else:
        lines.append("Every skip is an expected opt-in (scripts/expected_skips.txt).")
    report = "\n".join(lines)
    print(report)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a") as handle:
            handle.write("```\n" + report + "\n```\n")
    return 1 if unknown and "--report-only" not in flags else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
