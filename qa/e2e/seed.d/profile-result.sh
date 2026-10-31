#!/usr/bin/env bash
# seed:profile-result (J-0526): one saved profile analysis the studio can reopen. Env: DATA. Throwaway CI runner only.
# The studio does NOT load it at open (GoalongProfileStudio.swift:61 load() builds a request from the history; :145 open(url) is the only reader, via
# openSaved() :302 « Ouvrir une analyse… », NSOpenPanel with directory = chatgpt/profile-analyses, :461). The seed only guarantees the file exists.
set -u
RID="7e046000-0000-4000-8000-000000000526"
DIR="$DATA/chatgpt/profile-analyses"; F="$DIR/$RID.analysis.json"
case "${1:-}" in
  seed)
    # AppPaths.chatGPTDirectory = DATA/chatgpt (AppPaths.swift:~96); save() writes there, 0600 files, 0700 dirs (GoalongProfileStudio.swift:135-141)
    [[ -d "$DATA/chatgpt" ]] || touch "$DATA/.t046-profile-result-made-chatgpt"
    mkdir -p "$DIR"; chmod 700 "$DATA/chatgpt" "$DIR"
    # Archive = {request, result} (parseArchive, GoalongProfileStudio.swift:148); schema goalong.profile-analysis.v2; evidence_digest = sha256(context_json)
    # (same JSON as qa/e2e/seed_analysis.py; apply() at :151 re-checks the digest, so python3 computes it)
    python3 - "$F" <<'PY' || exit 1
import json, hashlib, sys, datetime
day = (datetime.date.today() - datetime.timedelta(days=1)).isoformat(); rid = "7e046000-0000-4000-8000-000000000526"
ctx = {"include_conversations": False, "date": day, "timezone": "Europe/Paris", "modules": ["projects"], "instructions": "",
  "evidence": [{"id": "e1", "kind": "observation", "start": day+"T09:00:00Z", "end": day+"T10:00:00Z", "text": "Projet T-046 : une heure de travail dans l'éditeur."}]}
cj = json.dumps(ctx, ensure_ascii=False, separators=(",", ":"), sort_keys=True)
arc = {"request": {"schema": "goalong.profile-analysis.v2", "request_id": rid, "policy": {"excluded_terms": [], "replacements": [], "additional_instructions": ""}, "context_json": cj},
  "result": {"request_id": rid, "evidence_digest": hashlib.sha256(cj.encode()).hexdigest(),
    "items": [{"id": "i1", "module": "projects", "title": "Projet T-046 avancé", "summary": "Une heure de travail sur le projet T-046.", "status": "observed", "caveat": "", "evidence_refs": ["e1"]}]}}
with open(sys.argv[1], "w") as f: json.dump(arc, f, ensure_ascii=False)
PY
    chmod 600 "$F"; exit 0 ;;
  unseed)
    rm -f "$F"; rmdir "$DIR" 2>/dev/null
    if [[ -e "$DATA/.t046-profile-result-made-chatgpt" ]]; then rmdir "$DATA/chatgpt" 2>/dev/null; rm -f "$DATA/.t046-profile-result-made-chatgpt"; fi
    exit 0 ;;
  *) echo "usage: $0 seed|unseed" >&2; exit 2 ;;
esac
