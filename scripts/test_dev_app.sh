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

# Removed and unknown settings are refused with exit 2 and their own message, before any build, data
# or process step. GOALONG_DEV_VALIDATE_ONLY stops an accepted run right after the checks, so a
# regressed refusal can never build, quit the owner's Goalong Dev or install anything.
export HOME="$WORK/home"; mkdir -p "$HOME"
export GOALONG_DEV_VALIDATE_ONLY=1 GOALONG_DEV_RELEASE_APP="$WORK/none.app"
expect_refusal() { # message, then VAR=value settings
  local message="$1" status=0; shift
  env "$@" "$ROOT/scripts/dev_app.sh" dev >"$WORK/out" 2>&1 || status=$?
  [[ "$status" == 2 ]] || fail "$* exited $status, expected 2: $(cat "$WORK/out")"
  grep -qF -- "$message" "$WORK/out" || fail "$* message: $(cat "$WORK/out")"
}
expect_refusal 'DATA=real no longer exists' GOALONG_DEV_DATA=real
expect_refusal 'DATA=isolated no longer exists' GOALONG_DEV_DATA=isolated
expect_refusal 'DATA must be clone, keep or fresh.' GOALONG_DEV_DATA=bogus
expect_refusal 'BLOCKING must be empty or copy.' GOALONG_DEV_BLOCKING=real
expect_refusal 'SERVER must be off or on.' GOALONG_DEV_SERVER=yes
expect_refusal 'NO_LAUNCH must be 0 or 1.' GOALONG_DEV_NO_LAUNCH=2
expect_refusal 'DATA and BLOCKING are refused with it' GOALONG_DEV_NO_LAUNCH=1 GOALONG_DEV_DATA=fresh
expect_refusal 'DATA and BLOCKING are refused with it' GOALONG_DEV_NO_LAUNCH=1 GOALONG_DEV_BLOCKING=copy
expect_refusal 'DEV_APP_DIR must be absolute.' GOALONG_DEV_APP_DIR=relative
expect_refusal 'never goes into /Applications' GOALONG_DEV_APP_DIR=/Applications
expect_refusal 'never goes into /Applications' "GOALONG_DEV_APP_DIR=/Applications/Goalong History.app/Contents"
expect_refusal 'never goes into /System' GOALONG_DEV_APP_DIR=/System/Applications
expect_refusal 'never goes inside an app bundle' "GOALONG_DEV_APP_DIR=$WORK/Other.app/Contents"
[[ ! -e "$WORK/Other.app" ]] || fail 'a refused DEV_APP_DIR was created'
# Accepted settings stop right after the checks.
"$ROOT/scripts/dev_app.sh" dev >"$WORK/out" 2>&1 || fail "defaults refused: $(cat "$WORK/out")"
grep -qF 'Settings accepted: data clone, blocking empty, server off, no launch 0' "$WORK/out" || fail 'defaults'
GOALONG_DEV_NO_LAUNCH=1 GOALONG_DEV_APP_DIR="$WORK/apps" "$ROOT/scripts/dev_app.sh" dev >"$WORK/out" 2>&1 || fail 'NO_LAUNCH refused'
[[ ! -e "$WORK/apps" ]] || fail 'validation created DEV_APP_DIR'
# make reads the settings from its command line only: a shell-wide DATA never reaches the script.
DATA=bogus SERVER=on make -s -n -C "$ROOT" dev-status >"$WORK/out"
grep -qF 'GOALONG_DEV_DATA="" ' "$WORK/out" && grep -qF 'GOALONG_DEV_SERVER="" ' "$WORK/out" || fail "environment leaked into make dev: $(cat "$WORK/out")"
make -s -n -C "$ROOT" dev DATA=keep NO_LAUNCH=1 DEV_APP_DIR=/private/tmp/x >"$WORK/out"
grep -qF 'GOALONG_DEV_DATA="keep"' "$WORK/out" && grep -qF 'GOALONG_DEV_APP_DIR="/private/tmp/x"' "$WORK/out" || fail 'make command line lost'
# A release that predates Goalong Dev is reported (it records and may block Goalong Dev).
OLD_RELEASE="$WORK/Release.app"; mkdir -p "$OLD_RELEASE/Contents/MacOS"
echo 'ai.goalong.localhistory only' >"$OLD_RELEASE/Contents/MacOS/Goalong History"
GOALONG_DEV_RELEASE_APP="$OLD_RELEASE" "$ROOT/scripts/dev_app.sh" dev >"$WORK/out" 2>&1
grep -qF 'the installed Goalong predates Goalong Dev' "$WORK/out" || fail 'old release not reported'
echo 'ai.goalong.localhistory ai.goalong.localhistory.dev' >"$OLD_RELEASE/Contents/MacOS/Goalong History"
GOALONG_DEV_RELEASE_APP="$OLD_RELEASE" "$ROOT/scripts/dev_app.sh" dev >"$WORK/out" 2>&1
! grep -qF 'predates' "$WORK/out" || fail 'a family-aware release was reported'
unset GOALONG_DEV_VALIDATE_ONLY

