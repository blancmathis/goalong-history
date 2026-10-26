# Goalong — guide des agents

## Où travailler
- Un worktree par sujet : `~/Developer/goalong-<sujet>-<date>`, créé depuis `origin/main`. Le checkout principal est en retard : ne pas y travailler.
- Si un dépôt local ne fetch plus (`bad object refs/heads/feat/garant-mac-20261008`), créer le worktree depuis `~/Developer/goalong-motion-placement-app-20260918`. Ne pas supprimer cette branche locale.
- Contexte projet (état, décisions, pièges) : `CONTEXT.md` du checkout principal (non versionné).

## Deux voies seulement
1. **Goalong Dev** (itération locale) : `make dev` construit le worktree en une app séparée qui tourne **à côté** de Goalong installé. Ne publie rien.
2. **Release** : PR → CI → merge sur `main` → Sparkle. **Merge = publication publique** : seulement quand le propriétaire dit « déploie ».
- Aucun autre déploiement local. Ne jamais installer une build locale dans `/Applications` : Sparkle la remplace (build `YYYYMMDD.HHMMSS` < `30000000.x`). Les agents launchd `ai.goalong.local-*` sont désactivés : ne pas les recharger.

## Goalong Dev (`make dev`)
- App `~/Applications/Goalong Dev.app` : bundle id `ai.goalong.localhistory.dev`, processus `Goalong History Dev`, même certificat que la release (exigence désignée sans empreinte : les permissions accordées restent d’un build à l’autre). Icône DEV, point orange en barre des menus, titres « — Dev », bandeau branche · commit · données.
- Build debug incrémental dans le `.build` du worktree (le même que `make test`), signe, installe, ferme **seulement** une Goalong Dev en cours, lance via `open`. Durée de chaque étape affichée ; log `.build/goalong-dev/build.log`. Goalong installé n’est jamais fermé : enregistrement et blocage réels continuent.
- Une seule Goalong Dev à la fois : le dernier `make dev` gagne (le bandeau dit quelle branche). L’étape installation/données prend un verrou global (`~/Library/Caches/goalong-dev-install.flock`) : deux worktrees n’installent jamais en même temps. `make dev-stop` ferme Goalong Dev seulement (il attend ce verrou, pas la fin d’un build) ; `make dev-status` donne branche, commit, date, mode de données et état.
- Données : `~/Library/Application Support/LocalHistory-Dev/`, jamais `LocalHistory/`. `DATA=clone` (défaut : clone APFS des vraies données, sans clé d’appareil, chaîne signée de l’appareil réel (`seals/`, `receipts/`, `integrity-state.json`), jetons de compte, `Blocking/`, `Focus/`, sauvegardes ni sockets), `DATA=keep` (garde l’état dev ; un dossier d’un ancien `make dev`, marqueur absent ou `v2`, perd d’abord clé d’appareil, chaîne signée, jetons et sauvegardes réels ; Goalong Dev refuse de démarrer dessus avant), `DATA=fresh` (vide, nouvel utilisateur). `DATA=real` n’existe plus. Réglages lus seulement sur la ligne de commande de `make` (un `export DATA=…` du shell est ignoré).
- Blocage et Concentration de Goalong Dev sont à elle, vides par défaut. `BLOCKING=copy` copie les listes réelles sans verrou, mot de passe ni session. Le vrai blocage reste appliqué par Goalong installé.
- Coupé dans Goalong Dev : envois serveur (site, envoi quotidien, partage, Jev, vérification) sauf `SERVER=on` (bandeau orange), élément de connexion, Sparkle, migrations d’installation, lien `goalong-history://`, installation/retrait des hooks d’agents (fichiers partagés avec Goalong installé : à gérer depuis Goalong installé). Préférences : domaine propre (`ai.goalong.localhistory.dev`). Socket CLI dans `LocalHistory-Dev/runtime`.
- Première utilisation : le propriétaire accorde une fois les permissions à Goalong Dev (Accessibilité, Surveillance de l’entrée, etc.).
- **Agents** : ne lancent pas Goalong Dev sans demande du propriétaire (fenêtres, demandes de permission). Utiliser `make dev NO_LAUNCH=1 DEV_APP_DIR=/private/tmp/…` (build, signe, installe ; ni données, ni fermeture, ni lancement ; `DATA`/`BLOCKING` refusés ; bandeau « données non préparées »). Sans `DEV_APP_DIR`, cela remplace la Goalong Dev du propriétaire (refusé si elle tourne).
- Limite tant qu’aucune release ne connaît `ai.goalong.localhistory.dev` (0.6.82 et avant ; `make dev` l’annonce) : Goalong installé enregistre les fenêtres et le texte de Goalong Dev dans le vrai `LocalHistory/`, et une liste « autoriser seulement » bloque Goalong Dev.
- Braise agit sur les vrais écrans (gamma global) : Braise actif dans les deux apps = conflit d’affichage. Le clone n’emporte pas l’état gamma de Goalong installé (`Braise/display-recovery*`).
- Non isolé ou non vérifié : trousseau (sans groupe partagé, séparation par bundle id non vérifiée).

