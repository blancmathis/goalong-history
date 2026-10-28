#!/bin/bash
# T-045 E2E probe. GitHub-hosted macOS runner ONLY: it launches the app, clicks it, edits the
# runner's TCC database and takes screenshots. It refuses to run anywhere else.
# Usage: qa/e2e/runner_probe.sh APP_PATH OUT_DIR
set -uo pipefail
if [[ "${GITHUB_ACTIONS:-}" != true || "${RUNNER_ENVIRONMENT:-}" != github-hosted ]]; then
  echo "runner_probe.sh runs only on a GitHub-hosted runner." >&2; exit 2
fi
APP="$1"; OUT="$2"
BUNDLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"
EXE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist")"
DATA="$HOME/Library/Application Support/LocalHistory-Dev"
DRIVER="$RUNNER_TEMP/ax_driver"
SUMMARY="$OUT/summary.txt"
mkdir -p "$OUT/shots" "$OUT/ax"
n=0
log() { echo "$*" | tee -a "$SUMMARY"; }
# Every probe is recorded, none stops the run: the summary is the result.
try() { local label="$1"; shift; local o; o="$("$@" 2>&1)"; local s=$?; log "[$label] exit=$s ${o:0:600}"; return $s; }
shot() { n=$((n + 1)); local f; f="$OUT/shots/$(printf %02d $n)-$1.png"; screencapture -x "$f"; log "[shot] $f $(stat -f %z "$f" 2>/dev/null) bytes"; }
dump() { "$DRIVER" dump "$BUNDLE" "$OUT/ax/$(printf %02d $n)-$1.txt" >/dev/null 2>&1; }
tcc_dump() {
  for db in "/Library/Application Support/com.apple.TCC/TCC.db" "$HOME/Library/Application Support/com.apple.TCC/TCC.db"; do
    echo "== $db"; sudo sqlite3 "$db" "select service, client, auth_value from access order by service, client" 2>&1
  done
}
# Runner VM state only (synthetic): permission and capture health as the app sees them.
copy_state() { mkdir -p "$OUT/state-$1"; cp "$DATA"/{capture-health.json,capability-consent.json,config.json} "$OUT/state-$1/" 2>/dev/null
  cp -R "$DATA/SupportDiagnostics" "$OUT/state-$1/" 2>/dev/null; true; }
launch() { open "$APP"; sleep 10; try "running" pgrep -x "$EXE"; }
quit_app() {
  try "quit (AppleEvent)" osascript -e "tell application id \"$BUNDLE\" to quit"
  sleep 4
  if pgrep -x "$EXE" >/dev/null; then try "quit (SIGTERM)" pkill -TERM -x "$EXE"; sleep 4; fi
}

log "== environment"
try "sw_vers" sw_vers
try "csrutil" csrutil status
try "user" id
tcc_dump > "$OUT/tcc-before.txt"
sudo sqlite3 "/Library/Application Support/com.apple.TCC/TCC.db" ".schema access" > "$OUT/tcc-schema.txt" 2>&1

log "== driver and runner permissions"
try "compile driver" xcrun swiftc -O "$(dirname "$0")/ax_driver.swift" -o "$DRIVER"
try "driver AX trusted" "$DRIVER" trusted
try "Automation: System Events" osascript -e 'tell application "System Events" to get name of first process whose frontmost is true'
try "Automation: Finder" osascript -e 'tell application "Finder" to get name of startup disk'
shot "desktop-before-launch"

log "== synthetic data (runner VM, no real data)"
rm -rf "$DATA"; mkdir -p "$DATA"; chmod 700 "$DATA"
touch "$DATA/.goalong-dev-seed-v3"
echo "Synthetic E2E data dir, GitHub runner $(date -u +%FT%TZ)" > "$DATA/SYNTHETIC-E2E.txt"
printf 'Note de test synthétique T-045.\nAucune donnée réelle.\n' > "$RUNNER_TEMP/synthetic-note.txt"

log "== phase A: no permission granted to the app"
launch
shot "A-launched"; dump "A-launched"
try "windows" "$DRIVER" windows "$BUNDLE"

log "== path 1: status item -> panel -> open -> three-step setup -> dashboard"
try "P1 status item" "$DRIVER" status-item "$BUNDLE"; sleep 3
shot "P1-panel"; dump "P1-panel"
try "P1 open dashboard" "$DRIVER" press "$BUNDLE" "Ouvrir"; sleep 4
shot "P1-setup-1-donnees"; dump "P1-setup-1-donnees"
for step in 2-sources 3-pret; do
  try "P1 continue -> $step" "$DRIVER" press "$BUNDLE" "onboarding-continue"; sleep 4
  shot "P1-setup-$step"; dump "P1-setup-$step"
