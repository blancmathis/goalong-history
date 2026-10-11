# Fast deploy — round 2 (2026-10-11)

**PARTIEL — code livré en #82 et #83, runner retiré, agent local actif, feed 0.6.74 vérifié. Objectif ≤10 min NON atteint : premier essai 648.456 s jusqu’à l’échec, second essai 904.227 s jusqu’à vérification Mac. Arrêt après deux approches, sans troisième essai.**

## Architecture et contrôles conservés

- PR #82 : https://github.com/blancmathis/goalong-history/pull/82 ; merge `922a1866145bc1d47018674c67262aef3a13f2b1`, le 2026-10-11 à 20:25:28 UTC. Worktree `/Users/mathisblanc/Developer/goalong-fast-ci-20261011`.
- Runner public désinscrit (API `total_count=0`), service, `~/actions-runner-goalong-history` et hooks retirés avant installation de l’agent local. Preuve `.fast-deploy-work/runner-removal-r2.log`. L’ancien hook pré-job n’est pas une frontière de sécurité ; aucun runner GitHub n’est installé sur le Mac.
- `scripts/local_auto_deploy.py` et `scripts/install_local_auto_deploy.py` : launchd utilisateur, poll sortant 60 s, verrou transmis aux enfants, checkout dédié exact et propre, état/tentative par SHA, arrêt des enfants et nettoyage des fixtures propres au run.
- Tests/builds en parallèle 4+4+4, scratchs persistants séparés, clé de chaîne d’outils, plist CLI immuable par hash et contrôle des versions dans chaque tranche. Signature certificate/team/DR épinglés, aucun import P12, changement de trousseau ni préférence motion/UI du propriétaire.
- Admission : trois gates officielles GitHub-hosted réussies sur l’arbre exact de main ou de sa PR fusionnée. Version issue du feed Ed25519 et de l’inventaire attesté ; namespace de build du resolver conservé, fondé sur le run ID qualité, jamais l’heure locale.
- `continuous-release.yml` sans trigger push : seul écrivain hébergé, groupe `goalong-history-feed-writer` partagé full/publication delta. Full authentifié avant deltas, calcul hors verrou, bases attestées, chaque delta appliqué et comparé à la cible signée ; manifeste de génération distinct, origine/capabilities/SBOM conservés. Aucun effacement de cache Sparkle utilisateur.
- Chaque publication garde `verify_published_update.sh`, signatures, provenances et refus d’un main dépassé. Disponibilité atomique du remplacement GitHub hors périmètre, comportement fermé conservé. Aucun service payant ajouté.
- Pro 812713 lu et vérifié, sans nouvelle consultation. Runbook : `docs/local-auto-deploy-20261011.md`.

## Premier merge chaud — échec mesuré

Agent launchd non interactif actif avant la fusion ; première détection à 20:26:05.220 UTC, soit **37.220 s** après le merge. App produite : **0.6.73 / 30000000.3817037.485301**, liée au SHA main exact. Trois gates PR finales réussies : quality `38170374853`, motion `38170374852`, sharing `38170374851`.

| Étape locale | Wall time |
| --- | ---: |
| fetch / checkout / clean | 0.727 / 0.024 / 0.132 s |
| admission des gates | 3.322 s |
| état public authentifié | 8.356 s |
| signing-preflight non interactif | 0.081 s |
| tests (1 849, 66 ignorés, zéro échec) | 162.439 s |
| arm64 / x86_64 (en parallèle) | 5.086 / 4.990 s |
| build, signature et vérification | 27.021 s |
| identité finale | 1.010 s |
| ZIP, transfert et dispatch | 135.029 s |
| total coordinateur jusqu’à l’échec | 611.264 s |
| merge → arrêt en échec | **648.456 s (10 min 48.5 s)** |

Les trois voies ne s’additionnent pas. Le champ historique `mergeToVerifiedSeconds` de ce run contient le temps d’arrêt en échec ; ce n’est pas une vérification réussie. Le coordinateur corrigé distingue désormais `mergeToStopSeconds`.

