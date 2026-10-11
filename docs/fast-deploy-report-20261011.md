# Fast deploy — état partiel au 2026-10-11

Objectif : [spec](fast-deploy-spec-20261011.md). **Non accepté : pipeline rapide non implémenté, pas de mesure optimisée, aucune fusion.**

## Préparation effectuée

- Runner officiel actions/runner **2.338.0**, archive osx-arm64 vérifiée contre le SHA-256 publié `df4cebda25c86a886ed204e49fee63f5c2e7cec5f447b5c98440a826bbdf9df2`.
- Installation `/Users/mathisblanc/actions-runner-goalong-history`, service launchd utilisateur actif, runner repository ID **21**, nom `goalong-mac`, labels `self-hosted`, `macOS`, `ARM64`, `goalong-mac`, état `online` vérifié par API.
- Approval policy passée de `first_time_contributors` à **`all_external_contributors`**, relue par API. Aucune permission de signature/appcast/provenance réduite.
- Hook pré-job local installé dans `/Users/mathisblanc/Library/Application Support/GoalongRunnerHooks`, hors checkout et hors application runner. Origine officielle, event, ref, workflow et PR interne contrôlés avant les steps ; refus fail closed des forks, `pull_request_target`, autres repos/branches/workflows et payload absent. Allowlist actuelle : `macos.yml`, `continuous-release.yml`.
- Hook post-job : suppression du keychain/P12 temporaire, `dist`, archives presigned et bases de deltas ; conserve `.build`. Les credentials officiels nécessaires au service runner restent privés (dossier 0700, fichiers 0600). Aucune clé développeur exportée.
- Identité locale testée sur une copie jetable de `/usr/bin/true` : signature puis vérification toutes architectures contre le certificat ET le team épinglés dans `Distribution/release-signing.json`.

Installation reproductible : `python3 scripts/install_goalong_runner.py` (installe/configure sans démarrer) ; ajouter `--start` lors de la première installation pour activer le service. Le token d'inscription passe par `ACTIONS_RUNNER_INPUT_TOKEN`, jamais en argument. Les copies locales des hooks ne sont pas mises à jour automatiquement par une PR.

## Mesures de référence réelles, pipeline existant

Les deux runs fournis dans la spec sont des runs **push main**, pas des runs de cette PR. Les durées ci-dessous viennent des timestamps de jobs/steps GitHub, sans arrondi à la minute. Les JSON complets sont conservés dans `.fast-deploy-work/baseline-*-{run,jobs}.json` du worktree.

| Run / étape | Mesuré | Nombre annoncé dans la spec / cible |
| --- | ---: | ---: |
| [38140195716](https://github.com/blancmathis/goalong-history/actions/runs/38140195716), job quality gate | 20 min 27 s | ~22 min / PR ~7 min |
| Workflow quality complet (queue incluse) | 20 min 36 s | ~22 min |
| Tests | 7 min 15 s | ~7 min |
| Rendu analytics | 1 min 31 s | journeys + renders ~4 min |
| Journeys natifs | 1 min 12 s | journeys + renders ~4 min |
| Build app gate | 8 min 16 s | ~8 min |
| [38140195867](https://github.com/blancmathis/goalong-history/actions/runs/38140195867), job publication | 33 min 38 s | ~34 min / merge → feed ~3 min |
| Workflow release complet (queue incluse) | 33 min 53 s | ~34 min |
| Build universel release | 21 min 1 s | ~21 min |
| DMG + ZIP | 1 min 10 s | inclus dans release |
| Appcast et deltas | 9 min 48 s | ~10 min |

Ces mesures ne prouvent pas un déploiement ≤10 min. Pas de mesure PR optimisée, de mesure après fusion, ni de nouvelle vérification publique/installation à ce stade.

## Vérifications et blocage

- Compilation syntaxique Python des deux nouveaux scripts : OK.
- Contrôles directs du guard : internal PR et push main acceptés ; fork, event target, repo/ref/workflow incorrects et payload absent refusés. Il reste à prouver le routage hosted d'une vraie PR de fork et le hook dans un vrai job.
- Runner online et approval policy vérifiés par API ; identité locale disponible et conforme au pin.
- Aucune modification des workflows/build/signature existants ; aucune modification de `fix/panel-height-20261011` ni de la release en cours (`38157634643` observé in_progress).
- Main actuellement sans protection de branche (API protection 404) : les checks requis restent à configurer, en coordination avec le pipeline final.
- Avis de design **gptpro#812713**, `/Users/mathisblanc/.gpt-pro/tasks/812713/brief.md` et `agent-view.md`. Prompt copié, envoi humain requis. Le skill `/Users/mathisblanc/.agents/skills/gpt-pro/SKILL.md` exige : « Freeze what Pro is reviewing: do not edit those files until the answer arrives ». Les workflows et scripts existants examinés restent gelés.
- Points à trancher avant intégration : cohérence app/CLI du versionnage de l'archive PR ; validation de provenance/tree avant réutilisation ; plusieurs instances isolées pour des jobs parallèles ; publication différée des deltas sans course avec une nouvelle release.

Après avis et intégration : runs réels sur la PR, mesure wall par stage et total ; ne fusionner qu'après fin de la release parallèle et sous tous les critères de la spec. Après fusion autorisée : mesure jusqu'à « Publish authenticated feed last », vérification publique avec `scripts/verify_published_update.sh`, confirmation du canal vu par l'app installée. Aucun seuil ni check de sécurité ne sera réduit pour obtenir un run vert.

Référence officielle des hooks runner : [GitHub — Running scripts before or after a job](https://docs.github.com/en/actions/how-tos/manage-runners/self-hosted-runners/run-scripts).
