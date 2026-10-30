#!/usr/bin/env python3
"""T-046 synthetic Computer History journal (GitHub runner only, no real data).

Writes ROOT/events/YYYY-MM-DD.jsonl: PER_DAY applicationActivated/windowChanged events per local
day, 08:00-20:00, for DAYS days ending yesterday. Events carry no integrity block (the app signs
only what it records itself): a limit stated in the case summary.
Usage: seed_events.py ROOT --days N --per-day N
"""
import argparse
import datetime as dt
import json
import os
import pathlib
import uuid

APPS = [("TextEdit", "com.apple.TextEdit"), ("Safari", "com.apple.Safari"), ("Finder", "com.apple.finder"),
        ("Terminal", "com.apple.Terminal"), ("Xcode", "com.apple.dt.Xcode"), ("Notes", "com.apple.Notes")]

parser = argparse.ArgumentParser()
parser.add_argument("root")
parser.add_argument("--days", type=int, required=True)
parser.add_argument("--per-day", type=int, required=True)
args = parser.parse_args()

events = pathlib.Path(args.root, "events")
events.mkdir(parents=True, exist_ok=True)
os.chmod(args.root, 0o700)
os.chmod(events, 0o700)
session = str(uuid.uuid4()).upper()
today = dt.date.today()
step = 12 * 3600 / args.per_day
total = 0
for back in range(args.days, 0, -1):
    day = today - dt.timedelta(days=back)
    start = dt.datetime.combine(day, dt.time(8)).astimezone()  # Local 08:00, written in UTC.
    path = events / f"{day.isoformat()}.jsonl"
    with open(path, "w", encoding="utf-8") as out:
        for i in range(args.per_day):
            name, bundle = APPS[(i // 7) % len(APPS)]
            stamp = (start + dt.timedelta(seconds=int(i * step))).astimezone(dt.timezone.utc)
            event = {
                "schemaVersion": 2, "id": str(uuid.uuid4()).upper(), "sessionID": session,
                "timestamp": stamp.strftime("%Y-%m-%dT%H:%M:%SZ"),
                "kind": "applicationActivated" if i % 7 == 0 else "windowChanged",
                "app": {"name": name, "bundleIdentifier": bundle, "processIdentifier": 400 + (i // 7) % len(APPS)},
                "window": {"title": f"Document synthétique T-046 {i % 50}", "role": "AXWindow", "subrole": "AXStandardWindow"},
            }
            out.write(json.dumps(event, ensure_ascii=False, separators=(",", ":")) + "\n")
    os.chmod(path, 0o600)
    total += args.per_day
print(f"seeded {total} events over {args.days} days in {events}")