Publisher [38172553858](https://github.com/blancmathis/goalong-history/actions/runs/38172553858), toutes les étapes de sécurité réussies avant le contrôle public final :

| Étape hébergée | Wall time |
| --- | ---: |
| validation archive/signature locale | 23 s |
| source/gates/policies | 8 s |
| architectures, identité, CLI et confidentialité | 33 s |
| installation Brew, DMG et nouveau ZIP | 79 s |
| appcast full authentifié | 37 s |
| inventaire / attestation | 3 / 4 s |
| archive immuable | 11 s |
| admission publique monotone | 9 s |
| nettoyage anciens assets | 3 s |
| assets rolling | 26 s |
| feed puis vérification (échec) | 17 s |

L’upload du nouveau feed a réussi, mais le GET immédiat a reçu l’ancien **feed valide signé 0.6.72**, puis le vérificateur a refusé la différence de build. Le feed 0.6.73 est ensuite devenu visible et authentifié. Les deltas ont été ignorés par dépendance à l’échec ; `latest-main` n’a pas été retagué après un contrôle raté.

Preuves complètes : `~/Library/Application Support/GoalongDeploy/runs/20261011T202605Z-922a1866145b/`, `.fast-deploy-work/live-publisher-jobs.json`, `.fast-deploy-work/publisher-failure-38172553858.log`, `.fast-deploy-work/real-merge.json`. Les mesures froides et de métadonnées ci-dessous ne constituent pas une publication après merge.

## Correction pour le second essai

Le vérificateur garde la même URL client et authentifie chaque lecture ; seul un feed signé plus ancien peut être relu (20 tentatives, pause 2 s). Feed invalide ou plus récent : refus immédiat, avant le téléchargement des archives. Le ZIP signé fourni est conservé byte-for-byte après sa vérification indépendante. Le DMG utilise le fallback natif hdiutil déjà existant, sans installation Brew. Sur le Mac, l’inventaire final attesté pour le SHA exact fournit le digest attendu ; le ZIP de l’URL publique immuable est téléchargé pendant la publication rolling. Le vérificateur exige ensuite la même URL dans le feed signé, vérifie taille, signatures Ed25519 et hash attesté. Packaging DMG et génération appcast lisent le ZIP immuable en parallèle ; toutes leurs sorties/erreurs sont attendues avant inventaire et publication.

Les contrôles Python/shell/actionlint et les politiques presigned/publication/signature/cryptographie ont réussi, `.fast-deploy-work/followup-checks.log`. La première CI corrective a échoué sur une assertion statique de syntaxe Bash ; l’assertion vise désormais le même argument de tag immuable dans l’appel Python. Tout le bloc « Validate scripts » exact a ensuite réussi localement en **16.410 s** (`.fast-deploy-work/validate-scripts-exact.{sh,json,log}`). Les tests du préchargement refusent URL/hash erronés, puis valident les octets signés réels (`.fast-deploy-work/followup-prefetch-checks.{json,log}`). Packaging natif : **18.475 s**, mauvais hash refusé, ZIP inchangé, `hdiutil imageinfo` réussi (`.fast-deploy-work/package-reuse.json`). Vérification publique de récupération : **PUBLIC_UPDATE_VERIFIED 0.6.73**, 82.492 s, zéro delta (`.fast-deploy-work/recovery-public-verify.{json,log}`) ; elle ne corrige pas rétroactivement l’échec du premier seuil. Le second merge réel et son résultat figurent ci-dessous ; aucun réessai automatique du SHA déjà tenté.

## Second merge chaud — publication vérifiée, seuil non atteint

PR #83 https://github.com/blancmathis/goalong-history/pull/83 fusionnée en **69a25978929074c7305768b447f6d56a4110adb3**, à **21:22:19 UTC**. Les trois gates du head **5b87b669fd57cbec9d575196242e6cd194a8a8db** ont réussi : qualité `38174725337`, motion `38174725292`, sharing `38174725296`. Aucun troisième essai lancé : la règle d’arrêt de `/Users/mathisblanc/.claude/delegation/STANDING.md` s’applique après deux approches n’ayant pas passé le critère demandé.

App/feed **0.6.74 / 30000000.3817472.533701**, SHA exact ci-dessus. **PUBLIC_UPDATE_VERIFIED** sur GitHub à 21:36:45 UTC (step terminé 21:36:46), puis sur le Mac ; `latest-main` pointe maintenant sur le bon SHA. **Merge → vérification hébergée : 867.000 s (14 min 27 s)**. **Merge → vérification Mac : 904.227 s (15 min 04.2 s)**. Le seuil **≤600 s échoue**, y compris en ne comptant que le contrôle hébergé.

Détection launchd : **38.612 s**. Cache effectivement chaud : compilation tests **3.10 s**, builds par architecture **15.663 s**. La suite entière a pris **381.279 s** (1 849 tests, 66 ignorés, zéro échec), contre 162.439 s au premier merge ; transfert/dispatch **219.467 s**, contre 135.029 s. Le snapshot pendant cette mesure montre une charge **27.51 / 35.17 / 28.18** sur 14 cœurs, plusieurs processus concurrents actifs et 1 704 Mo de swap utilisé. Cette charge coïncide avec le ralentissement ; sa causalité n’a pas été isolée. Aucun processus externe n’a été modifié.

| Étape locale | Wall time |
| --- | ---: |
| fetch | 0.778 s |
| checkout | 0.151 s |
| clean | 0.272 s |
| hosted-gates | 4.383 s |
| authenticated-public-state | 10.377 s |
| signing-preflight | 0.125 s |
| build-sign-verify | 80.568 s |
| tests | 381.279 s |
| build-x86_64 | 15.663 s |
| build-arm64 | 15.663 s |
| final-identity | 8.490 s |
| handoff | 219.467 s |
| await-Publish immutable update archive | 139.653 s |
| download-final-manifest | 1.087 s |
| verify-final-provenance | 8.422 s |
| download-public-archive | 82.792 s |
| await-Publish authenticated feed last | 2.946 s |
| verify-published | 4.957 s |
| total coordinateur | 865.613 s |
| merge → vérification Mac | **904.227 s** |

Tests/builds en parallèle ; téléchargement public chevauchant la publication rolling : ne pas additionner les voies indépendantes. Les métriques d’attente sont séparées des stages de commande.

Publisher [38176855447](https://github.com/blancmathis/goalong-history/actions/runs/38176855447) : job full **success** ; workflow global encore en cours à l’arrêt du relevé (deltas).

| Étape hébergée | Wall time |
| --- | ---: |
| Set up job | 2 s |
| Run actions/checkout@d23441a48e516b6c34aea4fa41551a30e30af803 | 3 s |
| Require update signing credentials | 0 s |
| Validate explicitly supplied local signature | 20 s |
| Test source for supplied build | 10 s |
| Resolve rolling version | 0 s |
| Verify architecture, stable signature, identity, and privacy policy | 26 s |
| Package DMG and generate authenticated Community appcast | 42 s |
| Generate auditable release inventory | 3 s |
| Attest Community release provenance | 2 s |
| Refuse to publish a superseded or non-main commit | 1 s |
| Publish immutable update archive | 12 s |
| Require monotonic authenticated release state | 10 s |
| Remove retired rolling-release assets | 3 s |
| Publish rolling GitHub release | 27 s |
| Publish authenticated feed last | 27 s |
| Retain full generation for deferred deltas | 7 s |
| Remove temporary signing keychain | 0 s |
| Post Run actions/checkout@d23441a48e516b6c34aea4fa41551a30e30af803 | 1 s |
| Complete job | 1 s |

Packaging natif **23.819 s**, appcast **42.329 s**, exécutés en parallèle (step GitHub 42 s) ; toutes erreurs et sorties attendues. L’ancienne voie séquentielle packaging + appcast avait pris 116 s au premier merge. Inventaire final attesté vérifié sur Mac pour ce SHA/ref/workflow GitHub-hosted exact ; URL publique préchargée identique à l’enclosure signée, signatures/taille/hash vérifiés. Contrôle final Mac **4.957 s** après préchargement de **82.792 s**.

Search list de trousseaux et préférence Reduce Motion identiques avant/après, `.fast-deploy-work/after-second-merge-environment.json`. Runner GitHub absent, agent local actif et état `published-verified` pour ce SHA ; pas de répétition automatique du même SHA. Aucun service payant, exception de signature/provenance ni second écrivain ajouté.

Deltas : `prepare-deltas` **in_progress** dans le snapshot final ; publication/application/attestations delta non revendiquées comme vérifiées de bout en bout. Le feed full vérifié contient **0 delta** et reste utilisable. Le calcul déjà engagé continue hors du chemin critique, avec la publication éventuelle sérialisée sous le même verrou hébergé. Aucun nouveau test ni merge lancé pour prolonger cet essai.

Preuves : `/Users/mathisblanc/Library/Application Support/GoalongDeploy/runs/20261011T212257Z-69a259789290/timings.json`, `verify-published.log`, `verify-final-provenance.log`, `final-manifest/`, `publisher-jobs.json` ; `.fast-deploy-work/second-real-merge.json`, `second-publisher-jobs.json`, `second-publisher-full-job.log`, `second-merge-process-snapshot.log`, `pr83-final-completion.json`.

**Suite nécessaire pour satisfaire l’objectif :** une nouvelle décision du propriétaire après ces deux échecs de délai, puis une mesure réelle admissible. Les chiffres locaux froids/chauds précédents et une extrapolation à charge réduite ne prouvent pas le seuil. Le rapport final est mis à jour localement dans le worktree ; le code est fusionné, les descriptions #82/#83 porteront ce résultat sans nouveau merge de documentation.

## Références historiques

Le round 1 portait sur l’admission du runner public et avait été bloqué à juste titre. Décision propriétaire révisée : aucun runner sur ce Mac ; l’avis Pro sur la promotion PR n’autorise pas une promotion non prouvée. Le round 2 construit directement le SHA exact de main.

Baselines avant optimisation : quality `38140195716` **20 min 36 s** (tests 7 min 15 s, build 8 min 16 s) ; release `38140195867` **33 min 53 s** (build 21 min 1 s, packaging 1 min 10 s, appcast/deltas 9 min 48 s). Mesures/JSON originaux `.fast-deploy-work/baseline-*-{run,jobs}.json` ; CI initiale #82 `38159168063` **18 min 59 s**, motion `38159168059` **8 min 03 s**, sharing `38159168107` **3 min 42 s**. Ces runs historiques ne mesurent pas le seuil merge→feed du round 2.

## Environnement local et limites

Les liens d’objets Git vers l’archive NVME sont devenus pendants. Les objets officiels ont été récupérés par clone isolé ; cibles d’origine conservées dans `.fast-deploy-work/git-object-directory-repair.json`. Certains anciens refs locaux hors périmètre restent sans objets : la mise à jour officielle de main est récupérée dans le clone isolé, sans modifier ces refs ni d’autres worktrees.

## Mesure froide locale (préparation sans publication)

Checkout exact `24b2c3a0e1613634d38cfc18ff79d8507f896d55`, scratchs SwiftPM vides au départ, Apple M4 Pro, macOS/Xcode locaux. Build `0.6.73` / `30000000.3815916.806301`. Cette mesure couvre clone, état public authentifié, tests, deux builds, signature/vérification et ZIP de staging ; aucune fusion ni écriture du feed.

| Étape | Wall time |
| --- | ---: |
| clone | 4.563 s |
| fetch | 0.491 s |
| checkout | 0.169 s |
| authenticated-public-state | 8.258 s |
| tests | 335.762 s |
| build-arm64 | 331.498 s |
| build-x86_64 | 331.489 s |
| build-sign-verify | 396.790 s |
| final-identity | 1.012 s |
| staging-archive | 19.974 s |
| Total préparation froide | **432.817 s** |

Les voies tests/arm64/x86_64 sont parallèles : ne pas additionner leurs temps. Suite : **1 849 tests, 66 ignorés, zéro échec** ; runtime tests 192.363 s, compilation comprise dans la ligne tests. Version/build CLI contrôlés dans les deux tranches ; identité pin/DR et audit de confidentialité passés. Preuves : `/Users/mathisblanc/Library/Application Support/GoalongDeploy/runs/20261011T194451Z-24b2c3a0e161/timings.json`, logs par étape et `.fast-deploy-work/cold-coordinator.log`.

## Régression cache chaud / métadonnées

Deuxième checkout `c08f92af67371b7a90e144ca0419570fb74b1bf7` sur les mêmes scratchs : version de fixture **0.6.74**, build `30000000.3816946.129801`, après la préparation froide 0.6.73 / `30000000.3815916.806301`. Cette version de fixture utilise un plancher explicite uniquement en mode `--build-only` ; aucune publication.

- arm64 **5.996 s**, x86_64 **5.863 s** ; build + signature + bundle/CLI/identité/audit **26.440 s**.
- Tests **170.450 s**, 1 849 tests / 66 ignorés / zéro échec ; ZIP **20.021 s** ; état public authentifié **7.952 s**.
- Total préparation **200.505 s (3 min 20.5 s)**. Le plist par hash provoque bien le relink pour version/build changés ; les deux tranches concordent avec le bundle extérieur.
- Preuves : `/Users/mathisblanc/Library/Application Support/GoalongDeploy/runs/20261011T195340Z-c08f92af6737/timings.json` et logs ; `.fast-deploy-work/warm-metadata-coordinator.log`.
- L’archive publique réelle 0.6.72, hash égal au manifeste attesté, passe le lecteur strict utilisé par les deltas. Le SBOM et les capabilities originaux restent inchangés ; seul le manifeste de génération décrit les nouveaux feed/deltas.
