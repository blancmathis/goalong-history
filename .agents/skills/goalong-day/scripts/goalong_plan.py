#!/usr/bin/env python3
"""Prepare and apply revision-checked Goalong edits without a background worker.

The native app remains the only writer. Preparing is read-only. Applying sends
one request; a timeout never triggers an automatic retry.
"""
import argparse
import datetime as dt
import json
from pathlib import Path
import subprocess
import sys
import uuid

DEFAULT_CLI = "/Applications/Goalong History.app/Contents/MacOS/goalong"
STATUSES = ("queued", "running", "waitingForYou", "readyForReview", "done", "failed", "cancelled")
PATCH_KEYS = {"actor", "reason", "items", "removeItemIDs", "processes", "removeProcessIDs", "agenda", "intention", "reflow"}
MAX_INPUT = 65536


class GoalongError(Exception):
    def __init__(self, payload):
        self.payload = payload


def fail(code, message):
    raise GoalongError({"error": code, "message": message})


def load_json(path):
    if path == "-":
        raw = sys.stdin.read(MAX_INPUT + 1)
    else:
        with open(path, encoding="utf-8") as stream:
            raw = stream.read(MAX_INPUT + 1)
    if len(raw.encode("utf-8")) > MAX_INPUT:
        fail("invalidArgument", "Input exceeds 64 KiB.")
    try:
        data = json.loads(raw)
    except ValueError:
        fail("invalidArgument", "Expected JSON input.")
    if not isinstance(data, dict):
        fail("invalidArgument", "Expected a JSON object.")
    return data


def exact_day(value):
    try:
        parsed = dt.date.fromisoformat(value)
    except (TypeError, ValueError):
        fail("invalidArgument", "Use an explicit YYYY-MM-DD day.")
    if parsed.isoformat() != value:
        fail("invalidArgument", "Use an explicit YYYY-MM-DD day.")
    return value


def revision(value):
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        fail("invalidArgument", "Revision must be a nonnegative integer.")
    return value


