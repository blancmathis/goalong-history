#!/bin/bash
# T-046 L3: one shard (S1-S4) of the 1027-row matrix qa/e2e/t046-rows.tsv on a GitHub-hosted macOS runner.
# Launches Goalong Dev on synthetic data, presses real controls, edits the runner's TCC database and takes
# screenshots: it refuses to run anywhere else. Per row: navigation, AX target + action (ax_driver act),
# proof = rows/<id>.png + rows/ax/<id>.txt, one line in results.tsv.
# Usage: qa/e2e/t046_shard.sh APP_PATH OUT_DIR SHARD [PART/PARTS]
set -uo pipefail
if [[ "${GITHUB_ACTIONS:-}" != true || "${RUNNER_ENVIRONMENT:-}" != github-hosted ]]; then
  echo "t046_shard.sh runs only on a GitHub-hosted runner." >&2; exit 2
fi
APP="$1"; OUT="$2"; SHARD="$3"; SLICE="${4:-1/1}"
HERE="$(cd "$(dirname "$0")" && pwd)"
BUNDLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"
EXE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist")"
DATA="$HOME/Library/Application Support/LocalHistory-Dev"
DRIVER="$RUNNER_TEMP/ax_driver"
ROWS="$OUT/rows"; RESULTS="$OUT/results.tsv"; SUMMARY="$OUT/summary.txt"
mkdir -p "$ROWS/ax" "$OUT/setup"
printf 'id\tshard\tverdict\tproof_png\tax_dump\tcause\tdetail\n' > "$RESULTS"
log() { echo "$*" | tee -a "$SUMMARY"; }
# perl alarm: macOS has no timeout(1). A hung AX call never stalls the shard.
tmo() { local s="$1"; shift; perl -e 'alarm shift; exec @ARGV' "$s" "$@"; }
# Like tmo, but the command runs in its own process group and the whole group dies at the alarm (exit 142):
# a child (an osascript dialog, say) cannot keep the output pipe open after its shell is killed.
tmog() { perl -e '$s=shift; $p=fork; if(!$p){setpgrp(0,0); exec @ARGV; exit 127}
  $SIG{ALRM}=sub{kill "KILL",-$p; waitpid($p,0); exit 142}; alarm $s; waitpid($p,0); exit($?>>8)' "$1" "${@:2}"; }
drv() { tmo 40 "$DRIVER" "$@"; }

log "== shard $SHARD slice $SLICE, $(date -u +%FT%TZ), commit $(git -C "$HERE" rev-parse --short HEAD)"
log "Sources/ Tests/ vs 06e199f: $(git -C "$HERE" diff --stat 06e199f -- Sources Tests | tail -1)"
xcrun swiftc -O "$HERE/ax_driver.swift" -o "$DRIVER" || { log "driver build failed"; exit 1; }
python3 -I "$HERE/t046_plan.py" "$HERE/t046-rows.tsv" "$(git -C "$HERE" rev-parse --show-toplevel)" "$SHARD" "$OUT/plan-all.tsv" | tee -a "$SUMMARY"
total=$(wc -l < "$OUT/plan-all.tsv"); part=${SLICE%/*}; parts=${SLICE#*/}
from=$(( (part - 1) * total / parts + 1 )); to=$(( part * total / parts ))
sed -n "${from},${to}p" "$OUT/plan-all.tsv" > "$OUT/plan.tsv"
log "rows $from-$to of $total"

# ---------- app session (same setup as qa/e2e/runner_probe.sh)
launch() { open "$APP"; sleep 8; pgrep -x "$EXE" >/dev/null; }
quit_app() {
  osascript -e "tell application id \"$BUNDLE\" to quit" >/dev/null 2>&1; sleep 4
  pgrep -x "$EXE" >/dev/null && { pkill -TERM -x "$EXE"; sleep 4; }
  true
}
front() { osascript -e "tell application id \"$BUNDLE\" to activate" >/dev/null 2>&1; sleep 0.4; }
esc() { front; osascript -e 'tell application "System Events" to key code 53' >/dev/null 2>&1; sleep 0.8; }
panel=0
press3() { local i; for i in 1 2 3; do drv press "$BUNDLE" "$@" >/dev/null 2>&1 && return 0; sleep 1; done; return 1; }
open_dashboard() { drv press "$BUNDLE" "Ouvrir Goalong Dev" AXButton >/dev/null 2>&1 || drv press "$BUNDLE" "Ouvrir" >/dev/null 2>&1; sleep 3; }
cleanup() {
  drv dismiss-alerts "$BUNDLE" >/dev/null 2>&1
  esc
  [[ $panel == 1 ]] && { drv status-item "$BUNDLE" >/dev/null 2>&1; sleep 1; panel=0; }
  drv close-extra "$BUNDLE" "Goalong History — Dev" >/dev/null 2>&1
  true
}
# Navigation vocabulary (as qa/e2e/lot1_steps.sh): nav:SECTION pane:PANE p:LABEL (required) pp:ID-PREFIX (required, first id starting with it) o:LABEL (optional)
# si (status item) pc (panel closed itself) w:N set:ID\ 0|1 t:DISCLOSURE|TARGET. Prints the failed required steps.
# L3d: pp:A|B tries each prefix in turn (blocking suggestions are gone once a list exists); ty:NEEDLE=TEXT types into
# a field; pb:LABEL / pm:LABEL press an AXButton / AXMenuItem only; mi:TOP1,TOP2|ITEM picks an app-menu item;
# pu:PRESS|NEEDLE presses PRESS until NEEDLE shows (onboarding steps).
navigate() {
  local miss="" c
  for c in "$@"; do
    case "$c" in
      nav:*) press3 "sidebar-${c#nav:}" || miss+="$c;"; sleep 1.5
             # Activité keeps its detail view (usage, rhythm...) between rows: back to the day first.
             [[ $c == nav:overview ]] && drv press "$BUNDLE" activity-detail-back >/dev/null 2>&1 && sleep 1 ;;
      t:*) local d="${c#t:}"; d="${d%%|*}"; local x="${c#*|}"  # t:DISCLOSURE|TARGET: open the disclosure only if needed
           drv press "$BUNDLE" "$x" >/dev/null 2>&1 || { drv press "$BUNDLE" "$d" >/dev/null 2>&1; sleep 1
             drv press "$BUNDLE" "$x" >/dev/null 2>&1 || miss+="$c;"; }; sleep 1.5 ;;
      pane:*) press3 sidebar-settings || miss+="sidebar-settings;"; sleep 1
              drv press "$BUNDLE" settings-back >/dev/null 2>&1 && sleep 1
              if [[ "${c#pane:}" != home ]]; then press3 "settings-${c#pane:}" || miss+="$c;"; sleep 1.5; fi ;;
      p:*) drv press "$BUNDLE" "${c#p:}" >/dev/null 2>&1 || miss+="$c;"; sleep 1 ;;
      pp:*) local ok=0 a; IFS='|' read -ra alts <<< "${c#pp:}"
            for a in "${alts[@]}"; do drv pressprefix "$BUNDLE" "$a" >/dev/null 2>&1 && { ok=1; break; }; done
            ((ok)) || miss+="$c;"; sleep 1 ;;
      pu:*) local u="${c#pu:}" k  # pu:PRESS|NEEDLE: press PRESS (onboarding-continue) until NEEDLE is in the AX tree.
            for k in 1 2 3 4; do drv dump "$BUNDLE" "$RUNNER_TEMP/pu.txt" >/dev/null 2>&1
              grep -qF -- "${u#*|}" "$RUNNER_TEMP/pu.txt" && break
              drv press "$BUNDLE" "${u%%|*}" >/dev/null 2>&1 || { miss+="$c;"; break; }; sleep 3; done ;;
      ty:*) local f="${c#ty:}"; drv settext "$BUNDLE" "${f%%=*}" "${f#*=}" >/dev/null 2>&1 || miss+="$c;"; sleep 1 ;;
      pb:*) drv press "$BUNDLE" "${c#pb:}" AXButton >/dev/null 2>&1 || miss+="$c;"; sleep 1 ;;
      pm:*) drv press "$BUNDLE" "${c#pm:}" AXMenuItem >/dev/null 2>&1 || miss+="$c;"; sleep 1 ;;
      mi:*) local m="${c#mi:}" ok=0 top; IFS=',' read -ra tops <<< "${m%%|*}"
            for top in "${tops[@]}"; do drv menu "$BUNDLE" "$top" "${m#*|}" >/dev/null 2>&1 && { ok=1; break; }; done
            ((ok)) || miss+="$c;"; sleep 1.5 ;;
      o:*) drv press "$BUNDLE" "${c#o:}" >/dev/null 2>&1; sleep 1 ;;
      si) drv status-item "$BUNDLE" >/dev/null 2>&1 && panel=$((1 - panel)) || miss+="si;"; sleep 2 ;;
      pc) panel=0 ;;
      set:*) drv set "$BUNDLE" ${c#set:} >/dev/null 2>&1 || miss+="$c;"; sleep 1 ;;
      w:*) sleep "${c#w:}" ;;
    esac
  done
  printf '%s' "$miss"
}
rowshot() { screencapture -x "$ROWS/$1.png"; sips -Z 1280 "$ROWS/$1.png" >/dev/null 2>&1; drv dump "$BUNDLE" "$ROWS/ax/$1.txt" >/dev/null 2>&1; }
record() { # id verdict png ax cause detail
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$SHARD" "$2" "$3" "$4" "$5" "$(printf '%s' "$6" | tr '\t\n' '  ' | cut -c1-400)" >> "$RESULTS"
}

