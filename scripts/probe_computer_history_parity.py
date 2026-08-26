#!/usr/bin/env python3
"""Compare bounded Computer History metadata from Codex and Goalong sources.

The probe streams JSONL directly from caller-selected source files or directories.
It never writes an index, snapshot, transcript, or event copy, and its JSON output
contains only fixed labels, counters, timestamps, and explicit coverage issues.

"Within tolerance" describes only the observed aggregate rows in the requested UTC
interval. It is not a claim of exact implementation parity, complete OS capture, user
identity, or human-origin input.
"""

from __future__ import annotations

import argparse
import datetime as dt
import errno
import hashlib
import json
import math
import os
import re
import stat
import sys
from array import array
from collections import Counter
from dataclasses import dataclass, field
from typing import Any, Iterable


UTC = dt.timezone.utc
CATEGORIES = (
    "app",
    "window",
    "focus",
    "click",
    "scroll",
    "shortcut",
    "typing",
    "url",
    "semantic_before",
    "semantic_after",
)
SEVERE_ISSUES = {
    "byte_budget_exhausted",
    "directory_depth_exhausted",
    "directory_entry_budget_exhausted",
    "file_budget_exhausted",
    "inaccessible_source",
    "malformed_json",
    "missing_source",
    "missing_timestamp",
    "oversized_line",
    "read_error",
    "row_budget_exhausted",
    "source_changed_during_read",
    "symlink_rejected",
    "unsupported_source_type",
}

DISCRIMINATOR_PATHS = (
    ("kind",),
    ("type",),
    ("name",),
    ("category",),
    ("actionKind",),
    ("action_kind",),
    ("eventKind",),
    ("event_kind",),
    ("eventType",),
    ("event_type",),
    ("_eventType",),
    ("currentEventType",),
    ("event",),
    ("event", "kind"),
    ("event", "type"),
    ("data", "kind"),
    ("data", "type"),
    ("payload", "kind"),
    ("payload", "type"),
)
TIMESTAMP_PATHS = (
    ("timestamp",),
    ("time",),
    ("ts",),
    ("capturedAt",),
    ("captured_at",),
    ("observedAt",),
    ("observed_at",),
    ("createdAt",),
    ("created_at",),
    ("current_timestamp",),
    ("event", "timestamp"),
    ("data", "timestamp"),
    ("payload", "timestamp"),
)
PHASE_PATHS = (
    ("metadata", "computer_history.interaction_phase"),
    ("metadata", "interaction_phase"),
    ("interactionPhase",),
    ("interaction_phase",),
    ("semanticPhase",),
    ("semantic_phase",),
    ("phase",),
    ("data", "phase"),
    ("payload", "phase"),
)
INTERACTION_ID_PATHS = (
    ("metadata", "computer_history.interaction_id"),
    ("metadata", "interaction_id"),
    ("interactionID",),
    ("interactionId",),
    ("interaction_id",),
    ("data", "interaction_id"),
    ("payload", "interaction_id"),
)

TOKEN_CATEGORIES = {
    "app": {
        "app",
        "appactivated",
        "appchange",
        "appchanged",
        "applicationactivated",
        "application",
        "applicationchange",
        "applicationchanged",
        "applicationswitch",
        "appswitch",
        "foregroundappchanged",
    },
    "window": {
        "focusedwindowchanged",
        "windowactivated",
        "windowchange",
        "windowchanged",
        "windowcreated",
        "windowfocuschanged",
        "window",
    },
    "focus": {
        "controlfocuschanged",
        "elementfocuschanged",
        "focuschange",
        "focuschanged",
        "focusedelementchanged",
        "focus",
    },
    "click": {"click", "mouseclick", "pointerclick", "tap"},
    "scroll": {"mousescroll", "scroll", "scrollburst", "wheelscroll"},
    "shortcut": {"hotkey", "keyboardshortcut", "shortcut"},
    "typing": {
        "keyboardinput",
        "keyboardtextinput",
        "textinput",
        "typing",
        "typingburst",
        "typingevent",
    },
    "url": {
        "addresschanged",
        "navigationchanged",
        "pagechange",
        "pagechanged",
        "urlchange",
        "urlchanged",
        "url",
    },
}
GAP_TOKENS = {
    "accessibilityunavailable",
    "capturegap",
    "capturesuppressed",
    "dropped",
    "droppedevent",
    "observationgap",
    "permissionunavailable",
    "secureinputsuppressed",
}
SEMANTIC_MARKERS = ("semantic", "axtree", "accessibilitytree")
BEFORE_PHASES = {"before", "pre", "preaction", "preinteraction"}
AFTER_PHASES = {
    "after",
    "post",
    "postaction",
    "postinteraction",
    "settled",
    "stable",
}
DAILY_JSONL_NAME = re.compile(
    r"^(\d{4})-(\d{2})-(\d{2})(?:\.semantic)?\.jsonl$"
)
SEGMENT_DIRECTORY_NAME = re.compile(
    r"^(\d{4})-(\d{2})-(\d{2})T(\d{2})-(\d{2})-(\d{2})Z$"
)
MAX_EVENT_SPAN_MILLISECONDS = 60_000
EVENT_START_MILLISECOND_PATHS = (
    ("metadata", "computer_history.input_observed_at_unix_ms"),
    ("metadata", "input_observed_at_unix_ms"),
    ("inputObservedAtUnixMs",),
    ("input_observed_at_unix_ms",),
)
EVENT_DURATION_MILLISECOND_PATHS = (
    ("metadata", "duration_ms"),
    ("durationMilliseconds",),
    ("duration_ms",),
)


