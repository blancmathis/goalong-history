#!/bin/bash
# DMG and HERE are used by the case scripts; ls of a flat report folder; the redirect needs no root.
# shellcheck disable=SC2034,SC2010,SC2024
# T-046 hard cases, shared helpers. GitHub-hosted macOS runner ONLY: the cases install the app in
# /Applications, edit the runner's TCC database, mount disk images, block the network and move the
# clock. They refuse to run anywhere else. Every datum is synthetic (runner VM).
# Sourced by hard_a.sh, hard_b.sh, hard_c.sh with: DIST_DIR OUT_DIR
set -uo pipefail
if [[ "${GITHUB_ACTIONS:-}" != true || "${RUNNER_ENVIRONMENT:-}" != github-hosted ]]; then
  echo "qa/hard runs only on a GitHub-hosted runner." >&2; exit 2
fi
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST="$1"; OUT="$2"; mkdir -p "$OUT"
NEW_APP="$DIST/Goalong History.app"
DMG="$DIST/Goalong-History-macOS-universal.dmg"
APP="/Applications/Goalong History.app"
CLI="$APP/Contents/MacOS/goalong"
BUNDLE=ai.goalong.localhistory
EXE="Goalong History"
GUARD_EXE=goalong-blocking-guard
DATA="$HOME/Library/Application Support/LocalHistory"
DRIVER="$RUNNER_TEMP/ax_driver"
RESULTS="$OUT/hard-results.tsv"
[[ -f $RESULTS ]] || printf 'case\tverdict\texpected\tobserved\tproof\n' > "$RESULTS"
[[ -x $DRIVER ]] || xcrun swiftc -O "$HERE/ax_driver.swift" -o "$DRIVER" || { echo "driver build failed" >&2; exit 3; }

CASE=""; CDIR=""; n=0; FAILS=""; OBS=""; CASE_T0=0
log() { echo "$*" | tee -a "$CDIR/summary.txt"; }
# Every probe is recorded; none stops the case. Output is cut to keep the summary readable.
try() { local label="$1"; shift; local o s; o="$("$@" 2>&1)"; s=$?; log "[$label] exit=$s ${o:0:400}"; return $s; }
fail() { FAILS+="$1; "; log "[FAIL] $1"; }
obs() { OBS+="$1; "; log "[obs] $1"; }
# Runs a command with a time limit (macOS has no timeout(1)).
tmo() { local s="$1"; shift; perl -e 'alarm shift; exec @ARGV' "$s" "$@"; }
# Screenshot of the runner screen, reduced to 1280 px wide so 9 cases stay well under the artifact cap.
shot() {
  n=$((n + 1)); local f; f="$CDIR/$(printf %02d $n)-$1.png"
  screencapture -x "$RUNNER_TEMP/shot.png" && sips -Z 1280 "$RUNNER_TEMP/shot.png" --out "$f" >/dev/null 2>&1
  log "[shot] ${f#"$OUT"/} $(stat -f %z "$f" 2>/dev/null) bytes"
}
dump() { tmo 30 "$DRIVER" dump "$BUNDLE" "$CDIR/ax/$(printf %02d $n)-$1.txt" >/dev/null 2>&1; }
# Text search in a fresh AX dump, menus left out, no-break spaces read as spaces.
axhas() {
  tmo 30 "$DRIVER" dump "$BUNDLE" "$RUNNER_TEMP/has.txt" >/dev/null 2>&1 || return 2
  grep -v 'role=AXMenu' "$RUNNER_TEMP/has.txt" | sed $'s/\xc2\xa0/ /g; s/\xe2\x80\xaf/ /g' | grep -Em1 -- "$1"
}

begin() {
  CASE="$1"; CDIR="$OUT/$1"; n=0; FAILS=""; OBS=""; CASE_T0=$(date +%s)
  mkdir -p "$CDIR/ax"
  log "== $CASE  ($(date -u +%FT%TZ))"; log "attendu : $2"; EXPECTED="$2"
  ls "$HOME/Library/Logs/DiagnosticReports" > "$RUNNER_TEMP/crash-before.txt" 2>/dev/null
}
# Logs, crash reports and the verdict line. A crash report written during the case fails it.
finish() {
  local secs=$(( $(date +%s) - CASE_T0 + 30 )) c
  log show --last "${secs}s" --style compact \
    --predicate "process == \"$EXE\" OR process == \"$GUARD_EXE\" OR process == \"goalong\"" 2>/dev/null | tail -n 4000 > "$CDIR/app-log.txt"
  while IFS= read -r c; do
    if [[ $c == *Goalong* || $c == *goalong* ]]; then
      mkdir -p "$CDIR/crash"; cp "$HOME/Library/Logs/DiagnosticReports/$c" "$CDIR/crash/"; fail "rapport de plantage $c"
    fi
  done < <(ls "$HOME/Library/Logs/DiagnosticReports" 2>/dev/null | grep -vxF -f "$RUNNER_TEMP/crash-before.txt")
  cp "$DATA"/{capture-health.json,capability-consent.json,config.json} "$CDIR/" 2>/dev/null
  cp -R "$DATA/SupportDiagnostics" "$CDIR/" 2>/dev/null
  local verdict=pass; [[ -n $FAILS ]] && verdict=fail
  log "== verdict $CASE : $verdict  ${FAILS}"
  printf '%s\t%s\t%s\t%s\t%s\n' "$CASE" "$verdict" "$EXPECTED" "${OBS}${FAILS:+ ÉCARTS: $FAILS}" "$CASE/" >> "$RESULTS"
}