## Interdits
- Jamais forcer la fermeture : un blocage actif peut refuser de quitter ; le résoudre dans l’app.
- Ne pas modifier `/Applications/Goalong History.app`, ni le trousseau, ni `blocking.json` à la main app ouverte.

## Vérifications
- Jamais `swift test` nu. Trois commandes, toutes en HOME jetable (`scripts/run_swift_tests.sh`) : `make check` (boucle rapide : build incrémental + tests des cibles modifiées vs `origin/main`, ou `FILTER=Regex`, sans les 5 tests lents ; durée affichée), `make test` (suite complète puis rapport des tests ignorés ; un skip absent de `scripts/expected_skips.txt` fait échouer), `make test-ui` (rendus et tests AX opt-in, `GOALONG_*_SNAPSHOTS` / `*_UI_TESTS`, sans fenêtre visible ; dit si l’écran est verrouillé ; PNG dans `/tmp/goalong-test-ui-*`). Un test opt-in nouveau doit entrer dans `expected_skips.txt` (`python3 scripts/skip_report.py LOG --emit-allowlist` aide). Les cibles App et Ambiance chargent le hook `GoalongHeadlessTestSupport`, qui supprime à la sortie les plists `UserDefaults(suiteName:)` créés par la course (jamais ceux qui existaient) ; `scripts/clean_leaked_test_prefs.sh [--dry-run|--delete] [--include-other-test-suites]` nettoie les anciennes fuites (`goalong-auto-consent-*` seulement par défaut). Puis `make audit`.
- Scripts Goalong Dev : `bash scripts/test_dev_app.sh` (sans build ni lancement ; lancé par `make test` et la CI). Identité dev/release : `bash scripts/test_stable_release_identity.sh` (clé de signature requise).
- Après ajout d’un fichier Swift dans l’app : `python3 scripts/generate_support_source_allowlist.py`.
- Toute nouvelle sortie réseau : `docs/NETWORK.md` et `scripts/generate_security_artifacts.py`.

## Tests invisibles (règle de Mathis, 2026-10-26)
- Aucune fenêtre de test ne doit apparaître sur l’écran du Mac ni prendre le focus. Jamais.
- Lancer les tests sur `ssh ci` quand c’est possible. `ci` est Linux : les tests AppKit, la galerie et les rendus restent sur le Mac.
- Sur le Mac, jamais au premier plan : `open -g -j` (jamais `open` seul), ni `activate`, processus `.prohibited`/`.accessory`, fenêtres à alpha 0, hors écran ou en bas à droite, cachées ou réduites, sans focus clavier. Fermer chaque fenêtre et chaque instance lancée à la fin.
- Garanti par construction : `Tests/GoalongHeadlessTestSupport` (fenêtres à alpha réel 0 vérifié à chaque mise à l’écran, sans animation, éléments de barre des menus cachés, processus `.prohibited`, ni activation ni ouverture d’URL/app ; un chien de garde interroge le serveur de fenêtres toutes les 100 ms, cache toute fenêtre visible, écrit `[headless-tests] VISIBLE` et la course sort en 1). En plus, `scripts/window_guard.swift` surveille `make check|test|test-ui` et `make gallery` toutes les 50 ms : fenêtre visible ou focus pris = processus tué, course en échec. Test : `HeadlessWindowGuardTests`. Pour voir les fenêtres : `GOALONG_TESTS_VISIBLE=1` (coupe tout).
