#!/usr/bin/env bash
# seed:bg-devproject (J-0552): developer project tracked (« Suivi des fichiers développeur »). Env: DATA. Exit 3 = projects/consent read at launch. Throwaway CI runner only.
set -u
C="$DATA/capability-consent.json"; BAK="$DATA/.t046-devproject-consent.bak"; NONE="$DATA/.t046-devproject-consent.none"
P="$DATA/developer-projects.json"; PBAK="$DATA/.t046-devproject-projects.bak"; PNONE="$DATA/.t046-devproject-projects.none"
PROJ="$DATA/t046-devproject"
case "${1:-}" in
  seed)
    # Consent GoalongCapability.developerActivity (CapabilityConsentStore.swift:10), file AppPaths.swift:109; same doc shape as seed screentime-on (:42-47).
    # GoalongDeveloperRuntime.refresh (GoalongDeveloperRuntime.swift:41-48) starts the watcher only when isEnabled(.developerActivity) and not paused; created at AppDelegate.swift:239.
    # Projects: DATA/developer-projects.json {version:1,projects:[{id,name,rootPath,watchRootPaths?}]} (GoalongDeveloperStore.swift:39-45): id = SHA-256 hex of the
    # canonical root path (GoalongDeveloperModels.swift:41-43), rootPath absolute; the git check is in add() :51 only, but a real repo (git init) keeps the data honest.
    # FSEventStreamCreate on observationRoots (GoalongDeveloperFileMonitor.swift:76) with since = current event id when no cursor (:64): no replay, so edits are seen only after launch.
    if [[ -e "$C" ]]; then cp -p "$C" "$BAK"; else : > "$NONE"; fi
    if [[ -e "$P" ]]; then cp -p "$P" "$PBAK"; else : > "$PNONE"; fi
    mkdir -p "$PROJ"; git -C "$PROJ" init -q 2>/dev/null; echo "t046" > "$PROJ/README.md"
    chflags nouchg "$C" 2>/dev/null
    python3 - "$C" "$P" "$PROJ" <<'PY' || exit 1
import json, sys, os, hashlib
c, p, proj = sys.argv[1:4]
root = os.path.realpath(proj)
try: d = json.load(open(c))
except Exception: d = {}
d["schemaVersion"] = 1; d["policyVersion"] = 1; d.setdefault("capabilities", {})
d["capabilities"]["developerActivity"] = {"enabled": True, "surface": "settings"}
with open(c, "w") as f: json.dump(d, f)
os.chmod(c, 0o600)
proj_doc = {"version": 1, "projects": [{"id": hashlib.sha256(root.encode()).hexdigest(), "name": "t046-devproject", "rootPath": root}]}
with open(p, "w") as f: json.dump(proj_doc, f)
os.chmod(p, 0o600)
PY
    exit 3 ;;
  unseed)
    # Restore (or remove) consent and projects file, remove the repo and the cursor/journal the watcher wrote for it (developer-cursor.json, GoalongDeveloperStore.swift:76).
    if [[ -e "$BAK" ]]; then mv -f "$BAK" "$C"; elif [[ -e "$NONE" ]]; then rm -f "$C" "$NONE"; fi
    if [[ -e "$PBAK" ]]; then mv -f "$PBAK" "$P"; elif [[ -e "$PNONE" ]]; then rm -f "$P" "$PNONE" "$DATA/developer-cursor.json"; fi
    rm -rf "$PROJ"
    exit 0 ;;
  *) echo "usage: $0 seed|unseed" >&2; exit 2 ;;
esac