class ProbePathError(Exception):
    def __init__(self, issue: str):
        super().__init__(issue)
        self.issue = issue


class StopSource(Exception):
    pass


@dataclass(frozen=True)
class Limits:
    max_bytes: int
    max_rows: int
    max_files: int
    max_line_bytes: int
    max_depth: int
    max_directory_entries: int


@dataclass
class SourceSummary:
    label: str
    bucket_seconds: int
    interval_start_ms: int
    interval_end_ms: int
    input_count: int = 0
    files_opened: int = 0
    directory_entries_seen: int = 0
    dated_entries_skipped: int = 0
    bytes_read: int = 0
    rows_seen: int = 0
    rows_in_interval: int = 0
    rows_outside_interval: int = 0
    target_event_rows: int = 0
    explicit_gap_events: int = 0
    semantic_without_before_after_phase_events: int = 0
    category_counts: Counter[str] = field(default_factory=Counter)
    category_timestamps_ms: dict[str, array[int]] = field(
        default_factory=lambda: {category: array("q") for category in CATEGORIES}
    )
    category_span_starts_ms: dict[str, array[int]] = field(
        default_factory=lambda: {category: array("q") for category in CATEGORIES}
    )
    issues: Counter[str] = field(default_factory=Counter)
    first_timestamp: dt.datetime | None = None
    last_timestamp: dt.datetime | None = None
    semantic_interactions: dict[bytes, int] = field(default_factory=dict)

    def issue(self, code: str) -> None:
        self.issues[code] += 1

    @property
    def read_complete(self) -> bool:
        return not any(self.issues[issue] for issue in SEVERE_ISSUES)

    @property
    def semantic_pair_count(self) -> int:
        return sum(state == 3 for state in self.semantic_interactions.values())

    def observe_timestamp(self, timestamp: dt.datetime) -> None:
        if self.first_timestamp is None or timestamp < self.first_timestamp:
            self.first_timestamp = timestamp
        if self.last_timestamp is None or timestamp > self.last_timestamp:
            self.last_timestamp = timestamp

    def add_category(
        self,
        category: str,
        timestamp: dt.datetime,
        span_start_ms: int,
    ) -> None:
        timestamp_ms = int(timestamp.timestamp() * 1_000)
        self.category_counts[category] += 1
        self.category_timestamps_ms[category].append(timestamp_ms)
        self.category_span_starts_ms[category].append(min(span_start_ms, timestamp_ms))

    def occupied_bucket_intervals_ms(
        self, category: str
    ) -> tuple[array[int], array[int]]:
        bucket_ms = self.bucket_seconds * 1_000
        occupied: dict[int, tuple[int, int]] = {}
        for start_ms, end_ms in zip(
            self.category_span_starts_ms[category],
            self.category_timestamps_ms[category],
        ):
            clipped_start = max(start_ms, self.interval_start_ms)
            clipped_end = min(end_ms, self.interval_end_ms - 1)
            if clipped_end < clipped_start:
                continue
            for bucket in range(
                clipped_start // bucket_ms, clipped_end // bucket_ms + 1
            ):
                bucket_start = max(clipped_start, bucket * bucket_ms)
                bucket_end = min(clipped_end, (bucket + 1) * bucket_ms - 1)
                prior = occupied.get(bucket)
                if prior is None:
                    occupied[bucket] = (bucket_start, bucket_end)
                else:
                    occupied[bucket] = (
                        min(prior[0], bucket_start),
                        max(prior[1], bucket_end),
                    )
        ordered = [occupied[bucket] for bucket in sorted(occupied)]
        return (
            array("q", (interval[0] for interval in ordered)),
            array("q", (interval[1] for interval in ordered)),
        )

    def occupied_bucket_count(self, category: str) -> int:
        starts, _ = self.occupied_bucket_intervals_ms(category)
        return len(starts)

    def output(self) -> dict[str, Any]:
        return {
            "read_complete_within_probe_bounds": self.read_complete,
            "input_count": self.input_count,
            "files_opened": self.files_opened,
            "directory_entries_seen": self.directory_entries_seen,
            "dated_entries_skipped": self.dated_entries_skipped,
            "bytes_read": self.bytes_read,
            "rows_seen": self.rows_seen,
            "rows_in_interval": self.rows_in_interval,
            "rows_outside_interval": self.rows_outside_interval,
            "target_event_rows": self.target_event_rows,
            "first_observed_utc": format_timestamp(self.first_timestamp),
            "last_observed_utc": format_timestamp(self.last_timestamp),
            "explicit_gap_events": self.explicit_gap_events,
            "semantic_without_before_after_phase_events": (
                self.semantic_without_before_after_phase_events
            ),
            "semantic_pair_count": self.semantic_pair_count,
            "categories": {
                category: {
                    "event_count": self.category_counts[category],
                    "occupied_time_buckets": self.occupied_bucket_count(category),
                }
                for category in CATEGORIES
            },
            "issues": dict(sorted(self.issues.items())),
        }


