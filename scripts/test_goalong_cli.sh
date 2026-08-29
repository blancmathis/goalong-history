#!/bin/bash
set -euo pipefail

CLI="${1:?usage: test_goalong_cli.sh /path/to/goalong}"
TEST_ROOT="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/goalong-cli.XXXXXX")"
trap '/bin/rm -rf -- "$TEST_ROOT"' EXIT

[[ -x "$CLI" ]]
/bin/mkdir -p "$TEST_ROOT/chatgpt/recaps" "$TEST_ROOT/events" "$TEST_ROOT/computer-history"
/usr/bin/printf '%s\n' '{
  "schemaVersion": 2,
  "day": "2026-08-26T22:00:00Z",
  "generatedAt": "2026-08-27T00:05:00Z",
  "provider": "fixture",
  "planType": null,
  "contextDigest": "fixture-digest",
  "sourceCounts": {"localEvents": 12},
  "markdown": "One.\nTwo.\nThree.\nFour.\nFive.",
  "model": "gpt-5.6-luna",
  "reasoningEffort": "high",
  "productivityScore": 64,
  "confidenceScore": 80,
  "summaryLines": ["One.", "Two.", "Three.", "Four.", "Five."]
}' > "$TEST_ROOT/chatgpt/recaps/2026-08-27.chatgpt-recap.json"
/usr/bin/printf '%s\n' '{}' > "$TEST_ROOT/events/2026-08-27.jsonl"

before="$(find "$TEST_ROOT" -type f -exec shasum -a 256 {} \; | sort)"
"$CLI" --root "$TEST_ROOT" status \
  | jq -e '.snapshot == null and .assessment == null and .loadIssues == []' >/dev/null
"$CLI" --root "$TEST_ROOT" days \
  | jq -e '.recaps == ["2026-08-27"] and .aiConversationCandidateDays == [] and .agentActivityIndexStatus == "notIndexed"' >/dev/null
"$CLI" --root "$TEST_ROOT" recap 2026-08-27 \
  | jq -e '.status == "available" and .recap.productivityScore == 64' >/dev/null
"$CLI" --root "$TEST_ROOT" recap 2026-08-28 \
  | jq -e '.status == "notGenerated" and .recap == null' >/dev/null
if "$CLI" --root "$TEST_ROOT" recap 2026-02-31 >/dev/null 2>&1; then
  echo "Goalong CLI accepted an invalid calendar date." >&2
  exit 1
fi
"$CLI" --root "$TEST_ROOT" screen-time today \
  | jq -e '.schemaVersion == 1 and (.reports | type == "array") and (.status.kind | type == "string")' >/dev/null
"$CLI" --root "$TEST_ROOT" screen-time --mac-only \
  | jq -e '.scope == "macOnly" and (.reports | type == "array")' >/dev/null
"$CLI" --root "$TEST_ROOT" ai-conversations 2026-08-27 \
  | jq -e '.status == "notIndexed" and .conversations == [] and .candidateOffset == 0 and .nextCandidateOffset == null and .visitedConversationCandidateCount == 0 and .returnedConversationCount == 0 and .noVisibleMessageCandidateCount == 0 and .outputDroppedConversationCount == 0' >/dev/null
"$CLI" --root "$TEST_ROOT" ai-conversations 2026-08-27 --offset 24 \
  | jq -e '.status == "notIndexed" and .candidateOffset == 24 and .nextCandidateOffset == null' >/dev/null
if "$CLI" --root "$TEST_ROOT" ai-conversations 2026-08-27 --offset 50001 >/dev/null 2>&1; then
  echo "Goalong CLI accepted an out-of-range AI conversation offset." >&2
  exit 1
fi
after="$(find "$TEST_ROOT" -type f -exec shasum -a 256 {} \; | sort)"
[[ "$before" == "$after" ]]

echo "Goalong CLI tests passed: lightweight status, day discovery, recap present/missing states, direct Screen Time status, AI index-missing state, and zero source writes."