def native(cli, args, body=None, write=False):
    if not Path(cli).is_file():
        fail("unavailable", "Goalong CLI not found; continue the real task.")
    raw = None if body is None else json.dumps(body, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    if raw is not None and len(raw.encode("utf-8")) > MAX_INPUT:
        fail("invalidArgument", "Native request exceeds 64 KiB.")
    try:
        result = subprocess.run([cli, *args], input=raw, capture_output=True, text=True, timeout=12 if write else 4)
    except subprocess.TimeoutExpired:
        fail("outcomeUnknown" if write else "timeout", "No automatic retry. Read the plan and its receipts before any further write." if write else "Goalong did not answer; continue the real task.")
    except OSError as exc:
        fail("unavailable", type(exc).__name__)
    if result.returncode:
        try:
            error = json.loads(result.stderr)
        except ValueError:
            error = {"error": "nativeError", "exitCode": result.returncode}
        if not isinstance(error, dict):
            error = {"error": "nativeError", "exitCode": result.returncode}
        raise GoalongError(error)
    try:
        return json.loads(result.stdout)
    except ValueError:
        fail("outcomeUnknown" if write else "invalidResponse", "Goalong returned no readable JSON; inspect the current plan before writing again.")


def validate_patch(patch):
    if not isinstance(patch, dict) or not patch or set(patch) - PATCH_KEYS:
        fail("invalidArgument", "Patch must contain only documented plan patch fields.")
    for key, limit in (("items", 10), ("processes", 64), ("removeItemIDs", 10), ("removeProcessIDs", 64)):
        if key in patch and (not isinstance(patch[key], list) or len(patch[key]) > limit):
            fail("invalidArgument", f"Invalid {key} list.")
    # Native validation owns complete schemas, references and schedule invariants.
    # In particular an upsert is a complete object, not a field-level merge.
    for key in ("items", "processes"):
        for item in patch.get(key, []):
            if not isinstance(item, dict) or not item.get("id") or not item.get("title"):
                fail("invalidArgument", f"Each {key} upsert needs a stable id and title.")
    return patch


def operation(day, rev, request_id, kind, patch=None):
    result = {"schema": 1, "day": exact_day(day), "ifRevision": revision(rev),
              "requestID": request_id or str(uuid.uuid4()), "kind": kind}
    if not isinstance(result["requestID"], str) or not result["requestID"].strip() or len(result["requestID"]) > 120:
        fail("invalidArgument", "Request ID must be nonempty and at most 120 characters.")
    if kind == "patch":
        result["patch"] = validate_patch(patch)
    return result


def apply(cli, data):
    if data.get("schema") != 1 or data.get("kind") not in ("patch", "reflow", "undo"):
        fail("invalidArgument", "Expected a prepared Goalong operation, schema 1.")
    if not data.get("requestID"):
        fail("invalidArgument", "A prepared operation must retain its request ID.")
    prepared = operation(data.get("day"), data.get("ifRevision"), data["requestID"], data["kind"], data.get("patch"))
    args = ["plan", prepared["kind"], "--day", prepared["day"], "--if-revision", str(prepared["ifRevision"]), "--request-id", prepared["requestID"]]
    if prepared["kind"] == "patch":
        args += ["--file", "-"]
    return native(cli, args, prepared.get("patch"), write=True)


def prepare_process(cli, args):
    day = exact_day(args.day)
    try:
        process_id = str(uuid.UUID(args.id)).upper()
    except ValueError:
        fail("invalidArgument", "Process ID must be a stable UUID.")
    plan = native(cli, ["plan", "show", day])
    if not isinstance(plan, dict) or plan.get("day") != day or not isinstance(plan.get("items"), list):
        fail("invalidResponse", "Expected the complete native plan; do not build a write from a compact summary.")
    entries = plan.get("processes") or []
    current = next((p for p in entries if isinstance(p, dict) and str(p.get("id", "")).upper() == process_id), None)
    item = dict(current) if current else {"id": process_id}
    for source, field in (("title", "title"), ("project", "project"), ("agent", "agent"), ("external_id", "externalID"), ("context_url", "contextURL"), ("question", "question"), ("answer", "answer")):
        value = getattr(args, source)
        if value is not None:
            item[field] = value
    if not item.get("title"):
        fail("invalidArgument", "A new process requires --title.")
    if args.clear_question:
        item.pop("question", None)
    if args.clear_answer:
        item.pop("answer", None)
    item["status"] = args.status
    item["updatedAt"] = dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")
    patch = {"processes": [item], "actor": args.actor, "reason": args.reason}
    return operation(day, plan.get("revision", 0) or 0, args.request_id, "patch", patch)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cli", default=DEFAULT_CLI, help="Absolute native CLI path, never a shell command.")
    commands = parser.add_subparsers(dest="command", required=True)
    snapshot = commands.add_parser("snapshot", help="Read the complete plan before preparing a merge.")
    snapshot.add_argument("--day", required=True)
    prepare = commands.add_parser("prepare", help="Print an immutable operation; no write.")
    prepare.add_argument("--day", required=True)
    prepare.add_argument("--if-revision", required=True, type=int)
    prepare.add_argument("--request-id")
    prepare.add_argument("--kind", choices=("patch", "reflow", "undo"), default="patch")
    prepare.add_argument("--file", help="Patch JSON file or -, required for kind patch.")
    commit = commands.add_parser("apply", help="Send one previously prepared operation.")
    commit.add_argument("--file", required=True)
    process = commands.add_parser("process", help="Merge one explicit process report into a freshly read plan.")
    process.add_argument("--day", required=True)
    process.add_argument("--id", required=True, help="Keep the same UUID for this process throughout its lifecycle.")
    process.add_argument("--status", choices=STATUSES, required=True)
    for flag in ("title", "project", "agent", "external-id", "context-url", "question", "answer", "request-id"):
        process.add_argument("--" + flag)
    process.add_argument("--clear-question", action="store_true")
    process.add_argument("--clear-answer", action="store_true")
    process.add_argument("--actor", default="agent")
    process.add_argument("--reason", default="Explicit process report")
    args = parser.parse_args()
    try:
        if args.command == "snapshot":
            result = native(args.cli, ["plan", "show", exact_day(args.day)])
        elif args.command == "prepare":
            if args.kind == "patch" and not args.file:
                fail("invalidArgument", "--file is required for a patch.")
            if args.kind != "patch" and args.file:
                fail("invalidArgument", "Reflow and undo do not take a patch file.")
            result = operation(args.day, args.if_revision, args.request_id, args.kind, load_json(args.file) if args.file else None)
        elif args.command == "process":
            result = prepare_process(args.cli, args)
        else:
            result = apply(args.cli, load_json(args.file))
        print(json.dumps(result, ensure_ascii=False, indent=2))
    except GoalongError as exc:
        print(json.dumps(exc.payload, ensure_ascii=False), file=sys.stderr)
        return 1
    except (OSError, ValueError, TypeError) as exc:
        print(json.dumps({"error": "invalidArgument", "message": str(exc)}, ensure_ascii=False), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