def nested_value(payload: Any, path: tuple[str, ...]) -> Any:
    current = payload
    for key in path:
        if not isinstance(current, dict) or key not in current:
            return None
        current = current[key]
    return current


def normalized_token(value: Any) -> str | None:
    if not isinstance(value, str) or not value or len(value) > 160:
        return None
    token = re.sub(r"[^a-z0-9]+", "", value.casefold())
    return token or None


def discriminator_tokens(payload: dict[str, Any]) -> set[str]:
    tokens: set[str] = set()
    for path in DISCRIMINATOR_PATHS:
        token = normalized_token(nested_value(payload, path))
        if token:
            tokens.add(token)
    return tokens


def parse_timestamp(value: Any) -> dt.datetime | None:
    if isinstance(value, dict):
        seconds = value.get("seconds")
        nanoseconds = value.get("nanos", value.get("nanoseconds", 0))
        try:
            seconds_value = float(seconds)
            nanoseconds_value = float(nanoseconds)
        except (TypeError, ValueError):
            return None
        if not math.isfinite(seconds_value) or not math.isfinite(nanoseconds_value):
            return None
        try:
            return dt.datetime.fromtimestamp(
                seconds_value + nanoseconds_value / 1_000_000_000,
                tz=UTC,
            )
        except (OverflowError, OSError, ValueError):
            return None
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)) and math.isfinite(value):
        seconds = float(value)
        if abs(seconds) >= 100_000_000_000:
            seconds /= 1_000
        try:
            return dt.datetime.fromtimestamp(seconds, tz=UTC)
        except (OverflowError, OSError, ValueError):
            return None
    if not isinstance(value, str) or len(value) > 80:
        return None
    candidate = value.strip()
    if candidate.endswith("Z"):
        candidate = candidate[:-1] + "+00:00"
    try:
        parsed = dt.datetime.fromisoformat(candidate)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        return None
    return parsed.astimezone(UTC)


def event_timestamp(payload: dict[str, Any]) -> dt.datetime | None:
    for path in TIMESTAMP_PATHS:
        parsed = parse_timestamp(nested_value(payload, path))
        if parsed is not None:
            return parsed
    return None


def parse_utc_argument(value: str) -> dt.datetime | None:
    candidate = value.strip()
    if candidate.endswith("Z"):
        candidate = candidate[:-1] + "+00:00"
    try:
        parsed = dt.datetime.fromisoformat(candidate)
    except ValueError:
        return None
    if parsed.tzinfo is None or parsed.utcoffset() != dt.timedelta(0):
        return None
    return parsed.astimezone(UTC)


def event_phase(payload: dict[str, Any], tokens: set[str]) -> str | None:
    semantic_before = nested_value(payload, ("semantic", "before"))
    semantic_after = nested_value(payload, ("semantic", "after"))
    if semantic_before is not None and semantic_after is not None:
        return "both"
    for path in PHASE_PATHS:
        phase = normalized_token(nested_value(payload, path))
        if phase in BEFORE_PHASES:
            return "before"
        if phase in AFTER_PHASES:
            return "after"
    if any("before" in token or token.startswith("presemantic") for token in tokens):
        return "before"
    if any(
        "after" in token or "settled" in token or token.startswith("postsemantic")
        for token in tokens
    ):
        return "after"
    return None


def event_interaction_digest(payload: dict[str, Any]) -> bytes | None:
    for path in INTERACTION_ID_PATHS:
        value = nested_value(payload, path)
        if isinstance(value, (str, int)) and not isinstance(value, bool):
            encoded = str(value).encode("utf-8", errors="replace")
            if encoded and len(encoded) <= 512:
                return hashlib.blake2s(encoded, digest_size=16).digest()
    return None


def bounded_millisecond_value(value: Any) -> int | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, str):
        if not value or len(value) > 32:
            return None
        try:
            parsed = float(value)
        except ValueError:
            return None
    elif isinstance(value, (int, float)):
        parsed = float(value)
    else:
        return None
    if not math.isfinite(parsed) or parsed < 0 or parsed > 100_000_000_000_000:
        return None
    return int(parsed)


def event_span_start_ms(payload: dict[str, Any], timestamp: dt.datetime) -> int:
    """Return a bounded metadata-only start for a coalesced interaction row."""

    timestamp_ms = int(timestamp.timestamp() * 1_000)
    for path in EVENT_START_MILLISECOND_PATHS:
        candidate = bounded_millisecond_value(nested_value(payload, path))
        if candidate is None:
            continue
        if 0 <= timestamp_ms - candidate <= MAX_EVENT_SPAN_MILLISECONDS:
            return candidate
    for path in EVENT_DURATION_MILLISECOND_PATHS:
        duration = bounded_millisecond_value(nested_value(payload, path))
        if duration is not None:
            return timestamp_ms - min(duration, MAX_EVENT_SPAN_MILLISECONDS)
    return timestamp_ms


def is_semantic(tokens: set[str]) -> bool:
    return any(marker in token for token in tokens for marker in SEMANTIC_MARKERS)


