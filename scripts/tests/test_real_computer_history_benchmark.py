from __future__ import annotations

import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock


MODULE_PATH = Path(__file__).resolve().parents[1] / "real_computer_history_benchmark.py"
SPEC = importlib.util.spec_from_file_location(
    "real_computer_history_benchmark",
    MODULE_PATH,
)
assert SPEC is not None and SPEC.loader is not None
benchmark = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = benchmark
SPEC.loader.exec_module(benchmark)


class RealComputerHistoryBenchmarkTests(unittest.TestCase):
    def test_window_accepts_interaction_start_timestamp(self) -> None:
        rows = [
            {"id": "inside", "start": "2026-08-23T10:00:01Z"},
            {"id": "outside", "start": "2026-08-23T10:01:00Z"},
        ]

        selected = benchmark.window(
            rows,
            "2026-08-23T10:00:00Z",
            "2026-08-23T10:00:05Z",
            0,
        )

        self.assertEqual([row["id"] for row in selected], ["inside"])

    def test_status_requires_a_real_input_callback(self) -> None:
        ready = {
            "snapshot": {
                "permissions": {
                    "accessibilityPreflight": True,
                    "accessibilityFunctionalProbe": True,
                    "inputMonitoringPreflight": True,
                },
                "eventTapLifecycle": "createdEnabled",
            },
            "assessment": {"captureProven": True},
        }

        self.assertEqual(benchmark.status_reasons(ready), [])

        ready["assessment"]["captureProven"] = False
        self.assertTrue(
            any(
                "real input callback" in reason
                for reason in benchmark.status_reasons(ready)
            )
        )

    def test_resource_match_requires_resource_evidence(self) -> None:
        case = {
            "title": "Goalong Benchmark Page 03 TOKEN",
            "expected": "127.0.0.1:8123/page-03.html",
        }
        matching = {
            "title": case["title"],
            "canonicalURI": "http://127.0.0.1:8123/page-03.html",
        }

        self.assertTrue(benchmark.resource_ok(matching, case))
        self.assertFalse(benchmark.resource_ok({"title": "Unrelated"}, case))

    def test_missing_real_measurements_can_never_validate_public_parity(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            (root / "events").mkdir()
            output = root / "output"
            output.mkdir()
            run = {
                "id": "empty-real-run",
                "token": "TOKEN",
                "head": "a" * 40,
                "data_root": str(root),
                "output": str(output),
                "started": "2026-08-23T10:00:00Z",
                "ended": "2026-08-23T10:01:00Z",
                "signature": {
                    "developer_id_application": True,
                    "identifier": "ai.goalong.localhistory",
                },
                "preflight": {
                    "snapshot": {
                        "permissions": {
                            "accessibilityPreflight": True,
                            "accessibilityFunctionalProbe": True,
                            "inputMonitoringPreflight": True,
                        },
                        "eventTapLifecycle": "createdEnabled",
                    },
                    "assessment": {"captureProven": True},
                },
                "scenarios": [],
                "resources": [],
                "performance": {
                    "samples": 10,
                    "responsive": True,
                    "cpu_mean": 1,
                    "rss_peak_mb": 100,
                },
                "config_restored": True,
                "regressions": {"screen_time": True},
                "codex": {
                    "accessible": False,
                    "reason": "not available in this test",
                },
            }

            with mock.patch.object(
                benchmark,
                "build_memory",
                return_value={"memory": None},
            ):
                result = benchmark.score(run, Path("/missing-cli"))

            self.assertFalse(result["synthetic_fixture"])
            self.assertFalse(result["public_parity_validated"])
            self.assertEqual(result["status"], "incomplete_or_below_threshold")


if __name__ == "__main__":
    unittest.main()
