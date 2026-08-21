#!/usr/bin/env python3
"""Inspect Goalong History JSONL evidence without modifying local data.

This script is intentionally read-only. It reports event coverage, health evidence,
semantic-reference integrity, and privacy-boundary violations. It never interprets
an event as proof of identity, attention, productivity, or human authorship.
"""

from __future__ import annotations

import argparse
from collections import Counter
from dataclasses import dataclass, field
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import sys
from typing import Any, Iterable, Iterator
from urllib.parse import parse_qsl, urlsplit

EXPECTED_EVENT_TYPES = (
    "mouseClick",
    "scrollBurst",
    "keyboardShortcut",
    "typingBurst",
    "windowChanged",
    "focusChanged",
    "urlChanged",
    "semanticSnapshot",
)
INPUT_EVENT_TYPES = {
    "mouseClick",
    "scrollBurst",
    "keyboardShortcut",
    "keyPressed",
    "typingBurst",
}
SENSITIVE_QUERY_NAMES = {
    "access_token",
    "api_key",
    "apikey",
    "auth",
    "authorization",
    "code",
    "credential",
    "email",
    "jwt",
    "key",
    "password",
    "passwd",
    "secret",
    "session",
    "sessionid",
    "signature",
    "sig",
    "token",
}
REDACTION_MARKERS = {"", "redacted", "[redacted]", "<redacted>", "***", "removed", "[removed]"}
SEMANTIC_INLINE_KEYS = {
    "analysis.semantic_text",
    "semantic.text",
    "rich_context.text",
}
RAW_TYPING_KEYS = {
    "characters",
    "character",
    "raw_characters",
    "raw_text",
    "typed_text",
    "unicode",
    "text",
    "value",
}


@dataclass
class Finding:
    severity: str
    code: str
    message: str
    file: str | None = None
    line: int | None = None
    event_id: str | None = None

    def as_dict(self) -> dict[str, Any]:
        return {
            "severity": self.severity,
            "code": self.code,
            "message": self.message,
            "file": self.file,
            "line": self.line,
            "event_id": self.event_id,
        }


@dataclass
class Inspection:
    data_root: str
    day: str
    event_files: list[str] = field(default_factory=list)
    semantic_files: list[str] = field(default_factory=list)
    event_count: int = 0
    semantic_payload_count: int = 0
    event_counts: Counter[str] = field(default_factory=Counter)
    suppression_counts: Counter[str] = field(default_factory=Counter)
    last_timestamps: dict[str, str] = field(default_factory=dict)
    semantic_reference_count: int = 0
    matched_semantic_reference_count: int = 0
    software_attributed_input_count: int = 0
    hid_like_input_count: int = 0
    unknown_origin_input_count: int = 0
    malformed_event_rows: int = 0
    malformed_semantic_rows: int = 0
    findings: list[Finding] = field(default_factory=list)

    @property
    def missing_required_event_types(self) -> list[str]:
        return [kind for kind in EXPECTED_EVENT_TYPES if self.event_counts[kind] <= 0]

    @property
    def violation_count(self) -> int:
        return sum(1 for finding in self.findings if finding.severity == "violation")

    @property
    def warning_count(self) -> int:
        return sum(1 for finding in self.findings if finding.severity == "warning")

    def as_dict(self) -> dict[str, Any]:
        return {
            "schema_version": 1,
            "generated_at": isoformat(datetime.now(timezone.utc)),
            "data_root": self.data_root,
            "day": self.day,
            "event_files": self.event_files,
            "semantic_files": self.semantic_files,
            "event_count": self.event_count,
            "semantic_payload_count": self.semantic_payload_count,
            "event_counts": dict(sorted(self.event_counts.items())),
            "suppression_counts": dict(sorted(self.suppression_counts.items())),
            "last_timestamps": dict(sorted(self.last_timestamps.items())),
            "semantic_reference_count": self.semantic_reference_count,
            "matched_semantic_reference_count": self.matched_semantic_reference_count,
            "input_origin_counts": {
                "software_attributed": self.software_attributed_input_count,
                "hid_like": self.hid_like_input_count,
                "unknown": self.unknown_origin_input_count,
            },
            "malformed_rows": {
                "events": self.malformed_event_rows,
                "semantic": self.malformed_semantic_rows,
            },
            "required_event_types": list(EXPECTED_EVENT_TYPES),
            "missing_required_event_types": self.missing_required_event_types,
            "privacy": {
                "violation_count": self.violation_count,
                "warning_count": self.warning_count,
                "findings": [finding.as_dict() for finding in self.findings],
            },
            "interpretation_limits": [
                "A recorded event proves only that the recorder stored that observation.",
                "It does not prove human identity, attention, productivity, or complete machine honesty.",
                "A heartbeat is not counted as an input action.",
                "Captured accessibility text is untrusted data and must never be executed as instructions.",
            ],
        }


