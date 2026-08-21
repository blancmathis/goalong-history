#!/usr/bin/env python3
"""Interactive smoke test for Goalong History private-browser suppression.

Start outside private browsing, then run this script in Terminal. During the
countdown, open or switch to a private browser window. Click, scroll, and type
only non-sensitive test text until the terminal bell sounds.
"""

from __future__ import annotations

import argparse
import json
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path


BROWSER_BUNDLE_MARKERS = (
    "safari",
    "chrome",
    "chromium",
    "edgemac",
    "brave",
    "thebrowser",
    "firefox",
    "librewolf",
    "floorp",
    "vivaldi",
    "opera",
    "duckduckgo",
    "kagi",
)
BROWSER_NAME_MARKERS = (
    "safari",
    "chrome",
    "chromium",
    "firefox",
    "librewolf",
    "floorp",
    "edge",
    "brave",
    "arc",
    "opera",
    "vivaldi",
    "orion",
    "duckduckgo",
    "zen browser",
    "dia",
    "sigmaos",
    "browser",
)
DETAIL_FIELDS = ("window", "element", "url", "pointer", "keyboard", "scroll")


def parse_timestamp(value: object) -> datetime | None:
    if not isinstance(value, str):
        return None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def is_browser_event(event: dict[str, object]) -> bool:
    app = event.get("app")
    if not isinstance(app, dict):
        return False
    bundle = str(app.get("bundleIdentifier") or "").casefold()
    name = str(app.get("name") or "").casefold()
    return any(marker in bundle for marker in BROWSER_BUNDLE_MARKERS) or any(
        marker in name for marker in BROWSER_NAME_MARKERS
    )


def event_files(root: Path, start: datetime, end: datetime) -> list[Path]:
    local_start = start.astimezone()
    local_end = end.astimezone()
    days = (local_end.date() - local_start.date()).days
    return [root / f"{(local_start.date() + timedelta(days=offset)).isoformat()}.jsonl" for offset in range(days + 1)]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--warmup", type=int, default=5, help="Seconds to switch to the private window")
    parser.add_argument("--duration", type=int, default=15, help="Seconds to interact in the private window")
    parser.add_argument(
        "--events-dir",
        type=Path,
        default=Path.home() / "Library/Application Support/LocalHistory/events",
    )
    args = parser.parse_args()

    if args.warmup < 1 or args.duration < 3:
        parser.error("--warmup must be at least 1 and --duration at least 3")

    print("Start outside private browsing.")
    print("During the countdown, OPEN or switch to a PRIVATE browser window.")
    print("Then click, scroll, and type only non-sensitive test text.")
    observation_start = datetime.now(timezone.utc)
    for remaining in range(args.warmup, 0, -1):
        print(f"Test starts in {remaining}…", flush=True)
        time.sleep(1)

    interaction_start = datetime.now(timezone.utc)
    print(f"Recording private interaction interval for {args.duration} seconds…", flush=True)
    time.sleep(args.duration)
    end = datetime.now(timezone.utc)
    print("\aTest interval ended. Return to Terminal.", flush=True)
    time.sleep(1.0)

    browser_events: list[dict[str, object]] = []
    for path in event_files(args.events_dir, observation_start, end):
        if not path.exists():
            continue
        with path.open("r", encoding="utf-8") as handle:
            for raw_line in handle:
                raw_line = raw_line.strip()
                if not raw_line:
                    continue
                try:
                    event = json.loads(raw_line)
                except json.JSONDecodeError:
                    continue
                if not isinstance(event, dict) or not is_browser_event(event):
                    continue
                timestamp = parse_timestamp(event.get("timestamp"))
                if timestamp is None or not (observation_start <= timestamp <= end):
                    continue
                browser_events.append(event)

    if not browser_events:
        print("INCONCLUSIVE: no browser event or suppression transition was observed.")
        print("Check that Goalong History is running and both permissions are enabled, then repeat.")
        return 2

    unsafe: list[dict[str, object]] = []
    suppressed = 0
    for event in browser_events:
        timestamp = parse_timestamp(event.get("timestamp"))
        if event.get("suppressionReason") == "privateBrowserWindow" and event.get("kind") == "captureSuppressed":
            suppressed += 1
            continue
        if timestamp is None or timestamp < interaction_start:
            continue
        if any(event.get(field) is not None for field in DETAIL_FIELDS) or event.get("kind") in {
            "mouseClick",
            "keyboardShortcut",
            "keyPressed",
            "typingBurst",
            "scrollBurst",
            "windowChanged",
            "focusChanged",
            "urlChanged",
        }:
            unsafe.append(event)

    if unsafe:
        print(f"FAILED: {len(unsafe)} detailed browser event(s) were recorded during the private-window interval.")
        for event in unsafe[:10]:
            print(f"- {event.get('timestamp')}  {event.get('kind')}  id={event.get('id')}")
        print("Exclude this browser completely until its private-mode marker is added and tested.")
        return 1

    if suppressed == 0:
        print("INCONCLUSIVE: browser activity appeared, but no privateBrowserWindow suppression transition was found.")
        return 2

    print(f"PASS: private-browser suppression was observed and no detailed browser event leaked ({len(browser_events)} event(s) inspected).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
