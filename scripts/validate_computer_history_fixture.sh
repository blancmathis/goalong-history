#!/bin/bash
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
DAY="2026-08-20"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/goalong-computer-history-fixture.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This deterministic integration validation requires macOS." >&2
  exit 69
fi

POSITIVE_ROOT="$WORK/positive-store"
NEGATIVE_ROOT="$WORK/negative-store"
VALIDATION_OUTPUT="$WORK/validation"

python3 "$REPO/scripts/make_computer_history_parity_fixture.py" \
  --output "$POSITIVE_ROOT" \
  --day "$DAY"

bash "$REPO/scripts/validate_computer_history_parity.sh" \
  --repo "$REPO" \
  --data-root "$POSITIVE_ROOT" \
  --day "$DAY" \
  --output "$VALIDATION_OUTPUT" \
  --require-real-context \
  --minimum-pair-ratio 0.90

MEMORY_JSON="$VALIDATION_OUTPUT/$DAY.computer-history.json"
BIN_PATH="$(cd "$REPO" && swift build -c release --show-bin-path)"
QUERY_CLI="$BIN_PATH/goalong-history-query"

FIND_JSON="$WORK/find.json"
"$QUERY_CLI" --root "$POSITIVE_ROOT" find --days 1 \
  "Find the enterprise launch proposal document" >"$FIND_JSON"

RESOURCE_ID="$(python3 - "$FIND_JSON" <<'PY'
from __future__ import annotations

import json
import pathlib
import sys

payload = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
answer = payload.get("answer", {})
hits = answer.get("hits", [])
if not hits:
    raise SystemExit("Strict resource lookup returned no hit")
resource = hits[0].get("resource")
if not isinstance(resource, dict):
    raise SystemExit("First strict resource hit has no resource payload")
uri = resource.get("canonicalURI", "")
if "docs.google.com/document/d/goalong-parity-proposal" not in uri:
    raise SystemExit(f"Unexpected resource URI: {uri!r}")
identifier = resource.get("id")
if not isinstance(identifier, str) or not identifier:
    raise SystemExit("Strict resource hit has no stable ID")
print(identifier)
PY
)"

RESOURCE_JSON="$WORK/resource.json"
"$QUERY_CLI" --root "$POSITIVE_ROOT" resource --days 1 "$RESOURCE_ID" \
  >"$RESOURCE_JSON"

UNRELATED_JSON="$WORK/unrelated.json"
"$QUERY_CLI" --root "$POSITIVE_ROOT" find --days 1 \
  "Find the strategic acquisition document" >"$UNRELATED_JSON"

python3 - "$MEMORY_JSON" "$RESOURCE_JSON" "$UNRELATED_JSON" <<'PY'
from __future__ import annotations

import json
import pathlib
import sys

memory_envelope = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
resource_envelope = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))
unrelated_envelope = json.loads(pathlib.Path(sys.argv[3]).read_text(encoding="utf-8"))

memory = memory_envelope.get("memory")
if not isinstance(memory, dict):
    raise SystemExit("Positive fixture did not produce a causal memory")
coverage = memory.get("coverage", {})
expected = {
    "actionEventCount": 4,
    "linkedInteractionCount": 4,
    "interactionsWithBeforeAndAfterContext": 4,
}
for key, value in expected.items():
    if coverage.get(key) != value:
        raise SystemExit(f"coverage.{key}={coverage.get(key)!r}; expected {value}")
if len(memory.get("resources", [])) < 1:
    raise SystemExit("Positive fixture resolved no resource")
if len(memory.get("episodes", [])) < 1:
    raise SystemExit("Positive fixture reconstructed no episode")

resource = resource_envelope.get("resource")
if not isinstance(resource, dict):
    raise SystemExit("resource command failed to resolve the stable ID")
if not resource_envelope.get("relatedEpisodes"):
    raise SystemExit("resource command returned no related episode provenance")

unrelated_hits = unrelated_envelope.get("answer", {}).get("hits")
if unrelated_hits != []:
    raise SystemExit("Named unrelated lookup returned an unsupported resource")
PY

python3 "$REPO/scripts/make_computer_history_parity_fixture.py" \
  --output "$NEGATIVE_ROOT" \
  --day "$DAY" \
  --without-pairs

NEGATIVE_JSON="$WORK/negative-memory.json"
"$QUERY_CLI" --root "$NEGATIVE_ROOT" computer-history "$DAY" >"$NEGATIVE_JSON"

if python3 "$REPO/scripts/check_computer_history_memory.py" \
  "$NEGATIVE_JSON" \
  --require-actions \
  --require-resources \
  --require-semantic-pairs \
  --minimum-pair-ratio 0.90 \
  >"$WORK/negative-check.stdout" \
  2>"$WORK/negative-check.stderr"
then
  echo "Strict checker incorrectly accepted a fixture with no semantic pairs." >&2
  cat "$WORK/negative-check.stdout" >&2
  exit 1
fi

grep -Eq \
  'no before/after semantic pair|semantic pair ratio 0\.000 is below 0\.900' \
  "$WORK/negative-check.stderr" || {
    echo "Strict checker failed for an unexpected reason:" >&2
    cat "$WORK/negative-check.stderr" >&2
    exit 1
  }

python3 - "$MEMORY_JSON" <<'PY'
from __future__ import annotations

import json
import pathlib
import sys

memory = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))["memory"]
coverage = memory["coverage"]
ratio = (
    coverage["interactionsWithBeforeAndAfterContext"]
    / coverage["linkedInteractionCount"]
)
print(
    json.dumps(
        {
            "valid": True,
            "fixture": "deterministic-v1",
            "actions": coverage["actionEventCount"],
            "interactions": coverage["linkedInteractionCount"],
            "semantic_pairs": coverage["interactionsWithBeforeAndAfterContext"],
            "semantic_pair_ratio": ratio,
            "resources": len(memory["resources"]),
            "episodes": len(memory["episodes"]),
            "strict_negative_fixture_rejected": True,
            "strict_named_false_positive_rejected": True,
            "stable_resource_lookup_verified": True,
        },
        sort_keys=True,
    )
)
PY
