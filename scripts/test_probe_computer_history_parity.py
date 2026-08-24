#!/usr/bin/env python3
from __future__ import annotations

import datetime as dt
import json
import os
import pathlib
import stat
import subprocess
import tempfile
import unittest


REPO = pathlib.Path(__file__).resolve().parent.parent
PROBE = REPO / "scripts" / "probe_computer_history_parity.py"
ANSWER_CHECKER = REPO / "scripts" / "check_computer_history_answer.py"
VALIDATOR = REPO / "scripts" / "validate_computer_history_parity.sh"
START = "2026-08-24T10:00:00Z"
END = "2026-08-24T10:01:00Z"
SENSITIVE = "DO-NOT-EMIT-sensitive.example/private-transcript-body"


def event(timestamp: str, kind: str, **values: object) -> dict[str, object]:
    payload: dict[str, object] = {"timestamp": timestamp, "kind": kind}
    payload.update(values)
    return payload


class ComputerHistoryParityProbeTests(unittest.TestCase):
    def setUp(self) -> None:
        # macOS spells its temporary directory through `/var`, which is itself a
        # symlink. Use the canonical parent so the no-follow reader is testing only
        # fixture symlinks, not that operating-system alias.
        temporary_parent = pathlib.Path(tempfile.gettempdir()).resolve()
        self.temporary = tempfile.TemporaryDirectory(
            prefix="goalong-parity-probe-", dir=temporary_parent
        )
        self.root = pathlib.Path(self.temporary.name)
        self.codex = self.root / "codex.jsonl"
        self.goalong = self.root / "goalong.jsonl"

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def write_rows(self, path: pathlib.Path, rows: list[object]) -> None:
        path.write_text(
            "".join(
                row + "\n" if isinstance(row, str) else json.dumps(row) + "\n"
                for row in rows
            ),
            encoding="utf-8",
        )

    def run_probe(
        self,
        codex: pathlib.Path | None = None,
        goalong: pathlib.Path | None = None,
        *extra: str,
    ) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                "python3",
                str(PROBE),
                "--codex",
                str(codex or self.codex),
                "--goalong",
                str(goalong or self.goalong),
                "--start-utc",
                START,
                "--end-utc",
                END,
                *extra,
            ],
            check=False,
            capture_output=True,
            text=True,
        )

    def matching_fixture(self) -> tuple[list[object], list[object]]:
        codex_rows = [
            event("2026-08-24T10:00:01Z", "application_switch", app=SENSITIVE),
            event("2026-08-24T10:00:02Z", "window_changed", title=SENSITIVE),
            event("2026-08-24T10:00:03Z", "focused_element_changed", label=SENSITIVE),
            event("2026-08-24T10:00:04Z", "mouse_click", target=SENSITIVE),
            event("2026-08-24T10:00:05Z", "scroll", text=SENSITIVE),
            event("2026-08-24T10:00:06Z", "keyboard_shortcut", key=SENSITIVE),
            event("2026-08-24T10:00:07Z", "text_input", typedText=SENSITIVE),
            event("2026-08-24T10:00:08Z", "url_changed", url=SENSITIVE),
            event(
                "2026-08-24T10:00:09Z",
                "semantic_snapshot",
                phase="before",
                interaction_id=SENSITIVE,
                body=SENSITIVE,
            ),
            event(
                "2026-08-24T10:00:11Z",
                "semantic_snapshot",
                phase="after",
                interaction_id=SENSITIVE,
                body=SENSITIVE,
            ),
        ]
        goalong_rows = [
            event("2026-08-24T10:00:01.400Z", "applicationActivated", app={"name": SENSITIVE}),
            event("2026-08-24T10:00:02.400Z", "windowChanged", window={"title": SENSITIVE}),
            event("2026-08-24T10:00:03.400Z", "focusChanged", element={"label": SENSITIVE}),
            event("2026-08-24T10:00:04.400Z", "mouseClick", pointer={"button": SENSITIVE}),
            event("2026-08-24T10:00:05.400Z", "scrollBurst"),
            event("2026-08-24T10:00:06.400Z", "keyboardShortcut"),
            event("2026-08-24T10:00:07.400Z", "typingBurst", message=SENSITIVE),
            event("2026-08-24T10:00:08.400Z", "urlChanged", url={"value": SENSITIVE}),
            event(
                "2026-08-24T10:00:09.400Z",
                "semanticSnapshot",
                metadata={
                    "computer_history.interaction_phase": "before",
                    "computer_history.interaction_id": SENSITIVE,
                },
                semanticContext={"snapshotID": SENSITIVE},
            ),
            event(
                "2026-08-24T10:00:11.400Z",
                "semanticSnapshot",
                metadata={
                    "computer_history.interaction_phase": "settled",
                    "computer_history.interaction_id": SENSITIVE,
                },
                semanticContext={"snapshotID": SENSITIVE},
            ),
        ]
        return codex_rows, goalong_rows

    def test_matching_fixtures_are_observed_within_tolerance(self) -> None:
        codex_rows, goalong_rows = self.matching_fixture()
        self.write_rows(self.codex, codex_rows)
        self.write_rows(self.goalong, goalong_rows)
        result = self.run_probe()
        self.assertEqual(result.returncode, 0, result.stderr or result.stdout)
        self.assertLess(len(result.stdout.encode("utf-8")), 32 * 1_024)
        report = json.loads(result.stdout)
        self.assertEqual(report["result"], "observed_within_tolerance")
        self.assertTrue(report["safety"]["read_only"])
        self.assertTrue(report["safety"]["metadata_only_output"])
        self.assertEqual(report["sources"]["codex"]["semantic_pair_count"], 1)
        self.assertEqual(report["sources"]["goalong"]["semantic_pair_count"], 1)
        for category in (
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
        ):
            self.assertEqual(report["comparison"][category]["status"], "within_tolerance")

    def test_codex_protobuf_timestamp_and_structured_mouse_event_are_supported(self) -> None:
        timestamp = int(
            dt.datetime(2026, 8, 24, 10, 0, 2, tzinfo=dt.timezone.utc).timestamp()
        )
        self.write_rows(
            self.codex,
            [
                {
                    "current_timestamp": {"seconds": timestamp, "nanos": 0},
                    "_eventType": "mouse",
                    "mouseButton": "left",
                    "clickCount": 1,
                }
            ],
        )
        self.write_rows(
            self.goalong,
            [event("2026-08-24T10:00:02Z", "mouseClick")],
        )
        result = self.run_probe()
        self.assertEqual(result.returncode, 0, result.stdout)
        report = json.loads(result.stdout)
        self.assertEqual(report["comparison"]["click"]["status"], "within_tolerance")

    def test_codex_namespaced_text_input_is_classified_as_typing(self) -> None:
        self.write_rows(
            self.codex,
            [event("2026-08-24T10:00:02Z", "keyboard.text_input")],
        )
        self.write_rows(
            self.goalong,
            [event("2026-08-24T10:00:02Z", "typingBurst")],
        )
        result = self.run_probe()
        self.assertEqual(result.returncode, 0, result.stdout)
        report = json.loads(result.stdout)
        self.assertEqual(report["comparison"]["typing"]["status"], "within_tolerance")

    def test_gap_and_malformed_row_make_coverage_insufficient(self) -> None:
        self.write_rows(
            self.codex,
            [
                event("2026-08-24T10:00:02Z", "capture_suppressed"),
                "{malformed",
            ],
        )
        self.write_rows(
            self.goalong,
            [event("2026-08-24T10:00:02Z", "mouseClick")],
        )
        result = self.run_probe()
        self.assertEqual(result.returncode, 2)
        report = json.loads(result.stdout)
        self.assertEqual(report["result"], "insufficient_coverage")
        self.assertEqual(report["sources"]["codex"]["explicit_gap_events"], 1)
        self.assertEqual(report["sources"]["codex"]["issues"]["malformed_json"], 1)

    def test_mismatched_observations_are_outside_tolerance_not_exact(self) -> None:
        self.write_rows(
            self.codex,
            [
                event(f"2026-08-24T10:00:0{second}Z", "mouse_click")
                for second in (1, 3, 5, 7)
            ],
        )
        self.write_rows(
            self.goalong,
            [event("2026-08-24T10:00:01Z", "mouseClick")],
        )
        result = self.run_probe()
        self.assertEqual(result.returncode, 1)
        report = json.loads(result.stdout)
        self.assertEqual(report["result"], "observed_outside_tolerance")
        self.assertEqual(report["comparison"]["click"]["status"], "outside_tolerance")
        self.assertNotEqual(report["result"], "exact")

    def test_time_tolerance_is_applied_to_exact_event_timestamps(self) -> None:
        self.write_rows(
            self.codex,
            [event("2026-08-24T10:00:01.000Z", "mouse_click")],
        )
        self.write_rows(
            self.goalong,
            [event("2026-08-24T10:00:04.001Z", "mouseClick")],
        )
        outside = self.run_probe()
        self.assertEqual(outside.returncode, 1)
        outside_report = json.loads(outside.stdout)
        self.assertEqual(
            outside_report["comparison"]["click"]["goalong_time_match_ratio"], 0
        )

        self.write_rows(
            self.goalong,
            [event("2026-08-24T10:00:04.000Z", "mouseClick")],
        )
        boundary = self.run_probe()
        self.assertEqual(boundary.returncode, 0, boundary.stdout)

    def test_output_never_contains_source_content_or_paths(self) -> None:
        codex_rows, goalong_rows = self.matching_fixture()
        private_directory = self.root / SENSITIVE.replace("/", "-")
        private_directory.mkdir()
        codex = private_directory / "private-codex.jsonl"
        goalong = private_directory / "private-goalong.jsonl"
        self.write_rows(codex, codex_rows)
        self.write_rows(goalong, goalong_rows)
        result = self.run_probe(codex, goalong)
        combined = result.stdout + result.stderr
        self.assertNotIn(SENSITIVE, combined)
        self.assertNotIn(str(private_directory), combined)
        report = json.loads(result.stdout)
        self.assertFalse(report["safety"]["source_paths_emitted"])
        self.assertFalse(report["safety"]["content_or_snapshots_emitted"])

    def test_symlink_source_is_rejected_without_following_it(self) -> None:
        self.write_rows(self.codex, [event("2026-08-24T10:00:02Z", "mouse_click")])
        self.write_rows(self.goalong, [event("2026-08-24T10:00:02Z", "mouseClick")])
        symlink = self.root / "codex-link.jsonl"
        symlink.symlink_to(self.codex)
        result = self.run_probe(symlink, self.goalong)
        self.assertEqual(result.returncode, 2)
        report = json.loads(result.stdout)
        self.assertEqual(report["sources"]["codex"]["files_opened"], 0)
        self.assertEqual(report["sources"]["codex"]["issues"]["symlink_rejected"], 1)

    def test_symlinked_ancestor_is_rejected_without_opening_the_file(self) -> None:
        real_directory = self.root / "real"
        real_directory.mkdir()
        codex = real_directory / "events.jsonl"
        self.write_rows(codex, [event("2026-08-24T10:00:02Z", "mouse_click")])
        self.write_rows(self.goalong, [event("2026-08-24T10:00:02Z", "mouseClick")])
        linked_directory = self.root / "linked"
        linked_directory.symlink_to(real_directory, target_is_directory=True)
        result = self.run_probe(linked_directory / "events.jsonl", self.goalong)
        self.assertEqual(result.returncode, 2)
        report = json.loads(result.stdout)
        self.assertEqual(report["sources"]["codex"]["files_opened"], 0)
        self.assertEqual(report["sources"]["codex"]["issues"]["symlink_rejected"], 1)

    def test_inaccessible_source_has_an_explicit_state(self) -> None:
        if os.geteuid() == 0:
            self.skipTest("root can read chmod(0) fixtures")
        self.write_rows(self.codex, [event("2026-08-24T10:00:02Z", "mouse_click")])
        self.write_rows(self.goalong, [event("2026-08-24T10:00:02Z", "mouseClick")])
        original_mode = stat.S_IMODE(self.codex.stat().st_mode)
        self.codex.chmod(0)
        try:
            result = self.run_probe()
        finally:
            self.codex.chmod(original_mode)
        self.assertEqual(result.returncode, 2)
        report = json.loads(result.stdout)
        self.assertEqual(report["sources"]["codex"]["issues"]["inaccessible_source"], 1)

    def test_row_and_line_bounds_stop_without_emitting_payload(self) -> None:
        self.write_rows(
            self.codex,
            [
                event("2026-08-24T10:00:01Z", "mouse_click"),
                event("2026-08-24T10:00:02Z", "mouse_click", body=SENSITIVE),
                event("2026-08-24T10:00:03Z", "mouse_click"),
            ],
        )
        self.write_rows(
            self.goalong,
            [event("2026-08-24T10:00:01Z", "mouseClick")],
        )
        row_result = self.run_probe(
            self.codex, self.goalong, "--max-rows-per-source", "1"
        )
        self.assertEqual(row_result.returncode, 2)
        row_report = json.loads(row_result.stdout)
        self.assertEqual(
            row_report["sources"]["codex"]["issues"]["row_budget_exhausted"], 1
        )
        self.assertNotIn(SENSITIVE, row_result.stdout + row_result.stderr)

        self.write_rows(
            self.codex,
            [
                "{\"timestamp\":\"2026-08-24T10:00:01Z\","
                "\"kind\":\"mouse_click\",\"body\":\""
                + "x" * 400
                + "\"}"
            ],
        )
        line_result = self.run_probe(
            self.codex, self.goalong, "--max-line-bytes", "128"
        )
        self.assertEqual(line_result.returncode, 2)
        line_report = json.loads(line_result.stdout)
        self.assertEqual(
            line_report["sources"]["codex"]["issues"]["oversized_line"], 1
        )

    def test_exact_byte_bound_is_not_reported_as_exhausted(self) -> None:
        row = event("2026-08-24T10:00:02Z", "mouse_click")
        encoded = json.dumps(row) + "\n"
        self.codex.write_text(encoded, encoding="utf-8")
        self.goalong.write_text(encoded, encoding="utf-8")
        result = self.run_probe(
            self.codex,
            self.goalong,
            "--max-bytes-per-source",
            str(len(encoded.encode("utf-8"))),
        )
        self.assertEqual(result.returncode, 0, result.stdout)
        report = json.loads(result.stdout)
        self.assertNotIn("byte_budget_exhausted", report["sources"]["codex"]["issues"])

    def test_directory_traversal_has_a_global_entry_bound(self) -> None:
        codex_directory = self.root / "codex-directory"
        codex_directory.mkdir()
        for index in range(4):
            (codex_directory / f"irrelevant-{index}.txt").write_text(
                SENSITIVE, encoding="utf-8"
            )
        self.write_rows(self.goalong, [event("2026-08-24T10:00:01Z", "mouseClick")])
        result = self.run_probe(
            codex_directory,
            self.goalong,
            "--max-directory-entries-per-source",
            "1",
        )
        self.assertEqual(result.returncode, 2)
        report = json.loads(result.stdout)
        self.assertEqual(
            report["sources"]["codex"]["issues"]["directory_entry_budget_exhausted"],
            1,
        )
        self.assertLessEqual(report["sources"]["codex"]["directory_entries_seen"], 2)
        self.assertNotIn(SENSITIVE, result.stdout + result.stderr)

    def test_broad_roots_prune_irrelevant_canonical_dated_sources(self) -> None:
        codex_root = self.root / "codex-root"
        old_segment = codex_root / "segments" / "2026-08-01T10-00-00Z"
        current_segment = codex_root / "segments" / "2026-08-24T10-00-00Z"
        old_segment.mkdir(parents=True)
        current_segment.mkdir(parents=True)
        self.write_rows(
            old_segment / "events.jsonl",
            [event("2026-08-01T10:00:02Z", "mouse_click", body=SENSITIVE * 100)],
        )
        self.write_rows(
            current_segment / "events.jsonl",
            [event("2026-08-24T10:00:02Z", "mouse_click")],
        )

        goalong_root = self.root / "goalong-root"
        goalong_root.mkdir()
        self.write_rows(
            goalong_root / "2026-08-01.jsonl",
            [event("2026-08-01T10:00:02Z", "mouseClick", body=SENSITIVE * 100)],
        )
        self.write_rows(
            goalong_root / "2026-08-24.jsonl",
            [event("2026-08-24T10:00:02Z", "mouseClick")],
        )

        result = self.run_probe(
            codex_root,
            goalong_root,
            "--max-bytes-per-source",
            "1024",
        )
        self.assertEqual(result.returncode, 0, result.stdout)
        report = json.loads(result.stdout)
        self.assertEqual(report["result"], "observed_within_tolerance")
        self.assertEqual(report["sources"]["codex"]["files_opened"], 1)
        self.assertEqual(report["sources"]["goalong"]["files_opened"], 1)
        self.assertEqual(report["sources"]["codex"]["dated_entries_skipped"], 1)
        self.assertEqual(report["sources"]["goalong"]["dated_entries_skipped"], 1)
        self.assertNotIn("byte_budget_exhausted", report["sources"]["codex"]["issues"])
        self.assertNotIn("byte_budget_exhausted", report["sources"]["goalong"]["issues"])
        self.assertNotIn(SENSITIVE, result.stdout + result.stderr)

    def test_answer_checker_emits_only_metadata_for_sensitive_input(self) -> None:
        payload = {
            "answer": {
                "answer": SENSITIVE,
                "hits": [{"title": SENSITIVE, "excerpt": SENSITIVE}],
                "limitations": [SENSITIVE],
            }
        }
        result = subprocess.run(
            ["python3", str(ANSWER_CHECKER)],
            input=json.dumps(payload),
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn(SENSITIVE, result.stdout + result.stderr)
        self.assertEqual(
            json.loads(result.stdout),
            {"valid": True, "hit_count": 1, "limitation_count": 1},
        )

    def test_answer_checker_reports_fixed_shape_error_without_content(self) -> None:
        payload = {"answer": {"answer": SENSITIVE, "hits": SENSITIVE}}
        result = subprocess.run(
            ["python3", str(ANSWER_CHECKER)],
            input=json.dumps(payload),
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 1)
        self.assertNotIn(SENSITIVE, result.stdout + result.stderr)

    def test_validator_never_logs_raw_memory_or_question_answers(self) -> None:
        source = VALIDATOR.read_text(encoding="utf-8")
        self.assertNotIn("run_logged causal-memory", source)
        self.assertNotIn("causal-memory.log", source)
        self.assertNotIn(".computer-history.json", source)
        self.assertNotIn('run_logged ask-resume "$QUERY_CLI"', source)
        self.assertIn("check_computer_history_memory.py", source)
        self.assertIn("--quiet-errors", source)
        self.assertIn("check_computer_history_answer.py", source)
        self.assertIn("physical-input-metadata-probe", source)

    def test_probe_rejects_non_utc_interval_before_reading_sources(self) -> None:
        result = subprocess.run(
            [
                "python3",
                str(PROBE),
                "--codex",
                str(self.root / SENSITIVE),
                "--goalong",
                str(self.root / SENSITIVE),
                "--start-utc",
                "2026-08-24T12:00:00+02:00",
                "--end-utc",
                "2026-08-24T12:01:00+02:00",
            ],
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 64)
        self.assertNotIn(SENSITIVE, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
