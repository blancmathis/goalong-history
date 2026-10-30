#!/bin/bash
# French apostrophes in the searched texts are literal.
# shellcheck disable=SC1112
# T-046 hard-C: malformed imports, clock and time zone changes, crash (kill -9) and relaunch.
# GitHub-hosted runner only (see lib.sh). Usage: qa/hard/hard_c.sh DIST_DIR OUT_DIR
source "$(dirname "$0")/lib.sh"
restore_clock() {
  sudo systemsetup -settimezone Europe/Paris >/dev/null 2>&1
  sudo systemsetup -setusingnetworktime on >/dev/null 2>&1
  sudo sntp -sS time.apple.com >/dev/null 2>&1; true
}
trap restore_clock EXIT
# Picks PATH in the open panel of the frontmost app: ⌘⇧G, path, Return (go), Return (choose).
panel_pick() {
  front
  osascript -e 'tell application "System Events"' -e 'keystroke "g" using {command down, shift down}' -e 'delay 1.5' \
    -e "keystroke \"$1\"" -e 'delay 1.5' -e 'key code 36' -e 'delay 1.5' -e 'key code 36' -e 'end tell' >/dev/null 2>&1
  sleep 4
}

begin imports-malformed "Fichiers d’import cassés — export.xml Santé tronqué, vide, binaire, texte hexadécimal  : chaque fichier est refusé (message lisible dans la feuille, ou erreur CLI propre, code 1-127), rien n’est importé, pas de plantage."
reset_app_state; install_new; no_sparkle
IMP="$RUNNER_TEMP/imports"; rm -rf "$IMP"; mkdir -p "$IMP"
printf '<?xml version="1.0" encoding="UTF-8"?>\n<HealthData locale="fr_FR">\n <Record type="HKCategoryTypeIdentifierSleepAnalysis" sourceName="T046" startDate="2026-01-0' > "$IMP/tronque.xml"
: > "$IMP/vide.xml"
head -c 8192 /dev/urandom > "$IMP/binaire.xml"
head -c 4096 /dev/urandom | xxd -p > "$IMP/hexa.xml"
ls -la "$IMP" > "$CDIR/import-files.txt"
launch || fail "l’app ne démarre pas"
onboarding; dashboard
find "$DATA" -type f | sort > "$CDIR/data-files-before.txt"
for f in tronque vide binaire hexa; do
  cli "import-health-$f" import-health --file "$IMP/$f.xml" --from 2026-01-01 --to 2026-01-31; s=$?
  (( s >= 1 && s < 128 )) && obs "CLI $f.xml refusé (code $s)" || fail "CLI $f.xml : code $s"
done
for f in tronque vide binaire hexa; do
  # « Importer Apple Santé… » sits in Réglages › Avancé › Outils de partage et analyses (pane .tools).
  pane advanced || fail "Réglages › Avancé inaccessible"
  try "Outils de partage" press3 "Outils de partage et analyses"; sleep 3
  try "Importer Apple Santé" press3 "Importer Apple Santé" AXButton || { fail "bouton Importer Apple Santé absent"; continue; }
  sleep 3
  try "Choisir export.xml" press3 "Choisir export.xml" AXButton; sleep 3
  panel_pick "$IMP/$f.xml"
  try "Préparer l’aperçu local" press "Préparer l’aperçu local" AXButton; sleep 5
  shot "sante-$f"; dump "sante-$f"
  msg="$(axhas 'impossible|Impossible|illisible|invalide|erreur|Erreur|corromp|n’est pas|ne peut|Aucune|vide')" && obs "Santé $f : « ${msg:0:100} »" || obs "Santé $f : pas de message reconnu (voir capture)"
  press Fermer AXButton >/dev/null; esc
  running || { fail "l’app s’est arrêtée sur $f.xml"; launch; dashboard; }
done
find "$DATA" -type f | sort > "$CDIR/data-files-after.txt"
grep -i -E 'health|sante|santé' "$CDIR/data-files-after.txt" | grep -vxF -f "$CDIR/data-files-before.txt" > "$CDIR/health-new-files.txt"
[[ -s $CDIR/health-new-files.txt ]] && fail "fichiers Santé créés : $(head -3 "$CDIR/health-new-files.txt" | tr '\n' ' ')" || obs "aucun fichier Santé créé"
running || fail "l’app s’est arrêtée"
finish

begin ambiance-broken "Module Ambiance activé, puis « Ma musique › Ajouter… » : un .m4a vide, un .mp3 binaire et un .mp3 supprimé après ajout. Lire chaque fichier cassé affiche « Lecture impossible… » ; le fichier supprimé montre « Fichier introuvable » ; pas de plantage."
quit_app; reset_app_state; install_new; no_sparkle
AMB="$RUNNER_TEMP/ambiance"; rm -rf "$AMB"; mkdir -p "$AMB"
: > "$AMB/vide.m4a"; head -c 65536 /dev/urandom > "$AMB/binaire.mp3"; head -c 65536 /dev/urandom > "$AMB/absent.mp3"
launch || fail "l’app ne démarre pas"
onboarding; dashboard
pane modules || fail "Réglages › Modules inaccessible"
front
try "module Ambiance on" "$DRIVER" set "$BUNDLE" settings-module-ambiance 1 || try "module Ambiance on (click)" "$DRIVER" click "$BUNDLE" settings-module-ambiance; sleep 3
shot modules; dump modules
axhas 'id=settings-module-open-ambiance' >/dev/null && obs "module Ambiance activé" || fail "HARNAIS : module Ambiance non activé, cas non concluant"
try "open Ambiance" press3 settings-module-open-ambiance; sleep 4
for f in vide.m4a binaire.mp3 absent.mp3; do
  try "ambiance-add-files $f" press ambiance-add-files; sleep 3
  panel_pick "$AMB/$f"; sleep 3