done
# Step 3 opens the Accessibility sheet: refuse it for now (« Plus tard »), then finish.
try "P1 sheet: Plus tard" "$DRIVER" press "$BUNDLE" "Plus tard"; sleep 3
shot "P1-setup-3-sheet-closed"
try "P1 continue -> done" "$DRIVER" press "$BUNDLE" "onboarding-continue"; sleep 4
shot "P1-setup-done"; dump "P1-setup-done"
try "windows" "$DRIVER" windows "$BUNDLE"

log "== path 2: sidebar navigation"
for s in overview work history concentration settings; do
  try "P2 sidebar-$s" "$DRIVER" press "$BUNDLE" "sidebar-$s"; sleep 3
  shot "P2-$s"; dump "P2-$s"
done

log "== synthetic activity for the app's own capture"
open -a TextEdit "$RUNNER_TEMP/synthetic-note.txt"; sleep 6; open -a Finder; sleep 6
shot "A-activity"

log "== path 3: permissions refused, then granted (runner TCC.db), relaunch"
try "P3 Autorisations macOS" "$DRIVER" press "$BUNDLE" "Autorisations macOS"; sleep 3
shot "P3-before-grant"; dump "P3-before-grant"
copy_state before
quit_app
NOW=$(date +%s)
# The app's real designated requirement as csreq, so tccd can match the ad-hoc signature.
codesign -d -r- "$APP" 2>/dev/null | sed -n 's/^designated => //p' > "$RUNNER_TEMP/req.txt"
log "[designated] $(cat "$RUNNER_TEMP/req.txt")"
CSREQ=NULL
if csreq -r "$RUNNER_TEMP/req.txt" -b "$RUNNER_TEMP/req.bin" 2>>"$SUMMARY"; then CSREQ="X'$(xxd -p "$RUNNER_TEMP/req.bin" | tr -d '\n')'"; fi
for svc in kTCCServiceAccessibility kTCCServiceListenEvent kTCCServiceScreenCapture kTCCServicePostEvent; do
  try "grant $svc" sudo sqlite3 "/Library/Application Support/com.apple.TCC/TCC.db" \
    "INSERT OR REPLACE INTO access VALUES('$svc','$BUNDLE',0,2,4,1,$CSREQ,NULL,0,'UNUSED',NULL,0,$NOW,NULL,NULL,'UNUSED',$NOW);"
done
tcc_dump > "$OUT/tcc-after.txt"
try "restart tccd" sudo killall tccd; killall tccd 2>/dev/null; sleep 2
launch
try "P3 status item" "$DRIVER" status-item "$BUNDLE"; sleep 3
shot "P3-panel-after-grant"
try "P3 open dashboard" "$DRIVER" press "$BUNDLE" "Ouvrir Goalong Dev"; sleep 4
try "P3 sidebar-settings" "$DRIVER" press "$BUNDLE" "sidebar-settings"; sleep 3
try "P3 Autorisations macOS" "$DRIVER" press "$BUNDLE" "Autorisations macOS"; sleep 3
shot "P3-after-grant"; dump "P3-after-grant"
open -a TextEdit "$RUNNER_TEMP/synthetic-note.txt"; sleep 6; open -a Finder; sleep 8
shot "B-activity"

log "== app capture inventory"
{
  find "$DATA" -maxdepth 3 -type f -exec stat -f '%z %N' {} + 2>/dev/null | sort -k2
  echo "== event kinds and fields seen (counts only)"
  python3 - "$DATA" <<'PY'
import collections, json, pathlib, sys
kinds, fields = collections.Counter(), collections.Counter()
for f in pathlib.Path(sys.argv[1]).rglob('*.jsonl'):
    for line in f.read_text(errors='replace').splitlines():
        try: e = json.loads(line)
        except Exception: continue
        if isinstance(e, dict):
            kinds[e.get('kind', '?')] += 1
            fields.update(k for k, v in e.items() if v not in (None, '', [], {}))
print('kinds', dict(kinds)); print('fields', dict(fields))
PY
} > "$OUT/capture-inventory.txt" 2>&1
log "$(tail -2 "$OUT/capture-inventory.txt")"
copy_state after
cp "$HOME/Library/Logs/DiagnosticReports/"*Goalong* "$OUT/" 2>/dev/null
quit_app
log "== done: $n screenshots"
