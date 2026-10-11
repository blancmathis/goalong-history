# Déploiement local automatique — 2026-10-11

Le Mac surveille `origin/main` par une requête Git sortante toutes les 60 secondes. Il n’héberge aucun runner Actions. Les tests motion/UI et leurs préférences système restent sur les VM GitHub.

Installation par le propriétaire : `python3 scripts/install_local_auto_deploy.py --start`. Agent utilisateur `ai.goalong.local-auto-deploy`, fichiers `~/Library/Application Support/GoalongDeploy`, plist `~/Library/LaunchAgents/ai.goalong.local-auto-deploy.plist`. Le contrôleur installé est une copie revue ; après une modification du contrôleur, réinstaller explicitement cette copie. Le code de build exécuté provient du checkout exact de main.

Commande manuelle identique : `python3 scripts/local_auto_deploy.py --repository /Users/mathisblanc/Developer/goalong-fast-ci-20261011`. `--retry` autorise une nouvelle tentative du même SHA après examen du journal. Une mesure sans publication utilise `--build-only --sha SHA_COMPLET --run-id RUN_ID_CI`. Ne supprimer que les scratchs propres au déploiement pour mesurer à froid ; aucun cache utilisateur Sparkle n’est effacé.

Le verrou est acquis avant fetch/checkouts et transmis aux processus lancés. Les scratchs release arm64/x86_64 et debug tests sont distincts, avec un budget 4+4+4. La clé de cache comprend Swift/SDK, les dépendances épinglées, scripts et flags. Un plist CLI immuable par hash change les arguments du linker quand version/build changent. Aucun token ni clé privée ne va dans le cache.

Avant publication, les gates `build-test-package`, `verify`, `native-sharing` doivent être réussies dans les workflows officiels, pour l’arbre Git exact de main ou celui de la PR fusionnée. Une gate absente, un arbre différent ou un main dépassé bloque le déploiement. La version part du feed Ed25519 authentifié et de son inventaire attesté ; le build garde la formule du resolver et le run ID de la gate qualité. Une compilation locale par tranche et une suite Swift locale restent exécutées. Les résultats UI hébergés du même arbre évitent une nouvelle exécution sur le Mac propriétaire.

Le Mac vérifie la signature certificate/team/DR épinglée, les architectures, le bundle et les versions CLI, puis remet le ZIP par `publish_local_release.sh --dist ... --publish`. La voie presigned exige toujours le SHA exact de main et le hash fourni. GitHub vérifie indépendamment les gates, repackage, signe le feed Ed25519 et atteste les octets finaux. Les clés de mise à jour restent uniquement dans GitHub.

`continuous-release.yml` n’a plus de trigger push. Son job full et son job de publication delta partagent `goalong-history-feed-writer`, sans annuler une écriture en cours. Les deltas sont calculés dans un autre job, avec bases attestées, validation d’application et cible full inchangée ; un enrichissement dépassé ou une release scellée devient un no-op. Le manifeste full reste immuable ; un manifeste de génération delta et une attestation couvrent les nouvelles sorties. Chaque mutation du feed garde `verify_published_update.sh`.

La disponibilité atomique n’est pas promise : le remplacement GitHub `--clobber` conserve le comportement actuel d’échec fermé. Aucun service payant, aucune modification de trust anchor, de designated requirement ou de provenance n’est requis.

Les chronos locaux sont dans `runs/<date>-<sha>/timings.json`, avec un log complet par étape et `publisher-jobs.json`. L’agent attend la fin de « Publish authenticated feed last », pas la génération des deltas ; il télécharge ensuite le ZIP final immuable et refait `verify_published_update.sh` sur le Mac. Le temps fusion→vérification inclut détection, file d’attente, transfert et vérification publique.
