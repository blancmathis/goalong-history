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

log "== synthetic activity for the app's own capture"
open -a TextEdit "$RUNNER_TEMP/synthetic-note.txt"; sleep 6; open -a Finder; sleep 6
shot "A-activity"

log "== path 3: permissions refused, then granted (runner TCC.db), relaunch"
try "P3 sidebar-settings" "$DRIVER" press "$BUNDLE" "sidebar-settings"; sleep 2
try "P3 settings-permissions" "$DRIVER" press "$BUNDLE" "settings-permissions"; sleep 3
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
try "P3 open dashboard" "$DRIVER" press "$BUNDLE" "Ouvrir Goalong Dev" AXButton; sleep 4
try "P3 sidebar-settings" "$DRIVER" press "$BUNDLE" "sidebar-settings"; sleep 2
try "P3 settings-permissions" "$DRIVER" press "$BUNDLE" "settings-permissions"; sleep 3
shot "P3-after-grant"; dump "P3-after-grant"
open -a TextEdit "$RUNNER_TEMP/synthetic-note.txt"; sleep 6; open -a Finder; sleep 8
shot "B-activity"

log "== lot 1: one step per matrix row (qa/e2e/lot1_steps.sh)"
ROWS="$OUT/rows"; RESULTS="$OUT/results.tsv"; mkdir -p "$ROWS/ax"
printf 'row\tresult\tcapture\tmissing_required\tmissing_optional\n' > "$RESULTS"
front() { osascript -e "tell application id \"$BUNDLE\" to activate" >/dev/null 2>&1; sleep 0.5; }
esc() { front; osascript -e 'tell application "System Events" to key code 53' >/dev/null 2>&1; sleep 1; }
rowshot() { screencapture -x "$ROWS/$1.png"; "$DRIVER" dump "$BUNDLE" "$ROWS/ax/$1.txt" >/dev/null 2>&1; }
# Back to a known state: close sheets, the status panel, extra windows and the evening panel.
cleanup() {
  "$DRIVER" dismiss-alerts "$BUNDLE" | grep -v '^dismissed 0' >> "$SUMMARY"
  esc
  [[ $panel == 1 ]] && { "$DRIVER" status-item "$BUNDLE" >/dev/null 2>&1; sleep 1; panel=0; }
  "$DRIVER" close-extra "$BUNDLE" "Goalong History — Dev" >/dev/null 2>&1
  "$DRIVER" press "$BUNDLE" "Plus tard" AXButton >/dev/null 2>&1
  "$DRIVER" press "$BUNDLE" "Revenir à l’activité de la journée" AXButton >/dev/null 2>&1
  true
}
panel=0
# A step passes when every required control was found and pressed; optional misses are listed.
step() {
  local row="$1"; shift; local req="" opt="" c o s
  pgrep -x "$EXE" >/dev/null || { launch; "$DRIVER" press "$BUNDLE" "Ouvrir Goalong Dev" AXButton >/dev/null 2>&1; sleep 3; }
  front
  for c in "$@"; do
    case "$c" in
      nav:*) o="$("$DRIVER" press "$BUNDLE" "sidebar-${c#nav:}" 2>&1)" || req+="$c;"; sleep 2 ;;
      pane:*) "$DRIVER" press "$BUNDLE" sidebar-settings >/dev/null 2>&1 || req+="sidebar-settings;"; sleep 1
              "$DRIVER" press "$BUNDLE" settings-back >/dev/null 2>&1 && sleep 1
              if [[ "${c#pane:}" != home ]]; then "$DRIVER" press "$BUNDLE" "settings-${c#pane:}" >/dev/null 2>&1 || req+="$c;"; sleep 2; fi ;;
      p:*) o="$("$DRIVER" press "$BUNDLE" "${c#p:}" 2>&1)" || req+="${c#p:};"; sleep 1 ;;
      b:*) o="$("$DRIVER" press "$BUNDLE" "${c#b:}" AXCheckBox 2>&1)" || o="$("$DRIVER" press "$BUNDLE" "${c#b:}" AXButton 2>&1)" || req+="${c#b:};"; sleep 1 ;;
      o:*) o="$("$DRIVER" press "$BUNDLE" "${c#o:}" 2>&1)" || opt+="${c#o:};"; sleep 1 ;;
      mi:*) o="$("$DRIVER" press "$BUNDLE" "${c#mi:}" AXMenuItem 2>&1)" || req+="${c#mi:};"; sleep 1 ;;
      m:*) s="${c#m:}"; if [[ "$s" == *">"* ]]; then o="$("$DRIVER" menu "$BUNDLE" "${s%%>*}" "${s#*>}" 2>&1)"; else o="$("$DRIVER" menu "$BUNDLE" "$s" 2>&1)"; fi || req+="$c;"; sleep 1 ;;
      si) o="$("$DRIVER" status-item "$BUNDLE" 2>&1)" && panel=$((1 - panel)) || req+="status-item;"; sleep 2 ;;
      sm) o="$("$DRIVER" status-menu "$BUNDLE" 2>&1)" || req+="status-menu;"; sleep 1 ;;
      esc) esc ;;
      pc) panel=0 ;;
      has:*) for _ in 1 2 3 4 5 6; do  # The page may still be computing: retry for about 18 s.
               "$DRIVER" dump "$BUNDLE" "$RUNNER_TEMP/has.txt" >/dev/null 2>&1
               o="$(grep -Em1 -- "${c#has:}" "$RUNNER_TEMP/has.txt")" && break; sleep 3
             done
             [[ -n $o ]] || req+="has(${c#has:});" ;;
      w:*) sleep "${c#w:}" ;;
      s:*) rowshot "$row-${c#s:}" ;;
    esac
    log "[$row] $c -> ${o:0:200}"; o=""
  done
  sleep 1; rowshot "$row"; cleanup
  printf '%s\t%s\t%s\t%s\t%s\n' "$row" "$([[ -z $req ]] && echo pass || echo fail)" "$row.png" "$req" "$opt" >> "$RESULTS"
}
for f in 04-P1-setup-1-donnees 05-P1-setup-2-sources 06-P1-setup-3-pret 07-P1-setup-done; do
  cp "$OUT/shots/$f.png" "$ROWS/ONB-01-${f#*-P1-}.png" 2>/dev/null