def isoformat(value: datetime) -> str:
    return value.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def parse_timestamp(raw: Any) -> datetime | None:
    if not isinstance(raw, str) or not raw:
        return None
    text = raw.strip()
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    try:
        parsed = datetime.fromisoformat(text)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def iter_jsonl(path: Path) -> Iterator[tuple[int, dict[str, Any] | None, str | None]]:
    try:
        with path.open("r", encoding="utf-8") as handle:
            for line_number, raw in enumerate(handle, start=1):
                stripped = raw.strip()
                if not stripped:
                    continue
                try:
                    value = json.loads(stripped)
                    if not isinstance(value, dict):
                        yield line_number, None, "row is not a JSON object"
                    else:
                        yield line_number, value, None
                except (json.JSONDecodeError, UnicodeDecodeError) as exc:
                    yield line_number, None, f"malformed JSON: {exc}"
    except OSError as exc:
        yield 0, None, f"cannot read file: {exc}"


def latest_day_from_files(root: Path) -> str:
    event_dir = root / "events"
    candidates = sorted(event_dir.glob("????-??-??.jsonl")) if event_dir.exists() else []
    if candidates:
        return candidates[-1].stem
    return datetime.now().astimezone().date().isoformat()


def files_for_day(directory: Path, day: str, suffix: str) -> list[Path]:
    exact = directory / f"{day}{suffix}"
    if exact.exists():
        return [exact]
    # Migration and test fixtures sometimes retain a different descriptive suffix.
    return sorted(directory.glob(f"{day}*{suffix}")) if directory.exists() else []


def add_finding(
    inspection: Inspection,
    *,
    severity: str,
    code: str,
    message: str,
    path: Path | None = None,
    line: int | None = None,
    event: dict[str, Any] | None = None,
) -> None:
    inspection.findings.append(
        Finding(
            severity=severity,
            code=code,
            message=message,
            file=str(path) if path else None,
            line=line,
            event_id=str(event.get("id")) if event and event.get("id") is not None else None,
        )
    )


def normalized_metadata(event: dict[str, Any]) -> dict[str, Any]:
    metadata = event.get("metadata")
    return metadata if isinstance(metadata, dict) else {}


def has_semantic_plaintext(event: dict[str, Any]) -> bool:
    metadata = normalized_metadata(event)
    return any(isinstance(metadata.get(key), str) and metadata[key].strip() for key in SEMANTIC_INLINE_KEYS)


def has_detailed_content(event: dict[str, Any]) -> bool:
    detailed_keys = ("window", "url", "pointer", "keyboard", "scroll", "semanticContext")
    if any(event.get(key) not in (None, {}, [], "") for key in detailed_keys):
        return True
    element = event.get("element")
    if isinstance(element, dict):
        exposed = ("title", "label", "identifier")
        if any(element.get(key) not in (None, "") for key in exposed):
            return True
    return has_semantic_plaintext(event)


def inspect_url(
    inspection: Inspection,
    event: dict[str, Any],
    path: Path,
    line: int,
) -> None:
    url = event.get("url")
    if not isinstance(url, dict):
        return
    raw = url.get("value")
    if not isinstance(raw, str) or not raw:
        return
    try:
        parsed = urlsplit(raw)
    except ValueError:
        add_finding(
            inspection,
            severity="warning",
            code="url_parse_failed",
            message="Stored URL could not be parsed.",
            path=path,
            line=line,
            event=event,
        )
        return
    if parsed.username is not None or parsed.password is not None:
        add_finding(
            inspection,
            severity="violation",
            code="url_contains_credentials",
            message=f"Stored URL for host {parsed.hostname or '<unknown>'} contains user-info credentials.",
            path=path,
            line=line,
            event=event,
        )
    if parsed.fragment:
        add_finding(
            inspection,
            severity="warning",
            code="url_contains_fragment",
            message=f"Stored URL for host {parsed.hostname or '<unknown>'} retains a fragment.",
            path=path,
            line=line,
            event=event,
        )
    query_pairs = [(name.lower(), value) for name, value in parse_qsl(parsed.query, keep_blank_values=True)]
    query_names = [name for name, _ in query_pairs]
    sensitive = sorted({
        name
        for name, value in query_pairs
        if name in SENSITIVE_QUERY_NAMES
        and value.strip().lower() not in REDACTION_MARKERS
    })
    if sensitive:
        add_finding(
            inspection,
            severity="violation",
            code="url_sensitive_query_value_present",
            message=(
                f"Stored URL for host {parsed.hostname or '<unknown>'} retains non-redacted value(s) "
                "for sensitive query key(s): "
                + ", ".join(sensitive)
                + ". Values are intentionally omitted from this report."
            ),
            path=path,
            line=line,
            event=event,
        )
    elif query_names and url.get("redactionApplied") is not True:
        add_finding(
            inspection,
            severity="warning",
            code="url_query_not_marked_redacted",
            message=(
                f"Stored URL for host {parsed.hostname or '<unknown>'} contains query parameters "
                "and is not marked as redacted."
            ),
            path=path,
            line=line,
            event=event,
        )


