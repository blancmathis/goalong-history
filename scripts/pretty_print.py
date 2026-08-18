#!/usr/bin/env python3
"""Pretty-print a LocalHistory JSONL file without external dependencies."""

from __future__ import annotations

import argparse
import json
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("file", type=Path, help="Path to a LocalHistory .jsonl file")
    parser.add_argument("--kind", help="Only show events with this kind")
    args = parser.parse_args()

    with args.file.open("r", encoding="utf-8") as handle:
        for line_number, line in enumerate(handle, start=1):
            line = line.strip()
            if not line:
                continue
            try:
                event = json.loads(line)
            except json.JSONDecodeError as exc:
                print(f"Line {line_number}: invalid JSON: {exc}")
                continue
            if args.kind and event.get("kind") != args.kind:
                continue
            print(json.dumps(event, ensure_ascii=False, indent=2, sort_keys=True))
            print("-" * 80)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
