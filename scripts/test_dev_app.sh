#!/bin/bash
# Goalong Dev control without building or launching anything: argument refusals, data modes
# (clone excludes stakes, sockets and identities; never writes the real folder), BLOCKING=copy.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
WORK="$(mktemp -d /tmp/goalong-dev-test-XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
CONTROL="$WORK/dev-app-control"
xcrun swiftc "$ROOT/scripts/dev_app.swift" -o "$CONTROL"
fail() { echo "FAIL: $*" >&2; exit 1; }

# Removed and unknown settings are refused before any build, data or process step
# (a throwaway HOME, in case a refusal ever regresses).
export HOME="$WORK/home"; mkdir -p "$HOME"
for setting in DATA=real DATA=isolated DATA=bogus BLOCKING=real SERVER=yes NO_LAUNCH=2; do
  if env "$setting" "$ROOT/scripts/dev_app.sh" dev >"$WORK/out" 2>&1; then fail "$setting accepted"; fi
done
DATA=real "$ROOT/scripts/dev_app.sh" dev >"$WORK/out" 2>&1 || true
grep -q 'no longer exists' "$WORK/out" || fail 'DATA=real message'
if DEV_APP_DIR=relative "$ROOT/scripts/dev_app.sh" dev >/dev/null 2>&1; then fail 'relative DEV_APP_DIR accepted'; fi

BASE="$WORK/Application Support"
REAL="$BASE/LocalHistory" DEV="$BASE/LocalHistory-Dev"
mkdir -p "$REAL/events" "$REAL/Blocking" "$REAL/Focus/status" "$REAL/runtime" "$REAL/app-backups" \
  "$REAL/website-connections" "$REAL/jev" "$REAL/chatgpt/codex-home" "$REAL/chatgpt/history"
echo event >"$REAL/events/a.jsonl"; echo key >"$REAL/device-signing-key-v2.bin"
echo token >"$REAL/website-connections/x.token"; echo secret >"$REAL/jev/api-key"; echo ctx >"$REAL/jev/work-context.json"
echo auth >"$REAL/chatgpt/codex-home/auth.json"; echo h >"$REAL/chatgpt/history/h.json"
echo '{}' >"$REAL/blocking-backup-1.json"; echo '{}' >"$REAL/Focus/prompts.json"
cat >"$REAL/Blocking/blocking.json" <<'JSON'
{"version":1,"lists":[{"id":"L","name":"n","mode":"block","sites":[],"apps":[],
 "program":{"lockedUntil":"2030-01-01T00:00:00Z","ranges":[{"id":"R","weekdays":[1],"startMinute":0,"endMinute":60,"lock":{"kind":"strict"}}]}}],
 "sessions":[{"id":"S"}],"freeze":{"x":1},"passwordLock":{"hash":"h"},"heldPrograms":[]}
JSON
BEFORE="$(cd "$REAL" && find . -print0 | xargs -0 stat -f '%N %m %z' | sort | shasum)"

# Only LocalHistory -> sibling LocalHistory-Dev is accepted.
if "$CONTROL" seed-data clone "$REAL" "$BASE/Other" >/dev/null 2>&1; then fail 'bad dev path accepted'; fi
if "$CONTROL" seed-data clone "$DEV" "$REAL" >/dev/null 2>&1; then fail 'swapped paths accepted'; fi

"$CONTROL" seed-data clone "$REAL" "$DEV" >/dev/null
[[ -f "$DEV/events/a.jsonl" && -f "$DEV/jev/work-context.json" && -f "$DEV/chatgpt/history/h.json" ]] || fail 'clone missed data'
for absent in Blocking Focus runtime app-backups website-connections device-signing-key-v2.bin \
              blocking-backup-1.json jev/api-key chatgpt/codex-home; do
  [[ ! -e "$DEV/$absent" ]] || fail "clone copied $absent"
done
[[ "$(stat -f %Lp "$DEV")" == 700 ]] || fail 'dev folder mode'

echo dev-only >"$DEV/dev-state"
"$CONTROL" seed-data keep "$REAL" "$DEV" >/dev/null
[[ -f "$DEV/dev-state" ]] || fail 'keep lost the dev state'
"$CONTROL" seed-data fresh "$REAL" "$DEV" >/dev/null
[[ -z "$(ls -A "$DEV")" ]] || fail 'fresh is not empty'
rm -rf "$DEV"; "$CONTROL" seed-data keep "$REAL" "$DEV" >/dev/null
[[ -f "$DEV/events/a.jsonl" ]] || fail 'keep without dev data must clone'

"$CONTROL" copy-blocking "$REAL" "$DEV" >/dev/null
python3 - "$DEV/Blocking/blocking.json" <<'PY' || fail 'BLOCKING=copy kept a lock'
import json, sys
d = json.load(open(sys.argv[1]))
assert set(d) == {"version", "lists", "sessions"} and d["sessions"] == [], d
program = d["lists"][0]["program"]
assert "lockedUntil" not in program and all("lock" not in r for r in program["ranges"]), program
assert d["lists"][0]["name"] == "n"
PY
[[ ! -e "$DEV/Focus" ]] || fail 'BLOCKING=copy created Focus'

AFTER="$(cd "$REAL" && find . -print0 | xargs -0 stat -f '%N %m %z' | sort | shasum)"
[[ "$BEFORE" == "$AFTER" ]] || fail 'the real data folder changed'
echo 'Goalong Dev control tests passed.'