ui_row() { # id kind nav mode role needle action
  local id="$1" kind="$2" navs="$3" mode="$4" role="$5" needle="$6" action="$7" miss out st verdict cause
  pgrep -x "$EXE" >/dev/null || { launch; open_dashboard; }
  front
  eval "set -- $navs"
  miss="$(navigate "$@")"
  out="$(drv act "$BUNDLE" "$action" "$mode" "$role" "$needle" "$([[ $kind == trigger ]] && echo 0 || echo 3)" 2>&1)"; st=$?
  sleep 0.5; rowshot "$id"
  case "$st" in
    0) verdict=pass; cause="" ;;
    1) verdict=fail; cause="check" ;;
    5) if [[ $kind == trigger ]]; then verdict=N/A; cause="trigger-not-scripted"; else verdict=fail; cause="not-found"; fi ;;
    *) verdict=fail; cause="driver-exit-$st" ;;
  esac
  [[ -n $miss && $verdict == fail ]] && cause="nav($miss)$cause"
  record "$id" "$verdict" "rows/$id.png" "rows/ax/$id.txt" "$cause" "$out"
  cleanup
}

finish_onboarding() {
  local i
  for i in 1 2 3 4; do drv press "$BUNDLE" onboarding-continue >/dev/null 2>&1 || break; sleep 3
    drv press "$BUNDLE" "Plus tard" AXButton >/dev/null 2>&1 && sleep 2; done
  screencapture -x "$OUT/setup/onboarding-done.png"
}

