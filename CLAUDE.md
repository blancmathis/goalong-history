# Goalong — guide des agents

## Où travailler
- Un worktree par sujet : `~/Developer/goalong-<sujet>-<date>`, créé depuis `origin/main`. Le checkout principal est en retard : ne pas y travailler.
- Si un dépôt local ne fetch plus (`bad object refs/heads/feat/garant-mac-20261008`), créer le worktree depuis `~/Developer/goalong-motion-placement-app-20260918`. Ne pas supprimer cette branche locale.
- Contexte projet (état, décisions, pièges) : `CONTEXT.md` du checkout principal (non versionné).

## Deux voies seulement
1. Itération locale : `make dev` / `make dev-stop` (ci-dessous). Ne publie rien.
2. Release : PR → merge sur `main` → la CI signe, vérifie et publie via Sparkle. **Merge = publication publique** : seulement avec l’accord du propriétaire.
- Aucun autre déploiement local. Les agents launchd `ai.goalong.local-*` sont désactivés : ne pas les recharger.

## `make dev`
- Compile en debug pour l’architecture du Mac (sans clean, tests ni audit), ferme normalement Goalong, lance `.build/dev/Goalong History.app`. Log : `.build/dev/build.log`. Signature vérifiée avant chaque basculement ; même bundle id et certificat que la release (identité TCC conservée, permissions existantes).
- Données (mode écrit dans l’Info.plist du bundle dev, `GoalongBuildChannel=dev` + `GoalongDevDataMode` ; une relance le garde) :
  - `make dev` : données isolées dans `~/Library/Application Support/LocalHistory-Dev/`, re-semé à chaque lancement par clone APFS de `LocalHistory/` (instantané, sans coût disque). Le miroir Codex de l’historique va dans `LocalHistory-Dev/codex-memory-mirror/`, pas dans `~/.codex`.
  - `make dev DATA=keep` : garde l’état dev, sans re-semer.
  - `make dev DATA=real` : ancien comportement, lit et écrit les vraies données (avertissement affiché).
- Exception : le blocage reste le vrai. `LocalHistory/Blocking/` (listes, quotas, verrou, garant) et `LocalHistory/Focus/` (engagements, jokers) sont lus et écrits en vrai, sinon `make dev` contournerait un blocage.
- Avant chaque basculement (`make dev`, `make dev-stop`), copie horodatée de `Blocking/` et `Focus/` dans `LocalHistory/app-backups/dev-switch/<date>-dev|stop/` (20 dernières gardées). Restaurer : app fermée normalement, recopier le dossier voulu à la place de `LocalHistory/Blocking` (ou `Focus`), puis relancer.
- Distinction visuelle (copie dev seulement) : point orange sur les icônes de barre de menu (Goalong, Braise), icône du bundle avec bandeau « DEV », nom affiché `Goalong History Dev`, titres de fenêtres « — Dev », bande « Copie de développement · données isolées » (orange plein si vraies données) en haut du panneau et de la fenêtre principale. Le nom du processus reste « Goalong History » : le démon `fr.lifeos.goalong-guard` le cherche par `pgrep -x`.
- Sparkle et les migrations d’installation sont désactivés dans la copie dev.
- **Toujours finir une session d’agent par `make dev-stop`** : ferme la copie dev et relance `/Applications/Goalong History.app`.
- Les deux commandes sont exclusives. Après une interruption, vérifier qu’aucune ne tourne avant de supprimer `.build/dev/lock`. `make clean` supprime aussi le cache dev : quitter la copie dev avant.

## Non isolé en dev
- Préférences `UserDefaults` (même bundle id ; dont l’activation des modules Blocage/Concentration), trousseau, compte et serveur Supabase réels, identité de l’appareil, App Attest, enregistrement à l’ouverture de session, caches système du bundle id.
- La CLI `goalong` installée parle à l’app installée (`LocalHistory/runtime`), pas à la copie dev isolée.

## Interdits
- Jamais une 2e instance à côté de l’app installée (passer par `make dev` / `make dev-stop`).
- Jamais forcer la fermeture : un blocage actif peut refuser de quitter ; le résoudre dans l’app.
- Ne pas modifier `/Applications/Goalong History.app`, ni le trousseau, ni `blocking.json` à la main app ouverte. Le démon guard relance l’app ~5 s après un kill ; l’arrêter demande le mot de passe admin.

## Vérifications
- Tests ciblés (`swift test --filter …`), puis `make audit`.
- Les tests restent invisibles (`Tests/GoalongHeadlessTestSupport` : fenêtres à alpha 0, ni activation ni ouverture d’URL/app). Pour les voir : `GOALONG_TESTS_VISIBLE=1`.
- Après ajout d’un fichier Swift dans l’app : `python3 scripts/generate_support_source_allowlist.py`.
- Toute nouvelle sortie réseau : `docs/NETWORK.md` et `scripts/generate_security_artifacts.py`.
