# T-045 E2E lot 1: one step per row of T-045-matrice.md (stable ids), one capture per step,
# named by row id. Sourced by runner_probe.sh (GitHub-hosted runner only, synthetic data only).
# Commands: nav:SECTION  pane:PANE  p:LABEL (must press)  o:LABEL (optional press)
#           b:LABEL (must press, buttons only)  m:TOP>ITEM (app menu)  si / sm (status item / its menu)
#           esc  w:N (sleep)  s:NAME (extra capture ROW-NAME)

# --- Menu bar (status item, panel, context menu)
step MNB-01 si
step MNB-02 si w:2 s:panel esc
step MNB-03 si o:"Voir la journée" w:2
step MNB-04 sm o:"Confidentialité · tout suspendre" w:2 s:sheet o:Annuler esc
step MNB-05 sm o:"Effacer l’historique détaillé" w:1 s:menu esc
step MNB-06 sm o:Autorisations w:2 s:after esc
step MNB-07 sm o:Avancé w:1 esc
step MNB-08 sm w:1 esc
step MNB-09 si w:1 esc

# --- Main window, sidebar, banner, day picker
step WIN-01 nav:overview nav:work nav:history nav:concentration nav:settings nav:overview
step WIN-02 nav:overview o:"Signaler un problème…" w:2 s:sheet esc
step WIN-03 pane:home p:settings-privacy-stop w:1 o:"Tout suspendre" w:1 s:confirm o:Annuler esc
step WIN-04 nav:overview p:"Jour précédent" w:1 p:Aujourd’hui p:"Choisir un jour" w:1 s:calendar esc

# --- Activité
step ACT-01 nav:overview p:"7 jours" w:1 s:7j p:"28 jours" w:1 s:28j p:Jour
step ACT-02 nav:overview p:"Bilans et projets" w:2 s:bilans o:activity-detail-back o:Retour
step ACT-03 nav:overview p:"Couverture et sources" w:2 s:couverture o:activity-detail-back o:Retour
step ACT-04 nav:overview o:activity-usage-sort o:activity-usage-show-all w:1
step ACT-05 nav:overview p:"Ajouter une note sur cette journée" w:1 s:note esc
step ACT-06 nav:overview p:"Comment lire ces chiffres" w:1

# --- Mon travail
step WRK-01 nav:work o:work-allow w:2 s:allow esc
step WRK-02 nav:work o:work-classify-today o:work-automatic w:2
step WRK-03 nav:work o:"Nouvelle tâche…" w:1 s:sheet esc
step WRK-04 nav:work o:"Filtre" w:1

# --- Historique (Ce Mac, Temps d'écran Apple, Conversations locales)
step HIS-01 nav:history p:"Ce Mac" o:"Rechercher" w:1 o:"Effacer la recherche"
step HIS-02 nav:history p:"Ce Mac" o:Ouvrir w:1 esc
step HIS-03 nav:history p:"Ce Mac" o:"Filtrer le contexte" w:1
step HIS-04 nav:history p:"Ce Mac" o:Supprimer w:1 s:alert esc
step STE-01 nav:history p:"Temps d’écran Apple" w:2 o:screen-time-open-settings w:1 esc
step STE-02 nav:history p:"Temps d’écran Apple" o:"Voir mon activité Goalong" w:2
step AGT-01 nav:history p:"Conversations locales" w:2 o:"Vérifier les sources" w:1 s:sources esc
step AGT-03 nav:history p:"Conversations locales" o:Détecter w:2 esc

# --- Enregistrement / Confidentialité (activation with synthetic data on the runner)
step CNF-03 pane:recording w:2 o:"Modifier l’enregistrement" w:1 s:edit esc
step CNF-04 pane:recording o:"Choisir des applications…" w:1 s:apps esc
step CNF-05 pane:recording o:recording-visible-text w:1 s:text o:Annuler esc
step CNF-01 pane:recording o:"Ouvrir le dossier des données" w:2 esc
step CNF-02 pane:storage o:"Dernière heure" w:1 s:confirm o:Annuler esc
step CNF-06 pane:applications w:1
step ACT-REC nav:overview p:activity-recording-action w:2 s:setup o:recording-setup-confirm w:3 esc

