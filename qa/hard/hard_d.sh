#!/bin/bash
# French apostrophes in the searched texts are literal.
# shellcheck disable=SC1112
# T-046 hard-D (L4c): offline rows of the matrix the first three parts left partial.
#   site-send-unreachable       J-0258, J-0283  site on a closed 127.0.0.1 port (HTTP allowed on loopback only)
#   ambiance-download-offline   J-0887..J-0889, J-0893  pack download under pf, cancel, failure
#   offline-update-check-alert  J-1020, J-1021  « Rechercher les mises à jour » alerts
# GitHub-hosted runner only (see lib.sh). Usage: qa/hard/hard_d.sh DIST_DIR OUT_DIR
source "$(dirname "$0")/lib.sh"
restore_network() { sudo pfctl -d >/dev/null 2>&1; sudo pfctl -f /etc/pf.conf >/dev/null 2>&1; true; }
trap restore_network EXIT
printf 'set skip on lo0\nblock drop all\n' > "$RUNNER_TEMP/pf-offline.conf"
# The runner loses GitHub while pf is on: every window is bounded (≤ 3 min) and restored by the trap too.
offline_on() {
  try "pf on" sudo pfctl -E -f "$RUNNER_TEMP/pf-offline.conf"
  try "offline check" curl -sS -m 5 -o /dev/null https://github.com && fail "réseau encore joignable"
}
offline_off() { restore_network; try "online check" curl -sS -m 10 -o /dev/null https://github.com || obs "réseau pas encore revenu"; }
# One line per matrix row: id, verdict, proof (case folder + file).
ROWS="$OUT/l4c-rows.tsv"
[[ -f $ROWS ]] || printf 'id\tverdict\tdetail\tproof\n' > "$ROWS"
row() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$CASE/$4" >> "$ROWS"; log "[row] $1 $2 $3"; }
last_shot() { local f l=""; for f in "$CDIR"/[0-9][0-9]-*.png; do [[ -e $f ]] && l="${f##*/}"; done; echo "$l"; }
# Waits up to $1 s for an AX text (regex $2); prints the matching line.
wait_ax() { local end=$(( $(date +%s) + $1 )); while (( $(date +%s) < end )); do axhas "$2" && return 0; sleep 2; done; return 1; }
module_ambiance() {
  pane modules || fail "Réglages › Modules inaccessible"
  front
  try "module Ambiance on" "$DRIVER" set "$BUNDLE" settings-module-ambiance 1 || try "module Ambiance on (click)" "$DRIVER" click "$BUNDLE" settings-module-ambiance; sleep 3
  axhas 'id=settings-module-open-ambiance' >/dev/null || return 1
  try "open Ambiance" press3 settings-module-open-ambiance; sleep 4
}

begin site-send-unreachable "Compte du site relié par un fichier d’accès synthétique (gl_up_…, 0600) vers http://127.0.0.1:PORT fermé. Envoyer une journée (feuille de partage, sharing-send : J-0283) et « Envoyer les données vérifiées » (connexion manuelle : J-0258) : message d’erreur lisible (site injoignable), aperçu conservé, pas de plantage ni de blocage."
reset_app_state; install_new; no_sparkle; tcc_set 2
launch || fail "l’app ne démarre pas"
onboarding; record_on
activity 10; quit_app
try "seed 2 days" python3 -I "$HERE/seed_events.py" "$DATA" --days 2 --per-day 300
# The site export reads the Apple Screen Time daily archive; the runner has none. Synthetic days written by
# the unit job (T046OfflinePairingTests, archive format), Screen Time source enabled in the consent file.
FIX="$RUNNER_TEMP/t046-unit/screen-time-days"
if compgen -G "$FIX/*.json" >/dev/null; then
  mkdir -p "$DATA/apple-screen-time/days"; chmod 700 "$DATA/apple-screen-time" "$DATA/apple-screen-time/days"
  cp "$FIX"/*.json "$DATA/apple-screen-time/days/"; chmod 600 "$DATA/apple-screen-time/days/"*.json
  python3 -I - "$DATA/capability-consent.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p))
d["capabilities"]["appleScreenTime"] = {"enabled": True, "changedAt": "2026-10-30T00:00:00Z", "surface": "settings"}
json.dump(d, open(p, "w"), indent=2)
PY
  log "[fixture] $(ls "$DATA/apple-screen-time/days" | tr '\n' ' ')"
else
  fail "HARNAIS : jours Temps d’écran synthétiques absents ($FIX)"
fi
PORT=$(python3 -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')
curl -sS -m 3 -o /dev/null "http://127.0.0.1:$PORT/" && fail "HARNAIS : port $PORT ouvert"
TOKEN="$RUNNER_TEMP/site-access.token"
python3 -I -c 'print("gl_up_" + "A" * 43)' > "$TOKEN"; chmod 600 "$TOKEN"
defaults write "$BUNDLE" goalong.website.origin "http://127.0.0.1:$PORT"
defaults write "$BUNDLE" goalong.website.tokenFilePath "$TOKEN"
log "[site] origin http://127.0.0.1:$PORT token $(stat -f '%Lp %z' "$TOKEN")"
launch || fail "l’app ne démarre pas"
dashboard || fail "tableau de bord inaccessible"
pane website || fail "Réglages › Site inaccessible"
shot site; dump site
axhas 'Votre compte Goalong|127\.0\.0\.1' >/dev/null && obs "compte relié affiché" || obs "carte : compte relié non lu"
# J-0283: sharing sheet, once, preview then send.
try "open selected day" press3 website-open-selected-day; sleep 5
shot sharing-open; dump sharing-open
try "preview" press3 sharing-preview; sleep 10
shot sharing-preview; dump sharing-preview
if axhas 'id=sharing-send' >/dev/null; then
  try "send" press3 sharing-send; sleep 12
  shot sharing-sent; dump sharing-sent; p=$(last_shot)
  msg="$(axhas 'id=sharing-error')"
  running || fail "l’app s’est arrêtée à l’envoi"
  if [[ $msg == *"pu être joint"* || $msg == *injoignable* || $msg == *"Pas de connexion"* ]]; then
    obs "J-0283 : « ${msg:0:200} »"
    axhas 'id=sharing-send|Aperçu local du' >/dev/null && obs "aperçu conservé" || fail "aperçu perdu après l’échec"
    axhas 'id=sharing-success' >/dev/null && fail "J-0283 : succès affiché sans site"
    row J-0283 pass "erreur lisible, aperçu conservé" "$p"
  else
    fail "J-0283 : pas de message « site injoignable » après l’envoi (${msg:0:160})"; row J-0283 fail "message : ${msg:0:80}" "$p"
  fi
else
  msg="$(axhas 'id=sharing-error|Choisissez|Aucune|désactivée')"
  fail "HARNAIS : pas de bouton sharing-send après l’aperçu (${msg:0:160})"; row J-0283 fail "aperçu non obtenu" "$(last_shot)"
fi
# J-0258: « Récap relu ou connexion manuelle… » sheet, yesterday (seeded), offline preview, send.
try "sharing modifier" press "Modifier" AXButton; sleep 3
try "advanced tools" press3 "Outils avancés"; sleep 2
try "manual connection" press3 "Récap relu ou connexion manuelle"; sleep 5
shot manual-open; dump manual-open
try "prepare offline preview" press3 "Préparer l’aperçu" AXButton; sleep 10
shot manual-preview; dump manual-preview
try "send reviewed" press3 "Envoyer les données vérifiées" AXButton; sleep 12
shot manual-sent; dump manual-sent; p=$(last_shot)
running || fail "l’app s’est arrêtée à l’envoi manuel"
msg="$(axhas 'pu être joint|injoignable|Pas de connexion|hors ligne|Impossible d')"
if [[ -n $msg ]] && ! axhas 'Reçu par le site' >/dev/null; then
  obs "J-0258 : « ${msg:0:200} »"; row J-0258 pass "erreur lisible" "$p"
else
  fail "J-0258 : pas de message d’erreur lisible après « Envoyer les données vérifiées »"; row J-0258 fail "pas de message" "$p"
fi
tmo 15 "$DRIVER" dump "$BUNDLE" "$RUNNER_TEMP/alive.txt" >/dev/null 2>&1 || fail "l’app ne répond plus à l’AX"
quit_app
finish

begin ambiance-download-offline "Module Ambiance activé, réseau coupé par pf : « Lecture » sans pack installé (J-0887, J-0888) et « Télécharger » le pack (J-0889) ne plantent pas ; « Annuler » pendant le téléchargement rend « Télécharger » (J-0893) ; un nouveau téléchargement échoue avec « Réessayer » ou un message lisible ; pas de plantage."
reset_app_state; install_new; no_sparkle
launch || fail "l’app ne démarre pas"
onboarding; dashboard
module_ambiance || fail "HARNAIS : module Ambiance non activé, cas non concluant"
shot ambiance; dump ambiance
ls "$DATA" > "$CDIR/data-ls.txt" 2>&1
PACK=""
for id in orchestra textures; do axhas "id=ambiance-download-$id" >/dev/null && { PACK=$id; break; }; done
if [[ -z $PACK ]]; then
  obs "aucun pack non installé dans cette build"
  row J-0889 na "aucun pack non installé (pas de ambiance-download-*)" "$(last_shot)"
  row J-0893 na "aucun pack non installé (pas de ambiance-download-*)" "$(last_shot)"
else
  obs "pack non installé : $PACK"
fi
offline_on
# J-0887 / J-0888: play (the player card) without the pack.
if axhas 'id=ambiance-play' >/dev/null; then
  try "play" press3 ambiance-play; sleep 5
  shot play-offline; dump play-offline; p=$(last_shot)
  running && { row J-0887 pass "Lecture hors ligne sans plantage" "$p"; row J-0888 pass "Lecture hors ligne sans plantage (même bouton)" "$p"; } \
    || { fail "l’app s’est arrêtée sur Lecture"; row J-0887 fail "plantage" "$p"; row J-0888 fail "plantage" "$p"; launch; dashboard; module_ambiance; }
  axhas 'id=ambiance-play' >/dev/null && press ambiance-play >/dev/null 2>&1; sleep 2
else
  obs "pas de bouton ambiance-play sans pack"
  row J-0887 na "bouton ambiance-play absent sans pack installé" "$(last_shot)"; row J-0888 na "bouton ambiance-play absent sans pack installé" "$(last_shot)"
fi
if [[ -n $PACK ]]; then
  try "download $PACK" press3 "ambiance-download-$PACK"; sleep 4
  shot downloading; dump downloading; p=$(last_shot)
  if axhas "id=ambiance-cancel-$PACK" >/dev/null; then
    obs "téléchargement en cours hors ligne"; row J-0889 pass "Télécharger : état en cours, pas de plantage" "$p"
    try "cancel $PACK" press3 "ambiance-cancel-$PACK"; sleep 4
    shot cancelled; dump cancelled; p=$(last_shot)
    if axhas "id=ambiance-download-$PACK" >/dev/null && ! axhas "id=ambiance-cancel-$PACK" >/dev/null; then
      row J-0893 pass "Annuler rend Télécharger" "$p"
    else fail "Annuler ne rend pas Télécharger"; row J-0893 fail "toujours en cours" "$p"; fi
    try "download again" press3 "ambiance-download-$PACK"; sleep 2
  else
    msg="$(axhas 'Réessayer|impossible|Impossible|connexion|réseau')"
    obs "échec immédiat sans état en cours : « ${msg:0:160} »"
    row J-0889 pass "Télécharger échoue tout de suite : ${msg:0:80}" "$p"
    row J-0893 na "téléchargement jamais en cours hors ligne : Annuler non atteignable" "$p"
  fi
  # pf drops packets: the request waits for its time limit, bounded here at 120 s.
  if msg="$(wait_ax 120 'Réessayer|impossible|Impossible|connexion|réseau|hors ligne')"; then obs "échec lu : « ${msg:0:200} »"
  else obs "aucun échec affiché après 120 s hors ligne (téléchargement encore en attente)"; fi
  shot failed; dump failed
fi
running || fail "l’app s’est arrêtée"
offline_off
quit_app
finish

begin offline-update-check-alert "Réseau coupé par pf. Build avec Sparkle configuré : une recherche de fond en cours, puis « Rechercher les mises à jour » : à l’échec, alerte « Impossible de vérifier les mises à jour » (J-1021) ou erreur Sparkle lisible. Copie sans configuration Sparkle (SUPublicEDKey retirée, re-signée ad hoc) : alerte « Mises à jour indisponibles dans cette version » (J-1020). Pas de plantage."
reset_app_state; install_new; no_sparkle
launch || fail "l’app ne démarre pas"
onboarding; quit_app
# J-1021: the quiet session at launch hangs offline; the click waits behind it, then the failure is shown.
defaults write "$BUNDLE" SUEnableAutomaticChecks -bool YES
offline_on
launch 2 || fail "l’app ne démarre pas hors ligne"
try "menu: Rechercher les mises à jour" tmo 20 "$DRIVER" menu "$BUNDLE" "$EXE" "Rechercher les mises à jour"; sleep 3
shot update-clicked; dump update-clicked
if msg="$(wait_ax 120 'Impossible de vérifier les mises à jour|Erreur|erreur|n’a pas abouti|Mises à jour indisponibles')"; then
  shot update-result; dump update-result; p=$(last_shot)
  obs "alerte : « ${msg:0:200} »"
  if [[ $msg == *"Impossible de vérifier les mises à jour"* ]]; then row J-1021 pass "alerte Impossible de vérifier les mises à jour" "$p"
  else row J-1021 fail "autre message : ${msg:0:80}" "$p"; fail "J-1021 : pas l’alerte « Impossible de vérifier »"; fi
else
  shot update-result; dump update-result; p=$(last_shot)
  fail "J-1021 : aucun résultat après 120 s hors ligne"; row J-1021 fail "rien affiché en 120 s" "$p"
fi
running || fail "l’app s’est arrêtée"
"$DRIVER" dismiss-alerts "$BUNDLE" >/dev/null 2>&1; "$DRIVER" close-extra "$BUNDLE" "Goalong History" >/dev/null 2>&1
quit_app
offline_off
# J-1020: same build without a valid Sparkle configuration.
defaults write "$BUNDLE" SUEnableAutomaticChecks -bool NO
try "drop SUPublicEDKey" /usr/libexec/PlistBuddy -c 'Delete :SUPublicEDKey' "$APP/Contents/Info.plist"
try "re-sign ad hoc" codesign --force --sign - "$APP"
offline_on
launch 2 || fail "la copie sans Sparkle ne démarre pas"
try "menu: Rechercher les mises à jour" tmo 20 "$DRIVER" menu "$BUNDLE" "$EXE" "Rechercher les mises à jour"; sleep 4
shot unconfigured; dump unconfigured; p=$(last_shot)
if msg="$(axhas 'Mises à jour indisponibles dans cette version')"; then
  obs "alerte : « ${msg:0:160} »"; row J-1020 pass "alerte Mises à jour indisponibles dans cette version" "$p"
  try "alert: Annuler" press "Annuler" AXButton; sleep 2
  axhas 'Mises à jour indisponibles dans cette version' >/dev/null && fail "J-1020 : Annuler ne ferme pas l’alerte"
else
  fail "J-1020 : pas d’alerte « Mises à jour indisponibles dans cette version »"; row J-1020 fail "pas d’alerte" "$p"
fi
running || fail "l’app s’est arrêtée"
"$DRIVER" dismiss-alerts "$BUNDLE" >/dev/null 2>&1
quit_app
offline_off
finish
cat "$ROWS"
