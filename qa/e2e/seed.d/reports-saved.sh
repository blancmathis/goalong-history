#!/usr/bin/env bash
# seed:reports-saved (J-0460 J-0461): saved daily reports (« Rubrique » picker, « Ouvrir le bilan et ses sources »). Env: DATA. Exit 0. Throwaway CI runner only.
set -u
DIR="$DATA/chatgpt/recaps"; MARK="$DATA/.t046-reports-saved-made-chatgpt"
case "${1:-}" in
  seed)
    # Cards = files DATA/chatgpt/recaps/<yyyy-MM-dd>.chatgpt-recap.json (GoalongAnalyticsModel.swift:230, ChatGPTRecapPersistence.jsonURL ChatGPTRecapRuntime.swift:371),
    # read per displayed day, no cache of the folder (:236-240). Any card makes the « Rubrique » picker show (GoalongActivityContent.swift:684 payload.cards non-empty);
    # a module "dailyRecap" card gives « Ouvrir le bilan et ses sources » inside its disclosure (:701).
    # load() (ChatGPTRecapRuntime.swift:330-348): schemaVersion 1 only needs markdown <= legacy limit (:343), no attestation, so the file is a plain ChatGPTDailyRecap
    # (:120-135, Codable, dates iso8601, sourceCounts :ChatGPTRecapContext.swift:8, optional fields may be missing). day must equal the file day at local midnight (:241).
    [[ -d "$DATA/chatgpt" ]] || touch "$MARK"
    mkdir -p "$DIR"; chmod 700 "$DATA/chatgpt" "$DIR"
    python3 - "$DIR" <<'PY' || exit 1
import json, sys, datetime, os
for back in (1, 2):
    d = datetime.date.today() - datetime.timedelta(days=back)
    mid = datetime.datetime(d.year, d.month, d.day).astimezone()  # local midnight
    utc = mid.astimezone(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    zero = dict(localEvents=12, activeMinutes=95, semanticSnapshots=0, screenTimeDevices=0, screenTimeApplications=0, agentCaptures=0,
                agentMessages=0, visibleAgentMessages=0, agentToolCalls=0, agentErrors=0, analyzedAgentCaptures=0, importedChatMessages=0)
    rec = {"schemaVersion": 1, "day": utc, "generatedAt": utc, "provider": "codex_app_server_chatgpt", "contextDigest": "t046" + d.isoformat(),
           "sourceCounts": zero, "markdown": "Journée consacrée au projet T-046 (bilan de test du %s)." % d.isoformat()}
    p = os.path.join(sys.argv[1], d.isoformat() + ".chatgpt-recap.json")
    with open(p, "w") as f: json.dump(rec, f, ensure_ascii=False)
    os.chmod(p, 0o600)
PY
    exit 0 ;;
  unseed)
    # Remove only our files (the .md mirror may be written by « Ouvrir le bilan… », ChatGPTRecapRuntime.swift:361), then empty dirs we made.
    rm -f "$DIR"/*.chatgpt-recap.json "$DIR"/*.chatgpt-recap.md; rmdir "$DIR" 2>/dev/null
    if [[ -e "$MARK" ]]; then rmdir "$DATA/chatgpt" 2>/dev/null; rm -f "$MARK"; fi
    exit 0 ;;
  *) echo "usage: $0 seed|unseed" >&2; exit 2 ;;
esac
