#!/usr/bin/env python3
"""Validate a Computer History answer without echoing its source-derived content."""

from __future__ import annotations

import argparse
import json
import sys
from typing import Any


def positive_int(value: str) -> int:
    parsed = int(value)
    if parsed <= 0:
        raise argparse.ArgumentTypeError("must be greater than zero")
    return parsed


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--max-bytes", type=positive_int, default=16 * 1_024 * 1_024)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    raw = sys.stdin.buffer.read(args.max_bytes + 1)
    if len(raw) > args.max_bytes:
        print("Computer History answer exceeded the validation byte bound", file=sys.stderr)
        return 2
    try:
        payload: Any = json.loads(raw)
    except (json.JSONDecodeError, UnicodeDecodeError):
        print("Computer History answer was not valid JSON", file=sys.stderr)
        return 2

    answer = payload.get("answer") if isinstance(payload, dict) else None
    text = answer.get("answer") if isinstance(answer, dict) else None
    hits = answer.get("hits") if isinstance(answer, dict) else None
    limitations = answer.get("limitations") if isinstance(answer, dict) else None
    errors = 0
    errors += not isinstance(text, str) or not text.strip()
    errors += not isinstance(hits, list)
    errors += not isinstance(limitations, list) or not limitations
    if errors:
        print(
            f"Computer History answer validation failed: {errors} shape violation(s)",
            file=sys.stderr,
        )
        return 1

    print(
        json.dumps(
            {
                "valid": True,
                "hit_count": len(hits),
                "limitation_count": len(limitations),
            },
            sort_keys=True,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
