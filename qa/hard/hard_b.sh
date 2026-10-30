#!/bin/bash
# T-046 hard-B: large history, disk full, offline. GitHub-hosted runner only (see lib.sh).
# Usage: qa/hard/hard_b.sh DIST_DIR OUT_DIR
source "$(dirname "$0")/lib.sh"
restore_network() { sudo pfctl -d >/dev/null 2>&1; sudo pfctl -f /etc/pf.conf >/dev/null 2>&1; true; }
trap 'restore_network; hdiutil detach "$DATA" -force >/dev/null 2>&1' EXIT

begin large-history "1 000 000 d’événements sur 365 jours : l’app répond (élément de barre des menus) en moins de 60 s, Historique et Vue d’ensemble s’affichent, mémoire < 4 Go, la CLI liste les jours en moins de 300 s, pas de plantage."
reset_app_state; install_new; no_sparkle
launch && onboarding; quit_app
try "seed 1M" python3 -I "$HERE/seed_events.py" "$DATA" --days 365 --per-day 2740
log "[size] $(du -sh "$DATA/events" | cut -f1) $(events_stat)"
launch 2 || fail "l’app ne démarre pas sur 1 M d’événements"
(( LAUNCH_SECS <= 60 )) && obs "réponse AX en ${LAUNCH_SECS}s" || fail "réponse AX en ${LAUNCH_SECS}s (> 60 s)"
t0=$(date +%s); dashboard || fail "tableau de bord inaccessible"; obs "tableau de bord en $(( $(date +%s) - t0 ))s"
t0=$(date +%s); nav history || fail "Historique inaccessible"
sleep 10; shot history; dump history; obs "Historique en $(( $(date +%s) - t0 ))s (capture incluse)"
nav overview || obs "Vue d’ensemble inaccessible"
sleep 10; shot overview; dump overview
rss_mb=$(( $(ps -o rss= -p "$(pgrep -x "$EXE" | head -1)" 2>/dev/null || echo 0) / 1024 ))
(( rss_mb > 0 && rss_mb < 4096 )) && obs "mémoire ${rss_mb} Mo" || fail "mémoire ${rss_mb} Mo"
t0=$(date +%s); cli days days || fail "CLI days en erreur ou > 300 s"; obs "CLI days en $(( $(date +%s) - t0 ))s"
sleep 30; running || fail "l’app s’est arrêtée"
quit_app
finish

begin disk-full "Dossier de données sur un volume APFS de 64 Mo rempli jusqu’à ENOSPC pendant l’enregistrement : pas de plantage, bandeau « Enregistrement interrompu : le disque est plein » ou « Espace disque presque plein », puis reprise de l’enregistrement quand l’espace est libéré."
reset_app_state; install_new; no_sparkle
try "create 64m" hdiutil create -size 64m -fs APFS -volname T046Full -ov "$RUNNER_TEMP/full.dmg"
mkdir -p "$DATA"
try "attach on data dir" sudo hdiutil attach -owners on -nobrowse -mountpoint "$DATA" "$RUNNER_TEMP/full.dmg" || fail "montage du volume"
sudo chown "$(id -u):$(id -g)" "$DATA"; chmod 700 "$DATA"
log "[volume] $(df -h "$DATA" | tail -1) $(stat -f '%Su %Sp' "$DATA")"
tcc_set 2
launch || fail "l’app ne démarre pas"
onboarding; record_on
activity 30; sleep 5
before=$(events_lines); log "[events before fill] $(events_stat)"
try "fill (dd until ENOSPC)" dd if=/dev/zero of="$DATA/.t046-filler" bs=1m
log "[volume full] $(df -k "$DATA" | tail -1)"
activity 60; sleep 10
full=$(events_lines); log "[events while full] $(events_stat)"
dashboard; sleep 2
shot full; dump full
banner=""; for _ in 1 2 3 4; do banner="$(axhas 'disque est plein|Espace disque presque plein')" && break; sleep 15; done
[[ -n $banner ]] && obs "bandeau : ${banner:0:120}" || fail "aucun bandeau disque plein dans l’arbre AX"
shot full-later
running || fail "l’app s’est arrêtée disque plein"
rm -f "$DATA/.t046-filler"; log "[volume freed] $(df -k "$DATA" | tail -1)"
activity 60; sleep 20
after=$(events_lines); log "[events after free] $(events_stat)"
(( after > full )) && obs "reprise : $full → $after lignes" || fail "pas de reprise après libération ($full → $after lignes)"
shot recovered; dump recovered
running || fail "l’app s’est arrêtée après libération"
log "[counts] avant=$before plein=$full après=$after"
quit_app
try "detach" hdiutil detach "$DATA" -force
finish

