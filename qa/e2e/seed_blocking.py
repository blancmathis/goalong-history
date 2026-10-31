#!/usr/bin/env python3
# L3k: Blocage seed (class C, lot 3). Written BEFORE the Blocking module is switched on: the app replaces a file
# changed while it runs. Fake sites only. One always-on program range (active block, Arrêter, breaks), an active and a
# scheduled "typing" session, a slow-down list; a damaged blocking.json with a good .previous gives the recovery
# banner (J-0089). No password: the create-password rows set it. Usage: seed_blocking.py DATA_DIR
import json,os,sys,uuid,time
d=os.path.join(sys.argv[1],"Blocking"); os.makedirs(d,mode=0o700,exist_ok=True); os.chmod(d,0o700)
R=978307200; now=time.time()-R; H=3600
def u(): return str(uuid.uuid4()).upper()
A,B2,C2=u(),u(),u()
rng=lambda: {"id":u(),"weekdays":[1,2,3,4,5,6,7],"startMinute":0,"endMinute":1440,"lock":"free"}
lists=[
 {"id":A,"name":"T046 Réseaux","mode":"block","sites":[{"pattern":"t046-social.example"}],"apps":[],
  "program":{"ranges":[rng()]},"breaks":{"count":2,"minutes":5},"quotaMinutesPerDay":60},
 {"id":B2,"name":"T046 Vidéo","mode":"block","sites":[{"pattern":"t046-video.example"}],"apps":[],"program":{"ranges":[]}},
 {"id":C2,"name":"T046 Ralentir","mode":"block","sites":[{"pattern":"t046-slow.example"}],"apps":[],"program":{"ranges":[]},
  "action":"slowDown","slowDownSeconds":5,"continueMinutes":2},
]
sessions=[
 {"id":u(),"listIDs":[B2],"start":now-60,"end":now+8*H,"lock":"typing","origin":{"manual":{}}},          # BL-TYPING (active)
 {"id":u(),"listIDs":[B2],"start":now+6*H,"end":now+7*H,"lock":"typing","origin":{"manual":{}}},         # BL-SCHED typing
]
doc={"version":1,"lists":lists,"sessions":sessions}
p=os.path.join(d,"blocking.json"); open(p,"w").write(json.dumps(doc)); os.chmod(p,0o600)
# BL-ERR: same good document as the backup, damaged current file -> recovery .previous shows the error banner
q=os.path.join(d,"blocking.previous.json"); open(q,"w").write(json.dumps(doc)); os.chmod(q,0o600)
open(p,"w").write("{damaged"); os.chmod(p,0o600)
