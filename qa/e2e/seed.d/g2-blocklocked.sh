#!/bin/bash
# G2 (J-0390 J-0391): the menu-bar panel lists a LOCKED block list (button « Arrêter… ») and a free one (switch « Bloquer … »).
# Disposable runner only. Sources: MenuBarPanelView.swift:655-667 (row), MenuBarPanelModel.swift:386-397 (locked = controller.isStricterOnly),
# BlockingController.swift:1412 (a session with lock != free on the list), BlockingStore.swift:17 (Blocking/blocking.json, read once at launch),
# BlockingModel.swift:105-113 + seed_blocking.py (document format, dates = seconds since 2001-01-01), GoalongModules.swift:13 (module key).
# Exit 3: the app is stopped here (it would rewrite blocking.json on quit) and restarted by the shard.
set -u
B="$DATA/Blocking"; BAK="$DATA/.g2-blocklocked-bak"; K="goalong.module.blocking.enabled"
stop_app() { pkill -KILL -x "Goalong History Dev" 2>/dev/null; sleep 2; defaults write "$BUNDLE" goalong.runtime.sessionOpen.v1 -bool false; }  # BackgroundContinuityPolicy.swift:62 (no « arrêt non propre » banner)
case "${1:-}" in
seed)
  stop_app
  [[ -e $BAK ]] || { mkdir -p "$BAK"; [[ -d $B ]] && cp -Rp "$B" "$BAK/Blocking"; defaults read "$BUNDLE" "$K" > "$BAK/module" 2>/dev/null || echo none > "$BAK/module"; }
  rm -rf "$B"; mkdir -p "$B"; chmod 700 "$B"
  python3 -I - "$B" <<'PY' || exit 1
import json,os,sys,uuid,time
d=sys.argv[1]; R=978307200; now=time.time()-R; H=3600
u=lambda:str(uuid.uuid4()).upper()
L,F=u(),u()
lists=[{"id":L,"name":"T046 Verrouillée","mode":"block","sites":[{"pattern":"t046-g2-locked.example"}],"apps":[],"program":{"ranges":[]}},
       {"id":F,"name":"T046 Libre","mode":"block","sites":[{"pattern":"t046-g2-free.example"}],"apps":[],"program":{"ranges":[]}}]
sessions=[{"id":u(),"listIDs":[L],"start":now-60,"end":now+8*H,"lock":"typing","origin":{"manual":{}}}]
p=os.path.join(d,"blocking.json"); open(p,"w").write(json.dumps({"version":1,"lists":lists,"sessions":sessions})); os.chmod(p,0o600)
PY
  defaults write "$BUNDLE" "$K" -bool true
  exit 3 ;;
unseed)
  stop_app
  rm -rf "$B"; [[ -d $BAK/Blocking ]] && cp -Rp "$BAK/Blocking" "$B"
  if [[ "$(cat "$BAK/module" 2>/dev/null)" == none ]]; then defaults delete "$BUNDLE" "$K" 2>/dev/null; else defaults write "$BUNDLE" "$K" -bool "$( [[ "$(cat "$BAK/module" 2>/dev/null)" == 1 ]] && echo true || echo false)"; fi
  rm -rf "$BAK"; exit 3 ;;
*) exit 2 ;;
esac
