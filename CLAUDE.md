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
- Une seule Goalong Dev à la fois : le dernier `make dev` gagne (le bandeau dit quelle branche). L’étape installation/données prend un verrou global (`~/Library/Caches/goalong-dev-install.lock`) : deux worktrees n’installent jamais en même temps. `make dev-stop` ferme Goalong Dev seulement ; `make dev-status` donne branche, commit, date, mode de données et état.
- Données : `~/Library/Application Support/LocalHistory-Dev/`, jamais `LocalHistory/`. `DATA=clone` (défaut : clone APFS des vraies données, sans clé d’appareil, jetons de compte, `Blocking/`, `Focus/`, sauvegardes ni sockets), `DATA=keep` (garde l’état dev ; un dossier d’un ancien `make dev` perd d’abord clé d’appareil, jetons et sauvegardes réels), `DATA=fresh` (vide, nouvel utilisateur). `DATA=real` n’existe plus. Réglages lus seulement sur la ligne de commande de `make` (un `export DATA=…` du shell est ignoré).
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
- Démon garde `fr.lifeos.goalong-guard`, s’il est actif (inactif depuis le 2026-10-15) : il relance l’app installée ~5 s après un kill (`pgrep -x "Goalong History"`, Goalong Dev n’est pas concernée) ; l’arrêter demande le mot de passe admin.

## Vérifications
- Jamais `swift test` nu (fuites dans `~/Library/Preferences`). Tests ciblés avec un HOME jetable : `home=$(mktemp -d /tmp/goalong-test-XXXXXX); GOALONG_TEST_HOME="$home" CFFIXED_USER_HOME="$home" xcrun swift test --filter X; rm -rf "$home"`. Puis `make audit` et `make test`.
- Scripts Goalong Dev : `bash scripts/test_dev_app.sh` (sans build ni lancement ; lancé par `make test` et la CI). Identité dev/release : `bash scripts/test_stable_release_identity.sh` (clé de signature requise).
- Les tests restent invisibles (`Tests/GoalongHeadlessTestSupport` : fenêtres à alpha 0, ni activation ni ouverture d’URL/app). Pour les voir : `GOALONG_TESTS_VISIBLE=1`.
- Après ajout d’un fichier Swift dans l’app : `python3 scripts/generate_support_source_allowlist.py`.
- Toute nouvelle sortie réseau : `docs/NETWORK.md` et `scripts/generate_security_artifacts.py`.
