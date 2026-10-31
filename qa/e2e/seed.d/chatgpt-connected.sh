#!/usr/bin/env bash
# seed:chatgpt-connected (J-0521 J-0786): « Connecter ChatGPT » succeeds, then « Déconnecter ChatGPT » shows. Env: HOME DATA. Exit 3 = consent is read at launch.
# The nav must still click « Connecter ChatGPT » once: `connected` is in-memory only (GoalongSiteAnalysisSheet.swift:13,103). Throwaway CI runner only.
set -u
C="$DATA/capability-consent.json"; BAK="$DATA/.t046-chatgpt-consent.bak"; NONE="$DATA/.t046-chatgpt-consent.none"
X="$HOME/.local/bin/codex"; XBAK="$X.t046.bak"; XNONE="$X.t046.none"
case "${1:-}" in
  seed)
    # 1. Consent « Autoriser les analyses »: connect() refuses without it (GoalongSiteAnalysisSheet.swift:77, consent closure :27); file AppPaths.swift:109,
    #    key chatGPTAnalysis (CapabilityConsentStore.swift:11), doc {schemaVersion, policyVersion, capabilities} (:42-47), read once at launch (:107) -> exit 3.
    if [[ -e "$C" ]]; then cp -p "$C" "$BAK"; else : > "$NONE"; fi
    chflags nouchg "$C" 2>/dev/null
    mkdir -p "$DATA" && python3 - "$C" <<'PY' || exit 1
import json, sys, os
p = sys.argv[1]
try: d = json.load(open(p))
except Exception: d = {}
d["schemaVersion"] = 1; d["policyVersion"] = 1; d.setdefault("capabilities", {})
d["capabilities"]["chatGPTAnalysis"] = {"enabled": True, "surface": "settings"}
with open(p, "w") as f: json.dump(d, f)
os.chmod(p, 0o600)
PY
    # 2. Fake Codex: CodexExecutableLocator.locate() tries $HOME/.local/bin/codex (ChatGPT/CodexAppServerClient.swift:695) after the bundle; the session runs
    #    `codex app-server` (:785), JSONL on stdio (framing :153-168, :313). Handshake: initialize -> {codexHome} (:834-858, must equal
    #    $CODEX_HOME = <DATA>/chatgpt/site-analysis-codex-home, set :1685), notification `initialized` (:862), account/read -> {account:{type:chatgpt,planType}} (:877-895),
    #    account/logout -> {} (:939). Anything else (thread/start, login) -> JSON-RPC error: no analysis is possible.
    mkdir -p "$HOME/.local/bin"
    if [[ -e "$X" || -L "$X" ]]; then mv -f "$X" "$XBAK"; else : > "$XNONE"; fi
    cat > "$X" <<'PYEOF'
#!/usr/bin/env python3
import json, os, sys
if sys.argv[1:2] != ["app-server"]: sys.exit(2)
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    try: m = json.loads(line)
    except Exception: continue
    if "id" not in m: continue  # `initialized` and other notifications: no reply
    meth, r = m.get("method"), {"jsonrpc": "2.0", "id": m["id"]}
    if meth == "initialize": r["result"] = {"userAgent": "codex/t046-fake", "codexHome": os.environ.get("CODEX_HOME", "")}
    elif meth == "account/read": r["result"] = {"account": {"type": "chatgpt", "email": "t046@example.com", "planType": "plus"}, "requiresOpenaiAuth": False}
    elif meth == "account/logout": r["result"] = {}
    else: r["error"] = {"code": -32601, "message": "t046 fake codex: unsupported " + str(meth)}
    sys.stdout.write(json.dumps(r) + "\n"); sys.stdout.flush()
PYEOF
    chmod 755 "$X"
    exit 3 ;;
  unseed)
    # Put consent and the previous codex back (or remove ours).
    if [[ -e "$BAK" ]]; then mv -f "$BAK" "$C"; elif [[ -e "$NONE" ]]; then rm -f "$C" "$NONE"; fi
    if [[ -e "$XBAK" || -L "$XBAK" ]]; then mv -f "$XBAK" "$X"; elif [[ -e "$XNONE" ]]; then rm -f "$X" "$XNONE"; fi
    exit 0 ;;
  *) echo "usage: $0 seed|unseed" >&2; exit 2 ;;
esac
