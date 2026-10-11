# Fast deploy — round 2, mesures en cours (2026-10-11)

**Révision locale approuvée et implémentée, validation en cours. Aucun runner GitHub sur le Mac ; les gates PR restent sur GitHub-hosted. La publication full et les deltas passent par le même écrivain hébergé. Le seuil ≤10 min reste à mesurer.**

Le code exact de runner v2.338.0 confirme l'objection de Pro : un hook pré-job sortant en erreur ne constitue pas une frontière indépendante du YAML. L'exécution de steps avec `always()`/`failure()` reste possible. Le contrôle local d'origine est donc une défense supplémentaire et ne prouve pas que le fork ne peut pas exécuter de code sur ce Mac.

## État concret et fichiers

- PR : https://github.com/blancmathis/goalong-history/pull/82, branche `ci/fast-deploy-20261011`, worktree `/Users/mathisblanc/Developer/goalong-fast-ci-20261011`.
- `/Users/mathisblanc/Developer/goalong-fast-ci-20261011/scripts/install_goalong_runner.py` : refuse maintenant inscription et activation publiques, avant tout changement local/API.
- `/Users/mathisblanc/Developer/goalong-fast-ci-20261011/scripts/guard_self_hosted_runner.py` : documentation et résultat corrigés ; ne prétend plus bloquer les steps hostiles.
- `/Users/mathisblanc/Developer/goalong-fast-ci-20261011/docs/fast-deploy-spec-20261011.md` : spec d'origine inchangée.
- `/Users/mathisblanc/Developer/goalong-fast-ci-20261011/docs/fast-deploy-admission-proposal-20261011.md` : proposition concrète de contrôleur privé et clarification du contrat du feed.
- Approval policy Actions **`all_external_contributors`** conservée et déjà relue par API ; aucun contrôle de signature/appcast/provenance réduit.
- Binaries officiels runner **2.338.0** conservés dans `/Users/mathisblanc/actions-runner-goalong-history` ; archive osx-arm64 contrôlée contre le SHA-256 publié `df4cebda25c86a886ed204e49fee63f5c2e7cec5f447b5c98440a826bbdf9df2`.
- Inscription publique créée par l'agent, ID **21**, supprimée après vérification du nom et de l'état offline/non busy. Labels avant suppression : self-hosted/macOS/ARM64/goalong-mac.
- Service `actions.runner.blancmathis-goalong-history.goalong-mac` : domaines launchd gui/user 501 **disabled**, plist `RunAtLoad=false`, aucun processus Listener/runsvc observé. Le wrapper `svc.sh stop` avait affiché « Unload failed: 5: Input/output error » avec exit 0 ; les checks directs launchctl/process/API ont établi l'arrêt, puis la désactivation a été confirmée indépendamment.
- Aucun Worker log depuis l'installation (**0**) ; aucune exécution de job sur ce runner n'est observée. Aucun canari hostile n'a été exécuté sur le compte propriétaire.
- Identité locale : signature d'une copie jetable de `/usr/bin/true` puis vérification toutes architectures contre certificat et team épinglés réussies ; aucune clé exportée. Ce probe ne prouve pas l'accès non interactif du futur service privé.

## Confirmation indépendante de la revue

Sources exactes v2.338.0 récupérées et conservées dans `.fast-deploy-work/runner-source/` :

- `JobExtension.cs:301–312,584–586` : actions préparées, hook ajouté aux pré-étapes, puis pré-étapes et steps ordinaires réunis. Blob `d3d5fb7b0e286b4a11161c9071758bbeff18ef05`.
- `ScriptHandler.cs:351–355` : le code de sortie non nul marque l'étape failed. Blob `b898f051dedf060852ec894e9cf0553349ed01d9`.
- `StepsRunner.cs:200–256,273–278` : les conditions des étapes suivantes continuent à être évaluées ; le résultat d'échec est agrégé au job. Blob `4a114fe0b241c1b6e9ebb7bf205b05108e0faea5`.
- `JobHookProvider.cs:68–87` : hook exécuté via ScriptHandler. Blob `9d616851d0ee4c5bf0bbc7158dc46497a884f1f7`.

