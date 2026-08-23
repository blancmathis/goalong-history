#!/usr/bin/env python3
"""Create deterministic local Computer History fixtures for strict CI validation.

The generated tree mirrors the read-only LocalHistory store. It contains no user data,
never touches the default Application Support directory, and can generate either a
fully paired causal fixture or an intentionally incomplete negative fixture.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
from datetime import datetime, timedelta, timezone
from typing import Any


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True, type=pathlib.Path)
    parser.add_argument("--day", default="2026-08-20")
    parser.add_argument(
        "--without-pairs",
        action="store_true",
        help="Generate actions and resources without semantic before/after evidence.",
    )
    return parser.parse_args()


def iso8601(value: datetime) -> str:
    return value.astimezone(timezone.utc).isoformat(timespec="milliseconds").replace(
        "+00:00", "Z"
    )


def sha256(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def app() -> dict[str, Any]:
    return {
        "name": "Safari",
        "bundleIdentifier": "com.apple.Safari",
        "processIdentifier": 4242,
    }


def window(title: str) -> dict[str, Any]:
    return {"title": title, "role": "AXWindow", "subrole": None}


def element(role: str, label: str, identifier: str) -> dict[str, Any]:
    return {
        "role": role,
        "subrole": None,
        "title": label,
        "label": label,
        "identifier": identifier,
        "isSecure": False,
    }


def url_snapshot() -> dict[str, Any]:
    return {
        "value": "https://docs.google.com/document/d/goalong-parity-proposal/edit",
        "host": "docs.google.com",
        "redactionApplied": False,
    }


def classification() -> dict[str, Any]:
    return {
        "category": "work",
        "isWork": True,
        "confidence": 0.99,
        "classifierVersion": "deterministic-parity-fixture-v1",
    }


def semantic_payload(
    identifier: str,
    captured_at: datetime,
    text: str,
    focused_role: str,
) -> dict[str, Any]:
    return {
        "schemaVersion": 1,
        "id": identifier,
        "capturedAt": iso8601(captured_at),
        "application": app(),
        "window": window("Enterprise Launch Proposal — Google Docs"),
        "url": url_snapshot(),
        "focusedRole": focused_role,
        "source": "mixed",
        "text": text,
        "contentSHA256": sha256(text),
        "redacted": False,
        "truncated": False,
    }


def semantic_reference(payload: dict[str, Any]) -> dict[str, Any]:
    text = payload["text"]
    return {
        "snapshotID": payload["id"],
        "capturedAt": payload["capturedAt"],
        "source": payload["source"],
        "contentSHA256": payload["contentSHA256"],
        "characterCount": len(text),
        "redacted": payload["redacted"],
        "truncated": payload["truncated"],
    }


def base_event(
    identifier: str,
    timestamp: datetime,
    kind: str,
    interaction_id: str,
    target: dict[str, Any],
) -> dict[str, Any]:
    return {
        "schemaVersion": 4,
        "id": identifier,
        "sessionID": "deterministic-computer-history-parity",
        "timestamp": iso8601(timestamp),
        "kind": kind,
        "app": app(),
        "window": window("Enterprise Launch Proposal — Google Docs"),
        "element": target,
        "url": url_snapshot(),
        "classification": classification(),
        "metadata": {
            "computer_history.interaction_id": interaction_id,
            "computer_history.fixture": "deterministic-v1",
        },
    }


def semantic_event(
    identifier: str,
    timestamp: datetime,
    interaction_id: str,
    phase: str,
    payload: dict[str, Any],
    target: dict[str, Any],
) -> dict[str, Any]:
    event = base_event(
        identifier=identifier,
        timestamp=timestamp,
        kind="semanticSnapshot",
        interaction_id=interaction_id,
        target=target,
    )
    event["semanticContext"] = semantic_reference(payload)
    event["metadata"]["computer_history.interaction_phase"] = phase
    event["metadata"]["computer_history.interaction_trigger"] = "fixture"
    return event


def action_event(
    identifier: str,
    timestamp: datetime,
    interaction_id: str,
    kind: str,
    target: dict[str, Any],
    action: dict[str, Any],
    metadata: dict[str, str],
) -> dict[str, Any]:
    event = base_event(
        identifier=identifier,
        timestamp=timestamp,
        kind=kind,
        interaction_id=interaction_id,
        target=target,
    )
    event.update(action)
    event["metadata"].update(metadata)
    return event


def build_fixture(day: datetime, without_pairs: bool) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    title = "Enterprise Launch Proposal — Google Docs"
    del title  # The stable title is supplied by window() in every event.
    scenarios = [
        {
            "name": "typing-pricing",
            "offset": 0,
            "kind": "typingBurst",
            "target": element("AXTextArea", "Pricing section", "pricing-editor"),
            "before": "Enterprise launch proposal. The pricing section is incomplete.",
            "after": "Enterprise launch proposal. Pricing now contains EUR 49 per seat.",
            "action": {
                "keyboard": {
                    "category": "text_activity",
                    "key": None,
                    "modifiers": [],
                    "isRepeat": False,
                }
            },
            "metadata": {
                "computer_history.interaction_trigger": "typing",
                "keystroke_count": "24",
                "duration_ms": "1800",
            },
        },
        {
            "name": "click-save",
            "offset": 60,
            "kind": "mouseClick",
            "target": element("AXButton", "Save", "save-button"),
            "before": "Draft changes are pending. The Save button is available.",
            "after": "Saved successfully. All proposal changes are synchronized.",
            "action": {
                "pointer": {
                    "button": "left",
                    "x": 842.0,
                    "y": 92.0,
                    "clickCount": 1,
                }
            },
            "metadata": {"computer_history.interaction_trigger": "click"},
        },
        {
            "name": "shortcut-save",
            "offset": 120,
            "kind": "keyboardShortcut",
            "target": element("AXTextArea", "Proposal editor", "proposal-editor"),
            "before": "Enterprise launch proposal is open for editing.",
            "after": "Saved successfully with Command-S. The document is up to date.",
            "action": {
                "keyboard": {
                    "category": "shortcut",
                    "key": "s",
                    "modifiers": ["command"],
                    "isRepeat": False,
                }
            },
            "metadata": {"computer_history.interaction_trigger": "shortcut"},
        },
        {
            "name": "scroll-risk",
            "offset": 180,
            "kind": "scrollBurst",
            "target": element("AXScrollArea", "Proposal document", "document-scroll"),
            "before": "The executive summary is visible at the top of the proposal.",
            "after": "The risk and mitigation section is now visible below the executive summary.",
            "action": {
                "scroll": {"deltaX": 0.0, "deltaY": -720.0, "eventCount": 12}
            },
            "metadata": {
                "computer_history.interaction_trigger": "scroll",
                "duration_ms": "900",
            },
        },
    ]

    events: list[dict[str, Any]] = []
    payloads: list[dict[str, Any]] = []
    for scenario in scenarios:
        interaction_id = f"fixture-{scenario['name']}"
        action_time = day + timedelta(seconds=scenario["offset"])

        if not without_pairs:
            before = semantic_payload(
                f"{interaction_id}-before",
                action_time - timedelta(milliseconds=250),
                scenario["before"],
                scenario["target"]["role"],
            )
            settled = semantic_payload(
                f"{interaction_id}-settled",
                action_time + timedelta(seconds=1),
                scenario["after"],
                scenario["target"]["role"],
            )
            payloads.extend([before, settled])
            events.append(
                semantic_event(
                    f"{interaction_id}-before-event",
                    action_time - timedelta(milliseconds=250),
                    interaction_id,
                    "before",
                    before,
                    scenario["target"],
                )
            )

        events.append(
            action_event(
                f"{interaction_id}-action",
                action_time,
                interaction_id,
                scenario["kind"],
                scenario["target"],
                scenario["action"],
                scenario["metadata"],
            )
        )

        if not without_pairs:
            events.append(
                semantic_event(
                    f"{interaction_id}-settled-event",
                    action_time + timedelta(seconds=1),
                    interaction_id,
                    "settled",
                    settled,
                    scenario["target"],
                )
            )

    events.sort(key=lambda row: (row["timestamp"], row["id"]))
    payloads.sort(key=lambda row: (row["capturedAt"], row["id"]))
    return events, payloads


def write_jsonl(path: pathlib.Path, rows: list[dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as handle:
        for row in rows:
            handle.write(
                json.dumps(row, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
            )
            handle.write("\n")


def main() -> int:
    args = parse_args()
    try:
        day = datetime.strptime(args.day, "%Y-%m-%d").replace(
            hour=9, minute=0, second=0, tzinfo=timezone.utc
        )
    except ValueError as exc:
        raise SystemExit(f"Invalid --day: {args.day}: {exc}") from exc

    if args.output.exists() and any(args.output.iterdir()):
        raise SystemExit(f"Refusing to overwrite non-empty fixture directory: {args.output}")

    events, payloads = build_fixture(day=day, without_pairs=args.without_pairs)
    write_jsonl(args.output / "events" / f"{args.day}.jsonl", events)
    write_jsonl(args.output / "semantic" / f"{args.day}.jsonl", payloads)
    print(
        json.dumps(
            {
                "day": args.day,
                "events": len(events),
                "semantic_payloads": len(payloads),
                "actions": 4,
                "expected_pair_ratio": 0.0 if args.without_pairs else 1.0,
                "output": str(args.output),
            },
            sort_keys=True,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