def classified_categories(
    payload: dict[str, Any], tokens: set[str]
) -> tuple[set[str], str | None]:
    categories = {
        category
        for category, known_tokens in TOKEN_CATEGORIES.items()
        if tokens.intersection(known_tokens)
    }
    phase: str | None = None
    if is_semantic(tokens):
        phase = event_phase(payload, tokens)
        if phase in ("before", "both"):
            categories.add("semantic_before")
        if phase in ("after", "both"):
            categories.add("semantic_after")

    # Codex model-facing rows can carry a broad input event type plus a narrow
    # structured field. Only fixed key presence is considered; values are never
    # retained or emitted.
    if nested_value(payload, ("keyboardShortcut",)) is not None:
        categories.add("shortcut")
    structured_keyboard = nested_value(payload, ("keyboard",))
    if "keyboardshortcut" in tokens and isinstance(structured_keyboard, dict):
        modifiers = structured_keyboard.get("modifiers")
        normalized_modifiers = {
            token
            for value in (modifiers if isinstance(modifiers, list) else [])
            if (token := normalized_token(value)) is not None
        }
        if not normalized_modifiers.intersection({"command", "control"}):
            # Codex labels editing/navigation keys (for example Delete or
            # Option-Delete) as keyboardShortcut. Goalong deliberately keeps
            # those as keyPressed and reserves shortcut for Command/Control
            # chords, so omit the broader provider label from this category.
            categories.discard("shortcut")
    if nested_value(payload, ("scroll",)) is not None:
        categories.add("scroll")
    if tokens.intersection({"mouse", "pointer"}) and any(
        nested_value(payload, path) is not None
        for path in (("mouseButton",), ("clickCount",), ("pointer",))
    ):
        categories.add("click")
    if tokens.intersection({"keyboard", "input"}) and any(
        nested_value(payload, path) is not None
        for path in (("typedText",), ("textInput",), ("keystrokeCount",))
    ):
        categories.add("typing")
    return categories, phase


def format_timestamp(value: dt.datetime | None) -> str | None:
    if value is None:
        return None
    return value.astimezone(UTC).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def issue_for_os_error(error: OSError) -> str:
    if error.errno in (errno.ENOENT, errno.ENOTDIR):
        return "missing_source"
    if error.errno in (errno.EACCES, errno.EPERM):
        return "inaccessible_source"
    if error.errno == errno.ELOOP:
        return "symlink_rejected"
    return "read_error"


def absolute_components(path: str) -> list[str]:
    absolute = os.path.abspath(path)
    return [component for component in absolute.split(os.sep) if component]


def open_root_no_follow(path: str) -> tuple[int, bool]:
    """Open every path component without following symlinks."""

    components = absolute_components(path)
    if not components:
        raise ProbePathError("unsupported_source_type")
    no_follow = getattr(os, "O_NOFOLLOW", 0)
    directory_flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | no_follow
    directory_fd = os.open(os.sep, directory_flags)
    try:
        for component in components[:-1]:
            metadata = os.stat(component, dir_fd=directory_fd, follow_symlinks=False)
            if stat.S_ISLNK(metadata.st_mode):
                raise ProbePathError("symlink_rejected")
            if not stat.S_ISDIR(metadata.st_mode):
                raise ProbePathError("unsupported_source_type")
            next_fd = os.open(component, directory_flags, dir_fd=directory_fd)
            os.close(directory_fd)
            directory_fd = next_fd

        name = components[-1]
        metadata = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
        if stat.S_ISLNK(metadata.st_mode):
            raise ProbePathError("symlink_rejected")
        is_directory = stat.S_ISDIR(metadata.st_mode)
        if not is_directory and not stat.S_ISREG(metadata.st_mode):
            raise ProbePathError("unsupported_source_type")
        flags = directory_flags if is_directory else os.O_RDONLY | no_follow
        result_fd = os.open(name, flags, dir_fd=directory_fd)
        opened = os.fstat(result_fd)
        expected_type = stat.S_ISDIR if is_directory else stat.S_ISREG
        if not expected_type(opened.st_mode):
            os.close(result_fd)
            raise ProbePathError("unsupported_source_type")
        return result_fd, is_directory
    except OSError as error:
        raise ProbePathError(issue_for_os_error(error)) from error
    finally:
        os.close(directory_fd)


def segment_directory_start(name: str) -> dt.datetime | None:
    match = SEGMENT_DIRECTORY_NAME.fullmatch(name)
    if match is None:
        return None
    try:
        return dt.datetime(*(int(value) for value in match.groups()), tzinfo=UTC)
    except ValueError:
        return None


def relevant_segment_directory_names(
    entries: list[tuple[str, os.stat_result]],
    start: dt.datetime,
    end: dt.datetime,
) -> set[str]:
    """Keep the segment covering the start plus every segment begun in-range."""

    segments = [
        (segment_start, name)
        for name, metadata in entries
        if stat.S_ISDIR(metadata.st_mode)
        if (segment_start := segment_directory_start(name)) is not None
    ]
    relevant = {name for segment_start, name in segments if start <= segment_start < end}
    predecessors = [item for item in segments if item[0] <= start]
    if predecessors:
        relevant.add(max(predecessors)[1])
    return relevant


