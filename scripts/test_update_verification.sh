#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d /tmp/goalong-update-verification.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
xcrun swiftc "$ROOT/scripts/verify_update_archive.swift" -o "$WORK/verify"
xcrun swift "$ROOT/scripts/test_update_verification.swift" "$WORK/verify" "$WORK"