row_verdict() { # kind status -> "verdict cause"
  case "$2" in
    0) echo "pass -" ;;
    1) echo "fail check" ;;
    5) [[ $1 == trigger ]] && echo "N/A trigger-not-scripted" || echo "fail not-found" ;;
    *) echo "fail driver-exit-$2" ;;
  esac
}

log "== synthetic data (runner VM, no real data)"
rm -rf "$DATA"; mkdir -p "$DATA"; chmod 700 "$DATA"
touch "$DATA/.goalong-dev-seed-v3"
echo "Synthetic E2E data dir, GitHub runner $(date -u +%FT%TZ)" > "$DATA/SYNTHETIC-E2E.txt"
printf 'Note de test synthétique T-046.\nAucune donnée réelle.\n' > "$RUNNER_TEMP/synthetic-note.txt"
# L3b prepared state: 14 days of activity (same seed as L4), and one local Claude Code conversation in the
# runner's own HOME (disposable VM) for the Conversations IA source.
python3 -I "$HERE/seed_events.py" "$DATA" --days 14 --per-day 720 --today | tee -a "$SUMMARY"
conv="$HOME/.claude/projects/-tmp-t046"; mkdir -p "$conv"
ts="$(date -u -v-2H +%FT%TZ)"; sid="7e046000-0000-4000-8000-000000000046"
printf '%s\n' \
  "{\"type\":\"user\",\"sessionId\":\"$sid\",\"cwd\":\"/tmp/t046\",\"timestamp\":\"$ts\",\"uuid\":\"u1\",\"message\":{\"role\":\"user\",\"content\":\"Conversation synthétique T-046\"}}" \
  "{\"type\":\"assistant\",\"sessionId\":\"$sid\",\"cwd\":\"/tmp/t046\",\"timestamp\":\"$ts\",\"uuid\":\"a1\",\"parentUuid\":\"u1\",\"message\":{\"role\":\"assistant\",\"model\":\"synthetic\",\"content\":[{\"type\":\"text\",\"text\":\"Réponse synthétique.\"}],\"usage\":{\"input_tokens\":10,\"output_tokens\":5}}}" \
  > "$conv/$sid.jsonl"