def dated_file_is_relevant(
    name: str,
    start: dt.datetime,
    end: dt.datetime,
) -> bool:
    """Prune only canonical dated Goalong daily journals.

    Explicit file or segment paths are still read because this filter is applied only
    to children discovered below a caller-selected directory. Unrecognized names stay
    eligible, so the optimization cannot silently exclude another provider layout.
    """

    match = DAILY_JSONL_NAME.fullmatch(name)
    if match is None:
        return True
    try:
        file_day = dt.date(*(int(value) for value in match.groups()))
    except ValueError:
        return True

    final_instant = end - dt.timedelta(microseconds=1)
    relevant_days = {
        start.date(),
        final_instant.date(),
        start.astimezone().date(),
        final_instant.astimezone().date(),
    }
    return file_day in relevant_days


def process_payload(
    payload: Any,
    summary: SourceSummary,
    start: dt.datetime,
    end: dt.datetime,
) -> None:
    if not isinstance(payload, dict):
        summary.issue("malformed_json")
        return
    timestamp = event_timestamp(payload)
    if timestamp is None:
        summary.issue("missing_timestamp")
        return
    if timestamp < start or timestamp >= end:
        summary.rows_outside_interval += 1
        return

    summary.rows_in_interval += 1
    summary.observe_timestamp(timestamp)
    tokens = discriminator_tokens(payload)
    metadata = payload.get("metadata")
    observation_gap = (
        isinstance(metadata, dict)
        and str(metadata.get("observation_gap", "")).lower() == "true"
    )
    if (
        tokens.intersection(GAP_TOKENS)
        or payload.get("suppressionReason") is not None
        or observation_gap
    ):
        summary.explicit_gap_events += 1

    categories, semantic_phase = classified_categories(payload, tokens)
    if is_semantic(tokens) and semantic_phase is None:
        summary.semantic_without_before_after_phase_events += 1
    if not categories:
        return
    summary.target_event_rows += 1
    span_start_ms = event_span_start_ms(payload, timestamp)
    for category in categories:
        summary.add_category(category, timestamp, span_start_ms)

    if semantic_phase is not None:
        interaction_digest = event_interaction_digest(payload)
        if interaction_digest is not None:
            prior = summary.semantic_interactions.get(interaction_digest, 0)
            phase_bit = {"before": 1, "after": 2, "both": 3}[semantic_phase]
            summary.semantic_interactions[interaction_digest] = prior | phase_bit


def process_line(
    raw_line: bytes,
    summary: SourceSummary,
    limits: Limits,
    start: dt.datetime,
    end: dt.datetime,
) -> None:
    stripped = raw_line.strip()
    if not stripped:
        return
    if summary.rows_seen >= limits.max_rows:
        summary.issue("row_budget_exhausted")
        raise StopSource
    summary.rows_seen += 1
    try:
        payload = json.loads(stripped)
    except (json.JSONDecodeError, UnicodeDecodeError):
        summary.issue("malformed_json")
        return
    process_payload(payload, summary, start, end)


def prefix_fingerprint(file_fd: int, byte_count: int) -> bytes | None:
    """Hash one pinned prefix without changing the descriptor's stream offset."""

    if byte_count < 0:
        return None
    digest = hashlib.sha256()
    offset = 0
    while offset < byte_count:
        try:
            chunk = os.pread(file_fd, min(65_536, byte_count - offset), offset)
        except OSError:
            return None
        if not chunk:
            return None
        digest.update(chunk)
        offset += len(chunk)
    return digest.digest()


def stream_file(
    file_fd: int,
    summary: SourceSummary,
    limits: Limits,
    start: dt.datetime,
    end: dt.datetime,
) -> None:
    summary.files_opened += 1
    try:
        initial_metadata = os.fstat(file_fd)
    except OSError as error:
        summary.issue(issue_for_os_error(error))
        return
    initial_size = initial_metadata.st_size
    initial_mtime_ns = initial_metadata.st_mtime_ns
    initial_device = initial_metadata.st_dev
    initial_inode = initial_metadata.st_ino
    file_bytes_read = 0
    streamed_prefix = hashlib.sha256()
    buffer = bytearray()
    discarding_oversized = False
    try:
        while file_bytes_read < initial_size:
            remaining = limits.max_bytes - summary.bytes_read
            if remaining <= 0:
                summary.issue("byte_budget_exhausted")
                raise StopSource
            try:
                chunk = os.read(
                    file_fd,
                    min(65_536, remaining, initial_size - file_bytes_read),
                )
            except OSError as error:
                summary.issue(issue_for_os_error(error))
                return
            if not chunk:
                summary.issue("source_changed_during_read")
                break
            file_bytes_read += len(chunk)
            summary.bytes_read += len(chunk)
            streamed_prefix.update(chunk)

            for byte in chunk:
                if byte == 0x0A:
                    if discarding_oversized:
                        summary.issue("oversized_line")
                        discarding_oversized = False
                        buffer.clear()
                    else:
                        process_line(bytes(buffer), summary, limits, start, end)
                        buffer.clear()
                elif not discarding_oversized:
                    if len(buffer) >= limits.max_line_bytes:
                        discarding_oversized = True
                        buffer.clear()
                    else:
                        buffer.append(byte)

        if discarding_oversized:
            summary.issue("oversized_line")
        elif buffer:
            process_line(bytes(buffer), summary, limits, start, end)
    finally:
        try:
            final_metadata = os.fstat(file_fd)
            exact_snapshot = (
                final_metadata.st_dev == initial_device
                and final_metadata.st_ino == initial_inode
                and final_metadata.st_size == initial_size
                and final_metadata.st_mtime_ns == initial_mtime_ns
            )
            verified_append_only_growth = (
                file_bytes_read == initial_size
                and final_metadata.st_dev == initial_device
                and final_metadata.st_ino == initial_inode
                and final_metadata.st_size >= initial_size
                and prefix_fingerprint(file_fd, initial_size)
                == streamed_prefix.digest()
            )
            if not exact_snapshot and not verified_append_only_growth:
                summary.issue("source_changed_during_read")
        except OSError as error:
            summary.issue(issue_for_os_error(error))


