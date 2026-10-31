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
printf 'id\tshard\tverdict\tproof_png\tax_dump\tcause\tdetail\tchanged\tenabled\n' > "$RESULTS"
log() { echo "$*" | tee -a "$SUMMARY"; }
# perl alarm: macOS has no timeout(1). A hung AX call never stalls the shard.
tmo() { local s="$1"; shift; perl -e 'alarm shift; exec @ARGV' "$s" "$@"; }
# Like tmo, but the command runs in its own process group and the whole group dies at the alarm (exit 142):
# a child (an osascript dialog, say) cannot keep the output pipe open after its shell is killed.
tmog() { perl -e '$s=shift; $p=fork; if(!$p){setpgrp(0,0); exec @ARGV; exit 127}
  $SIG{ALRM}=sub{kill "KILL",-$p; waitpid($p,0); exit 142}; alarm $s; waitpid($p,0); exit($?>>8)' "$1" "${@:2}"; }
# L3m: a row has ROW_MAX seconds; past its deadline every driver call fails at once (exit 142), so a mute AX tree
# costs one row, not the job (L3l: three jobs hit 125 min).
ROW_END=0; ROW_MAX=150
drv() { if (( ROW_END > 0 && $(date +%s) > ROW_END )); then return 142; fi; tmo 40 "$DRIVER" "$@"; }

log "== shard $SHARD slice $SLICE, $(date -u +%FT%TZ), commit $(git -C "$HERE" rev-parse --short HEAD)"
log "Sources/ Tests/ vs 973ff6a: $(git -C "$HERE" diff --stat 973ff6a -- Sources Tests | tail -1)"
xcrun swiftc -O "$HERE/ax_driver.swift" -o "$DRIVER" || { log "driver build failed"; exit 1; }
# L3m: Blocage rows (screen Blocage…, or a nav through the Blocage page) run in their own job SB, the only one with
# the Blocage seed (an active block and a locked list changed other pages, and the AX tree went mute in L3l).
blk='$9 ~ /^Blocage/ || ($3 ~ /blocking/ && $1 !~ /^J-(0228|0858)$/) || $1 ~ /^J-(0108|0109|0110|0980)$/'  # L3n: J-0228/J-0858 need the Distractions suggestions, which the Blocage seed removes
if [[ $SHARD == SB ]]; then
  : > "$OUT/plan-all.tsv"
  for s in S1 S2 S3; do
    python3 -I "$HERE/t046_plan.py" "$HERE/t046-rows.tsv" "$(git -C "$HERE" rev-parse --show-toplevel)" "$s" "$OUT/plan-$s.tsv" | tee -a "$SUMMARY"
    awk -F'\t' "$blk" "$OUT/plan-$s.tsv" >> "$OUT/plan-all.tsv"
  done
else
  python3 -I "$HERE/t046_plan.py" "$HERE/t046-rows.tsv" "$(git -C "$HERE" rev-parse --show-toplevel)" "$SHARD" "$OUT/plan-raw.tsv" | tee -a "$SUMMARY"
  if [[ $SHARD == S4 ]]; then cp "$OUT/plan-raw.tsv" "$OUT/plan-all.tsv"; else awk -F'\t' "!($blk)" "$OUT/plan-raw.tsv" > "$OUT/plan-all.tsv"; fi
fi
total=$(wc -l < "$OUT/plan-all.tsv"); part=${SLICE%/*}; parts=${SLICE#*/}
from=$(( (part - 1) * total / parts + 1 )); to=$(( part * total / parts ))
sed -n "${from},${to}p" "$OUT/plan-all.tsv" > "$OUT/plan.tsv"
log "rows $from-$to of $total"
# L3e: an empty slice (S4 with a t046-only.txt list of UI rows) stops here, before the app session.
if [[ ! -s "$OUT/plan.tsv" ]]; then log "empty plan: nothing to run"; : > "$RESULTS"; exit 0; fi

# ---------- app session (same setup as qa/e2e/runner_probe.sh)
launch() { open "$APP"; sleep 8; pgrep -x "$EXE" >/dev/null; }
quit_app() {
  osascript -e "tell application id \"$BUNDLE\" to quit" >/dev/null 2>&1; sleep 4
  pgrep -x "$EXE" >/dev/null && { pkill -TERM -x "$EXE"; sleep 4; }
  pgrep -x "$EXE" >/dev/null && { pkill -KILL -x "$EXE"; sleep 2; }  # L3m: runner VM only (a mute app ignores TERM).
  true
}
front() { tmo 15 osascript -e "tell application id \"$BUNDLE\" to activate" >/dev/null 2>&1; sleep 0.4; }
esc() { front; osascript -e 'tell application "System Events" to key code 53' >/dev/null 2>&1; sleep 0.8; }
panel=0; mute=0
press3() { local i; for i in 1 2 3; do drv press "$BUNDLE" "$@" >/dev/null 2>&1 && return 0; sleep 1; done; return 1; }
open_dashboard() { drv press "$BUNDLE" "Ouvrir Goalong Dev" AXButton >/dev/null 2>&1 || drv press "$BUNDLE" "Ouvrir" >/dev/null 2>&1; sleep 3; }
cleanup() {
  drv dismiss-alerts "$BUNDLE" sheets >/dev/null 2>&1
  esc
  drv close-popover "$BUNDLE" >/dev/null 2>&1; panel=0  # L3m: `si` runs in a subshell, $panel was never reliable.
  drv close-extra "$BUNDLE" "Goalong History — Dev" >/dev/null 2>&1
  true
}
# Navigation vocabulary (as qa/e2e/lot1_steps.sh): nav:SECTION pane:PANE p:LABEL (required) pp:ID-PREFIX (required, first id starting with it) o:LABEL (optional)
# si (status item) pc (panel closed itself) w:N set:ID\ 0|1 t:DISCLOSURE|TARGET. Prints the failed required steps.
# L3d: pp:A|B tries each prefix in turn (blocking suggestions are gone once a list exists); ty:NEEDLE=TEXT types into
# a field; pb:LABEL / pm:LABEL press an AXButton / AXMenuItem only; mi:TOP1,TOP2|ITEM picks an app-menu item;
# pu:PRESS|NEEDLE presses PRESS until NEEDLE shows (onboarding steps).
# L3e: px:TEXT presses the control whose title/description equals TEXT; pk:OPENER|ITEM opens a menu and picks ITEM in
# one driver process (empty ITEM: the menu stays open for the row's act; the tree after the press goes to
# rows/ax/<row>-menu.txt); tk:FIELD=TEXT types TEXT as key events into a field; dump:NAME saves rows/ax/<row>-NAME.txt.
# L3f: ck:LABEL=0|1 sets a checkbox found by id or exact label (idempotent, unlike p:); pkc:OPENER|ITEM as pk: but
# clicks ITEM with the mouse; rec:off turns this Mac's recording off (ui_row turns it back on after the row).
# L3g: ex:ID|TEXT is not a step: it is the row's effect check, passed to ax_driver act (a click with changed=0
# passes only if ID or TEXT is in the tree after the press).
# L3h: wf:TEXT waits (12 s) until TEXT shows, else presses the last nav:/p:/pb:/px:/pp: step again and waits once more;
# sd:LABEL=DAYS@HOUR sets a date picker (sd:Activité depuis=-1@9: yesterday 09:00); pick:ITEM is not a step: the row's
# act opens its target's menu and chooses ITEM (ax_driver act, 9th argument). ck: also opens a disclosure triangle.
# L3j: nm waits for the next minute (+1 s): « Actualisé à HH:MM » then moves when the refresh runs (J-0467).
navigate() {
  local miss="" c last=""
  for c in "$@"; do
    case "$c" in nav:*|p:*|pb:*|px:*|pp:*) last="$c" ;; esac
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
      seed:*) row_seed "${c#seed:}" || miss+="$c;" ;;
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
      nm) sleep $(( 61 - 10#$(date +%S) )) ;;
      px:*) drv pressexact "$BUNDLE" "${c#px:}" >/dev/null 2>&1 || miss+="$c;"; sleep 1 ;;
      pk:*) local k="${c#pk:}"
        drv popup "$BUNDLE" "${k%%|*}" "${k#*|}" "$ROWS/ax/${CUR:-setup}-menu.txt" >/dev/null 2>&1 || miss+="$c;"; sleep 1 ;;
      tk:*) local f="${c#tk:}"; drv typekeys "$BUNDLE" "${f%%=*}" "${f#*=}" >/dev/null 2>&1 || miss+="$c;"; sleep 1 ;;
      ck:*) local f="${c#ck:}"; drv set "$BUNDLE" "${f%=*}" "${f##*=}" >/dev/null 2>&1 || miss+="$c;"; sleep 1 ;;
      pkc:*) local k="${c#pkc:}"
        drv popup "$BUNDLE" "${k%%|*}" "${k#*|}" "$ROWS/ax/${CUR:-setup}-menu.txt" click >/dev/null 2>&1 || miss+="$c;"; sleep 1 ;;
      rec:off) miss+="$(navigate pane:recording "set:source-localComputerHistory 0" w:2)"; cleanup >/dev/null ;;
      wf:*) drv waitfor "$BUNDLE" "${c#wf:}" 12 >/dev/null 2>&1 || { [[ -n $last ]] && navigate "$last" >/dev/null
              drv waitfor "$BUNDLE" "${c#wf:}" 12 >/dev/null 2>&1 || miss+="$c;"; } ;;
      sd:*) local f="${c#sd:}" v; v="${f##*=}"
            drv setdate "$BUNDLE" "${f%=*}" "${v%@*}" "${v#*@}" >/dev/null 2>&1 || miss+="$c;"; sleep 1 ;;
      dump:*) drv dump "$BUNDLE" "$ROWS/ax/${CUR:-setup}-${c#dump:}.txt" >/dev/null 2>&1 ;;
    esac
  done
  printf '%s' "$miss"
}
rowshot() { screencapture -x "$ROWS/$1.png"; sips -Z 1280 "$ROWS/$1.png" >/dev/null 2>&1; drv dump "$BUNDLE" "$ROWS/ax/$1.txt" >/dev/null 2>&1; }
record() { # id verdict png ax cause detail; L3g: changed and enabled columns, copied from the driver's output.
  local ch en
  ch="$(printf '%s\n' "$6" | sed -n 's/^changed=//p' | tail -n 1)"; en="$(printf '%s\n' "$6" | sed -n 's/^enabled=//p' | tail -n 1)"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$SHARD" "$2" "$3" "$4" "$5" "$(printf '%s' "$6" | tr '\t\n' '  ' | cut -c1-400)" "$ch" "$en" >> "$RESULTS"
}
expect_of() { local c; for c in "$@"; do [[ $c == ex:* ]] && { printf '%s' "${c#ex:}"; return; }; done; }
pick_of() { local c; for c in "$@"; do [[ $c == pick:* ]] && { printf '%s' "${c#pick:}"; return; }; done; }

