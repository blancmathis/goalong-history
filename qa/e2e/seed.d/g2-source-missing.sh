#!/bin/bash
# G2 (J-0803): « Source introuvable » alert when the AI-conversations source folder is missing.
# SourceActivation.swift:127-139 (aiConversations consent on + watched folders checked), :355-370 (alert).
# Formats: Features/AgentActivity/Sources/Models.swift:71-154 (AgentWatchedFolder, AgentActivityConfiguration, id = agent-source-<sha256("provider\0path")[:24]>),
# CapabilityConsentStore.swift (capability-consent.json). Exit 3: configuration is read at launch.
set -u
stop_app() { pkill -KILL -x "Goalong History Dev" 2>/dev/null; sleep 2; defaults write "$BUNDLE" goalong.runtime.sessionOpen.v1 -bool false; }  # BackgroundContinuityPolicy.swift:62 (no « arrêt non propre » banner)
# bak FILE...: copy each file (or marker .absent) into $BAK once; rest FILE...: put it back.
bak() { mkdir -p "$BAK"; for f in "$@"; do n=$(echo "$f" | tr / _); [[ -e $BAK/$n || -e $BAK/$n.absent ]] && continue; [[ -e $DATA/$f ]] && { mkdir -p "$BAK/$(dirname "$n")"; cp -p "$DATA/$f" "$BAK/$n"; } || : > "$BAK/$n.absent"; done; }
rest() { for f in "$@"; do n=$(echo "$f" | tr / _); if [[ -e $BAK/$n ]]; then mkdir -p "$DATA/$(dirname "$f")"; cp -p "$BAK/$n" "$DATA/$f"; else rm -f "$DATA/$f"; fi; done; }
BAK="$DATA/.g2-source-missing-bak"; C=agent-activity-v2/configuration.json; K=capability-consent.json
case "${1:-}" in
seed)
  stop_app; bak "$C" "$K"; mkdir -p "$DATA/agent-activity-v2"
  python3 -I - "$DATA" <<'PY' || exit 1
import json,os,sys,hashlib,datetime
d=sys.argv[1]; R=978307200; p="/nonexistent-t046-g2/claude-projects"
fid="agent-source-"+hashlib.sha256(("claudeCode\0"+p).encode()).hexdigest()[:24]
iso=datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
cfg={"schemaVersion":2,"watchedFolders":[{"id":fid,"displayName":"Claude Code (T046)","path":p,"provider":"claudeCode","isEnabled":True,"includeSubdirectories":True,"captureMode":"transcriptsAndLogs","isManaged":False,"addedAt":iso}],"discoveryTombstones":[],"scanIntervalSeconds":30,"fullDiscoveryIntervalSeconds":86400,"maximumFileBytes":268435456,"maximumIndexEntries":10000}
open(os.path.join(d,"agent-activity-v2/configuration.json"),"w").write(json.dumps(cfg)); os.chmod(os.path.join(d,"agent-activity-v2/configuration.json"),0o600)
cp=os.path.join(d,"capability-consent.json")
try: doc=json.load(open(cp))
except Exception: doc={"schemaVersion":1,"policyVersion":1,"capabilities":{}}
doc.setdefault("capabilities",{})["aiConversations"]={"enabled":True,"changedAt":datetime.datetime.now().timestamp()-R,"surface":"t046"}
open(cp,"w").write(json.dumps(doc)); os.chmod(cp,0o600)
PY
  exit 3 ;;
unseed) stop_app; rest "$C" "$K"; rm -rf "$BAK"; exit 3 ;;
*) exit 2 ;;
esac