done
shot added; dump added
for f in vide binaire absent; do axhas "AXButton.*desc=$f" >/dev/null && obs "$f ajouté" || fail "$f absent de « Ma musique »"; done
rm -f "$AMB/absent.mp3"
for f in vide.m4a binaire.mp3; do
  try "play $f" press3 "$f" AXButton; sleep 5
  shot "play-$f"; dump "play-$f"
  msg="$(axhas 'Lecture impossible')" && obs "$f : « ${msg:0:120} »" || fail "$f : pas de message « Lecture impossible »"
  running || { fail "l’app s’est arrêtée en lisant $f"; launch; dashboard; }
done
# Leave and come back so the page reads the file list again.
nav overview; sleep 2; pane modules; press3 settings-module-open-ambiance >/dev/null; sleep 4
shot absent; dump absent
axhas 'Fichier introuvable|value=Introuvable' >/dev/null && obs "absent.mp3 : « Fichier introuvable »" || fail "absent.mp3 : pas de « Fichier introuvable »"
running || fail "l’app s’est arrêtée"
quit_app
finish

begin clock-timezone "Pendant l’enregistrement : fuseau Europe/Paris → America/Santiago → Europe/Paris, puis horloge mise au 25/10/2026 02:58 CEST pour traverser le passage à l’heure d’hiver. Pas de plantage, l’enregistrement continue, toutes les lignes du journal restent lisibles, la CLI lit les jours, Vue d’ensemble et Historique s’affichent."
quit_app; tcc_set 2
try "tz Paris" sudo systemsetup -settimezone Europe/Paris
launch || fail "l’app ne démarre pas"
dashboard; record_on
activity 20; log "[paris] $(events_stat)"
try "tz Santiago" sudo systemsetup -settimezone America/Santiago; sleep 5
activity 20; log "[santiago] $(events_stat)"
dashboard; nav overview; shot santiago-overview; dump santiago-overview
try "tz Paris again" sudo systemsetup -settimezone Europe/Paris; sleep 5
activity 20
try "network time off" sudo systemsetup -setusingnetworktime off
real0=$(date +%s); s0=$SECONDS
try "clock → 2026-10-25 00:58:00 UTC (02:58 CEST)" sudo date -u 1025005826
activity 90; log "[after DST] $(date) $(events_stat)"
dashboard; nav overview; shot dst-overview; dump dst-overview
nav history; sleep 3; shot dst-history; dump dst-history
running || fail "l’app s’est arrêtée pendant les changements d’heure"
back="$(python3 -I -c 'import sys,time; print(time.strftime("%m%d%H%M%Y.%S", time.gmtime(int(sys.argv[1]))))' $(( real0 + SECONDS - s0 )))"
try "clock restore" sudo date -u "$back"; restore_clock; log "[clock] $(date -u)"
stat_line="$(events_stat)"; log "[journal] $stat_line"
[[ $stat_line == *" bad=0 "* ]] && obs "journal lisible ($stat_line)" || fail "lignes illisibles : $stat_line"
cli days days || fail "CLI days en erreur"
cli status status || obs "CLI status code non nul"
grep -h -o '"timestamp":"[^"]*"' "$DATA"/events/*.jsonl 2>/dev/null | tail -n 400 > "$CDIR/last-timestamps.txt"
running || fail "l’app s’est arrêtée"
finish

begin crash-kill "kill -9 de l’app (et du gardien s’il tourne) pendant l’enregistrement : à la relance, pas d’assistant, aucune ligne perdue avant les dernières secondes, journal lisible (au plus la dernière ligne coupée, réparée à la relance), l’enregistrement reprend."
running || { launch; dashboard; }
activity 30
pid=$(pgrep -x "$EXE" | head -1); before=$(events_lines); log "[before kill] pid=$pid $(events_stat)"
try "kill -9 app" kill -9 "$pid"
if pgrep -x "$GUARD_EXE" >/dev/null; then try "kill -9 guard" pkill -KILL -x "$GUARD_EXE"; else obs "gardien absent (aucun blocage actif)"; fi
sleep 15
running && obs "relancée seule après kill -9" || obs "pas de relance automatique (attendu sans gardien)"
log "[after kill] $(events_stat)"; shot after-kill
running || launch || fail "relance impossible"
sleep 5; dump relaunched; shot relaunched
axhas 'id=onboarding-continue' >/dev/null && fail "l’assistant revient après kill -9"
dashboard || fail "tableau de bord inaccessible après relance"
activity 30; sleep 10
after=$(events_lines); stat_line="$(events_stat)"; log "[after relaunch] $stat_line"
(( after >= before )) && obs "lignes $before → $after" || fail "lignes perdues ($before → $after)"
(( after > before )) || fail "l’enregistrement ne reprend pas"
[[ $stat_line == *" bad=0 "* ]] && obs "journal lisible" || fail "journal illisible après relance : $stat_line"
cli status status || obs "CLI status code non nul"
nav history; shot history; dump history
running || fail "l’app s’est arrêtée"
quit_app
finish
