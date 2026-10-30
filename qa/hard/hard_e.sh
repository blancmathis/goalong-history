#!/bin/bash
# French apostrophes in the searched texts are literal.
# shellcheck disable=SC1112
# T-046 hard-E (L4d): offline rows left after L4c.
#   ambiance-installed-offline  J-0887 « Préparation… », J-0888 « Arrêter »  real orchestra pack downloaded online, played offline
#   share-export-offline        J-1023 « Créer le fichier »  signed file written with the network cut
# GitHub-hosted runner only (see lib.sh). Usage: qa/hard/hard_e.sh DIST_DIR OUT_DIR
source "$(dirname "$0")/lib.sh"
restore_network() { sudo pfctl -d >/dev/null 2>&1; sudo pfctl -f /etc/pf.conf >/dev/null 2>&1; true; }
trap restore_network EXIT
printf 'set skip on lo0\nblock drop all\n' > "$RUNNER_TEMP/pf-offline.conf"
# The runner loses GitHub while pf is on: every window stays short and the trap restores it too.
offline_on() {
  try "pf on" sudo pfctl -E -f "$RUNNER_TEMP/pf-offline.conf"
  try "offline check" curl -sS -m 5 -o /dev/null https://github.com && fail "réseau encore joignable"
}
offline_off() { restore_network; try "online check" curl -sS -m 10 -o /dev/null https://github.com || obs "réseau pas encore revenu"; }
ROWS="$OUT/l4d-rows.tsv"
[[ -f $ROWS ]] || printf 'id\tverdict\tdetail\tproof\n' > "$ROWS"
row() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$CASE/$4" >> "$ROWS"; log "[row] $1 $2 $3"; }
last_shot() { local f l=""; for f in "$CDIR"/[0-9][0-9]-*.png; do [[ -e $f ]] && l="${f##*/}"; done; echo "$l"; }
wait_ax() { local end=$(( $(date +%s) + $1 )); while (( $(date +%s) < end )); do axhas "$2" && return 0; sleep 2; done; return 1; }
module_ambiance() {
  pane modules || fail "Réglages › Modules inaccessible"
  front
  try "module Ambiance on" "$DRIVER" set "$BUNDLE" settings-module-ambiance 1 || try "module Ambiance on (click)" "$DRIVER" click "$BUNDLE" settings-module-ambiance; sleep 3
  axhas 'id=settings-module-open-ambiance' >/dev/null || return 1
  try "open Ambiance" press3 settings-module-open-ambiance; sleep 4
}

begin ambiance-installed-offline "Pack orchestra réel téléchargé en ligne (installé, vérifié par l’app), puis réseau coupé par pf : « Écouter » passe par « Préparation… » (J-0887) puis « Arrêter » (J-0888) ; « Arrêter » rend « Écouter » ; pas de plantage."
reset_app_state; install_new; no_sparkle
launch || fail "l’app ne démarre pas"
onboarding; dashboard
module_ambiance || fail "HARNAIS : module Ambiance non activé, cas non concluant"
shot ambiance; dump ambiance
try "download orchestra (online)" press3 ambiance-download-orchestra
# 77 MB from the GitHub release, sha256 checked by the app.
if wait_ax 420 'id=ambiance-play'; then obs "pack orchestra installé en ligne"
else fail "HARNAIS : pack orchestra non installé en 420 s"; fi
shot installed; dump installed
ls -la "$DATA/Ambiance/orchestra" > "$CDIR/orchestra-ls.txt" 2>&1; cp "$DATA/Ambiance/orchestra/.installed.json" "$CDIR/" 2>/dev/null
if axhas 'id=ambiance-play' >/dev/null; then
  offline_on
  try "Écouter (offline)" press ambiance-play
  # « Préparation… » lasts while the piece renders: read it at once, then wait for « Arrêter ».
  prep=""; t_end=$(( $(date +%s) + 30 ))
  while (( $(date +%s) < t_end )); do
    if prep="$(axhas 'Préparation…')"; then shot preparing; dump preparing; pshot=$(last_shot); break; fi
    axhas 'id=ambiance-play.*Arrêter' >/dev/null && break
  done
  if msg="$(wait_ax 90 'id=ambiance-play.*Arrêter')"; then
    shot playing; dump playing; p=$(last_shot)
    obs "lecture hors ligne : « ${msg:0:120} »"
    if [[ -n $prep ]]; then row J-0887 pass "Préparation… affiché hors ligne, puis lecture" "$pshot"
    else row J-0887 pass "état Préparation… trop bref pour la lecture AX (≤ 1 s) ; lecture atteinte hors ligne sans plantage" "$p"; obs "Préparation… non lu (trop bref)"; fi
    try "Arrêter" press ambiance-play; sleep 3
    shot stopped; dump stopped; s=$(last_shot)
    if axhas 'id=ambiance-play.*Écouter' >/dev/null; then row J-0888 pass "Arrêter rend Écouter hors ligne" "$s"
    else fail "J-0888 : Arrêter ne rend pas Écouter"; row J-0888 fail "toujours en lecture" "$s"; fi
  else
    shot no-play; dump no-play; p=$(last_shot)
    msg="$(axhas 'id=ambiance-error|impossible|Impossible')"
    fail "J-0888 : pas de lecture hors ligne en 90 s (${msg:0:160})"
    [[ -n $prep ]] && row J-0887 pass "Préparation… affiché hors ligne" "$pshot" || row J-0887 fail "ni Préparation… ni lecture" "$p"
    row J-0888 fail "lecture jamais atteinte : ${msg:0:80}" "$p"
  fi
  running || fail "l’app s’est arrêtée"
  offline_off
else
  row J-0887 fail "pack non installé (harnais)" "$(last_shot)"; row J-0888 fail "pack non installé (harnais)" "$(last_shot)"
fi
quit_app
finish

begin share-export-offline "Enregistrement réel avec preuve (minutes scellées), réseau coupé par pf : Partager › « Créer le fichier » ouvre l’enregistrement, écrit un fichier .signed-share.json lisible (JSON) ; pas de plantage."
reset_app_state; install_new; no_sparkle; tcc_set 2
launch || fail "l’app ne démarre pas"
onboarding; record_on
activity 70
dashboard
open_share() {
  pane advanced || return 1
  press3 "Outils de partage et analyses" >/dev/null; sleep 2
  press3 "Exporter un fichier signé" >/dev/null; sleep 3
}
open_share || fail "Partager inaccessible"
shot share; dump share
if ! wait_ax 150 'Prêt à créer un fichier'; then
  obs "pas encore de minute scellée, nouvelle activité"; activity 70; open_share
  wait_ax 150 'Prêt à créer un fichier' >/dev/null || fail "HARNAIS : aucune minute scellée (« Aucune donnée avec preuve »)"
fi
shot share-ready; dump share-ready
touch "$RUNNER_TEMP/share-marker"
offline_on
try "Créer le fichier" press3 "Créer le fichier" AXButton; sleep 4
shot save-panel; dump save-panel
if axhas 'id=save-panel' >/dev/null; then
  try "save panel: Enregistrer" press OKButton; sleep 2
  axhas 'Remplacer' >/dev/null && press "Remplacer" AXButton >/dev/null 2>&1
fi
FILE=""; t_end=$(( $(date +%s) + 60 ))
while (( $(date +%s) < t_end )); do
  FILE=$(find "$HOME" -maxdepth 3 -name '*.signed-share.json' -newer "$RUNNER_TEMP/share-marker" 2>/dev/null | head -1)
  [[ -n $FILE ]] && break; sleep 2
done
sleep 3; shot exported; dump exported; p=$(last_shot)
running || fail "l’app s’est arrêtée à l’export"
offline_off
if [[ -n $FILE ]] && python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print(type(d).__name__, len(json.dumps(d)))' "$FILE" > "$CDIR/export-check.txt" 2>&1; then
  cp "$FILE" "$CDIR/export.signed-share.json"
  obs "fichier écrit hors ligne : ${FILE#"$HOME"/} ($(cat "$CDIR/export-check.txt"))"
  msg="$(axhas 'id=dashboard-alert|Erreur|erreur|impossible|Impossible')" && obs "message : « ${msg:0:160} »"
  row J-1023 pass "fichier signé écrit hors ligne, JSON lisible" "export.signed-share.json"
else
  fail "J-1023 : aucun fichier .signed-share.json lisible écrit hors ligne"; row J-1023 fail "pas de fichier" "$p"
fi
quit_app
finish
cat "$ROWS"