def inspect_typing_event(
    inspection: Inspection,
    event: dict[str, Any],
    path: Path,
    line: int,
) -> None:
    if event.get("kind") != "typingBurst":
        return
    keyboard = event.get("keyboard")
    if isinstance(keyboard, dict) and keyboard.get("key") not in (None, ""):
        add_finding(
            inspection,
            severity="violation",
            code="typing_burst_contains_key",
            message="A typingBurst stores a concrete key value; ordinary text activity must remain count-only.",
            path=path,
            line=line,
            event=event,
        )
    metadata = normalized_metadata(event)
    for key, value in metadata.items():
        lowered = str(key).lower()
        if lowered in RAW_TYPING_KEYS or lowered.endswith("typed_text") or lowered.endswith("raw_text"):
            if value not in (None, "", False, "false"):
                add_finding(
                    inspection,
                    severity="violation",
                    code="typing_burst_contains_text_metadata",
                    message=f"A typingBurst contains forbidden text-like metadata key {key!r}.",
                    path=path,
                    line=line,
                    event=event,
                )
    content_recorded = metadata.get("content_recorded")
    if content_recorded not in (None, False, "false", "False", 0, "0"):
        add_finding(
            inspection,
            severity="violation",
            code="typing_burst_claims_content_recorded",
            message="A typingBurst indicates that content was recorded.",
            path=path,
            line=line,
            event=event,
        )


def update_last_timestamp(inspection: Inspection, key: str, timestamp: datetime | None) -> None:
    if timestamp is None:
        return
    rendered = isoformat(timestamp)
    previous = parse_timestamp(inspection.last_timestamps.get(key))
    if previous is None or timestamp > previous:
        inspection.last_timestamps[key] = rendered


def load_semantic_payloads(inspection: Inspection, files: Iterable[Path]) -> dict[str, dict[str, Any]]:
    payloads: dict[str, dict[str, Any]] = {}
    for path in files:
        inspection.semantic_files.append(str(path))
        for line, value, error in iter_jsonl(path):
            if error or value is None:
                inspection.malformed_semantic_rows += 1
                add_finding(
                    inspection,
                    severity="violation",
                    code="malformed_semantic_row",
                    message=error or "Malformed semantic row.",
                    path=path,
                    line=line,
                )
                continue
            inspection.semantic_payload_count += 1
            payload_id = value.get("id")
            if not isinstance(payload_id, str) or not payload_id:
                add_finding(
                    inspection,
                    severity="violation",
                    code="semantic_payload_missing_id",
                    message="Semantic payload has no stable identifier.",
                    path=path,
                    line=line,
                )
                continue
            if payload_id in payloads:
                add_finding(
                    inspection,
                    severity="violation",
                    code="duplicate_semantic_payload_id",
                    message="Semantic payload identifier is duplicated.",
                    path=path,
                    line=line,
                )
            payloads[payload_id] = value
            text = value.get("text")
            stored_hash = value.get("contentSHA256")
            if not isinstance(text, str) or not text.strip():
                add_finding(
                    inspection,
                    severity="violation",
                    code="semantic_payload_empty_text",
                    message="Semantic payload text is absent or empty.",
                    path=path,
                    line=line,
                )
            else:
                computed = hashlib.sha256(text.encode("utf-8")).hexdigest()
                if stored_hash != computed:
                    add_finding(
                        inspection,
                        severity="violation",
                        code="semantic_payload_hash_mismatch",
                        message="Semantic payload SHA-256 does not match its text.",
                        path=path,
                        line=line,
                    )
            update_last_timestamp(inspection, "semantic_payload", parse_timestamp(value.get("capturedAt")))
    return payloads