launch || log "app did not start"
drv status-item "$BUNDLE" >/dev/null 2>&1; sleep 2
open_dashboard
screencapture -x "$OUT/setup/first-launch.png"; drv dump "$BUNDLE" "$OUT/setup/first-launch.txt" >/dev/null 2>&1

# Onboarding rows first, on the fresh app, with no cleanup between them (the plan puts them first).
while IFS=$'\037' read -r -u 3 id kind navs mode role needle action na screen; do
  [[ $screen == Onboarding ]] || continue
  echo "$id" >> "$OUT/done.ids"
  if [[ $kind == na ]]; then record "$id" N/A "" "" na "$na"; continue; fi
  # L3d: an onboarding row may need its step first (navs = onboarding-continue presses, from t046-nav.tsv @onboarding).
  if [[ -n $navs ]]; then eval "set -- $navs"; navigate "$@" >/dev/null; fi
  out="$(drv act "$BUNDLE" "$action" "$mode" "$role" "$needle" 0 2>&1)"; st=$?
  rowshot "$id"; drv dismiss-alerts "$BUNDLE" >/dev/null 2>&1
  read -r v c <<< "$(row_verdict "$kind" "$st")"
  record "$id" "$v" "rows/$id.png" "rows/ax/$id.txt" "${c#-}" "$out"
done 3< <(tr "\t" "\037" < "$OUT/plan.tsv")
finish_onboarding

log "== permissions granted in the runner TCC.db, relaunch"
quit_app
NOW=$(date +%s)
codesign -d -r- "$APP" 2>/dev/null | sed -n 's/^designated => //p' > "$RUNNER_TEMP/req.txt"
CSREQ=NULL
csreq -r "$RUNNER_TEMP/req.txt" -b "$RUNNER_TEMP/req.bin" 2>/dev/null && CSREQ="X'$(xxd -p "$RUNNER_TEMP/req.bin" | tr -d '\n')'"
for svc in kTCCServiceAccessibility kTCCServiceListenEvent kTCCServiceScreenCapture kTCCServicePostEvent; do
  sudo sqlite3 "/Library/Application Support/com.apple.TCC/TCC.db" \
    "INSERT OR REPLACE INTO access VALUES('$svc','$BUNDLE',0,2,4,1,$CSREQ,NULL,0,'UNUSED',NULL,0,$NOW,NULL,NULL,'UNUSED',$NOW);" 2>>"$SUMMARY"
done
sudo killall tccd 2>/dev/null; killall tccd 2>/dev/null; sleep 2
launch; drv status-item "$BUNDLE" >/dev/null 2>&1; panel=1; sleep 2; open_dashboard; cleanup
log "== recording on, modules on, synthetic activity"
log "nav miss: $(navigate pane:recording p:source-localComputerHistory w:3 o:recording-setup-confirm w:2)"; cleanup
log "nav miss: $(navigate pane:modules "set:settings-module-concentration 1" "set:settings-module-blocking 1" \
  "set:settings-module-braise 1" "set:settings-module-ambiance 1" w:2)"; cleanup
