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
# The same DEV_APP_DIR gives the same answer on every run, through /tmp -> /private/tmp or not.
mkdir -p "$WORK/apps" "$WORK/real-apps"
[[ "$WORK" == /tmp/* ]] || fail "test folder outside /tmp: $WORK"
for dir in "$WORK/apps" "/tmp/${WORK##*/}/apps" "/private/tmp/${WORK##*/}/apps" "$WORK/apps"; do
  [[ -d "$dir" ]] || fail "missing $dir"
  GOALONG_DEV_NO_LAUNCH=1 GOALONG_DEV_APP_DIR="$dir" "$ROOT/scripts/dev_app.sh" dev >"$WORK/out" 2>&1 \
    || fail "an existing DEV_APP_DIR reached through /tmp was refused: $dir $(cat "$WORK/out")"
done
# A link on the final component (the folder or the bundle) redirects the install: refused.
ln -s "$WORK/real-apps" "$WORK/linked-apps"
expect_refusal 'Refusing redirected Goalong Dev path' GOALONG_DEV_NO_LAUNCH=1 "GOALONG_DEV_APP_DIR=$WORK/linked-apps"
ln -s "$WORK/real-apps" "$WORK/apps/Goalong Dev.app"
expect_refusal 'Refusing redirected Goalong Dev path' GOALONG_DEV_NO_LAUNCH=1 "GOALONG_DEV_APP_DIR=$WORK/apps"
rm "$WORK/apps/Goalong Dev.app"
ln -s /Applications "$WORK/to-applications"
expect_refusal 'never goes into /Applications' GOALONG_DEV_NO_LAUNCH=1 "GOALONG_DEV_APP_DIR=$WORK/to-applications/Sub"
# Spec K: a severe block of Goalong Dev (guard-until or locked-until in the future) refuses make dev;
# NO_LAUNCH=1 into another folder stays allowed, an ended block changes nothing.
mkdir -p "$HOME/Library/Application Support/LocalHistory-Dev/Blocking"
DEV_MARKER="$HOME/Library/Application Support/LocalHistory-Dev/Blocking/guard-until"
echo "$(( $(date +%s) + 600 ))" > "$DEV_MARKER"
expect_refusal 'Goalong Dev a un blocage sévère actif' GOALONG_DEV_DATA=keep
expect_refusal 'Goalong Dev a un blocage sévère actif' GOALONG_DEV_NO_LAUNCH=1 "GOALONG_DEV_APP_DIR=$HOME/Applications"
GOALONG_DEV_NO_LAUNCH=1 GOALONG_DEV_APP_DIR="$WORK/apps" "$ROOT/scripts/dev_app.sh" dev >"$WORK/out" 2>&1 \
  || fail "NO_LAUNCH elsewhere refused during a dev block: $(cat "$WORK/out")"
mv "$DEV_MARKER" "${DEV_MARKER%guard-until}locked-until"
expect_refusal 'Goalong Dev a un blocage sévère actif' GOALONG_DEV_DATA=keep
echo "$(( $(date +%s) - 5 ))" > "${DEV_MARKER%guard-until}locked-until"
"$ROOT/scripts/dev_app.sh" dev >"$WORK/out" 2>&1 || fail "an ended dev block still refused: $(cat "$WORK/out")"
rm -rf "$HOME/Library/Application Support/LocalHistory-Dev"
# Spec K: the dev bundle embeds only its own guard agent (.dev.blocking-guard), never the release one.
grep -qF 'GUARD_LABEL="$BUNDLE_ID.blocking-guard"' "$ROOT/scripts/build_app_core.sh" || fail 'guard agent label is not derived from the bundle id'
if [[ -n "${GOALONG_DEV_BUNDLE_CHECK:-}" ]]; then
  agents="$(ls "$GOALONG_DEV_BUNDLE_CHECK/Contents/Library/LaunchAgents")"
  [[ "$agents" == ai.goalong.localhistory.dev.blocking-guard.plist ]] || fail "dev bundle launch agents: $agents"
fi
# Marker name shared by make dev and the app's guard.
grep -qF 'let seedMarker = ".goalong-dev-seed-v3"' "$ROOT/scripts/dev_app.swift" \
  && grep -qF 'public static let seedMarker = ".goalong-dev-seed-v3"' "$ROOT/Sources/LocalHistoryCore/GoalongBuildChannel.swift" \
  || fail 'make dev and GoalongDevDataGuard use different seed markers'
# Every identity or credential the clone skips is also refused by the app's guard.
for item in device-signing-key-v2.bin website-connections seals receipts integrity-state.json app-backups setup-backups \
            jev/api-key chatgpt/codex-home chatgpt/site-analysis-codex-home chatgpt/proofs/private-evidence \
            blocking-backup- display-recovery; do
  grep -qF "\"$item\"" "$ROOT/scripts/dev_app.swift" && grep -qF "\"$item\"" "$ROOT/Sources/LocalHistoryCore/GoalongBuildChannel.swift" \
    || fail "make dev and GoalongDevDataGuard disagree on $item"
done
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
# Install swap interrupted (Ctrl-C between the two renames): cleanup puts the previous Goalong Dev back.
# The real cleanup function is extracted and run on a scratch folder; nothing is built or launched.
SWAP="$WORK/swap"; mkdir -p "$SWAP"
eval "$(/usr/bin/sed -n '/^cleanup() {$/,/^}$/p' "$ROOT/scripts/dev_app.sh")"
declare -F cleanup >/dev/null || fail 'cleanup function not found in dev_app.sh'
(
  DEV_APP="$SWAP/Goalong Dev.app" NEW_APP="$SWAP/.new" OLD_APP="$SWAP/.old"
  HAVE_GLOBAL_LOCK=0 HAVE_WORKTREE_LOCK=0
  mkdir -p "$NEW_APP" "$OLD_APP"; echo previous >"$OLD_APP/id"
  cleanup
)
[[ "$(cat "$SWAP/Goalong Dev.app/id" 2>/dev/null)" == previous && ! -e "$SWAP/.old" && ! -e "$SWAP/.new" ]] || fail 'interrupted swap lost Goalong Dev'
(
  DEV_APP="$SWAP/Goalong Dev.app" NEW_APP='' OLD_APP="$SWAP/.old"
  HAVE_GLOBAL_LOCK=0 HAVE_WORKTREE_LOCK=0
  mkdir -p "$OLD_APP"; echo installed >"$DEV_APP/id"
  cleanup
)
[[ "$(cat "$SWAP/Goalong Dev.app/id")" == installed && ! -e "$SWAP/.old" ]] || fail 'finished swap kept the old copy'
unset -f cleanup
# dev-stop never waits on this worktree's build lock (a make dev may compile for minutes); it waits on the
# global lock only. Validation-only stop quits nothing. The control tool is renamed in place, never left half built.
WORKTREE_LOCK="$ROOT/.build/goalong-dev/lock"; mkdir -p "$ROOT/.build/goalong-dev"
if mkdir "$WORKTREE_LOCK" 2>/dev/null; then
  status=0; "$ROOT/scripts/dev_app.sh" stop >"$WORK/out" 2>&1 || status=$?
  rmdir "$WORKTREE_LOCK"
  [[ "$status" == 0 ]] && grep -qF 'Stop accepted (validation only' "$WORK/out" || fail "dev-stop blocked by the worktree lock: $(cat "$WORK/out")"
else
  echo 'NOTE: a make dev holds this worktree lock; dev-stop lock check skipped.'
fi
ls "$ROOT/.build/goalong-dev" | grep -q '^dev-app-control\.build-' && fail 'a half-built control tool was left behind'
unset GOALONG_DEV_VALIDATE_ONLY

# Global install lock (flock): a holder blocks the others; when it dies, even killed, exactly one
# waiter at a time gets it. Several waiters never hold it together.
GLOBAL_LOCK="$WORK/lock/goalong-dev-install.flock"
lock_holder() { # name, seconds
  GLOBAL_LOCK="$GLOBAL_LOCK" GOALONG_DEV_LOCK_WAIT=20 bash -c 'source "$1"; acquire_global_lock >/dev/null
    echo "in $2" >>"$4"; sleep "$3"; echo "out $2" >>"$4"' _ "$ROOT/scripts/dev_app_lock.sh" "$1" "$2" "$WORK/lock.log"
}
mkdir -p "$WORK/lock"; : >"$WORK/lock.log"
GLOBAL_LOCK="$GLOBAL_LOCK" bash -c 'source "$1"; acquire_global_lock >/dev/null; touch "$2"; exec sleep 30' \
  _ "$ROOT/scripts/dev_app_lock.sh" "$WORK/held" & HOLDER=$!
for _ in $(seq 100); do [[ -e "$WORK/held" ]] && break; sleep 0.05; done
[[ -e "$WORK/held" ]] || fail 'the lock holder did not start'
if GLOBAL_LOCK="$GLOBAL_LOCK" GOALONG_DEV_LOCK_WAIT=1 bash -c 'source "$1"; acquire_global_lock' _ "$ROOT/scripts/dev_app_lock.sh" >"$WORK/out" 2>&1; then
  fail 'a second make dev got the lock while it was held'
fi
grep -qF 'Still locked after 1 s' "$WORK/out" || fail "lock wait message: $(cat "$WORK/out")"
lock_holder A 1 & A=$!; lock_holder B 1 & B=$!
sleep 0.5; kill -9 "$HOLDER"; wait "$HOLDER" 2>/dev/null || true
wait "$A" || fail 'waiter A failed'; wait "$B" || fail 'waiter B failed'
python3 - "$WORK/lock.log" <<'PY' || fail "two make dev held the lock together: $(cat "$WORK/lock.log")"
import sys
lines = open(sys.argv[1]).read().split()
pairs = list(zip(lines[0::2], lines[1::2]))
assert len(pairs) == 4, lines
assert pairs[0][0] == "in" and pairs[1] == ("out", pairs[0][1]) and pairs[2][0] == "in" and pairs[3] == ("out", pairs[2][1]), lines
assert {pairs[0][1], pairs[2][1]} == {"A", "B"}, lines
PY

BASE="$WORK/Application Support"
REAL="$BASE/LocalHistory" DEV="$BASE/LocalHistory-Dev"
mkdir -p "$REAL/events" "$REAL/Blocking" "$REAL/Focus/status" "$REAL/runtime" "$REAL/app-backups" \
  "$REAL/website-connections" "$REAL/jev" "$REAL/chatgpt/codex-home" "$REAL/chatgpt/history" "$REAL/Braise"
echo '{}' >"$REAL/Braise/preferences.json"; echo '{}' >"$REAL/Braise/display-recovery-ABC.json"
echo event >"$REAL/events/a.jsonl"; echo key >"$REAL/device-signing-key-v2.bin"
echo token >"$REAL/website-connections/x.token"; echo secret >"$REAL/jev/api-key"; echo ctx >"$REAL/jev/work-context.json"
echo auth >"$REAL/chatgpt/codex-home/auth.json"; echo h >"$REAL/chatgpt/history/h.json"
mkdir -p "$REAL/chatgpt/proofs/private-evidence"; echo sealed >"$REAL/chatgpt/proofs/private-evidence/x.capsule"
echo '{}' >"$REAL/chatgpt/proofs/p.json"
echo '{}' >"$REAL/blocking-backup-1.json"; echo '{}' >"$REAL/Focus/prompts.json"
mkdir -p "$REAL/seals" "$REAL/receipts"; echo '{"deviceID":"REAL"}' >"$REAL/seals/2026-10-01.seals.jsonl"
echo '{"deviceID":"REAL"}' >"$REAL/receipts/2026-10-01.receipts.jsonl"; echo '{}' >"$REAL/integrity-state.json"
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
[[ -f "$DEV/events/a.jsonl" && -f "$DEV/jev/work-context.json" && -f "$DEV/chatgpt/history/h.json" && -f "$DEV/chatgpt/proofs/p.json" ]] || fail 'clone missed data'
for absent in Blocking Focus runtime app-backups website-connections device-signing-key-v2.bin \
              blocking-backup-1.json jev/api-key chatgpt/codex-home Braise/display-recovery-ABC.json \
              chatgpt/proofs/private-evidence seals receipts integrity-state.json; do
  [[ ! -e "$DEV/$absent" ]] || fail "clone copied $absent"
done
[[ -f "$DEV/Braise/preferences.json" && -f "$DEV/.goalong-dev-seed-v3" ]] || fail 'clone missed Braise preferences or its marker'
[[ -f "$REAL/Braise/display-recovery-ABC.json" ]] || fail 'the real Braise state was removed'
[[ "$(stat -f %Lp "$DEV")" == 700 ]] || fail 'dev folder mode'

echo dev-only >"$DEV/dev-state"
"$CONTROL" seed-data keep "$REAL" "$DEV" >/dev/null
[[ -f "$DEV/dev-state" ]] || fail 'keep lost the dev state'
"$CONTROL" seed-data fresh "$REAL" "$DEV" >/dev/null
[[ "$(ls -A "$DEV")" == .goalong-dev-seed-v3 ]] || fail "fresh is not empty: $(ls -A "$DEV")"
rm -rf "$DEV"; "$CONTROL" seed-data keep "$REAL" "$DEV" >/dev/null
[[ -f "$DEV/events/a.jsonl" ]] || fail 'keep without dev data must clone'

# DATA=keep on a folder seeded by the old make dev (#85: real device key and tokens, no marker).
rm -rf "$DEV"; mkdir -m 700 "$DEV"; cp -R "$REAL/." "$DEV/"; rm -rf "$DEV/Blocking" "$DEV/Focus"
mkdir -p "$DEV/Blocking"; echo dev-lists >"$DEV/Blocking/blocking.json"; echo dev-only >"$DEV/dev-state"
"$CONTROL" seed-data keep "$REAL" "$DEV" >/dev/null
for absent in device-signing-key-v2.bin website-connections app-backups blocking-backup-1.json jev/api-key \
              chatgpt/codex-home Braise/display-recovery-ABC.json chatgpt/proofs/private-evidence \
              seals receipts integrity-state.json; do
  [[ ! -e "$DEV/$absent" ]] || fail "keep kept the old clone's $absent"
done
[[ -f "$DEV/dev-state" && -f "$DEV/Blocking/blocking.json" && -f "$DEV/jev/work-context.json" && -f "$DEV/.goalong-dev-seed-v3" ]] || fail 'keep lost dev state'
# A v2 clone (marker v2, real anchor chain) is cleaned by keep too.
rm -rf "$DEV"; mkdir -m 700 "$DEV"; cp -R "$REAL/seals" "$REAL/receipts" "$REAL/integrity-state.json" "$DEV/"
echo v2 >"$DEV/.goalong-dev-seed-v2"; echo dev-only >"$DEV/dev-state"
"$CONTROL" seed-data keep "$REAL" "$DEV" >/dev/null
for absent in seals receipts integrity-state.json; do [[ ! -e "$DEV/$absent" ]] || fail "keep kept the v2 clone's $absent"; done
[[ -f "$DEV/dev-state" && -f "$DEV/.goalong-dev-seed-v3" ]] || fail 'keep lost the v2 dev state'
mkdir -p "$DEV/Braise"
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

# No readable real lists: the message tells whether the dev lists (DATA=keep) stay or Blocking is empty.
BASE2="$WORK/Other Support"; REAL2="$BASE2/LocalHistory" DEV2="$BASE2/LocalHistory-Dev"
mkdir -p "$REAL2" "$DEV2/Blocking"; echo dev-lists >"$DEV2/Blocking/blocking.json"
out="$("$CONTROL" copy-blocking "$REAL2" "$DEV2")"
[[ "$out" == *"keeps its own block lists"* && "$(cat "$DEV2/Blocking/blocking.json")" == dev-lists ]] || fail "kept dev lists misreported: $out"
rm -rf "$DEV2/Blocking"
out="$("$CONTROL" copy-blocking "$REAL2" "$DEV2")"
[[ "$out" == *"stays empty"* ]] || fail "empty dev blocking misreported: $out"

AFTER="$(cd "$REAL" && find . -print0 | xargs -0 stat -f '%N %m %z' | sort | shasum)"
[[ "$BEFORE" == "$AFTER" ]] || fail 'the real data folder changed'
echo 'Goalong Dev control tests passed.'
