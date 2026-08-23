#!/bin/bash
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST="${LOCALHISTORY_BENCHMARK_BUILD_MANIFEST:-$REPO/dist/goalong-real-benchmark-build.json}"
APP="/Applications/Goalong History.app"
USER_EXPECTED_HEAD=""

ARGS=("$@")
for ((INDEX = 0; INDEX < ${#ARGS[@]}; INDEX++)); do
  case "${ARGS[$INDEX]}" in
    --app)
      INDEX=$((INDEX + 1))
      [[ $INDEX -lt ${#ARGS[@]} ]] || { echo "Missing value for --app" >&2; exit 64; }
      APP="${ARGS[$INDEX]}"
      ;;
    --expected-head)
      INDEX=$((INDEX + 1))
      [[ $INDEX -lt ${#ARGS[@]} ]] || { echo "Missing value for --expected-head" >&2; exit 64; }
      USER_EXPECTED_HEAD="${ARGS[$INDEX]}"
      ;;
  esac
done

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This benchmark must run in Mathis's foreground macOS session." >&2
  exit 69
fi
if [[ ! -d "$REPO/.git" ]]; then
  echo "Not a Goalong History checkout: $REPO" >&2
  exit 66
fi

HEAD_SHA="$(git -C "$REPO" rev-parse HEAD)"
if [[ -n "$USER_EXPECTED_HEAD" && "$USER_EXPECTED_HEAD" != "$HEAD_SHA" ]]; then
  echo "Requested HEAD $USER_EXPECTED_HEAD, but checkout is $HEAD_SHA" >&2
  exit 65
fi
if [[ ! -f "$MANIFEST" ]]; then
  cat >&2 <<EOF
Missing exact-build manifest: $MANIFEST

Build and install the exact clean HEAD first:

  export LOCALHISTORY_CODESIGN_IDENTITY='Developer ID Application: NAME (TEAMID)'
  bash scripts/build_real_computer_history_benchmark_app.sh --install
EOF
  exit 77
fi
if [[ ! -d "$APP" ]]; then
  echo "Installed app not found: $APP" >&2
  exit 66
fi

/usr/bin/codesign --verify --strict --verbose=2 "$APP"
/usr/bin/python3 - "$MANIFEST" "$HEAD_SHA" "$APP" <<'PY'
from __future__ import annotations

import hashlib
import json
import pathlib
import plistlib
import subprocess
import sys

manifest_path = pathlib.Path(sys.argv[1])
expected_head = sys.argv[2]
app = pathlib.Path(sys.argv[3])
manifest = json.loads(manifest_path.read_text())
errors: list[str] = []

if manifest.get("type") != "goalong-real-benchmark-build":
    errors.append("manifest type is not goalong-real-benchmark-build")
if manifest.get("head_sha") != expected_head:
    errors.append(
        f"manifest HEAD {manifest.get('head_sha')!r} does not match {expected_head!r}"
    )
if manifest.get("developer_id_application") is not True:
    errors.append("manifest does not record a Developer ID Application build")
if manifest.get("bundle_id") != "ai.goalong.localhistory":
    errors.append(f"manifest bundle ID is {manifest.get('bundle_id')!r}")

info_path = app / "Contents" / "Info.plist"
with info_path.open("rb") as handle:
    info = plistlib.load(handle)
if info.get("CFBundleIdentifier") != "ai.goalong.localhistory":
    errors.append(f"installed bundle ID is {info.get('CFBundleIdentifier')!r}")

binary = app / "Contents" / "MacOS" / "Goalong History"
digest = hashlib.sha256(binary.read_bytes()).hexdigest()
if digest != manifest.get("binary_sha256"):
    errors.append(
        "installed binary SHA-256 does not match the exact build manifest "
        f"({digest} != {manifest.get('binary_sha256')})"
    )

details = subprocess.run(
    ["/usr/bin/codesign", "-d", "--verbose=4", str(app)],
    text=True,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    check=False,
).stdout
if not details:
    details = subprocess.run(
        ["/usr/bin/codesign", "-d", "--verbose=4", str(app)],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    ).stderr
if "Authority=Developer ID Application:" not in details:
    errors.append("installed app lacks a Developer ID Application authority")
if manifest.get("team_id") and f"TeamIdentifier={manifest['team_id']}" not in details:
    errors.append("installed TeamIdentifier does not match the build manifest")

if errors:
    for error in errors:
        print(f"- {error}", file=sys.stderr)
    raise SystemExit(
        "Installed app is not the exact Developer ID-signed build recorded for this HEAD."
    )

print(
    f"Exact installed build verified: {expected_head} / {digest[:16]} / "
    f"team {manifest.get('team_id')}"
)
PY

cat <<'NOTICE'
Goalong Computer History — REAL foreground benchmark

This is not the deterministic 4/4 fixture. It measures physical input, the exact
installed app identity and binary, TCC evidence, causal before/after coverage, privacy
leakage, resource search/reopening, resume accuracy, Codex comparison and timeline
performance.

The script never resets TCC and never grants permissions automatically. It creates only
disposable benchmark files/pages plus a report folder on the Desktop.
NOTICE

exec /usr/bin/python3 "$REPO/scripts/real_computer_history_benchmark.py" run \
  --repo "$REPO" \
  --app "$APP" \
  --expected-head "$HEAD_SHA" \
  "$@"