# L3b: planned tasks and today's commitment through the app's own CLI (it talks to the running app), and the
# conversation source switched on (a button while the source is off, so a press, not set:).
log "== prepared state: tasks, commitment, conversation source"
xcrun swift build --product goalong > "$OUT/setup/cli-build.log" 2>&1 || log "goalong CLI build failed"
GOALONG="$(xcrun swift build --show-bin-path)/goalong"
for t in "Rédiger la note T-046" "Relire le rapport synthétique" "Préparer la démo"; do
  tmo 60 "$GOALONG" --root "$DATA" plan add "$t" --estimate 45 >> "$SUMMARY" 2>&1 || log "plan add failed: $t"
done
tmo 60 "$GOALONG" --root "$DATA" commitment set --day today --kind work --target 2h >> "$SUMMARY" 2>&1 || log "commitment set failed"
# L3d: a saved work definition (Mon travail rows: Corriger, Autoriser…, the studio prompt) typed through the UI.
log "nav miss: $(navigate nav:work o:monitoring-edit-goals "ty:monitoring-work-goals=Rédiger le rapport T-046 et préparer la démo" \
  "ty:monitoring-work-apps=TextEdit, Terminal, Xcode" "ty:monitoring-work-content=rapport, démo, tests" \
  "ty:monitoring-procrastination=vidéos, réseaux sociaux" p:monitoring-save-goals w:2)"; cleanup
log "nav miss: $(navigate nav:history p:"Conversations locales" w:2 o:source-aiConversations w:3 o:"Détecter les dossiers courants" w:3)"; cleanup
open -a TextEdit "$RUNNER_TEMP/synthetic-note.txt"; sleep 3; drv input 60 >> "$SUMMARY"
open -a Safari; sleep 3; drv input 30 >> "$SUMMARY"
front; sleep 3
screencapture -x "$OUT/setup/ready.png"; drv dump "$BUNDLE" "$OUT/setup/ready.txt" >/dev/null 2>&1

