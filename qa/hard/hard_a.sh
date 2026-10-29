#!/bin/bash
# T-046 hard-A: fresh install from the .dmg, update with data from 0.6.163, permissions denied.
# GitHub-hosted runner only (see lib.sh). Usage: qa/hard/hard_a.sh DIST_DIR OUT_DIR
source "$(dirname "$0")/lib.sh"
OLD_TAG=main-40923827207-1  # Goalong History 0.6.163, public pre-release.

begin install-fresh "Le .dmg s’ouvre ; l’app copiée dans /Applications est valide (codesign), démarre sur un Mac sans données, montre l’assistant de démarrage, crée son dossier de données et arrive au tableau de bord."
reset_app_state; rm -rf "$APP"
try "dmg verify" hdiutil verify "$DMG" || fail "hdiutil verify"
MNT="$RUNNER_TEMP/dmg-mnt"; mkdir -p "$MNT"
if try "dmg attach" hdiutil attach -nobrowse -readonly -mountpoint "$MNT" "$DMG"; then
  ls -la "$MNT" > "$CDIR/dmg-content.txt" 2>&1
  try "copy to /Applications" ditto "$MNT/Goalong History.app" "$APP" || fail "copie depuis le .dmg"
  try "dmg detach" hdiutil detach "$MNT"
else
  fail "montage du .dmg"
fi
try "codesign" codesign --verify --deep --strict "$APP" || fail "codesign --verify"
log "[version] $(defaults read "$APP/Contents/Info" CFBundleShortVersionString) ($(defaults read "$APP/Contents/Info" CFBundleVersion))"
no_sparkle
launch || fail "l’app ne tourne pas après lancement"
obs "lancement ${LAUNCH_SECS}s"
shot launched; dump launched
onboarding || fail "assistant de démarrage absent"
dashboard || fail "tableau de bord inaccessible"
shot dashboard; dump dashboard
[[ -d $DATA ]] && obs "dossier de données créé ($(stat -f %Sp "$DATA"))" || fail "dossier de données absent"
running || fail "l’app s’est arrêtée"
quit_app
finish

begin update-data "Mise à jour avec données : 0.6.163 (pré-release publique) installée, assistant fait, 30 jours d’historique synthétique ; le bundle est remplacé par la build testée. L’app relancée ne refait pas l’assistant, garde tous les jours et fichiers d’événements (aucun fichier perdu ni raccourci), et l’Historique s’affiche. Sparkle réel : N/A (voir summary)."
log "[sparkle] Vraie mise à jour Sparkle = N/A : la clé EdDSA privée de publication n’existe pas sur le runner (secret jamais exposé à une PR) et la build testée est signée ad hoc, pas Developer ID ; Sparkle refuserait donc l’archive. Le test reproduit l’étape d’installation de Sparkle : remplacement du .app en place, données et préférences gardées."
reset_app_state; rm -rf "$APP"
OLD="$RUNNER_TEMP/old"; rm -rf "$OLD"; mkdir -p "$OLD"
if try "download 0.6.163" gh release download "$OLD_TAG" -R "$GITHUB_REPOSITORY" -p 'Goalong-History-macOS-universal.zip*' -D "$OLD"; then
  want="$(awk '{print $1}' "$OLD/Goalong-History-macOS-universal.zip.sha256")"; got="$(shasum -a 256 "$OLD/Goalong-History-macOS-universal.zip" | awk '{print $1}')"
  [[ $want == "$got" ]] && log "[sha256] ok $got" || fail "sha256 0.6.163 ($want ≠ $got)"
  ditto -x -k "$OLD/Goalong-History-macOS-universal.zip" "$OLD/x" && ditto "$OLD/x/Goalong History.app" "$APP"
  xattr -dr com.apple.quarantine "$APP" 2>/dev/null
