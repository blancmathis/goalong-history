#!/bin/bash
# G2 (J-0981 J-0982): quit while a « Mot de passe » block runs asks for the password (no Cmd-Q needed: the shard drives the menu).
# BlockingController.swift:241 (quitIsLocked), :917-920 (quitRequiresPassword); AppDelegate.swift:505-555 (quit alerts).
# Format: BlockingModel.swift:89-95 (lock = password), :138-160 (passwordLock), BlockingPassword.swift:6-60 (PBKDF2-HMAC-SHA256, 200000 it, salt 16, hash 32).
# Password used by the row: t046-g2-pw. Dates = seconds since 2001-01-01. Exit 3: blocking is read once at launch.
set -u
stop_app() { pkill -KILL -x "Goalong History Dev" 2>/dev/null; sleep 2; defaults write "$BUNDLE" goalong.runtime.sessionOpen.v1 -bool false; }  # BackgroundContinuityPolicy.swift:62 (no « arrêt non propre » banner)
# bak FILE...: copy each file (or marker .absent) into $BAK once; rest FILE...: put it back.
bak() { mkdir -p "$BAK"; for f in "$@"; do n=$(echo "$f" | tr / _); [[ -e $BAK/$n || -e $BAK/$n.absent ]] && continue; [[ -e $DATA/$f ]] && { mkdir -p "$BAK/$(dirname "$n")"; cp -p "$DATA/$f" "$BAK/$n"; } || : > "$BAK/$n.absent"; done; }
rest() { for f in "$@"; do n=$(echo "$f" | tr / _); if [[ -e $BAK/$n ]]; then mkdir -p "$DATA/$(dirname "$f")"; cp -p "$BAK/$n" "$DATA/$f"; else rm -f "$DATA/$f"; fi; done; }
BAK="$DATA/.g2-blockpw-bak"; B="$DATA/Blocking"; K="goalong.module.blocking.enabled"
case "${1:-}" in
seed)
  stop_app
  [[ -e $BAK ]] || { mkdir -p "$BAK"; [[ -d $B ]] && cp -Rp "$B" "$BAK/Blocking"; defaults read "$BUNDLE" "$K" > "$BAK/module" 2>/dev/null || echo none > "$BAK/module"; }
  rm -rf "$B"; mkdir -p "$B"; chmod 700 "$B"
  python3 -I - "$B" <<'PY' || exit 1
import json,os,sys,uuid,time,hashlib,base64
d=sys.argv[1]; R=978307200; now=time.time()-R; H=3600
u=lambda:str(uuid.uuid4()).upper()
salt=os.urandom(16); h=hashlib.pbkdf2_hmac("sha256",b"t046-g2-pw",salt,200000,32)
L=u()
lists=[{"id":L,"name":"T046 Mot de passe","mode":"block","sites":[{"pattern":"t046-g2-pw.example"}],"apps":[],"program":{"ranges":[]}}]
sessions=[{"id":u(),"listIDs":[L],"start":now-60,"end":now+8*H,"lock":"password","origin":{"manual":{}}}]
pl={"salt":base64.b64encode(salt).decode(),"hash":base64.b64encode(h).decode(),"iterations":200000,"createdAt":now-H,"failedAttempts":0}
p=os.path.join(d,"blocking.json"); open(p,"w").write(json.dumps({"version":1,"lists":lists,"sessions":sessions,"passwordLock":pl})); os.chmod(p,0o600)
PY
  defaults write "$BUNDLE" "$K" -bool true; exit 3 ;;
unseed)
  stop_app; rm -rf "$B"; [[ -d $BAK/Blocking ]] && cp -Rp "$BAK/Blocking" "$B"
  m=$(cat "$BAK/module" 2>/dev/null); if [[ $m == none || -z $m ]]; then defaults delete "$BUNDLE" "$K" 2>/dev/null; else defaults write "$BUNDLE" "$K" -bool "$([[ $m == 1 ]] && echo true || echo false)"; fi
  rm -rf "$BAK"; exit 3 ;;
*) exit 2 ;;
esac