# --- Réglages
step SET-01 pane:home o:"Rechercher un réglage" w:1
step SET-02 pane:recording o:"Fenêtres privées" w:1 s:alert o:Annuler esc
step SET-03 pane:recording o:settings-foreground-idle-limit w:1 esc
step SET-04 pane:tools o:"Choisir les dossiers de conversations…" w:1 esc
step SET-05 pane:home p:settings-update-status w:2 o:Rechercher w:1 esc
step SET-06 pane:advanced o:Recharger w:1
step SET-07 pane:advanced o:"Réinitialiser les réglages…" w:1 s:alert o:Annuler esc
step SET-08 pane:home b:"Garder Goalong actif en arrière-plan" w:1 b:"Garder Goalong actif en arrière-plan" o:"Ouvrir les éléments d’ouverture…" w:2 esc
step SET-09 pane:storage o:retention-automatic o:"Appliquer ces règles" w:1 s:confirm esc
step SET-10 pane:storage o:"Choisir…" w:2 s:panel esc o:"Effacer de l’historique…" w:1 s:sheet esc
step SET-11 pane:applications o:"Exclusions seulement" w:1
step SET-12 pane:modules w:1
step SET-13 pane:advanced o:settings-developer-mode w:1
step SET-14 pane:advanced w:1
step SET-15 pane:advanced o:Terminal w:1 esc
step PRM-01 pane:permissions w:2 o:permission-primary-action w:2 s:after esc
step PRM-04 pane:permissions o:"Vérifier l’accès à nouveau" w:2

# --- Envoi à Goalong, Analyse ChatGPT, Jev, Support
step SHR-01 pane:website w:2 o:"Choisir le fichier d’accès…" w:2 s:panel esc
step SHR-02 nav:history p:"Partager cette journée…" w:2 s:sheet o:sharing-close esc
step SHR-06 pane:website o:"Configurer les envois" w:2 s:sheet esc
step ANL-01 pane:chatGPT w:2 o:"Voir les données" w:1 esc
step JEV-01 pane:jev w:2 o:jev-open-connection w:1 s:connection o:jev-connection-close esc
step JEV-03 pane:jev o:jev-intervention-settings w:1
step SUP-01 pane:home p:settings-report-problem w:3 s:sheet o:support-more w:1 esc
step SUP-03 pane:advanced o:"Conserver les journaux" w:1

# --- Modules: turn each on (runner only), then open its page
step CON-07 pane:modules o:settings-module-concentration o:settings-module-blocking o:settings-module-braise o:settings-module-ambiance w:2
step CON-01 nav:concentration w:2 o:"Ajouter une intention" w:1 s:sheet esc
step CON-02 nav:concentration o:Verrouiller w:1
step CON-03 pane:modules o:settings-module-open-concentration w:2
step CON-05 nav:concentration o:"Prendre un engagement" w:1 s:sheet esc
step CON-06 nav:concentration o:"Nouvelle liste…" w:1 s:sheet esc
step BLK-01 pane:modules o:settings-module-open-blocking w:2 o:blocking-page
step BLK-02 pane:modules o:settings-module-open-blocking w:1 o:blocking-week w:1
step BLK-03 pane:modules o:settings-module-open-blocking o:blocking-new-list w:1 s:sheet o:blocking-list-close esc
step BLK-04 pane:modules o:settings-module-open-blocking o:blocking-password-row w:1 s:sheet esc
step BLK-05 pane:modules o:settings-module-open-blocking o:blocking-protection w:1 esc
step BRS-01 pane:modules o:settings-module-open-braise w:2 o:"Pause 15 min" w:1 o:Reprendre
step BRS-02 pane:modules o:settings-module-open-braise o:"Ajouter un horaire" w:1
step AMB-01 pane:modules o:settings-module-open-ambiance w:2 o:Ajouter… w:1 s:sheet esc

# --- Application menu (last: APP-05 quits and reopens)
step APP-01 m:Fichier m:Édition m:Fenêtre esc
step APP-02 m:"Goalong Dev>À propos" w:2 s:about esc
step APP-03 m:"Goalong Dev>Réglages" w:2
step APP-04 m:"Goalong Dev>Rechercher les mises à jour" w:2 s:window esc
step APP-06 m:"Aide>Guide" w:2 esc
step APP-07 m:"Aide>Signaler un problème" w:2 s:sheet esc