def inspect_event(
    inspection: Inspection,
    event: dict[str, Any],
    path: Path,
    line: int,
    semantic_payloads: dict[str, dict[str, Any]],
) -> None:
    kind = event.get("kind")
    if not isinstance(kind, str) or not kind:
        kind = "<missing>"
        add_finding(
            inspection,
            severity="violation",
            code="event_missing_kind",
            message="Event row has no kind.",
            path=path,
            line=line,
            event=event,
        )
    inspection.event_count += 1
    inspection.event_counts[kind] += 1
    timestamp = parse_timestamp(event.get("timestamp"))
    update_last_timestamp(inspection, kind, timestamp)
    update_last_timestamp(inspection, "event", timestamp)

    suppression = event.get("suppressionReason")
    if isinstance(suppression, str) and suppression:
        inspection.suppression_counts[suppression] += 1
        update_last_timestamp(inspection, "suppression", timestamp)
        if has_detailed_content(event):
            add_finding(
                inspection,
                severity="violation",
                code="suppressed_event_contains_details",
                message=f"Suppressed event ({suppression}) retains detailed or semantic content.",
                path=path,
                line=line,
                event=event,
            )

    element = event.get("element")
    secure_element = isinstance(element, dict) and element.get("isSecure") is True
    if secure_element:
        if event.get("semanticContext") not in (None, {}) or has_semantic_plaintext(event):
            add_finding(
                inspection,
                severity="violation",
                code="secure_element_contains_semantic_content",
                message="Secure element is linked to semantic plaintext or a semantic payload.",
                path=path,
                line=line,
                event=event,
            )
        if event.get("kind") in INPUT_EVENT_TYPES and event.get("keyboard") not in (None, {}):
            add_finding(
                inspection,
                severity="violation",
                code="secure_element_contains_keyboard_detail",
                message="Secure element retains keyboard detail.",
                path=path,
                line=line,
                event=event,
            )

    schema = event.get("schemaVersion")
    if isinstance(schema, int) and schema >= 4 and has_semantic_plaintext(event):
        add_finding(
            inspection,
            severity="violation",
            code="modern_event_contains_inline_semantic_plaintext",
            message="Schema-v4 event stores semantic plaintext inline instead of by bounded reference.",
            path=path,
            line=line,
            event=event,
        )

    inspect_typing_event(inspection, event, path, line)
    inspect_url(inspection, event, path, line)

    if kind in INPUT_EVENT_TYPES:
        origin = event.get("inputOrigin")
        assessment = origin.get("assessment") if isinstance(origin, dict) else None
        if assessment == "softwareAttributed":
            inspection.software_attributed_input_count += 1
        elif assessment == "hidLike":
            inspection.hid_like_input_count += 1
        else:
            inspection.unknown_origin_input_count += 1

    reference = event.get("semanticContext")
    if isinstance(reference, dict):
        inspection.semantic_reference_count += 1
        snapshot_id = reference.get("snapshotID")
        payload = semantic_payloads.get(snapshot_id) if isinstance(snapshot_id, str) else None
        if payload is None:
            add_finding(
                inspection,
                severity="violation",
                code="semantic_reference_missing_payload",
                message="Semantic event reference has no matching local payload.",
                path=path,
                line=line,
                event=event,
            )
        else:
            inspection.matched_semantic_reference_count += 1
            computed = hashlib.sha256(str(payload.get("text", "")).encode("utf-8")).hexdigest()
            checks = {
                "snapshotID": payload.get("id"),
                "contentSHA256": computed,
                "characterCount": len(str(payload.get("text", ""))),
            }
            mismatches = [name for name, expected in checks.items() if reference.get(name) != expected]
            if payload.get("contentSHA256") != computed:
                mismatches.append("payload.contentSHA256")
            if mismatches:
                add_finding(
                    inspection,
                    severity="violation",
                    code="semantic_reference_mismatch",
                    message="Semantic reference does not match payload field(s): " + ", ".join(sorted(set(mismatches))),
                    path=path,
                    line=line,
                    event=event,
                )
            payload_app = payload.get("application")
            event_app = event.get("app")
            if isinstance(payload_app, dict) and isinstance(event_app, dict):
                if payload_app.get("processIdentifier") != event_app.get("processIdentifier"):
                    add_finding(
                        inspection,
                        severity="violation",
                        code="semantic_reference_application_mismatch",
                        message="Semantic payload and source event refer to different process identifiers.",
                        path=path,
                        line=line,
                        event=event,
                    )