def walk_directory(
    directory_fd: int,
    summary: SourceSummary,
    limits: Limits,
    start: dt.datetime,
    end: dt.datetime,
    depth: int = 0,
) -> None:
    if depth > limits.max_depth:
        summary.issue("directory_depth_exhausted")
        raise StopSource
    no_follow = getattr(os, "O_NOFOLLOW", 0)
    directory_flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | no_follow
    scan_fd = os.dup(directory_fd)
    try:
        discovered: list[tuple[str, os.stat_result]] = []
        with os.scandir(scan_fd) as entries:
            for entry in entries:
                summary.directory_entries_seen += 1
                if summary.directory_entries_seen > limits.max_directory_entries:
                    summary.issue("directory_entry_budget_exhausted")
                    raise StopSource
                name = entry.name
                try:
                    metadata = entry.stat(follow_symlinks=False)
                except OSError as error:
                    summary.issue(issue_for_os_error(error))
                    continue
                discovered.append((entry.name, metadata))

        discovered.sort(key=lambda item: item[0])
        relevant_segments = relevant_segment_directory_names(discovered, start, end)
        for name, metadata in discovered:
            if stat.S_ISLNK(metadata.st_mode):
                summary.issue("symlink_rejected")
                continue
            if stat.S_ISDIR(metadata.st_mode):
                if (
                    segment_directory_start(name) is not None
                    and name not in relevant_segments
                ):
                    summary.dated_entries_skipped += 1
                    continue
                try:
                    child_fd = os.open(name, directory_flags, dir_fd=directory_fd)
                except OSError as error:
                    summary.issue(issue_for_os_error(error))
                    continue
                try:
                    walk_directory(child_fd, summary, limits, start, end, depth + 1)
                finally:
                    os.close(child_fd)
                continue
            if not stat.S_ISREG(metadata.st_mode) or not name.casefold().endswith(".jsonl"):
                continue
            if not dated_file_is_relevant(name, start, end):
                summary.dated_entries_skipped += 1
                continue
            if summary.files_opened >= limits.max_files:
                summary.issue("file_budget_exhausted")
                raise StopSource
            try:
                file_fd = os.open(name, os.O_RDONLY | no_follow, dir_fd=directory_fd)
            except OSError as error:
                summary.issue(issue_for_os_error(error))
                continue
            try:
                opened = os.fstat(file_fd)
                if not stat.S_ISREG(opened.st_mode):
                    summary.issue("unsupported_source_type")
                    continue
                stream_file(file_fd, summary, limits, start, end)
            finally:
                os.close(file_fd)
    except OSError as error:
        summary.issue(issue_for_os_error(error))
    finally:
        try:
            os.close(scan_fd)
        except OSError:
            # `scandir` owns and may already have closed the duplicated descriptor.
            pass


def read_source(
    label: str,
    paths: Iterable[str],
    limits: Limits,
    bucket_seconds: int,
    start: dt.datetime,
    end: dt.datetime,
) -> SourceSummary:
    summary = SourceSummary(
        label=label,
        bucket_seconds=bucket_seconds,
        interval_start_ms=int(start.timestamp() * 1_000),
        interval_end_ms=int(end.timestamp() * 1_000),
    )
    for path in paths:
        summary.input_count += 1
        if summary.files_opened >= limits.max_files:
            summary.issue("file_budget_exhausted")
            break
        try:
            root_fd, is_directory = open_root_no_follow(path)
        except ProbePathError as error:
            summary.issue(error.issue)
            continue
        try:
            if is_directory:
                walk_directory(root_fd, summary, limits, start, end)
            else:
                stream_file(root_fd, summary, limits, start, end)
        except StopSource:
            break
        finally:
            os.close(root_fd)
    return summary


def timestamp_match_count(
    left: array[int], right: array[int], tolerance_ms: int
) -> int:
    """Return the maximum ordered one-to-one matches within the time tolerance."""

    ordered_left = sorted(left)
    ordered_right = sorted(right)
    left_index = 0
    right_index = 0
    matched = 0
    while left_index < len(ordered_left) and right_index < len(ordered_right):
        left_timestamp = ordered_left[left_index]
        right_timestamp = ordered_right[right_index]
        if right_timestamp < left_timestamp - tolerance_ms:
            right_index += 1
        elif left_timestamp < right_timestamp - tolerance_ms:
            left_index += 1
        else:
            matched += 1
            left_index += 1
            right_index += 1
    return matched


