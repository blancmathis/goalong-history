#!/usr/bin/env python3
"""Compare public codesign requirements with reviewed release pins, not binary hashes."""
import argparse
import hashlib
import json
import re
import sys

COMPONENTS = {"app", "cli", "relauncher"}
TOKEN = re.compile(r'"(?:\\.|[^"\\])*"|/\*.*?\*/|[A-Za-z_][A-Za-z0-9_.-]*|[0-9]+|[^\s]', re.S)


def fingerprint(requirement: str) -> str:
    if not isinstance(requirement, str) or not 1 <= len(requirement) <= 16384:
        raise ValueError("Missing or oversized designated requirement")
    # Ignore rendering whitespace/comments, but never change quoted certificate/ID text.
    tokens = [m.group(0) for m in TOKEN.finditer(requirement) if not m.group(0).startswith("/*")]
    return hashlib.sha256(json.dumps(tokens, separators=(",", ":"), ensure_ascii=True).encode()).hexdigest()


def verify(component: str, requirement: str, pins: dict) -> None:
    hashes = pins.get("requirementsSHA256", {})
    if pins.get("schema") != 1 or set(hashes) != COMPONENTS:
        raise ValueError("Invalid permission identity policy")
    if not all(isinstance(v, str) and re.fullmatch(r"[0-9a-f]{64}", v) for v in hashes.values()):
        raise ValueError("Invalid permission requirement fingerprint")
    if component not in COMPONENTS or fingerprint(requirement) != hashes[component]:
        raise ValueError("Designated requirement changed: explicit reviewed identity migration required")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--pins", required=True)
    parser.add_argument("--component", required=True, choices=sorted(COMPONENTS))
    args = parser.parse_args()
    try:
        with open(args.pins, encoding="utf-8") as stream:
            pins = json.load(stream)
        text = sys.stdin.read(32768)
        lines = [line[len("designated => "):] for line in text.splitlines() if line.startswith("designated => ")]
        if len(lines) != 1:
            raise ValueError("Expected one designated requirement for the selected architecture")
        verify(args.component, lines[0], pins)
    except (ValueError, OSError) as error:
        print(str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