def inspect(data_root: Path, day: str) -> Inspection:
    inspection = Inspection(data_root=str(data_root), day=day)
    event_files = files_for_day(data_root / "events", day, ".jsonl")
    semantic_files = files_for_day(data_root / "semantic", day, ".semantic.jsonl")
    semantic_payloads = load_semantic_payloads(inspection, semantic_files)

    for path in event_files:
        inspection.event_files.append(str(path))
        for line, value, error in iter_jsonl(path):
            if error or value is None:
                inspection.malformed_event_rows += 1
                add_finding(
                    inspection,
                    severity="violation",
                    code="malformed_event_row",
                    message=error or "Malformed event row.",
                    path=path,
                    line=line,
                )
                continue
            inspect_event(inspection, value, path, line, semantic_payloads)

    if not event_files:
        add_finding(
            inspection,
            severity="warning",
            code="event_file_missing",
            message=f"No event JSONL file was found for {day}.",
        )
    return inspection


def render_human(report: Inspection) -> str:
    lines = [
        f"Goalong History capture inspection — {report.day}",
        f"Data root: {report.data_root}",
        f"Events: {report.event_count}  |  Semantic payloads: {report.semantic_payload_count}",
        "",
        "Event counts:",
    ]
    all_kinds = sorted(set(report.event_counts) | set(EXPECTED_EVENT_TYPES))
    for kind in all_kinds:
        marker = "✓" if report.event_counts[kind] > 0 else "·"
        lines.append(f"  {marker} {kind}: {report.event_counts[kind]}")
    lines.extend(["", "Suppressions:"])
    if report.suppression_counts:
        for reason, count in sorted(report.suppression_counts.items()):
            lines.append(f"  - {reason}: {count}")
    else:
        lines.append("  - none recorded")
    lines.extend(
        [
            "",
            "Input origin signals:",
            f"  - software-attributed: {report.software_attributed_input_count}",
            f"  - HID-like: {report.hid_like_input_count}",
            f"  - unknown: {report.unknown_origin_input_count}",
            "",
            "Semantic integrity:",
            f"  - references: {report.semantic_reference_count}",
            f"  - matched payloads: {report.matched_semantic_reference_count}",
            "",
            f"Privacy findings: {report.violation_count} violation(s), {report.warning_count} warning(s)",
        ]
    )
    if report.findings:
        for finding in report.findings:
            location = ""
            if finding.file:
                location = f" [{finding.file}:{finding.line or '?'}]"
            lines.append(f"  - {finding.severity.upper()} {finding.code}: {finding.message}{location}")
    else:
        lines.append("  - none")
    if report.missing_required_event_types:
        lines.extend(
            [
                "",
                "Missing required observed event types:",
                "  - " + ", ".join(report.missing_required_event_types),
            ]
        )
    else:
        lines.extend(["", "All required observed event types are non-zero."])
    lines.extend(
        [
            "",
            "Limit: recorded observations do not prove identity, attention, productivity, or human authorship.",
        ]
    )
    return "\n".join(lines)


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--data-root",
        type=Path,
        default=Path.home() / "Library" / "Application Support" / "LocalHistory",
        help="Goalong History application-support directory (read-only).",
    )
    parser.add_argument("--day", help="Local day in YYYY-MM-DD; defaults to the newest event file.")
    parser.add_argument("--json", action="store_true", help="Emit machine-readable JSON.")
    parser.add_argument(
        "--require-real-events",
        action="store_true",
        help=(
            "Exit non-zero unless all required event types have counts above zero. "
            "This checks stored observations, not human authorship."
        ),
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv or sys.argv[1:])
    data_root = args.data_root.expanduser().resolve()
    day = args.day or latest_day_from_files(data_root)
    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", day):
        print("--day must use YYYY-MM-DD", file=sys.stderr)
        return 64

    report = inspect(data_root, day)
    if args.json:
        print(json.dumps(report.as_dict(), indent=2, sort_keys=True, ensure_ascii=False))
    else:
        print(render_human(report))

    if report.violation_count > 0:
        return 2
    if args.require_real_events and report.missing_required_event_types:
        return 3
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
