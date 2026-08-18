#!/usr/bin/env python3
"""Validate LocalHistory JSONL syntax and privacy invariants.

This checks the shape LocalHistory itself promises. It cannot infer whether a
browser vendor failed to expose a private-mode marker, so a real private-window
smoke test is still required after browser updates.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from urllib.parse import parse_qsl, urlsplit


FORBIDDEN_SUPPRESSED_FIELDS = ("window", "element", "url", "pointer", "keyboard", "scroll")
PRIVATE_MARKERS = (
    "incognito",
    "inprivate",
    "private browsing",
    "private window",
    "navigation privée",
    "fenêtre privée",
    "navegación privada",
    "ventana privada",
    "navegação privada",
    "janela privada",
    "inkognito",
    "privates fenster",
    "匿名浏览",
    "无痕浏览",
    "シークレット",
    "プライベートブラウズ",
    "시크릿",
)


def validate_event(event: object, line_number: int) -> list[str]:
    errors: list[str] = []
    if not isinstance(event, dict):
        return [f"line {line_number}: event is not a JSON object"]

    for field in ("schemaVersion", "id", "sessionID", "timestamp", "kind"):
        if field not in event:
            errors.append(f"line {line_number}: missing required field {field!r}")

    if event.get("suppressionReason") == "privateBrowserWindow":
        leaked = [field for field in FORBIDDEN_SUPPRESSED_FIELDS if event.get(field) is not None]
        if leaked:
            errors.append(
                f"line {line_number}: private suppression event contains detailed fields: {', '.join(leaked)}"
            )

    if event.get("kind") == "typingBurst":
        keyboard = event.get("keyboard")
        metadata = event.get("metadata")
        if not isinstance(keyboard, dict) or keyboard.get("key") is not None:
            errors.append(f"line {line_number}: typingBurst contains a key value")
        if not isinstance(metadata, dict) or metadata.get("content_recorded") != "false":
            errors.append(f"line {line_number}: typingBurst does not declare content_recorded=false")

    url = event.get("url")
    if isinstance(url, dict) and isinstance(url.get("value"), str):
        value = url["value"]
        parts = urlsplit(value)
        if parts.username or parts.password:
            errors.append(f"line {line_number}: URL contains credentials")
        if parts.fragment:
            errors.append(f"line {line_number}: URL contains a fragment")
        if any(value for _, value in parse_qsl(parts.query, keep_blank_values=True)):
            errors.append(f"line {line_number}: URL contains a non-empty query value")

    serialized = json.dumps(event, ensure_ascii=False).casefold()
    if event.get("suppressionReason") == "privateBrowserWindow":
        for marker in PRIVATE_MARKERS:
            if marker.casefold() in serialized:
                errors.append(f"line {line_number}: private marker leaked into a suppression event")
                break

    return errors


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("files", nargs="+", type=Path, help="One or more .jsonl files")
    args = parser.parse_args()

    errors: list[str] = []
    event_count = 0
    for path in args.files:
        with path.open("r", encoding="utf-8") as handle:
            for line_number, raw_line in enumerate(handle, start=1):
                raw_line = raw_line.strip()
                if not raw_line:
                    continue
                event_count += 1
                try:
                    event = json.loads(raw_line)
                except json.JSONDecodeError as exc:
                    errors.append(f"{path}: line {line_number}: invalid JSON: {exc}")
                    continue
                for error in validate_event(event, line_number):
                    errors.append(f"{path}: {error}")

    if errors:
        print(f"FAILED: {len(errors)} problem(s) across {event_count} event(s)")
        for error in errors:
            print(f"- {error}")
        return 1

    print(f"OK: {event_count} event(s) passed syntax and privacy-invariant checks")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