done
step CNF-REC pane:recording p:source-localComputerHistory w:3 s:sheet o:recording-setup-confirm w:3
log "== synthetic activity with recording on (runner only)"
# Synthetic HID input while each app is frontmost, so active time and per-app minutes are non-zero
# (run 5: no input event ever reached the app, every app showed « < 1 min »).
open -a TextEdit "$RUNNER_TEMP/synthetic-note.txt"; sleep 4; try "input TextEdit" "$DRIVER" input 180
open -a Safari; sleep 4; try "input Safari" "$DRIVER" input 90
open -a Finder; sleep 4; try "input Finder" "$DRIVER" input 30
copy_state input
log "[input] $(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print({k: v for k, v in d.items() if "nput" in k or "uppress" in k})' "$OUT/state-input/capture-health.json" 2>&1)"
front; sleep 5
source "$(dirname "$0")/lot1_steps.sh"
log "== lot 1 results"; cat "$RESULTS" | tee -a "$SUMMARY"

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
# Braise start failure (run 5: « Braise n’a pas pu démarrer »): the folder and its path, as tccd and the app see them.
{ ls -la@eO "$DATA/Braise" "$HOME/Library/Application Support/Braise"; stat -f '%N %HT %Sp %Su' "$HOME" "$HOME/Library" "$HOME/Library/Application Support" "$DATA" "$DATA/Braise"
  grep -i braise "$DATA"/SupportDiagnostics/*/diagnostics.log | tail -20; } > "$OUT/braise-diagnostic.txt" 2>&1
cp "$HOME/Library/Logs/DiagnosticReports/"*Goalong* "$OUT/" 2>/dev/null
quit_app
log "== done: $n screenshots"
