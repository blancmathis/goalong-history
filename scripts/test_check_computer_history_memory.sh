#!/bin/bash
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
CHECKER="$REPO/scripts/check_computer_history_memory.py"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/goalong-ch-checker.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

write_fixture() {
  local path="$1"
  local retained_fields="$2"
  cat >"$path" <<JSON
{
  "memory": {
    "coverage": {
      "sourceEventCount": 10,
      "actionEventCount": 10,
      "linkedInteractionCount": 10,
      "interactionsWithBeforeAndAfterContext": 1,
      "resourceCount": 10,
      "episodeCount": 10,
      "suppressedEventCount": 0${retained_fields}
    },
    "episodes": [{
      "id": "episode-1",
      "start": "2026-08-24T08:00:00Z",
      "end": "2026-08-24T08:01:00Z",
      "resourceIDs": ["resource-1"],
      "sourceInteractionCount": 10,
      "provenance": {
        "sourceEventIDs": ["event-1"],
        "sourceSequences": [1],
        "sourceEventHashes": ["event-hash-1"]
      },
      "interactions": [{
        "id": "interaction-1",
        "start": "2026-08-24T08:00:10Z",
        "end": "2026-08-24T08:00:11Z",
        "resourceIDs": ["resource-1"],
        "provenance": {
          "sourceEventIDs": ["event-1"],
          "sourceSequences": [1],
          "sourceEventHashes": ["event-hash-1"]
        }
      }]
    }],
    "resources": [{
      "id": "resource-1",
      "provenance": {
        "sourceEventIDs": ["event-1"],
        "sourceSequences": [1],
        "sourceEventHashes": ["resource-hash-1"]
      }
    }],
    "workflowPatterns": [{
      "id": "workflow-1",
      "fingerprint": "workflow-fingerprint-1",
      "occurrenceCount": 10,
      "episodeIDs": ["episode-1"]
    }],
    "suggestions": [{
      "id": "suggestion-1",
      "workflowID": "workflow-1",
      "episodeIDs": ["episode-1"]
    }]
  }
}
JSON
}

COMPACT="$WORK_DIR/compact.json"
write_fixture "$COMPACT" ',
      "retainedEpisodeCount": 1,
      "retainedInteractionCount": 1,
      "retainedResourceCount": 1'
python3 "$CHECKER" "$COMPACT" >/dev/null
python3 "$CHECKER" - --quiet-errors <"$COMPACT" >/dev/null

FULL="$WORK_DIR/full.json"
sed \
  -e 's/"sourceEventCount": 10/"sourceEventCount": 1/' \
  -e 's/"actionEventCount": 10/"actionEventCount": 1/' \
  -e 's/"linkedInteractionCount": 10/"linkedInteractionCount": 1/' \
  -e 's/"resourceCount": 10/"resourceCount": 1/' \
  -e 's/"episodeCount": 10/"episodeCount": 1/' \
  -e 's/"sourceInteractionCount": 10/"sourceInteractionCount": 1/' \
  -e 's/"suppressedEventCount": 0,/"suppressedEventCount": 0/' \
  "$COMPACT" \
  | sed '/"retainedEpisodeCount"/d; /"retainedInteractionCount"/d; /"retainedResourceCount"/d' \
  >"$FULL"
python3 "$CHECKER" "$FULL" >/dev/null

OVERLAPPING="$WORK_DIR/overlapping.json"
cat >"$OVERLAPPING" <<'JSON'
{
  "memory": {
    "coverage": {
      "sourceEventCount": 2,
      "actionEventCount": 2,
      "linkedInteractionCount": 2,
      "interactionsWithBeforeAndAfterContext": 0,
      "resourceCount": 0,
      "episodeCount": 2,
      "suppressedEventCount": 0
    },
    "episodes": [
      {
        "id": "overlap-1",
        "start": "2026-08-24T08:00:00Z",
        "end": "2026-08-24T08:00:10Z",
        "resourceIDs": [],
        "provenance": {
          "sourceEventIDs": ["event-1"],
          "sourceSequences": [1],
          "sourceEventHashes": []
        },
        "interactions": [{
          "id": "interaction-overlap-1",
          "start": "2026-08-24T08:00:02Z",
          "end": "2026-08-24T08:00:10Z",
          "resourceIDs": [],
          "provenance": {
            "sourceEventIDs": ["event-1"],
            "sourceSequences": [1],
            "sourceEventHashes": []
          }
        }]
      },
      {
        "id": "overlap-2",
        "start": "2026-08-24T08:00:05Z",
        "end": "2026-08-24T08:00:06Z",
        "resourceIDs": [],
        "provenance": {
          "sourceEventIDs": ["event-2"],
          "sourceSequences": [2],
          "sourceEventHashes": []
        },
        "interactions": [{
          "id": "interaction-overlap-2",
          "start": "2026-08-24T08:00:05Z",
          "end": "2026-08-24T08:00:06Z",
          "resourceIDs": [],
          "provenance": {
            "sourceEventIDs": ["event-2"],
            "sourceSequences": [2],
            "sourceEventHashes": []
          }
        }]
      }
    ],
    "resources": [],
    "workflowPatterns": [],
    "suggestions": []
  }
}
JSON
python3 "$CHECKER" "$OVERLAPPING" >/dev/null

RESOURCE_WITHOUT_PROVENANCE="$WORK_DIR/resource-without-provenance.json"
sed \
  -e '/"resources": \[/,/^    \}],$/ { /"provenance": {/,/^      }/d; }' \
  -e 's/"id": "resource-1",/"id": "resource-1"/' \
  "$COMPACT" >"$RESOURCE_WITHOUT_PROVENANCE"