# L3n lot 5: seed:NAME puts one failure or account state in place in the middle of a row (fixed list, no eval);
# ui_row undoes every seed after the row (row_unseed). Sources: L3-na-analyse.tsv, /tmp/l3n/seeds.md (research, file:line).
# L3n extension point: seed:NAME not listed in row_seed runs qa/e2e/seed.d/NAME.sh seed (then NAME.sh unseed after the row),
# env DATA BUNDLE GOALONG OUT, 60 s max, output in summary.txt. Exit 0 = seeded; 3 = seeded, restart the app (state read
# at launch); other = nav miss. One file per seed, written by a helper; row_seed's own cases win on a name clash.
seed_ext() { # seed|unseed NAME
  [[ $2 =~ ^[a-z0-9-]+$ && -f "$HERE/seed.d/$2.sh" ]] || return 1
  local rc; DATA="$DATA" BUNDLE="$BUNDLE" GOALONG="$GOALONG" OUT="$OUT" tmo 60 bash "$HERE/seed.d/$2.sh" "$1" >> "$SUMMARY" 2>&1; rc=$?
  log "[$CUR] seed.d/$2.sh $1: exit $rc"
  if [[ $rc == 3 ]]; then quit_app; launch; open_dashboard; front; rc=0; fi
  return $rc
}
row_seed() {
  local tok
  case "$1" in
    site|site-unmanaged)  # website account linked (GoalongSiteSubmission.swift:130: regular file, 0600 exactly)
      mkdir -p "$DATA/website-connections"; chmod 700 "$DATA/website-connections"
      if [[ $1 == site ]]; then tok="$DATA/website-connections/$(uuidgen).token"; else tok="$DATA/t046-token.txt"; fi
      printf 'tok-t046' > "$tok"; chmod 600 "$tok"
      defaults write "$BUNDLE" goalong.website.origin "https://example-t046.invalid"
      defaults write "$BUNDLE" goalong.website.tokenFilePath "$tok" ;;
    health)  # one saved Apple Health day (GoalongHealthArchive.validate)
      mkdir -p "$DATA/health"; chmod 700 "$DATA/health"; local d; d=$(date -v-1d +%F)
      printf '{"version":2,"source":"apple-health","days":[{"date":"%s","title":"Santé T-046","summary":"","outcomes":[],"activities":[],"telemetry":{"timezone":"Europe/Paris","receivedAt":"%s","state":"completed","devices":[],"websites":null,"agent":null},"health":{"version":1,"coverage":"partial","workouts":[],"metrics":[{"key":"sleepSeconds","value":25200,"unit":"s","source":"Synthetic","sampleCount":1,"aggregation":"interval-union"}]}}]}' \
        "$d" "$(date -u +%FT%TZ)" > "$DATA/health/$d.json"; chmod 600 "$DATA/health/$d.json" ;;
    analysis-link)  # a derived file that is not a regular file: the delete preflight refuses (DerivedHistoryCleaner.swift:67)
      mkdir -p "$DATA/analysis"; [[ -e "$DATA/analysis/$(date +%F).analysis.json" ]] || ln -s /dev/null "$DATA/analysis/$(date +%F).analysis.json" ;;
    task-commit)  # an open commitment on a task blocks its rename (GoalongWorkStore.swift:233)
      tmo 60 "$GOALONG" --root "$DATA" commitment set --day today --kind task --task "Rapport T-046" --target 30m >> "$SUMMARY" 2>&1 ;;
    plan-bad)  # an unreadable plan day: rename ends with a notice (GoalongWorkStore.swift:242)
      mkdir -p "$DATA/Focus/plans"; printf '{bad' > "$DATA/Focus/plans/2020-01-01.json"; chmod 600 "$DATA/Focus/plans/2020-01-01.json" ;;
    consent-lock) chflags uchg "$DATA/capability-consent.json" ;;  # consent writes fail (CapabilityConsentStore persist)
    data-ro) chmod 500 "$DATA" ;;  # new files in the data folder fail (exclusions, global pause); undone after the row
    *) seed_ext seed "$1" || return 1 ;;
  esac
  echo "$1" >> "$OUT/.seeded"; sleep 1  # navigate runs in a subshell: the list lives in a file
}
row_unseed() {
  [[ -s "$OUT/.seeded" ]] || return 0
  local s; for s in $(sort -u "$OUT/.seeded"); do case "$s" in
    data-ro) chmod 700 "$DATA" ;;
    consent-lock) chflags nouchg "$DATA/capability-consent.json" ;;
    site|site-unmanaged) defaults delete "$BUNDLE" goalong.website.tokenFilePath >/dev/null 2>&1
      for k in origin accountID accountCredentialFingerprint; do defaults delete "$BUNDLE" "goalong.website.$k" >/dev/null 2>&1; done
      rm -f "$DATA/t046-token.txt"; rm -rf "$DATA/website-connections" ;;
    health) rm -f "$DATA"/health/*.json ;;
    analysis-link) [[ -L "$DATA/analysis/$(date +%F).analysis.json" ]] && rm -f "$DATA/analysis/$(date +%F).analysis.json" ;;
    task-commit) tmo 60 "$GOALONG" --root "$DATA" commitment set --day today --kind work --target 2h >> "$SUMMARY" 2>&1 ;;
    plan-bad) rm -f "$DATA/Focus/plans/2020-01-01.json" ;;
    *) seed_ext unseed "$s" ;;
  esac; done
  log "[$CUR] seeded and undone: $(sort -u "$OUT/.seeded" | tr '\n' ' ')"; rm -f "$OUT/.seeded"
}

ui_row() { # id kind nav mode role needle action
  local id="$1" kind="$2" navs="$3" mode="$4" role="$5" needle="$6" action="$7" miss out st verdict cause
  pgrep -x "$EXE" >/dev/null || { launch; open_dashboard; }
  # L3m: no menu bar window and no extra window left by an earlier row, Goalong Dev in front.
  drv close-popover "$BUNDLE" >/dev/null 2>&1; drv close-extra "$BUNDLE" "Goalong History — Dev" >/dev/null 2>&1
  # L3n: in run 41220255354 (SB 2/2) the main window was gone before the first row and no row reopened it.
  drv dump "$BUNDLE" "$OUT/.win.txt" >/dev/null 2>&1
  grep -q "role=AXWindow | title=Goalong History — Dev" "$OUT/.win.txt" || { log "[$id] start: main window absent, reopened"; drv status-item "$BUNDLE" >/dev/null 2>&1; sleep 2; open_dashboard; drv close-popover "$BUNDLE" >/dev/null 2>&1; front; }
  front; CUR="$id"; ROW_END=$(( $(date +%s) + ROW_MAX ))
  # L3j: every row starts clean: an alert or sheet left by an earlier row (J-0863) is closed first.
  local pre; pre="$(drv dismiss-alerts "$BUNDLE" sheets 2>&1)"
  [[ $pre == *"dismissed 0 alert(s)"* || -z $pre ]] || { log "[$id] start: ${pre//$'\n'/ ; }"; sleep 1; }
  eval "set -- $navs"
  miss="$(navigate "$@")"
  if [[ $kind == disc ]]; then  # L3n: discovery pass, nav + AX dump only; DISC is never sorted as a verdict.
    ROW_END=0; sleep 0.5; rowshot "$id"
    record "$id" DISC "rows/$id.png" "rows/ax/$id.txt" "${miss:+nav($miss)}discovery" "nav + dump, sans verdict"
    row_unseed; cleanup; return
  fi
  out="$(drv act "$BUNDLE" "$action" "$mode" "$role" "$needle" "$([[ $kind == trigger ]] && echo 0 || echo 3)" "$(expect_of "$@")" "$(pick_of "$@")" 2>&1)"; st=$?
  local late=$(( $(date +%s) > ROW_END )); ROW_END=0
  sleep 0.5; rowshot "$id"
  read -r verdict cause <<< "$(row_verdict "$kind" "$st")"; cause="${cause#-}"
  [[ $st == 142 ]] && ((late)) && cause="row-timeout-${ROW_MAX}s"
  [[ -n $miss && $verdict != pass ]] && cause="nav($miss)$cause"  # L3e: N/A rows show their nav miss too.
  record "$id" "$verdict" "rows/$id.png" "rows/ax/$id.txt" "$cause" "$out"
  # L3m: two mute rows in a row: restart the app (data stays on disk), so the next rows are measured.
  if [[ $st == 142 ]]; then mute=$((mute + 1)); else mute=0; fi
  if (( mute >= 2 )); then log "[$id] AX tree mute twice: app restarted"; quit_app; launch; open_dashboard; mute=0; fi
  row_unseed
  cleanup
  # L3h: a press that opened System Settings (or a Finder window, J-0365) leaves it in front: close it, app in front.
  if pgrep -x "System Settings" >/dev/null; then osascript -e 'tell application "System Settings" to quit' >/dev/null 2>&1; sleep 1; front; fi
  if [[ $navs == *app:com.apple.finder* ]]; then osascript -e 'tell application "Finder" to close every window' >/dev/null 2>&1; front; fi
  # L3f: a row that read with recording off (rec:off) turns it back on, as the setup did.
  if [[ $navs == *rec:off* ]]; then navigate pane:recording p:source-localComputerHistory w:3 o:recording-setup-confirm w:2 >/dev/null; cleanup; fi
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
    10) echo "fail no-effect" ;;    # L3g strict click: changed=0 and the row's ex: element absent.
    11) echo "fail not-a-control" ;;
    12) echo "fail disabled" ;;
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
# L3j: owner-classified tasks for those contexts (Activité « Tâches », Corriger, Nouvelle tâche: J-0452/0453/0504/0505/0488).
python3 -I "$HERE/seed_work.py" "$DATA" | tee -a "$SUMMARY"
python3 -I "$HERE/seed_analysis.py" "$DATA" "$(date +%F)" | tee -a "$SUMMARY"  # L3k: J-0526
# L3e: the work definition and a synthetic Jev key as files the app reads at launch (settext and typed UI fields do
# not reach the SwiftUI bindings, L3d). JevWorkContextStore: jev/work-context.json schema 3, <= 800 bytes;
# JevMonitor: jev/api-key, 8-1024 printable ASCII. JevLocalFiles: dir 0700, files 0600.
mkdir -p "$DATA/jev"; chmod 700 "$DATA/jev"
printf '%s' '{"schemaVersion":3,"summary":"Rédiger le rapport T-046 et préparer la démo","applications":"TextEdit, Terminal, Xcode","content":"rapport, démo, tests","procrastination":"vidéos, réseaux sociaux"}' > "$DATA/jev/work-context.json"
printf '%s' 't046-synthetic-key-not-a-real-secret' > "$DATA/jev/api-key"
chmod 600 "$DATA/jev/work-context.json" "$DATA/jev/api-key"
conv="$HOME/.claude/projects/-tmp-t046"; mkdir -p "$conv"
ts="$(date -u -v-2H +%FT%TZ)"; sid="7e046000-0000-4000-8000-000000000046"
printf '%s\n' \
  "{\"type\":\"user\",\"sessionId\":\"$sid\",\"cwd\":\"/tmp/t046\",\"timestamp\":\"$ts\",\"uuid\":\"u1\",\"message\":{\"role\":\"user\",\"content\":\"Conversation synthétique T-046\"}}" \
  "{\"type\":\"assistant\",\"sessionId\":\"$sid\",\"cwd\":\"/tmp/t046\",\"timestamp\":\"$ts\",\"uuid\":\"a1\",\"parentUuid\":\"u1\",\"message\":{\"role\":\"assistant\",\"model\":\"synthetic\",\"content\":[{\"type\":\"text\",\"text\":\"Réponse synthétique.\"}],\"usage\":{\"input_tokens\":10,\"output_tokens\":5}}}" \
  > "$conv/$sid.jsonl"
# L3j: a second common folder (Codex), so « Détecter les dossiers courants » lists two (Discovery.swift candidates).
mkdir -p "$HOME/.codex/sessions/t046"; printf '%s\n' "{\"type\":\"session_meta\",\"timestamp\":\"$ts\"}" > "$HOME/.codex/sessions/t046/rollout-t046.jsonl"
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
  set --; if [[ -n $navs ]]; then eval "set -- $navs"; navigate "$@" >/dev/null; fi
  out="$(drv act "$BUNDLE" "$action" "$mode" "$role" "$needle" 0 "$(expect_of "$@")" "$(pick_of "$@")" 2>&1)"; st=$?
  rowshot "$id"; drv dismiss-alerts "$BUNDLE" >/dev/null 2>&1
  # L3f: a row that opened System Settings (J-0807) leaves it in front: a later Return key would go there (J-0811).
  if pgrep -x "System Settings" >/dev/null; then osascript -e 'tell application "System Settings" to quit' >/dev/null 2>&1; sleep 1; front; fi
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
# L3k: the Blocage seed must exist before the module loads it (BlockingController reads it once).
if [[ $SHARD == SB ]]; then python3 -I "$HERE/seed_blocking.py" "$DATA" >> "$SUMMARY" 2>&1 || log "blocking seed failed"; fi
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
# L3k: two finished focus sessions (J-0132/0133) and a Braise night rule (J-0742), through the same CLI.
for i in 1 2; do
  tmo 60 "$GOALONG" --root "$DATA" session start --intent "T046 séance $i" --minutes 5 >> "$SUMMARY" 2>&1; sleep 2
  tmo 60 "$GOALONG" --root "$DATA" session stop --outcome done --note "note $i" >> "$SUMMARY" 2>&1 || log "session $i failed"
done
# L3l: `session stop` still opens the « C’est fait ? » review panel (L3k: it stayed over every row, S2 timed out).
# Answer it here (its « Fermer sans répondre » button; the outcome is already given), then check none is left.
sleep 2; drv dismiss-alerts "$BUNDLE" sheets >> "$SUMMARY" 2>&1
drv dump "$BUNDLE" "$OUT/setup/after-sessions.txt" >/dev/null 2>&1
grep -q concentration-review-panel "$OUT/setup/after-sessions.txt" && log "review panel still open after the session seed"
tmo 60 "$GOALONG" --root "$DATA" braise schedule add 1,2,3,4,5,6,7 22:00 06:00 >> "$SUMMARY" 2>&1 || log "braise rule failed"
# L3e: the work definition is seeded in jev/work-context.json before launch (the UI typing of L3d saved nothing).
log "nav miss: $(navigate nav:history p:"Conversations locales" w:2 o:source-aiConversations w:3 o:"Détecter les dossiers courants" w:3)"; cleanup
# L3j: that button only exists on the management page (AgentActivityPage.swift:120/132), not in Historique:
# detect the folders there, so J-0372/0373 find « Modifier le suivi de … ».
log "nav miss: $(navigate pane:recording p:"Choisir les dossiers de conversations…" w:3 o:"Détecter les dossiers courants" w:3)"; cleanup
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
  # L3n: J-0557 (Ambiance playback) needs an audio output; the runner's devices are the proof either way.
  system_profiler SPAudioDataType > "$OUT/cli/audio-devices.txt" 2>&1
  while IFS=$'\t' read -r -u 3 id rx; do
    grep -q "^$id"$'\t' "$OUT/plan.tsv" || continue
    { echo "$id — trace attendue : /$rx/ (insensible à la casse)"; grep -Eim 25 -- "$rx" "$ev"; } > "$OUT/cli/$id.txt"
    textproof "$OUT/cli/$id.txt" "$id"
    if [[ $(wc -l < "$OUT/cli/$id.txt") -gt 1 ]]; then record "$id" pass "rows/$id.png" "rows/ax/$id.txt" "" "trace /$rx/"
    elif [[ $id == J-0557 ]] && ! grep -q "Output Channels\|Default Output Device: Yes" "$OUT/cli/audio-devices.txt"; then
      record "$id" N/A "rows/$id.png" "cli/audio-devices.txt" no-audio-output "N/A justifié : le runner n’a aucune sortie audio (system_profiler SPAudioDataType, cli/audio-devices.txt)"
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