Conclusion statique confirmée, sans reproduction hostile sur le Mac. Références : [JobExtension](https://github.com/actions/runner/blob/v2.338.0/src/Runner.Worker/JobExtension.cs#L301-L312), [StepsRunner](https://github.com/actions/runner/blob/v2.338.0/src/Runner.Worker/StepsRunner.cs#L200-L285), [ScriptHandler](https://github.com/actions/runner/blob/v2.338.0/src/Runner.Worker/Handlers/ScriptHandler.cs#L351-L355).

Le second point de Pro est confirmé : `continuous-release.yml:317` utilise `--clobber`, dont la [documentation CLI](https://cli.github.com/manual/gh_release_upload) annonce suppression avant upload. Les signatures restent requises ; disponibilité continue et atomicité ne sont pas garanties par ce mécanisme.

## Mesures réelles de la PR, pipeline existant

Les trois checks du commit **44d60a3d2562e433c65b6fcc0eadb70e21164469** ont réussi sur GitHub-hosted. Durées workflow depuis création jusqu'au dernier job terminé, queue incluse ; les stages sont des durées de steps exactes. JSON complets : `.fast-deploy-work/pr-82-*-{run,jobs}.json`.

| Run / étape | Mesuré | Spec / cible |
| --- | ---: | ---: |
| [Quality 38159168063](https://github.com/blancmathis/goalong-history/actions/runs/38159168063) | **18 min 59 s** | PR ~7 min |
| Tests | 6 min 47 s | baseline ~7 min |
| Analytics render | 1 min 24 s | journeys + renders baseline ~4 min |
| Journeys natifs | 1 min 10 s | journeys + renders baseline ~4 min |
| Build app | 7 min 28 s | baseline ~8 min |
| Packaging smoke | 22 s | inclus dans gate |
| [Motion 38159168059](https://github.com/blancmathis/goalong-history/actions/runs/38159168059) | 8 min 03 s | toutes les gates conservées |
| Motion native | 50 s | inclus dans motion |
| Build + tests motion | 6 min 47 s | duplication à résoudre |
| [Sharing 38159168107](https://github.com/blancmathis/goalong-history/actions/runs/38159168107) | 3 min 42 s | gate conservée |

La PR n'implémente pas encore le pipeline optimisé. Ces résultats prouvent la CI existante de la préparation initiale ; ils ne valident ni l'admission du Mac ni le seuil ≤10 min. Les checks d'une révision ultérieure doivent être rapportés séparément.

## Runs de référence de la spec

Les deux runs fournis sont des **push main** historiques, pas une nouvelle release de cette PR. JSON conservés dans `.fast-deploy-work/baseline-*-{run,jobs}.json`.

| Run / étape | Mesuré | Nombre annoncé par la spec / cible |
| --- | ---: | ---: |
| [38140195716](https://github.com/blancmathis/goalong-history/actions/runs/38140195716), workflow quality | 20 min 36 s | ~22 min / PR ~7 min |
| Tests | 7 min 15 s | ~7 min |
| Build app gate | 8 min 16 s | ~8 min |
| [38140195867](https://github.com/blancmathis/goalong-history/actions/runs/38140195867), workflow release | 33 min 53 s | ~34 min / merge → feed ~3 min |
| Build universel release | 21 min 1 s | ~21 min |
| DMG + ZIP | 1 min 10 s | inclus dans release |
| Appcast et deltas | 9 min 48 s | ~10 min |

## Décisions et reprise

Versionnage réglé avec Pro : garder V/B du candidat PR dans l'app et les deux tranches CLI ; prouver même arbre, toutes gates et état public authentifié ; promouvoir uniquement si V/B encore admissibles, re-signer le seul rattachement extérieur à main, reconstruire archives/inventaires/attestations. Sinon fallback sûr. Aucun nouveau patch Mach-O ni exception dans le validateur presigned actuel.

**Blocages nécessitant le propriétaire :** autoriser une frontière d'admission privée (proposition ci-dessus) et préciser si le feed doit aussi garantir sa disponibilité continue. L'avis Pro est `/Users/mathisblanc/.gpt-pro/tasks/812713/response.md`, outcome `needs_input`. Le gel d'attente de réponse Pro est levé ; le blocage actuel vient de ces décisions de périmètre et des critères de sécurité de la spec.

La protection de main (404 lors du contrôle initial), les caches/parallélisme, la promotion vérifiée et les deltas différés restent à implémenter après ces décisions. Aucun changement des workflows existants, aucune modification de `fix/panel-height-20261011`. Aucune mesure après fusion de cette PR, aucune nouvelle installation/relance ni publication. Ne pas fusionner tant que l'admission, toutes les garanties et le total ≤10 min ne sont pas prouvés.

## Round 2 — révision locale approuvée

- Runner : API `total_count=0`, service/binaries/hooks retirés ; `.fast-deploy-work/runner-removal-r2.log`.
- Coordinateur local : `scripts/local_auto_deploy.py`, installation `scripts/install_local_auto_deploy.py` ; poll 60 s, lock conservé par les processus enfants, état par SHA, logs/chronos et checkout exact dédiés.
- Build/tests : voies 4+4+4 workers, scratchs par architecture/configuration/chaîne d’outils ; plist CLI immuable adressé par SHA-256, versions vérifiées dans les deux tranches. Signature pin sans import P12 ni modification des trousseaux.
- Réutilisation des preuves : `scripts/local_deploy_policy.py` exige les trois gates GitHub Actions officielles réussies sur le même arbre ; source SHA exacte et refus de main dépassé. Le namespace de build garde le run ID de la gate productrice, jamais une date locale.
- Publication : `continuous-release.yml` est uniquement manuel / signed_stage ; groupes de concurrence identiques pour full et deltas. Archive full/feed authentifié puis calcul des deltas sans verrou ; bases attestées, application de chaque delta vérifiée, générations et octets attestés.
- Préflight feed public et inventaire attesté réussi ; contrôle CLI par tranche réussi sur l’app installée. Actionlint, Python/shell et politiques de release/archives/motion vérifiés ; logs `.fast-deploy-work/`.
- Réparation Git locale : objets archivés via liens NVME devenus pendants ; packs officiels récupérés par clone isolé, cibles d’origine conservées dans `.fast-deploy-work/git-object-directory-repair.json`. Aucun ref ni autre worktree changé.
- Mesures froide et vraie fusion chaude : à renseigner avant de déclarer l’objectif atteint.