def interval_match_count(
    left_starts: array[int],
    left_ends: array[int],
    right_starts: array[int],
    right_ends: array[int],
    tolerance_ms: int,
) -> int:
    """Return maximum ordered one-to-one interval matches within tolerance."""

    left_index = 0
    right_index = 0
    matched = 0
    while left_index < len(left_starts) and right_index < len(right_starts):
        left_start = left_starts[left_index]
        left_end = left_ends[left_index]
        right_start = right_starts[right_index]
        right_end = right_ends[right_index]
        if right_end < left_start - tolerance_ms:
            right_index += 1
        elif left_end < right_start - tolerance_ms:
            left_index += 1
        else:
            matched += 1
            left_index += 1
            right_index += 1
    return matched


def timestamp_match_ratio(event_count: int, matched_count: int, other_count: int) -> float:
    if event_count == 0:
        return 1.0 if other_count == 0 else 0.0
    return matched_count / event_count


def compare_sources(
    codex: SourceSummary,
    goalong: SourceSummary,
    absolute_count_tolerance: int,
    relative_count_tolerance: float,
    time_tolerance_seconds: int,
    minimum_time_match_ratio: float,
) -> tuple[str, dict[str, Any]]:
    tolerance_ms = time_tolerance_seconds * 1_000
    comparisons: dict[str, Any] = {}
    codex_observed = False
    has_additional_goalong_evidence = False
    missing_goalong_evidence = False
    for category in CATEGORIES:
        codex_count = codex.category_counts[category]
        goalong_count = goalong.category_counts[category]
        raw_paired_event_count = timestamp_match_count(
            codex.category_timestamps_ms[category],
            goalong.category_timestamps_ms[category],
            tolerance_ms,
        )
        codex_raw_match = timestamp_match_ratio(
            codex_count, raw_paired_event_count, goalong_count
        )
        goalong_raw_match = timestamp_match_ratio(
            goalong_count, raw_paired_event_count, codex_count
        )

        codex_bucket_starts, codex_bucket_ends = codex.occupied_bucket_intervals_ms(
            category
        )
        goalong_bucket_starts, goalong_bucket_ends = (
            goalong.occupied_bucket_intervals_ms(category)
        )
        codex_bucket_count = len(codex_bucket_starts)
        goalong_bucket_count = len(goalong_bucket_starts)
        maximum_bucket_count = max(codex_bucket_count, goalong_bucket_count)
        allowed_bucket_delta = max(
            absolute_count_tolerance,
            math.ceil(maximum_bucket_count * relative_count_tolerance),
        )
        directional_bucket_delta = goalong_bucket_count - codex_bucket_count
        bucket_delta = abs(directional_bucket_delta)
        paired_bucket_count = interval_match_count(
            codex_bucket_starts,
            codex_bucket_ends,
            goalong_bucket_starts,
            goalong_bucket_ends,
            tolerance_ms,
        )
        codex_match = timestamp_match_ratio(
            codex_bucket_count, paired_bucket_count, goalong_bucket_count
        )
        goalong_match = timestamp_match_ratio(
            goalong_bucket_count, paired_bucket_count, codex_bucket_count
        )

        if maximum_bucket_count == 0:
            status = "not_observed"
        elif codex_bucket_count == 0:
            status = "additional_goalong_evidence"
            has_additional_goalong_evidence = True
        else:
            codex_observed = True
            within = (
                bucket_delta <= allowed_bucket_delta
                and codex_match >= minimum_time_match_ratio
                and goalong_match >= minimum_time_match_ratio
            )
            if within:
                status = "within_tolerance"
            elif (
                goalong_bucket_count >= codex_bucket_count
                and codex_match >= minimum_time_match_ratio
            ):
                status = "goalong_additional_evidence"
                has_additional_goalong_evidence = True
            else:
                status = "missing_or_unmatched_goalong_evidence"
                missing_goalong_evidence = True
        comparisons[category] = {
            "status": status,
            "evaluation_unit": "occupied_time_bucket",
            "codex_event_count": codex_count,
            "goalong_event_count": goalong_count,
            "paired_raw_event_count": raw_paired_event_count,
            "codex_raw_event_time_match_ratio": round(codex_raw_match, 6),
            "goalong_raw_event_time_match_ratio": round(goalong_raw_match, 6),
            "codex_occupied_buckets": codex_bucket_count,
            "goalong_occupied_buckets": goalong_bucket_count,
            "occupied_bucket_count_delta": bucket_delta,
            "goalong_minus_codex_occupied_buckets": directional_bucket_delta,
            "allowed_occupied_bucket_delta": allowed_bucket_delta,
            "paired_time_bucket_count": paired_bucket_count,
            "codex_time_match_ratio": round(codex_match, 6),
            "goalong_time_match_ratio": round(goalong_match, 6),
        }

    insufficient = (
        not codex.read_complete
        or not goalong.read_complete
        or codex.explicit_gap_events > 0
        or goalong.explicit_gap_events > 0
        or not codex_observed
    )
    if insufficient:
        overall = "insufficient_coverage"
    elif missing_goalong_evidence:
        overall = "codex_evidence_missing_in_goalong"
    elif has_additional_goalong_evidence:
        overall = "goalong_at_least_codex"
    else:
        overall = "observed_within_tolerance"
    return overall, comparisons


def positive_int(value: str) -> int:
    parsed = int(value)
    if parsed <= 0:
        raise argparse.ArgumentTypeError("must be greater than zero")
    return parsed


