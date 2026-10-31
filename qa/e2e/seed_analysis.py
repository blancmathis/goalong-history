#!/usr/bin/env python3
# L3k: a valid saved profile analysis (J-0526 and the Activité cards). Usage: seed_analysis.py DATA_DIR [YYYY-MM-DD]
import json, hashlib, os, sys
data = sys.argv[1]; day = sys.argv[2] if len(sys.argv) > 2 else "2026-10-30"
rid = "7e046000-0000-4000-8000-000000000526"
ctx = {"include_conversations": False, "date": day, "timezone": "Europe/Paris",
  "modules": ["projects"], "instructions": "",
  "evidence": [{"id": "e1", "kind": "observation", "start": day+"T09:00:00Z", "end": day+"T10:00:00Z",
                "text": "Projet T-046 : une heure de travail dans l'éditeur."}]}
cj = json.dumps(ctx, ensure_ascii=False, separators=(",", ":"), sort_keys=True)
arc = {"request": {"schema": "goalong.profile-analysis.v2", "request_id": rid,
         "policy": {"excluded_terms": [], "replacements": [], "additional_instructions": ""},
         "context_json": cj},
       "result": {"request_id": rid, "evidence_digest": hashlib.sha256(cj.encode()).hexdigest(),
         "items": [{"id": "i1", "module": "projects", "title": "Projet T-046 avancé",
                    "summary": "Une heure de travail sur le projet T-046.", "status": "observed",
                    "caveat": "", "evidence_refs": ["e1"]}]}}
d = os.path.join(data, "chatgpt", "profile-analyses"); os.makedirs(d, mode=0o700, exist_ok=True)
os.chmod(os.path.join(data, "chatgpt"), 0o700); os.chmod(d, 0o700)
p = os.path.join(d, rid + ".analysis.json")
with open(p, "w") as f: json.dump(arc, f, ensure_ascii=False)
os.chmod(p, 0o600); print(p)
