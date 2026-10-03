# Activité de développement et agents par projet

Implémentation D1–D5 du plan [Data depth](DATA_DEPTH.md), 2026-10-03. Les vues et
Réglages sont intégrés séparément sur `feat/data-depth-20261003` ; ce lot fournit leurs API.

## Contrat

Ces sources ne changent jamais `GoalongLocalAnalytics.activeSeconds`. Un span de conversation
est une borne documentaire, pas un temps d'exécution continu ou une mesure d'attention. Le
statut de chaque source distingue désactivation, absence, format inconnu, erreur et lecture
partielle. Un compteur absent n'est pas affiché comme une activité nulle.

Les données de T3 et d'AgentActivity sont transitoires. Aucun message, titre de fil, payload,
checkpoint, diff, commande shell, sujet de commit ou contenu de fichier n'est analysé ici.
Les noms de projets T3 et les chemins de dépôts servent au regroupement local, en mémoire.
Seule la sélection explicite de projets conserve leurs noms et racines dans
`developer-projects.json` (0600). Les journaux `developer/<jour>.jsonl` contiennent uniquement
un identifiant opaque de projet, une date de tranche, un nombre, un indicateur d'estimation
et un identifiant d'événement FSEvents. Ils suivent la conservation des événements détaillés
et la suppression des vues dérivées par jour/période.

## T3 Code

`T3CodeMetadataReader` (module AgentActivity) découvre `~/.t3/userdata/statev2.sqlite` derrière
le consentement Conversations locales. Il conserve les métadonnées v1 et v2 compatibles,
déduplique les demandes par fil et instant, et réunit les périodes des tours en cours pour
calculer durée d'exécution, chevauchements et nombre maximal de tours simultanés. Les délais
entre une fin de tour et la demande suivante dans le même fil sont plafonnés à deux heures.
Ce délai ne prouve pas que l'agent demandait une réponse de l'utilisateur.

Les requêtes lisent uniquement les colonnes permises et les lignes chevauchant le jour et
sa marge de deux heures. Le schéma est fingerprinté ; une colonne obligatoire absente donne
`unsupported`. La lecture limite projets (1024), lignes (20 000 par famille), cellules (8 KiB),
cache SQLite (2 MiB) et temps (2 s). Une limite atteinte donne `partial` sans inventer le reste.
La transaction est courte, la connexion utilise `SQLITE_OPEN_READONLY`, `query_only`,
`temp_store=MEMORY`, `mmap_size=0`, un délai de verrouillage de 100 ms et un progress handler.