begin disk-enospc "Vrai ENOSPC : dossier de données sur un volume APFS de 64 Mo rempli jusqu’au dernier octet (dd 1 Mo, 64 Ko, 4 Ko, 512 o, puis petits fichiers ; un ajout d’un octet doit échouer) pendant l’enregistrement. Attendu : pas de plantage, bandeau rouge « Enregistrement interrompu : le disque est plein » (il passe avant « presque plein »), puis reprise quand l’espace revient."
reset_app_state; install_new; no_sparkle
try "create 64m" hdiutil create -size 64m -fs APFS -volname T046Enospc -ov "$RUNNER_TEMP/enospc.dmg"
mkdir -p "$DATA"
try "attach on data dir" sudo hdiutil attach -owners on -nobrowse -mountpoint "$DATA" "$RUNNER_TEMP/enospc.dmg" || fail "montage du volume"
sudo chown "$(id -u):$(id -g)" "$DATA"; chmod 700 "$DATA"
tcc_set 2
launch || fail "l’app ne démarre pas"
onboarding; record_on
activity 30; sleep 5
before=$(events_lines); log "[events before fill] $(events_stat)"
mkdir -p "$DATA/.t046-fill"
for bs in 1m 64k 4k 512; do dd if=/dev/zero of="$DATA/.t046-fill/f-$bs" bs=$bs 2>/dev/null; done
for i in $(seq 1 4000); do printf x > "$DATA/.t046-fill/s$i" 2>/dev/null || break; done
log "[volume full] $(df -k "$DATA" | tail -1)"
if printf 'x' >> "$DATA/.t046-fill/probe" 2>/dev/null; then fail "HARNAIS : le volume accepte encore un octet"; else obs "ENOSPC vérifié (un octet refusé)"; fi
activity 60; sleep 10
full=$(events_lines); log "[events while full] $(events_stat)"
# Run 40981080335: a Finder window covered the app, the window showed « Enregistrement actif » + « presque plein »
# while the status item already said « disque plein ? ». First record the inactive window as is, then make it key.
dump full-inactive; shot full-inactive
log "[inactive] $(axhas 'disque est plein|presque plein' | head -c 120) | $(axhas 'Enregistrement actif|Enregistrement interrompu' | head -c 80)"
osascript -e 'tell application "Finder" to close every window' >/dev/null 2>&1
dashboard; nav overview; sleep 2
banner=""; for _ in 1 2 3 4 5 6; do front; nav history; nav overview; sleep 3; dump full; banner="$(axhas 'disque est plein')" && break; activity 10; sleep 10; done
log "[status item] $(grep -m1 'AXMenuBarItem | desc=Goalong' "$RUNNER_TEMP/has.txt" | head -c 200)"
log "[sidebar] $(axhas 'Enregistrement actif|Enregistrement interrompu' | head -c 80)"
shot full
[[ -n $banner ]] && obs "bandeau : ${banner:0:120}" || fail "pas de bandeau « le disque est plein » dans l’arbre AX ($(axhas 'presque plein' >/dev/null && echo 'seulement « presque plein »' || echo 'aucun bandeau disque'))"
running || fail "l’app s’est arrêtée disque plein"
rm -rf "$DATA/.t046-fill"; log "[volume freed] $(df -k "$DATA" | tail -1)"
activity 60; sleep 30
after=$(events_lines); log "[events after free] $(events_stat)"
(( after > full )) && obs "reprise : $full → $after lignes" || fail "pas de reprise après libération ($full → $after lignes)"
# Run 40987361212: the window, not key, still said « Disque plein » while the status item had recovered.
dump recovered-inactive; shot recovered-inactive
log "[recovered inactive] $(axhas 'disque est plein|Disque plein|Enregistrement actif' | head -c 120) | $(grep -m1 'AXMenuBarItem | desc=Goalong' "$RUNNER_TEMP/has.txt" | head -c 160)"
axhas 'disque est plein' >/dev/null && obs "fenêtre non active : bandeau « disque plein » encore affiché après libération (état figé)"
osascript -e 'tell application "Finder" to close every window' >/dev/null 2>&1
front; nav history; nav overview; sleep 3
dump recovered; shot recovered
log "[recovered key] $(axhas 'disque est plein|Disque plein|Enregistrement actif' | head -c 120)"
axhas 'disque est plein' >/dev/null && fail "bandeau « disque plein » encore là après libération, fenêtre active" || obs "bandeau disparu après libération (fenêtre active)"
running || fail "l’app s’est arrêtée après libération"
log "[counts] avant=$before plein=$full après=$after"
quit_app
finish
try "detach" hdiutil detach "$DATA" -force

begin offline "Réseau coupé par pf (tout bloqué sauf lo0) : l’app redémarre hors ligne et répond, l’enregistrement local continue, Réglages › Site et « Rechercher les mises à jour » donnent un état ou une erreur lisible, sans plantage ni blocage ; tout revient quand le réseau revient."
reset_app_state; install_new; no_sparkle; tcc_set 2
launch || fail "l’app ne démarre pas"
onboarding; record_on; quit_app
printf 'set skip on lo0\nblock drop all\n' > "$RUNNER_TEMP/pf-offline.conf"
# The runner itself loses GitHub during this window: kept under 2 minutes, restored by the EXIT trap too.
try "pf on" sudo pfctl -E -f "$RUNNER_TEMP/pf-offline.conf"
try "offline check" curl -sS -m 5 -o /dev/null https://github.com && fail "réseau encore joignable"
before=$(events_lines)
launch || fail "l’app ne démarre pas hors ligne"
dashboard || fail "tableau de bord inaccessible hors ligne"
activity 15
pane website || obs "Réglages › Site inaccessible"
sleep 5; shot site-offline; dump site-offline
try "menu: Rechercher les mises à jour" tmo 20 "$DRIVER" menu "$BUNDLE" "$EXE" "Rechercher les mises à jour"; sleep 8
shot update-offline; dump update-offline
tmo 15 "$DRIVER" dump "$BUNDLE" "$RUNNER_TEMP/alive.txt" >/dev/null 2>&1 || fail "l’app ne répond plus à l’AX hors ligne"
"$DRIVER" dismiss-alerts "$BUNDLE" >/dev/null 2>&1; "$DRIVER" close-extra "$BUNDLE" "Goalong History" >/dev/null 2>&1
during=$(events_lines)
restore_network
try "online check" curl -sS -m 10 -o /dev/null https://github.com || obs "réseau pas encore revenu"
(( during > before )) && obs "enregistrement hors ligne : $before → $during lignes" || fail "rien enregistré hors ligne ($before → $during)"
sleep 15; running || fail "l’app s’est arrêtée"
shot back-online; dump back-online
quit_app
finish