def ratio(value: str) -> float:
    parsed = float(value)
    if not 0 <= parsed <= 1:
        raise argparse.ArgumentTypeError("must be between zero and one")
    return parsed


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Read-only metadata parity probe for a controlled UTC interval."
    )
    parser.add_argument("--codex", action="append", required=True, metavar="PATH")
    parser.add_argument("--goalong", action="append", required=True, metavar="PATH")
    parser.add_argument("--start-utc", required=True, metavar="ISO-8601")
    parser.add_argument("--end-utc", required=True, metavar="ISO-8601")
    parser.add_argument("--bucket-seconds", type=positive_int, default=2)
    parser.add_argument("--time-tolerance-seconds", type=positive_int, default=3)
    parser.add_argument("--absolute-count-tolerance", type=positive_int, default=1)
    parser.add_argument("--relative-count-tolerance", type=ratio, default=0.25)
    parser.add_argument("--minimum-time-match-ratio", type=ratio, default=0.8)
    parser.add_argument("--max-duration-seconds", type=positive_int, default=21_600)
    parser.add_argument("--max-bytes-per-source", type=positive_int, default=64 * 1_024 * 1_024)
    parser.add_argument("--max-rows-per-source", type=positive_int, default=200_000)
    parser.add_argument("--max-files-per-source", type=positive_int, default=256)
    parser.add_argument("--max-line-bytes", type=positive_int, default=1 * 1_024 * 1_024)
    parser.add_argument("--max-directory-depth", type=positive_int, default=8)
    parser.add_argument("--max-directory-entries-per-source", type=positive_int, default=4_096)
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    start = parse_utc_argument(args.start_utc)
    end = parse_utc_argument(args.end_utc)
    if start is None or end is None:
        print("start/end must be explicit UTC ISO-8601 timestamps", file=sys.stderr)
        return 64
    if end <= start:
        print("end must be later than start", file=sys.stderr)
        return 64
    if (end - start).total_seconds() > args.max_duration_seconds:
        print("requested interval exceeds the configured duration bound", file=sys.stderr)
        return 64

    limits = Limits(
        max_bytes=args.max_bytes_per_source,
        max_rows=args.max_rows_per_source,
        max_files=args.max_files_per_source,
        max_line_bytes=args.max_line_bytes,
        max_depth=args.max_directory_depth,
        max_directory_entries=args.max_directory_entries_per_source,
    )
    codex = read_source(
        "codex", args.codex, limits, args.bucket_seconds, start, end
    )
    goalong = read_source(
        "goalong", args.goalong, limits, args.bucket_seconds, start, end
    )
    overall, comparisons = compare_sources(
        codex,
        goalong,
        args.absolute_count_tolerance,
        args.relative_count_tolerance,
        args.time_tolerance_seconds,
        args.minimum_time_match_ratio,
    )
    report = {
        "schema_version": 3,
        "result": overall,
        "scope": {
            "start_utc": format_timestamp(start),
            "end_utc_exclusive": format_timestamp(end),
            "interval_seconds": int((end - start).total_seconds()),
            "physical_input_required_for_live_claim": True,
        },
        "safety": {
            "read_only": True,
            "metadata_only_output": True,
            "writes_performed": False,
            "source_paths_emitted": False,
            "content_or_snapshots_emitted": False,
            "index_created": False,
        },
        "bounds": {
            "max_bytes_per_source": limits.max_bytes,
            "max_rows_per_source": limits.max_rows,
            "max_files_per_source": limits.max_files,
            "max_line_bytes": limits.max_line_bytes,
            "max_directory_depth": limits.max_depth,
            "max_directory_entries_per_source": limits.max_directory_entries,
            "max_duration_seconds": args.max_duration_seconds,
        },
        "tolerance": {
            "bucket_seconds": args.bucket_seconds,
            "time_tolerance_seconds": args.time_tolerance_seconds,
            "absolute_count_tolerance": args.absolute_count_tolerance,
            "relative_count_tolerance": args.relative_count_tolerance,
            "timestamp_resolution_milliseconds": 1,
            "comparison_unit": "occupied_time_bucket",
            "maximum_coalesced_event_span_milliseconds": MAX_EVENT_SPAN_MILLISECONDS,
            "minimum_codex_coverage_time_match_ratio": args.minimum_time_match_ratio,
        },
        "sources": {"codex": codex.output(), "goalong": goalong.output()},
        "comparison": comparisons,
        "limitations": [
            "read_complete_within_probe_bounds describes source-file reads, not complete "
            "operating-system capture",
            "observed_within_tolerance is not exact parity or private implementation equivalence",
            "goalong_at_least_codex means every classified Codex category met the one-way "
            "coverage threshold while Goalong retained additional classified evidence; it is "
            "not proof that every additional event is useful",
            "silence is not inferred to be a capture gap; only explicit gap events and "
            "read issues are counted",
            "semantic_after includes explicit after or settled semantic phases",
            "category status compares bounded occupied time buckets, including numeric "
            "coalesced-event spans; raw row counts remain informational because providers "
            "use different event granularities",
            "live evidence is valid only for a controlled sequence performed through physical "
            "user input",
        ],
    }
    print(json.dumps(report, sort_keys=True, separators=(",", ":")))
    if overall in ("observed_within_tolerance", "goalong_at_least_codex"):
        return 0
    if overall == "codex_evidence_missing_in_goalong":
        return 1
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