Une base sans WAL actif est ouverte avec `immutable=1`. Un WAL actif n'est lu que si WAL et
SHM existent déjà ; aucun sidecar ni snapshot n'est créé par Goalong. Les verrous de lecture
SQLite utilisent le SHM existant. La base et le WAL ne sont pas modifiés. Voir le contrat
[SQLite WAL en lecture seule](https://sqlite.org/wal.html#read_only_databases).
Le chemin est résolu avec POSIX `realpath` : Foundation conserve l'alias `/var` sur macOS,
qui fait échouer `SQLITE_OPEN_NOFOLLOW` avec le code 1550. Les liens vers la base et les
sidecars sont refusés, et l'identité de la base est vérifiée avant/après ouverture.

## Regroupement, Git et fichiers

`GoalongRepositoryResolver` lit `.git`/`commondir` sans lancer Git : les worktrees liés et
sous-dossiers se regroupent avec le checkout principal. `GoalongDeveloperProject.rootPath`
est cette racine canonique ; `observationRoots` conserve aussi les worktrees réellement choisis,
pour que FSEvents ne perde pas leur activité. Ajouter une suggestion fusionne ces racines
sans créer deux projets (64 projets, 16 racines par projet au maximum). `GoalongAgentProjectGrouping` regroupe
les documents par dépôt, déduplique captures et jetons, et associe les compteurs T3. Les appels
d'outils/erreurs ne sont attribués au jour que si leur projection est explicitement journalière.
Les jetons sans valeur exploitable restent inconnus.

`GoalongGitActivityReader` lit la fin des reflogs HEAD, branches et worktrees. Il décode
uniquement l'heure, le nouveau hash et le préfixe d'action avant `:`. Les commits et amendements
sont dédupliqués par nouveau hash. Limites : 256 fichiers, 256 KiB par fichier, 20 000 lignes,
2 s ; une troncature, un changement de source ou une lecture refusée marque le résultat
partiel. Les mesures réelles sur un dépôt ancien peuvent donc être des bornes inférieures.

`GoalongDeveloperFileMonitor` observe les seules racines choisies par FSEvents (latence 30 s,
queue utility). Il ignore `.git`, `.build`, `node_modules`, `DerivedData`, `dist`, `build`, caches
et `.DS_Store`. Les chemins sont hachés uniquement dans une table transitoire, plafonnée à
10 000 fichiers par tranche de cinq minutes. Les snapshots successifs d'une tranche se
remplacent lors de la lecture : on ne somme pas plusieurs écritures du même compteur. La somme
journalière compte les fichiers distincts *par tranche*, pas les fichiers uniques de la journée.
Le watermark n'avance qu'après l'écriture des compteurs. Le runtime réagit au consentement,
aux projets et à la pause globale. Une reprise de pause ignore les changements pendant la pause.

**Limite FSEvents :** les événements historiques ne portent pas leur heure d'origine. Les
changements rejoués après un arrêt sont attribués à la tranche de réception et marqués estimés,
jamais antidatés. Une perte d'événements est signalée. Après un redémarrage dans la même tranche,
le compteur est une borne inférieure car l'ancien ensemble de chemins a été jeté. Après une
suppression explicite, cet ensemble est invalidé pour ne pas reconstituer les compteurs effacés.

## API pour les vues

- `GoalongDeveloperModel` (@MainActor, ObservableObject) : `value`, `status`, `t3Discovered`,
  `selectedProjects`, `suggestions`, `refresh(day:agents:)`, `setEnabled`, `addProject`,
  `removeProject`. Le caller peut fournir l'overview AgentActivity du jour déjà chargé ;
  sans overview, la valeur vide garde le jour demandé. `addProject` accepte une URL ou
  un `GoalongDeveloperProject` suggéré. Fichiers : `DeveloperActivity/GoalongDeveloperModel.swift`
  et `LocalHistoryCore/GoalongDeveloperModels.swift`.
- `GoalongDeveloperRuntime.status` et `stop()` : état/cycle de vie du moniteur ;
  `GoalongDeveloperStore.configuration()`, `add`, `remove`, `read`, `cursor` : sélection/compteurs locaux.
- `GoalongDeveloperDay` : `t3`, `agents`, `git`, `files`, `developerStatus`, projets/suggestions.
- `T3CodeDay` : statut, projets du jour, projets découverts, fingerprints source/schéma,
  nombre de lignes lues. `T3CodeProjectDay` : demandes, intervalles busy/waiting, leurs unions,
  simultanéité maximale, premier/dernier instant.
- `GoalongAgentProjectsDay` : statut, projets, sessions non attribuées.
  `GoalongAgentProjectDay` : sessions, providers, spans, jetons/appels/erreurs optionnels, T3.
- `GoalongGitActivity` : statut, actions horodatées, commits, premier/dernier instant, fingerprint.
- `GoalongFileModificationsDay` : statut, buckets et cumul `fileChanges`.
- `GoalongCapability.developerActivity` : « Activité de développement », éteint par défaut.
  Le runtime FSEvents est raccordé au cycle de vie de l'app dans AppDelegate.

`GoalongDeveloperReader` vit hors du main actor et garde des caches bornés par jour/révision.
Le nouveau booléen optionnel `GoalongAnalysisSelection.developer` est absent/désactivé dans les
anciennes sélections. Les bilans sélectionnés et granulaires ajoutent la section
« Développement » uniquement si ce booléen est vrai. Les exclusions globales omettent toute
la section, car les projets n'ont pas de provenance app/site. Les choix de dossiers d'agents
restent appliqués, et les remplacements de texte granulaires protègent les noms de projets.
La section est plafonnée à 12 projets et 8000 caractères ; aucun chemin n'est envoyé.
`ChatGPTRecapSourceCounts.developerProjects` est optionnel pour les anciens bilans et permet
à `hasMeaningfulData` de reconnaître un bilan alimenté seulement par cette nouvelle piste.

## Vérification

Tests nouveaux : `GoalongDeveloperTests`, `T3CodeMetadataTests`, `GoalongAgentProjectsTests`,
`GoalongDeveloperModelTests`. Ils vérifient schémas v1/v2, WAL vivant sans mutation de la base/WAL,
déduplication, clipping à minuit, unions/simultanéité, inconnus, refus des liens, sélection,
confidentialité et suppression des compteurs. Le test FSEvents réel crée un dépôt isolé dans
`.build/` : macOS n'émet pas les événements attendus dans `/var/folders` sur ce Mac.

Sanity check facultatif, agrégats seulement :

```sh
GOALONG_DEVELOPER_REAL_PROBE=1 swift test --filter T3CodeMetadataTests.testRealSourcesAggregateProbe
```

Résultat du 2026-10-03 à 22:15 (Europe/Paris), statut T3 `partial` : aujourd'hui 946 lignes de
métadonnées, 11 projets, 432 demandes ; hier 603 lignes, 11 projets, 294 demandes. Ces demandes
incluent les deux générations de T3. Reflogs du dépôt Goalong : aujourd'hui au moins 13 commits
et 6 autres actions ; hier au moins 3 commits et 4 autres actions (`partial`, budgets de lecture).
Chaque ligne ci-dessous est un projet opaque : secondes d'exécution et d'attente entre demandes
sont réunies **au sein de ce projet**, sans signifier une durée d'attention humaine.

| Jour | Projet | Demandes | Exécution (s) | Attente (s) | Tours parallèles max |
|---|---|---:|---:|---:|---:|
| 2026-10-03 | 28cd94b06877 | 45 | 5474 | 37088 | 2 |
| 2026-10-03 | 291e72a122bb | 1 | 45 | 7200 | 1 |
| 2026-10-03 | 3e5394968d9e | 5 | 327 | 17165 | 1 |
| 2026-10-03 | 40981e042744 | 12 | 2847 | 18486 | 1 |
| 2026-10-03 | 614382f52529 | 135 | 40808 | 57999 | 3 |
| 2026-10-03 | 6d89412b1d69 | 8 | 39 | 9263 | 1 |
| 2026-10-03 | 710a85e08aa8 | 24 | 16439 | 12614 | 2 |
| 2026-10-03 | c20b0e0c521a | 41 | 9951 | 53153 | 1 |
| 2026-10-03 | c597efb0f59b | 54 | 19054 | 41992 | 4 |
| 2026-10-03 | c7e0b667c982 | 30 | 45311 | 30722 | 2 |
| 2026-10-03 | e3ec982e3ecb | 77 | 7617 | 55205 | 3 |
| 2026-10-02 | 28cd94b06877 | 53 | 4209 | 49668 | 2 |
| 2026-10-02 | 291e72a122bb | 13 | 1250 | 10682 | 1 |
| 2026-10-02 | 3e5394968d9e | 2 | 8 | 14400 | 1 |
| 2026-10-02 | 614382f52529 | 27 | 20955 | 30998 | 2 |
| 2026-10-02 | 62e3f0cda32e | 0 | 0 | 4988 | 0 |
| 2026-10-02 | 710a85e08aa8 | 3 | 86 | 7354 | 1 |
| 2026-10-02 | 76558ad47c0e | 14 | 735 | 14963 | 1 |
| 2026-10-02 | c20b0e0c521a | 23 | 6086 | 25280 | 1 |
| 2026-10-02 | c597efb0f59b | 23 | 11828 | 37797 | 1 |
| 2026-10-02 | c7e0b667c982 | 60 | 24693 | 41132 | 1 |
| 2026-10-02 | e3ec982e3ecb | 76 | 12217 | 48047 | 2 |

Détails et preuve de sortie sans contenu : `/tmp/goalong-developer-checks/real-aggregate.log`.

### Résultats des contrôles

- Suite complète, HOME isolé : `Executed 1454 tests, with 32 tests skipped and 0 failures (0 unexpected)`
  (580 s), `/tmp/goalong-developer-full-green.log`. Les deux tests de chiffrement dépendant du
  trousseau sont ignorés explicitement lorsque le HOME ne possède aucun trousseau login ;
  ce garde-fou est conservé dans un commit séparé pour l’intégration.
- Allowlist, sécurité source et audit de confidentialité : passent. Tous les tests de scripts CI
  passent ; les contrôles upgrade/parity/update ont été exécutés dans un clone temporaire du
  même commit de départ, parce que le validateur upgrade exige un répertoire `.git` et refuse
  le fichier `.git` d'un worktree. Aucun script n'a été affaibli.
- Analytics : 2 tests ; rappels : 1 ; parcours natifs : 3 ; relancement réel de la fixture : OK.
  Export : 27 tests réussis dans chacun des trois fuseaux CI. Captures dans `qa/local-analytics/`
  et `qa/journey-ci/` pendant la CI. Les captures de ce contrôle sont conservées sous
  `/tmp/goalong-developer-checks/qa/`, données synthétiques et HOME isolé.
- Bundle release arm64 `0.6.0-ci`, build `202610032230`, révision de code `d9de60f` : OK ;
  signature ad hoc forcée, `plutil`, signature stricte, vérification locale, capacités et CLI : OK.
  Ce contrôle ne valide ni une signature Developer ID/notarisation ni une installation réelle.
  ZIP : 101904420 octets ; DMG : 113194598 octets.
  Bundle et archives dans `dist/`, statut exact dans
  `/tmp/goalong-developer-checks/bundle-state.json` (toutes les étapes : `exit=0`).
- **Blocage CI restant, hors lot D :** `GoalongDisclosureInteractionTests` échoue (10 erreurs,
  puis 11 avec HOME neuf). Message exact : `Clicking the title, not just the chevron, must collapse it`.
  La vue `GoalongDisclosureGroup.swift` et son test n'ont aucun diff avec le commit de départ.
  Aucun fichier de vue n'est modifié dans ce lot. Ne pas annoncer le gate CI entièrement vert ;
  l'intégration UI doit résoudre/valider ce test. Logs :
  `/tmp/goalong-developer-checks/disclosure-ui.log` et `disclosure-ui-fresh.log`.

Les journaux complets des contrôles sont dans `/tmp/goalong-developer-checks/`.

## Fichiers du lot

- Core, nouveaux : `Sources/LocalHistoryCore/GoalongDeveloperModels.swift`,
  `GoalongDeveloperFileIO.swift`, `GoalongDeveloperStore.swift`, `GoalongGitActivity.swift`.
- AgentActivity, nouveaux : `Features/AgentActivity/Sources/T3CodeMetadataReader.swift`,
  `GoalongAgentProjects.swift` ; tests correspondants dans `Features/AgentActivity/Tests/`.
- App, nouveaux : `Sources/LocalHistoryApp/DeveloperActivity/GoalongDeveloperModel.swift`,
  `GoalongDeveloperFileMonitor.swift`, `GoalongDeveloperRuntime.swift`, `GoalongDeveloperRecap.swift`.
- Raccords additifs dans `Sources/LocalHistoryApp/` : `CapabilityConsentStore.swift`,
  `AppDelegate.swift`, `GoalongAnalysisSelection.swift`, `ChatGPT/ChatGPTRecapContext.swift`,
  `ChatGPT/GoalongGranularContext.swift`, `HistoryRetentionStore.swift`, `DerivedHistoryCleaner.swift`,
  `SupportSourceAllowlist.swift` régénéré.
- Tests : `Tests/LocalHistoryCoreTests/GoalongDeveloperTests.swift`,
  `Tests/LocalHistoryAppTests/GoalongDeveloperModelTests.swift`, garde-fou dans `ChatGPTRecapTests.swift`.
- Documentation : ce guide, `docs/INDEX.md`, `docs/PRIVACY.md`. Aucun fichier de vue modifié.

## Points d'intégration

Raccorder `GoalongDeveloperModel` aux vues et au choix de projets dans Réglages, et utiliser
le statut propre de chaque source. T3 reste une piste de métadonnées découverte par
`t3Discovered` : il ne crée aucun faux document conversationnel dans `AgentActivityScanner`.
Pour Git/FSEvents, activer le nouveau consentement et ajouter explicitement les projets ;
les worktrees liés restent un seul projet, avec plusieurs racines d'observation.
La section du bilan exige `GoalongAnalysisSelection.developer == true`.
Les bornes partielles et les tranches FSEvents estimées restent des limites connues ;
ne pas les convertir en couverture complète ou en temps actif.