fi
OLD_VERSION="$(defaults read "$APP/Contents/Info" CFBundleShortVersionString 2>/dev/null)"
log "[old] $OLD_VERSION ($(defaults read "$APP/Contents/Info" CFBundleVersion 2>/dev/null))"
[[ $OLD_VERSION == 0.6.163 ]] || fail "0.6.163 non installée ($OLD_VERSION)"
no_sparkle
launch || fail "0.6.163 ne démarre pas"
onboarding || obs "0.6.163 sans assistant"
quit_app
try "seed" python3 -I "$HERE/seed_events.py" "$DATA" --days 30 --per-day 400
launch || fail "0.6.163 ne redémarre pas sur les données"
dashboard; nav history; sleep 5
shot old-history; dump old-history
cli old-days days || obs "CLI 0.6.163 days en erreur"
quit_app
(cd "$DATA/events" && stat -f '%N %z' ./*.jsonl) > "$CDIR/events-before.txt"
log "[before] $(events_stat)"
install_new
log "[new] $(defaults read "$APP/Contents/Info" CFBundleShortVersionString) ($(defaults read "$APP/Contents/Info" CFBundleVersion))"
launch || fail "la build testée ne démarre pas sur les données 0.6.163"
pgrep -x SecurityAgent >/dev/null && obs "SecurityAgent ouvert (trousseau : signature ad hoc ≠ Developer ID)"
shot new-launched; dump new-launched
axhas 'id=onboarding-continue' >/dev/null && fail "l’assistant revient après la mise à jour"
dashboard || fail "tableau de bord inaccessible après mise à jour"
nav history || fail "Historique inaccessible"
sleep 5; shot new-history; dump new-history
(cd "$DATA/events" && stat -f '%N %z' ./*.jsonl) > "$CDIR/events-after.txt"
log "[after] $(events_stat)"
lost="$(awk 'NR==FNR {after[$1]=$2; next} !($1 in after) || after[$1] < $2 {print $1}' "$CDIR/events-after.txt" "$CDIR/events-before.txt")"
[[ -z $lost ]] && obs "30 jours gardés" || fail "fichiers perdus ou raccourcis : ${lost//$'\n'/ }"
cli new-days days || fail "CLI days en erreur après mise à jour"
cli new-status status || obs "CLI status code non nul"
running || fail "l’app s’est arrêtée"
quit_app
finish

begin permissions-denied "Toutes les permissions refusées (Accessibilité, Surveillance de l’entrée, Enregistrement de l’écran, envoi d’événements : auth_value=0 dans TCC). L’app démarre, l’assistant passe ; activer l’enregistrement ouvre « Autoriser l’historique de ce Mac » qui dit ce qui manque (Accessibilité à autoriser) et propose « Ouvrir Réglages Système » ; l’enregistrement reste éteint tant que l’accès manque ; pas de plantage."
reset_app_state; install_new; no_sparkle
tcc_set 0
launch || fail "l’app ne démarre pas sans permission"
onboarding || fail "assistant absent"
dashboard || fail "tableau de bord inaccessible"
shot dashboard; dump dashboard
# Permissions are asked only for enabled features: try to turn recording on, then read what the app says.
pane recording || fail "Réglages › Enregistrement inaccessible"
front
try "recording source" "$DRIVER" set "$BUNDLE" source-localComputerHistory 1 || try "recording source (click)" "$DRIVER" click "$BUNDLE" source-localComputerHistory right
sleep 5; shot activation; dump activation
if axhas 'id=recording-setup-confirm' >/dev/null; then
  try "recording confirm" press3 recording-setup-confirm; sleep 5; shot activation-2; dump activation-2
fi
axhas 'À autoriser' >/dev/null && obs "accès manquant nommé (Accessibilité : À autoriser)" || fail "l’accès manquant n’est pas nommé"
if axhas 'id=permission-(primary-action|open-settings|targeted-repair)' >/dev/null; then obs "action de réparation proposée"; else fail "aucune action de permission proposée"; fi
c="$(tr -d '\n ' < "$DATA/capability-consent.json" 2>/dev/null)"; log "[consent] ${c:0:300}"
if [[ $c =~ \"localComputerHistory\":\{[^}]*\"enabled\":true ]]; then fail "enregistrement activé sans accès"; else obs "enregistrement resté éteint sans accès"; fi
try "permission-primary-action" press permission-primary-action; sleep 6
pgrep -x "System Settings" >/dev/null && obs "Réglages Système ouverts" || obs "Réglages Système non détectés (voir capture)"
shot after-action; dump after-action
osascript -e 'tell application "System Settings" to quit' >/dev/null 2>&1
esc; pane permissions; shot permissions; dump permissions
running || fail "l’app s’est arrêtée"
cli status status || obs "CLI status code non nul"
quit_app
finish