BASE="$WORK/Application Support"
REAL="$BASE/LocalHistory" DEV="$BASE/LocalHistory-Dev"
mkdir -p "$REAL/events" "$REAL/Blocking" "$REAL/Focus/status" "$REAL/runtime" "$REAL/app-backups" \
  "$REAL/website-connections" "$REAL/jev" "$REAL/chatgpt/codex-home" "$REAL/chatgpt/history" "$REAL/Braise"
echo '{}' >"$REAL/Braise/preferences.json"; echo '{}' >"$REAL/Braise/display-recovery-ABC.json"
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
              blocking-backup-1.json jev/api-key chatgpt/codex-home Braise/display-recovery-ABC.json; do
  [[ ! -e "$DEV/$absent" ]] || fail "clone copied $absent"
done
[[ -f "$DEV/Braise/preferences.json" && -f "$DEV/.goalong-dev-seed-v2" ]] || fail 'clone missed Braise preferences or its marker'
[[ -f "$REAL/Braise/display-recovery-ABC.json" ]] || fail 'the real Braise state was removed'
[[ "$(stat -f %Lp "$DEV")" == 700 ]] || fail 'dev folder mode'

echo dev-only >"$DEV/dev-state"
"$CONTROL" seed-data keep "$REAL" "$DEV" >/dev/null
[[ -f "$DEV/dev-state" ]] || fail 'keep lost the dev state'
"$CONTROL" seed-data fresh "$REAL" "$DEV" >/dev/null
[[ "$(ls -A "$DEV")" == .goalong-dev-seed-v2 ]] || fail "fresh is not empty: $(ls -A "$DEV")"
rm -rf "$DEV"; "$CONTROL" seed-data keep "$REAL" "$DEV" >/dev/null
[[ -f "$DEV/events/a.jsonl" ]] || fail 'keep without dev data must clone'

# DATA=keep on a folder seeded by the old make dev (#85: real device key and tokens, no marker).
rm -rf "$DEV"; mkdir -m 700 "$DEV"; cp -R "$REAL/." "$DEV/"; rm -rf "$DEV/Blocking" "$DEV/Focus"
mkdir -p "$DEV/Blocking"; echo dev-lists >"$DEV/Blocking/blocking.json"; echo dev-only >"$DEV/dev-state"
"$CONTROL" seed-data keep "$REAL" "$DEV" >/dev/null
for absent in device-signing-key-v2.bin website-connections app-backups blocking-backup-1.json jev/api-key \
              chatgpt/codex-home Braise/display-recovery-ABC.json; do
  [[ ! -e "$DEV/$absent" ]] || fail "keep kept the old clone's $absent"
done
[[ -f "$DEV/dev-state" && -f "$DEV/Blocking/blocking.json" && -f "$DEV/jev/work-context.json" && -f "$DEV/.goalong-dev-seed-v2" ]] || fail 'keep lost dev state'
# With the marker, the dev copy's own key and Braise state stay; a key equal to the real one never does.
echo own-key >"$DEV/device-signing-key-v2.bin"; echo '{}' >"$DEV/Braise/display-recovery-DEV.json"
"$CONTROL" seed-data keep "$REAL" "$DEV" >/dev/null
[[ -f "$DEV/device-signing-key-v2.bin" && -f "$DEV/Braise/display-recovery-DEV.json" ]] || fail 'keep dropped the dev copy own state'
cp "$REAL/device-signing-key-v2.bin" "$DEV/device-signing-key-v2.bin"
"$CONTROL" seed-data keep "$REAL" "$DEV" >/dev/null
[[ ! -e "$DEV/device-signing-key-v2.bin" ]] || fail 'keep kept the real device key'

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