# ---------- S4: CLI, make targets, background behaviors (transcripts drawn as PNG)
textproof() { cp "$1" "$ROWS/ax/$2.txt"; drv textshot "$1" "$ROWS/$2.png" >/dev/null 2>&1; }
if [[ $SHARD == S4 ]]; then
  log "== S4: goalong CLI"
  xcrun swift build --product goalong > "$OUT/setup/cli-build.log" 2>&1
  GOALONG="$(xcrun swift build --show-bin-path)/goalong"
  mkdir -p "$OUT/cli"
  python3 -I "$HERE/t046_cli.py" "$GOALONG" "$DATA" "$OUT/plan.tsv" "$OUT/cli" > "$OUT/cli/verdicts.tsv" 2>>"$SUMMARY"
  while IFS=$'\037' read -r -u 3 id v c d; do
    textproof "$OUT/cli/$id.txt" "$id"; record "$id" "$v" "rows/$id.png" "rows/ax/$id.txt" "$c" "$d"
  done 3< <(tr "\t" "\037" < "$OUT/cli/verdicts.tsv")
  log "== S4: background behaviors (app log, data folder, processes)"
  ev="$OUT/bg-evidence.txt"
  { echo "== data folder"; find "$DATA" -maxdepth 3 -print 2>/dev/null | sed "s#$DATA#DATA#"
    echo "== diagnostics"; cat "$DATA"/SupportDiagnostics/*/diagnostics.log 2>/dev/null | tail -n 3000
    echo "== unified log (app process, 40 min)"; /usr/bin/log show --last 40m --style compact --predicate "process == \"$EXE\"" 2>/dev/null | tail -n 4000
    echo "== processes"; ps -axo pid,comm | grep -i goalong
  } > "$ev" 2>&1
  while IFS=$'\t' read -r -u 3 id rx; do
    grep -q "^$id"$'\t' "$OUT/plan.tsv" || continue
    { echo "$id — trace attendue : /$rx/ (insensible à la casse)"; grep -Eim 25 -- "$rx" "$ev"; } > "$OUT/cli/$id.txt"
    textproof "$OUT/cli/$id.txt" "$id"
    if [[ $(wc -l < "$OUT/cli/$id.txt") -gt 1 ]]; then record "$id" pass "rows/$id.png" "rows/ax/$id.txt" "" "trace /$rx/"
    else record "$id" N/A "rows/$id.png" "rows/ax/$id.txt" no-trace "aucune trace /$rx/ sur le runner (coupé en Dev ou non déclenché)"; fi
  done 3< "$HERE/t046-bg.tsv"
  quit_app
  log "== S4: make targets and install scripts (runner only; clean last)"
  # Expected per row: "the target runs (or make -n lists the recipe); exit code recorded". Heavy suites (run by
  # the coverage/gallery jobs of L1) get make -n; the others run for real, capped at 25 min, and a timeout
  # falls back to make -n. Order: cheap first, clean last.
  mkdir -p "$OUT/stub"; printf '#!/bin/sh\ncat >/dev/null\necho "Keep data"\n' > "$OUT/stub/osascript"; chmod +x "$OUT/stub/osascript"
  HEAVY="make test|make test-ui|make gallery|make gallery-compare|make check"
  for spec in "make test" "make test-ui" "make gallery" "make gallery-compare" "make check" "make dev-status" \
              "make gallery-index" "make gallery-diff" "make gallery-accept" "make gallery-clean" "make audit" \
              "make dev" "make dev-stop" "make build" "make app" "make dmg" "make install" "install.sh" "Install.command" \
              "make uninstall" "uninstall.sh" "Uninstall.command" "make install-source" "make clean"; do
    id="$(awk -F'\t' -v s="$spec" '$1 ~ /^J-/ && $6==s {print $1; exit}' "$OUT/plan.tsv")"
    [[ -n $id ]] || continue
    case "$spec" in
      make\ dev) cmd=(make dev NO_LAUNCH=1 DEV_APP_DIR="$RUNNER_TEMP/devapp") ;;
      make\ *) cmd=($spec) ;;
      # The .command files ask with an AppleScript dialog: a PATH stub answers its default ("Keep data", "Install").
      *.command) cmd=(env PATH="$OUT/stub:$PATH" bash "./$spec") ;;
      *) cmd=("./$spec") ;;
    esac
    [[ "|$HEAVY|" == *"|$spec|"* ]] && cmd=(make -n "${spec#make }")
    t=$(date +%s)
    { echo "$id — \$ ${cmd[*]}"; tmog 1500 "${cmd[@]}" < /dev/null 2>&1 | tail -n 60; echo "# exit ${PIPESTATUS[0]} in $(( $(date +%s) - t )) s"; } > "$OUT/cli/$id.txt"
    rc="$(sed -n 's/^# exit \([0-9]*\) .*/\1/p' "$OUT/cli/$id.txt")"
    if [[ $rc == 142 && $spec == make\ * ]]; then
      { echo; echo "# timeout 25 min: recipe instead"; echo "\$ make -n ${spec#make }"; make -n "${spec#make }" < /dev/null 2>&1 | tail -n 30
        echo "# make -n exit ${PIPESTATUS[0]}"; } >> "$OUT/cli/$id.txt"
      grep -q '^# make -n exit 0$' "$OUT/cli/$id.txt" && rc=0n
    fi
    if [[ $spec == "make dev" ]] && grep -q 'requires the release Apple Development identity' "$OUT/cli/$id.txt"; then
      { echo; echo "# runner without the release signing identity (documented refusal): recipe"; echo "\$ make -n dev"
        make -n dev NO_LAUNCH=1 DEV_APP_DIR="$RUNNER_TEMP/devapp" < /dev/null 2>&1 | tail -n 30; echo "# make -n exit ${PIPESTATUS[0]}"; } >> "$OUT/cli/$id.txt"
      grep -q '^# make -n exit 0$' "$OUT/cli/$id.txt" && rc=0p
    fi
    textproof "$OUT/cli/$id.txt" "$id"
    if [[ $rc == 0p ]]; then record "$id" pass "rows/$id.png" "rows/ax/$id.txt" "precondition" "refus documenté (identité de signature absente du runner), make -n liste la recette"
    elif [[ $rc == 0 ]]; then record "$id" pass "rows/$id.png" "rows/ax/$id.txt" "" "${cmd[*]} exit 0"
    elif [[ $rc == 0n ]]; then record "$id" pass "rows/$id.png" "rows/ax/$id.txt" "recipe" "exécution > 25 min (alarme), make -n liste la recette"
    elif [[ $rc == 2 ]] && grep -q "run introuvable" "$OUT/cli/$id.txt"; then
      record "$id" pass "rows/$id.png" "rows/ax/$id.txt" "precondition" "exit 2 documenté : aucun run de galerie sur ce runner (make gallery d’abord)"
    else record "$id" fail "rows/$id.png" "rows/ax/$id.txt" "exit-$rc" "$(tail -n 3 "$OUT/cli/$id.txt")"; fi
    log "[$id] ${cmd[*]}: exit $rc"
  done
  # Rows not reached above (unknown spec): N/A with the reason.
  while IFS=$'\037' read -r -u 3 id kind _ _ _ needle _ na _; do
    grep -q "^$id"$'\t' "$RESULTS" || record "$id" N/A "" "" unhandled "S4 : pas de traitement pour « $needle » $na"
  done 3< <(tr "\t" "\037" < "$OUT/plan.tsv")
else
  log "== UI rows"
  while IFS=$'\037' read -r -u 3 id kind navs mode role needle action na screen; do
    grep -qx "$id" "$OUT/done.ids" 2>/dev/null && continue
    if [[ $kind == na ]]; then record "$id" N/A "" "" na "$na"; continue; fi
    ui_row "$id" "$kind" "$navs" "$mode" "$role" "$needle" "$action"
    log "[$id] $(tail -n 1 "$RESULTS" | cut -f3,6)"
  done 3< <(tr "\t" "\037" < "$OUT/plan.tsv")
  if [[ $SHARD == S1 && ! -f $HERE/t046-only.txt ]]; then  # Targeted run (L3b): screens already taken.
    # Screens without a gallery capture: PNG + AX dump per screen, then one PNG per scroll step (full height).
    log "== extra screens (qa/e2e/t046-screens.tsv)"
    mkdir -p "$OUT/screens/ax"
    while IFS=$'\t' read -r -u 3 name navs scrolls; do
      [[ -z $name || $name == \#* ]] && continue
      pgrep -x "$EXE" >/dev/null || { launch; open_dashboard; }
      front; eval "set -- $navs"; miss="$(navigate "$@")"; sleep 1
      screencapture -x "$OUT/screens/$name.png"; drv dump "$BUNDLE" "$OUT/screens/ax/$name.txt" >/dev/null 2>&1
      for ((k = 1; k <= scrolls; k++)); do drv scroll "$BUNDLE" >/dev/null 2>&1; sleep 1; screencapture -x "$OUT/screens/$name-$k.png"; done
      log "[screen $name] miss=${miss:-none} scrolls=$scrolls"
      cleanup
    done 3< "$HERE/t046-screens.tsv"
    # 39 Menu de l'app: each menu-bar menu of Goalong Dev, opened then closed.
    front
    for top in "Goalong Dev" "Goalong History Dev" "Fichier" "Édition" "Présentation" "Fenêtre" "Aide"; do
      drv menu "$BUNDLE" "$top" >/dev/null 2>&1 && { sleep 1; screencapture -x "$OUT/screens/39-menu-$top.png"; } || log "[screen 39-menu-$top] not found"
      esc
    done
    log "[screen 37-installation] no UI: the S4 transcripts of install.sh / Install.command are the proof"
    for f in "$OUT"/screens/*.png; do sips -Z 1280 "$f" >/dev/null 2>&1; done
  fi
  quit_app
fi
log "== results: $(tail -n +2 "$RESULTS" | cut -f3 | sort | uniq -c | tr '\n' ' ')"