running() { pgrep -x "$EXE" >/dev/null; }
# Opens the app and waits until it answers AX (status item present). Prints the seconds it took.
launch() {
  local t0 i; t0=$(date +%s)
  open "$APP"
  for i in $(seq 1 120); do
    running && tmo 10 "$DRIVER" status-item-present "$BUNDLE" >/dev/null 2>&1 && break
    sleep 1
  done
  LAUNCH_SECS=$(( $(date +%s) - t0 ))
  log "[launch] ${LAUNCH_SECS}s running=$(running && echo yes || echo no)"
  sleep "${1:-6}"; running
}
quit_app() {
  running || return 0
  osascript -e "tell application id \"$BUNDLE\" to quit" >/dev/null 2>&1
  local i; for i in $(seq 1 15); do running || return 0; sleep 1; done
  pkill -TERM -x "$EXE"; for i in $(seq 1 10); do running || return 0; sleep 1; done
  log "[quit] still running after quit + SIGTERM: SIGKILL (runner VM only)"; pkill -KILL -x "$EXE"; sleep 2
}
# Synthetic runner state only: no data, no preferences, no TCC rows for the app.
reset_app_state() {
  quit_app
  rm -rf "$DATA" "$HOME/Library/Caches/$BUNDLE" "$HOME/Library/HTTPStorages/$BUNDLE"
  defaults delete "$BUNDLE" >/dev/null 2>&1
  sudo sqlite3 "/Library/Application Support/com.apple.TCC/TCC.db" "DELETE FROM access WHERE client='$BUNDLE'" 2>/dev/null
  sqlite3 "$HOME/Library/Application Support/com.apple.TCC/TCC.db" "DELETE FROM access WHERE client='$BUNDLE'" 2>/dev/null
  true
}
# The updater stays off in the tests: no Sparkle window, no download (see the update case for why).
no_sparkle() {
  defaults write "$BUNDLE" SUEnableAutomaticChecks -bool NO
  defaults write "$BUNDLE" SUAutomaticallyUpdate -bool NO
  defaults write "$BUNDLE" SUHasLaunchedBefore -bool YES
}
install_new() { rm -rf "$APP"; ditto "$NEW_APP" "$APP"; }
# TCC rows for the installed bundle: 2 = allowed, 0 = denied. The csreq is the bundle's own requirement.
tcc_set() {
  local value="$1" now csreq=NULL svc
  now=$(date +%s)
  codesign -d -r- "$APP" 2>/dev/null | sed -n 's/^designated => //p' > "$RUNNER_TEMP/req.txt"
  if csreq -r "$RUNNER_TEMP/req.txt" -b "$RUNNER_TEMP/req.bin" 2>/dev/null; then csreq="X'$(xxd -p "$RUNNER_TEMP/req.bin" | tr -d '\n')'"; fi
  for svc in kTCCServiceAccessibility kTCCServiceListenEvent kTCCServiceScreenCapture kTCCServicePostEvent; do
    sudo sqlite3 "/Library/Application Support/com.apple.TCC/TCC.db" \
      "INSERT OR REPLACE INTO access VALUES('$svc','$BUNDLE',0,$value,4,1,$csreq,NULL,0,'UNUSED',NULL,0,$now,NULL,NULL,'UNUSED',$now);" \
      || log "[tcc] $svc insert failed"
  done
  sudo killall tccd 2>/dev/null; killall tccd 2>/dev/null; sleep 2
  sudo sqlite3 "/Library/Application Support/com.apple.TCC/TCC.db" "select service, auth_value from access where client='$BUNDLE'" > "$CDIR/tcc-$value.txt" 2>&1
}
front() { osascript -e "tell application id \"$BUNDLE\" to activate" >/dev/null 2>&1; sleep 0.5; }
esc() { front; osascript -e 'tell application "System Events" to key code 53' >/dev/null 2>&1; sleep 1; }
press() { tmo 30 "$DRIVER" press "$BUNDLE" "$@" 2>&1; }
# A single AX press can miss on the runner: 3 tries 1 s apart.
press3() { local i; for i in 1 2 3; do press "$@" && return 0; sleep 1; done; return 1; }
# First-run assistant, as the T-045 probe drives it: status item, open, three steps, Accessibility sheet refused.
onboarding() {
  try "status item" tmo 20 "$DRIVER" status-item "$BUNDLE"; sleep 3
  try "open" press3 "Ouvrir"; sleep 4
  shot "onboarding-1"; dump "onboarding-1"
  if ! axhas 'id=onboarding-continue' >/dev/null; then log "[onboarding] no assistant"; return 1; fi
  try "continue 2" press3 onboarding-continue; sleep 4
  try "continue 3" press3 onboarding-continue; sleep 4
  shot "onboarding-3"
  try "sheet: Plus tard" press "Plus tard"; sleep 3
  try "continue done" press3 onboarding-continue; sleep 4
  return 0
}
dashboard() {
  axhas 'id=sidebar-' >/dev/null && return 0
  tmo 20 "$DRIVER" status-item "$BUNDLE" >/dev/null 2>&1; sleep 2
  press3 "Ouvrir Goalong History" AXButton >/dev/null || press3 "Ouvrir" >/dev/null; sleep 4
  axhas 'id=sidebar-' >/dev/null
}
nav() { front; press3 "sidebar-$1" >/dev/null; local s=$?; sleep 3; return $s; }
pane() {
  nav settings; press settings-back >/dev/null 2>&1 && sleep 1
  press3 "settings-$1" >/dev/null; local s=$?; sleep 3; return $s
}
# Recording on, as the T-045 probe does it (CNF-REC): Réglages › Enregistrement › source › confirm.
record_on() {
  dashboard
  pane recording
  # AX press on the custom switch leaves it off (run 40960962788): real click on the switch at the row's right end.
  front
  try "recording source" "$DRIVER" set "$BUNDLE" source-localComputerHistory 1 || try "recording source (click)" "$DRIVER" click "$BUNDLE" source-localComputerHistory right
  sleep 5; shot "recording-sheet"; dump "recording-sheet"
  # The first activation opens the recording review sheet; its button reads « Valider et activer ».
  if axhas 'id=recording-setup-confirm|Valider et activer' >/dev/null; then
    try "recording confirm" press3 recording-setup-confirm || try "recording confirm (click)" "$DRIVER" click "$BUNDLE" recording-setup-confirm
    sleep 5
  fi
  shot "recording-after"; dump "recording-after"
  local c; c="$(tr -d '\n ' < "$DATA/capability-consent.json" 2>/dev/null)"
  log "[consent] ${c:0:300}"
  if [[ $c =~ \"localComputerHistory\":\{[^}]*\"enabled\":true ]]; then REC_ON=1; obs "enregistrement activé"
  else REC_ON=0; fail "HARNAIS : enregistrement non activé, cas non concluant"; fi
  esc
}
note_file() { printf 'Note de test synthétique T-046.\nAucune donnée réelle.\n' > "$RUNNER_TEMP/synthetic-note.txt"; echo "$RUNNER_TEMP/synthetic-note.txt"; }
# Synthetic HID input while TextEdit is frontmost, so the app records activity.
activity() { open -a TextEdit "$(note_file)"; sleep 3; tmo $(( $1 + 20 )) "$DRIVER" input "$1" >/dev/null 2>&1; open -a Finder; sleep 2; }
# "files lines bad last_bad": events journal lines and the ones that do not parse as JSON objects.
events_stat() {
  python3 -I - "$DATA/events" <<'PY'
import json, pathlib, sys
files = lines = bad = 0; last = ""
for f in sorted(pathlib.Path(sys.argv[1]).glob("*.jsonl")):
    files += 1
    for i, line in enumerate(f.read_bytes().splitlines(), 1):
        if not line.strip(): continue
        lines += 1
        try: ok = isinstance(json.loads(line), dict)
        except Exception: ok = False
        if not ok: bad += 1; last = f"{f.name}:{i}"
print(f"files={files} lines={lines} bad={bad} last_bad={last or '-'}")
PY
}
events_lines() { events_stat | sed -n 's/.* lines=\([0-9]*\) .*/\1/p'; }
cli() { local name="$1"; shift; tmo 300 "$CLI" --root "$DATA" "$@" > "$CDIR/cli-$name.txt" 2>&1; local s=$?; log "[cli $name] exit=$s $(head -c 300 "$CDIR/cli-$name.txt" | tr '\n' ' ')"; return $s; }