NEGATIVE_OUTPUT="$WORK_DIR/negative-output.txt"
if python3 "$CHECKER" "$RESOURCE_WITHOUT_PROVENANCE" \
  >/dev/null 2>"$NEGATIVE_OUTPUT"
then
  echo "Checker accepted a resource without provenance." >&2
  exit 1
fi
if ! rg -F 'resources[0].provenance must be an object' \
  "$NEGATIVE_OUTPUT" >/dev/null
then
  echo "Missing targeted resource provenance failure." >&2
  exit 1
fi

NULL_PROVENANCE_ELEMENT="$WORK_DIR/null-provenance-element.json"
sed 's/"sourceEventHashes": \["resource-hash-1"\]/"sourceEventHashes": [null]/' \
  "$COMPACT" >"$NULL_PROVENANCE_ELEMENT"
if python3 "$CHECKER" "$NULL_PROVENANCE_ELEMENT" \
  >/dev/null 2>"$NEGATIVE_OUTPUT"
then
  echo "Checker accepted a null provenance element." >&2
  exit 1
fi
if ! rg -F \
  'resources[0].provenance.sourceEventHashes[0] must be a non-empty string' \
  "$NEGATIVE_OUTPUT" >/dev/null
then
  echo "Missing targeted provenance element failure." >&2
  exit 1
fi

GLOBAL_INTERACTION_INVERSION="$WORK_DIR/global-interaction-inversion.json"
sed 's/"start": "2026-08-24T08:00:02Z"/"start": "2026-08-24T08:00:07Z"/' \
  "$OVERLAPPING" >"$GLOBAL_INTERACTION_INVERSION"
if python3 "$CHECKER" "$GLOBAL_INTERACTION_INVERSION" \
  >/dev/null 2>"$NEGATIVE_OUTPUT"
then
  echo "Checker accepted interactions that were globally out of order." >&2
  exit 1
fi
if ! rg -F 'interactions are not globally chronologically ordered' \
  "$NEGATIVE_OUTPUT" >/dev/null
then
  echo "Missing targeted global interaction order failure." >&2
  exit 1
fi

INVALID="$WORK_DIR/invalid.json"
sed 's/"retainedEpisodeCount": 1/"retainedEpisodeCount": 11/' "$COMPACT" >"$INVALID"
if python3 "$CHECKER" "$INVALID" >/dev/null 2>&1; then
  echo "Checker accepted retainedEpisodeCount above exact coverage." >&2
  exit 1
fi

FOREIGN_WORKFLOW_EPISODE="$WORK_DIR/foreign-workflow-episode.json"
sed \
  '/"workflowPatterns": \[/,/^    \}],$/ s/"episodeIDs": \["episode-1"\]/"episodeIDs": ["foreign-episode"]/' \
  "$COMPACT" >"$FOREIGN_WORKFLOW_EPISODE"
if python3 "$CHECKER" "$FOREIGN_WORKFLOW_EPISODE" \
  >/dev/null 2>"$NEGATIVE_OUTPUT"
then
  echo "Checker accepted a workflow reference outside retained episodes." >&2
  exit 1
fi
if ! rg -F 'workflowPatterns[0] references unknown episode' \
  "$NEGATIVE_OUTPUT" >/dev/null
then
  echo "Missing targeted workflow episode reference failure." >&2
  exit 1
fi

INVALID_WORKFLOW_COUNT="$WORK_DIR/invalid-workflow-count.json"
sed 's/"occurrenceCount": 10/"occurrenceCount": 1/' \
  "$COMPACT" >"$INVALID_WORKFLOW_COUNT"
if python3 "$CHECKER" "$INVALID_WORKFLOW_COUNT" \
  >/dev/null 2>"$NEGATIVE_OUTPUT"
then
  echo "Checker accepted a non-repeated workflow occurrence count." >&2
  exit 1
fi
if ! rg -F 'workflowPatterns[0].occurrenceCount must be an integer of at least 2' \
  "$NEGATIVE_OUTPUT" >/dev/null
then
  echo "Missing targeted workflow occurrence count failure." >&2
  exit 1
fi

SENTINEL="PRIVATE-COMPUTER-HISTORY-BODY-MUST-NOT-LEAK"
SENSITIVE_INVALID="$WORK_DIR/sensitive-invalid.json"
sed "s/interaction-1/$SENTINEL/g; s/\"retainedEpisodeCount\": 1/\"retainedEpisodeCount\": 11/" \
  "$COMPACT" >"$SENSITIVE_INVALID"
QUIET_OUTPUT="$WORK_DIR/quiet-output.txt"
if python3 "$CHECKER" - --quiet-errors <"$SENSITIVE_INVALID" >"$QUIET_OUTPUT" 2>&1; then
  echo "Quiet checker accepted an invalid fixture." >&2
  exit 1
fi
if rg -F "$SENTINEL" "$QUIET_OUTPUT" >/dev/null; then
  echo "Quiet checker leaked a source-derived sentinel." >&2
  exit 1
fi
if python3 "$CHECKER" - --quiet-errors --max-input-bytes 32 \
  <"$COMPACT" >"$QUIET_OUTPUT" 2>&1
then
  echo "Quiet checker ignored its input byte bound." >&2
  exit 1
fi
if rg -F "$SENTINEL" "$QUIET_OUTPUT" >/dev/null; then
  echo "Bounded quiet checker leaked a source-derived sentinel." >&2
  exit 1
fi

echo "Computer History checker regression tests passed: full, compact, workflows, overlapping, provenance, global interaction order, stdin, quiet and invalid coverage."
