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
/usr/bin/printf '%s\n' '{"not":"a share package"}' > "$TEST_ROOT/invalid-share.json"
/usr/bin/printf '%s\n' \
  '{"schemaVersion":4,"id":"site-1","sessionID":"fixture","timestamp":"2026-08-27T10:00:00Z","kind":"urlChanged","app":{"name":"Aside","bundleIdentifier":"at.studio.AsideBrowser","processIdentifier":1},"url":{"value":"https://x.com/home","host":"x.com","redactionApplied":true}}' \
  '{"schemaVersion":4,"id":"health","sessionID":"fixture","timestamp":"2026-08-27T10:00:10Z","kind":"recorderHealth","metadata":{"observation_gap":"false"}}' \
  '{"schemaVersion":4,"id":"permissions","sessionID":"fixture","timestamp":"2026-08-27T10:00:20Z","kind":"permissionStatus","metadata":{"accessibility":"true","input_monitoring":"true"}}' \
  '{"schemaVersion":4,"id":"site-2","sessionID":"fixture","timestamp":"2026-08-27T10:00:30Z","kind":"urlChanged","app":{"name":"Google Chrome","bundleIdentifier":"com.google.Chrome","processIdentifier":2},"url":{"value":"https://www.x.com/search","host":"www.x.com","redactionApplied":true}}' \
  '{"schemaVersion":4,"id":"internal","sessionID":"fixture","timestamp":"2026-08-27T10:01:00Z","kind":"windowChanged","app":{"name":"ChatGPT","bundleIdentifier":"com.openai.codex","processIdentifier":3},"url":{"value":"app://conversation/123","host":"-","redactionApplied":true}}' \
  '{"schemaVersion":4,"id":"site-3","sessionID":"fixture","timestamp":"2026-08-27T10:01:10Z","kind":"urlChanged","app":{"name":"Aside","bundleIdentifier":"at.studio.AsideBrowser","processIdentifier":1},"url":{"value":"https://chatgpt.com/","host":"chatgpt.com","redactionApplied":true}}' \
  '{"schemaVersion":4,"id":"boundary","sessionID":"fixture","timestamp":"2026-08-27T10:01:40Z","kind":"windowChanged","app":{"name":"Finder","bundleIdentifier":"com.apple.finder","processIdentifier":4}}' \
  > "$TEST_ROOT/events/2026-08-27.jsonl"

before="$(find "$TEST_ROOT" -type f -exec shasum -a 256 {} \; | sort)"
"$CLI" --root "$TEST_ROOT" status \
  | jq -e '.snapshot == null and .assessment == null and .loadIssues == []' >/dev/null
"$CLI" --root "$TEST_ROOT" days \
  | jq -e '.recaps == ["2026-08-27"] and .aiConversationCandidateDays == [] and .agentActivityIndexStatus == "notIndexed"' >/dev/null
"$CLI" --root "$TEST_ROOT" recap 2026-08-27 \
  | jq -e '.status == "available" and .recap.productivityScore == 64 and .integrity.status == "legacyUnsigned" and .integrity.localDeviceSignatureValid == false' >/dev/null
"$CLI" verify-recap "$TEST_ROOT/chatgpt/recaps/2026-08-27.chatgpt-recap.json" \
  | jq -e '.status == "legacyUnsigned" and .recap.productivityScore == 64 and .integrity.savedResultMatches == false' >/dev/null
"$CLI" --root "$TEST_ROOT" recap 2026-08-28 \
  | jq -e '.status == "notGenerated" and .recap == null' >/dev/null
if "$CLI" --root "$TEST_ROOT" recap 2026-02-31 >/dev/null 2>&1; then
  echo "Goalong CLI accepted an invalid calendar date." >&2
  exit 1
fi
set +e
screen_time_error="$("$CLI" --root "$TEST_ROOT" screen-time today 2>&1)"
screen_time_status=$?
mac_only_error="$("$CLI" --root "$TEST_ROOT" screen-time --mac-only 2>&1)"
mac_only_status=$?
set -e
[[ "$screen_time_status" -eq 4 ]]
[[ "$mac_only_status" -eq 4 ]]
[[ "$screen_time_error" == *"Apple Screen Time is unavailable"* ]]
[[ "$screen_time_error" == *"explicitly enable Screen Time"* ]]
[[ "$mac_only_error" == *"Apple Screen Time is unavailable"* ]]
"$CLI" --root "$TEST_ROOT" websites 2026-08-27 --limit 1 \
  | jq -e '.status.kind == "ready" and .scope == "thisMacGoalongObserved" and .includedInApplicationTotals == true and .sourceRowCount == 7 and .sourceEventCount == 5 and .peakEstimatedRetainedBytes > 0 and .totalWebsiteCount == 2 and .returnedWebsiteCount == 1 and .nextOffset == 1 and .websites[0].host == "x.com" and .websites[0].foregroundSeconds == 60 and .websites[0].sourceApplications == ["Aside", "Google Chrome"]' >/dev/null
"$CLI" --root "$TEST_ROOT" websites 2026-08-27 --limit 1 --offset 1 \
  | jq -e '.offset == 1 and .nextOffset == null and .websites[0].host == "chatgpt.com" and .websites[0].foregroundSeconds == 30' >/dev/null
"$CLI" --root "$TEST_ROOT" websites 2026-08-28 \
  | jq -e '.status.kind == "noSourceForDay" and .websites == []' >/dev/null
if "$CLI" --root "$TEST_ROOT" websites 2026-08-27 --limit 1001 >/dev/null 2>&1; then
  echo "Goalong CLI accepted an out-of-range website limit." >&2
  exit 1
fi
"$CLI" --root "$TEST_ROOT" ai-conversations 2026-08-27 \
  | jq -e '.status == "consentRequired" and .conversations == [] and .candidateOffset == 0 and .nextCandidateOffset == null and .visitedConversationCandidateCount == 0 and .returnedConversationCount == 0 and .noVisibleMessageCandidateCount == 0 and .outputDroppedConversationCount == 0' >/dev/null
"$CLI" --root "$TEST_ROOT" ai-conversations 2026-08-27 --offset 24 \
  | jq -e '.status == "consentRequired" and .candidateOffset == 24 and .nextCandidateOffset == null' >/dev/null
if "$CLI" --root "$TEST_ROOT" ai-conversations 2026-08-27 --offset 50001 >/dev/null 2>&1; then
  echo "Goalong CLI accepted an out-of-range AI conversation offset." >&2
  exit 1
fi
"$CLI" verify-share "$TEST_ROOT/invalid-share.json" \
  | jq -e '.status == "inaccessibleOrInvalid" and .report == null and (.error | type == "string")' >/dev/null
after="$(find "$TEST_ROOT" -type f -exec shasum -a 256 {} \; | sort)"
[[ "$before" == "$after" ]]

echo "Goalong CLI tests passed: lightweight status, day discovery, recap integrity states, offline recap/share verification, fail-closed Screen Time access without the consented app broker, ranked daily websites, default-off AI consent, and zero source writes."
