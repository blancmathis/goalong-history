# Concentration + Ralentir — implémentation locale (2026-10-04)

Worktree exclusif : `/Users/mathisblanc/Developer/goalong-concentration-20261004`.
Branche : `feat/concentration-20261004`, base locale de spec `a779c9a`.
Implémentation validée et commise localement. Aucun push, PR, déploiement ou essai de l’app installée.

## Commits locaux

| Commit | Contenu |
| --- | --- |
| `34066e2` | Domaine Concentration, fonctions pures, store protégé et tests |
| `286fda9` | Ralentir : modèle additif, règles, enforcement, compteurs, placeholder et tests |
| `0beb0a2` | Contrôleur/runtime, observation réutilisée, liens Blocage, socket/CLI, reachability, docs CLI et tests |

Ce rapport est livré dans le commit documentaire distinct
`docs(focus): record implementation verification and UI handoff`. Son hash est donné par
`git log -1 --format=%h -- docs/CONCENTRATION-IMPLEMENTATION.md`.

## Fichiers par domaine

| Domaine | Fichiers |
| --- | --- |
| Modèles et validation | `Concentration/ConcentrationModel.swift` : séances/événements/modes, plans, bilans, limites, réglages, erreurs, no-op audio, bornes de texte/date |
| Calculs purs | `Concentration/ConcentrationRules.swift` : phases et skips, détection/hystérésis, union plan/mesure, ratio médian, faits d’intervalle, limites une fois par période |
| Store | `Concentration/ConcentrationStore.swift` : parcours fd sans symlink, répertoires 0700/fichiers 0600, écritures atomiques, transaction plan/bilan multi-jour rejouable, journaux de statut, réglages/rappels/marques |
| Contrôleur et runtime | `Concentration/ConcentrationController.swift`, `Concentration/ConcentrationRuntime.swift` : seul writer, restauration/appClosed, lien Blocage, panneaux fonctionnels, prompts, observation consentie, routes |
| Réutilisation des sources | `ContextMonitor.swift`, `EventTapMonitor.swift`, `GoalongAnalyticsModel.swift` : sink sur les échantillons existants, comptages après les gates de confidentialité, verdict cache ; cache/fold d’Activité partagé, sans agent ni lecture de recap |
| Ralentir | `Blocking/BlockingModel.swift`, `BlockingRules.swift`, `BlockingController.swift`, `BlockingEnforcement.swift`, `BlockingStore.swift` : modèle additif, priorité du blocage, attente/autorisation par hôte ou app, hide/unhide sans lancement/terminaison de l’app ralentie, compteurs et verrous |
| Reachability | `GoalongModules.swift`, `GoalongModulesSettings.swift`, `DashboardModels.swift`, `DashboardRootView.swift` : module éteint par défaut, ligne Modules, suppression explicite des données, entrée après Blocage |
| Placeholders | `Concentration/ConcentrationPlaceholder.swift`, `Blocking/SlowDownPlaceholder.swift`. `GoalongAnalyticsPage.swift` contient seulement l’insertion du placeholder de marques de limites |
| CLI/socket | `LocalHistoryQueryCLI/GoalongFocusCLI.swift`, `GoalongReadOnlyQueryBroker.swift`, `LocalHistoryQueryCLI.swift`, `GoalongCLIContract.swift`, `AppDelegate.swift`, `docs/CLI.md` : toutes les commandes, schemas, effets déclarés, erreurs, watch/reconnexion |
| Inventaire | `SupportSourceAllowlist.swift`, régénéré avec le script existant. Aucun script d’audit affaibli ou modifié |

Les chemins de l’app sont relatifs à `Sources/LocalHistoryApp/`. Aucun fichier `ConcentrationPage*.swift`, `ConcentrationPanelViews.swift`, `BlockingPage*.swift` ou `BlockingShieldViews.swift` créé ou modifié.

## API exacte pour la session de design

Obtenir `ConcentrationRuntime.shared.controller` (optionnel) ; ne pas créer un contrôleur dans la vue.
Le runtime initialise le contrôleur uniquement après activation du module. `ConcentrationController`
est `@MainActor`, `ObservableObject`. Les propriétés suivantes sont `@Published private(set)` :

```swift
currentSession: FocusSession?
phase: FocusPhase?
status: FocusStatus
sessions: [FocusSession]                 // séances dont le début appartient à aujourd’hui
plan: FocusPlan
review: FocusReview?
settings: FocusSettings
itemMeasures: [FocusItemMeasure]
estimateRatio: Double?
sessionFacts: FocusFacts
limitMarks: [FocusLimitMark]
requestedEditor: FocusPanel.Kind?
panel: FocusPanel?
```

`error: String?` est `@Published` modifiable pour afficher un échec d’action UI.
Autres lectures : `hasLockedBlock: Bool`, `blockLists: [BlockList]`,
`sessionStartLimitWarnings: [FocusLimitMark]`, `menuBarText: String`, `hasTimer: Bool`.
`phase` fournit `kind`, `cycle`, `startedAt`, `endsAt`, `isWork` ; utiliser `endsAt` dans un
`TimelineView` de présentation pour le temps restant. Le contrôleur n’ajoute pas d’observateur du
premier plan pour rafraîchir ce texte.

Actions publiques destinées aux vues :

```swift
func startSession(intent: String, mode: FocusMode, planItemId: UUID? = nil,
                  blockListIds: [UUID] = [], blockDuringBreaks: Bool = false,
                  lock: Bool = false, ambiance: Bool = false) throws
func skipPhase() throws
func stopSession(outcome: FocusSession.Outcome? = nil, note: String? = nil) throws
func recordOutcome(sessionID: UUID, outcome: FocusSession.Outcome?, note: String? = nil) throws
func sessions(on day: String) throws -> [FocusSession]
func plan(on day: String) throws -> FocusPlan
func review(on day: String) throws -> FocusReview
func setPlan(_ value: FocusPlan) throws
@discardableResult
func addPlanItem(title: String, day: String, project: String? = nil,
                 estimateMinutes: Int? = nil) throws -> FocusPlanItem
func setItemStatus(_ id: UUID, day: String, status: FocusPlanItem.Status) throws
func movePlanItem(_ id: UUID, day: String, to target: String) throws
func setReview(_ value: FocusReview) throws
func updateSettings(_ value: FocusSettings) throws
func measures(for value: FocusPlan) throws -> [FocusItemMeasure]
func facts(for session: FocusSession) -> FocusFacts
func promptNow()
func promptLater()
func dismissPanel()
func dismissEditor()
func refresh()
```

`FocusSession.Outcome` : `.done`, `.partly`, `.notDone` (JSON `not-done`).
`FocusPlanItem.Status` : `.open`, `.done`, `.dropped`, `.moved` avec `toDay`.
`FocusFailure` : `moduleDisabled`, `invalidArgument`, `locked`, `notFound`, `storageFailed`, `appNotRunning`.
Le contrôleur refuse `stopSession` et `skipPhase` pendant le blocage courant verrouillé ; l’UI doit
utiliser ces actions pour les séances, y compris quand elle offre une action depuis Blocage.

Hooks de présentation raccordés par le runtime : `onPanelChange: ((FocusPanel?) -> Void)?`,
`onPhaseSound: (() -> Void)?`, `onOpenRequested: ((FocusPanel.Kind) -> Void)?`.
Le bouton « Faire maintenant » renseigne `requestedEditor` (`.morning` ou `.evening`), ouvre la page,
puis ferme le panneau. La vue finit par `dismissEditor()`.
Autres hooks/services, conservés par le runtime : `onStatusChange`, `onLimitMark`,
`measurementRefresh`, `observe(_:)`, `noteInput(at:count:)`, `applyMeasurements(_:hasDefinition:)`, `shutdown()`.

`FocusSessionAudio` : `startWork()`, `startBreak()`, `stop()`. Implémentation actuelle :
`NoOpFocusSessionAudio`. L’adapter Ambiance s’injectera dans l’init après son merge.

Pour Ralentir, utiliser `BlockingController.friction: BlockingFrictionPresentation?`,
`frictionUsage: BlockDayUsage?`, `frictionCounts(day:)`, `renounceFriction()`, `continueFriction()`.
Présentation : `listID`, `key`, `name`, `shownAt`, `readyAt`, `occurrence`.
Le contrôleur vérifie l’échéance lui-même : désactiver le bouton ne suffit pas.
`BlockList.action` est optionnel ; afficher `effectiveAction`, `delaySeconds`, `allowanceMinutes`.

## Placeholders à remplacer

- `Sources/LocalHistoryApp/Concentration/ConcentrationPlaceholder.swift` : page fonctionnelle,
  panneau de phase/bilan/rappel/limite et marques dans Activité. Remplacer les vues et le presenter
  `ConcentrationPlaceholderPanel.show(_:controller:)` / `close()` ; adapter les deux points d’entrée
  dans `DashboardRootView.swift` et `ConcentrationRuntime.swift`. La barre de menu reste au design.
- `Sources/LocalHistoryApp/Blocking/SlowDownPlaceholder.swift` : voile/site ou panneau/app, compte à
  rebours et boutons système. Presenter `SlowDownPlaceholderPanel.show(_:presentation:onRenounce:onContinue:)`
  / `close()`. Adapter le nom dans `BlockingEnforcement.swift` si nécessaire.
  `BlockingFrictionPresentation` reste dans `BlockingModel.swift` et doit être préservé.

## Lectures prudentes et écarts explicités

1. **Plan contre mesure** : afficher séparément les minutes de phases de travail liées à l’item et
   les minutes de travail observées sur le projet. La comparaison à l’estimation utilise l’union
   temporelle, pour éviter de compter deux fois une minute commune. La durée d’une séance n’est pas
   une preuve d’attention ou de travail réel. Un intervalle historique absent du cache est indiqué
   indisponible ; il n’est jamais inventé comme zéro.
2. **Détection** : fenêtre complète de 20 min ; inconnus éligibles, hors travail exclu. Hystérésis de
   5 min pour les sorties contextuelles ; absence et arrêt de capture immédiats. Les échantillons
   rapprochés sont regroupés à 0,75 s sans perdre les changements ni le temps d’entrée ; l’évaluation
   est bornée à cette cadence, sans timer. Cela évite une liste de taille non bornée pendant une rafale.
3. **Ralentir/quota** : la phrase « quota left » est appliquée littéralement : friction tant qu’il
   reste du quota (ou sans quota), blocage ferme à épuisement. Un blocage ferme effectif gagne ; une
   pause autorisée permet le passage. Une app d’une liste Ralentir reste masquée, même à quota
   épuisé ; elle n’est jamais terminée par cette liste. Adresse privée/illisible = blocage Standard, jamais permission
   sur un hôte inconnu. Un changement de réglage de friction retire les permissions précédentes.
4. **Verrous et phases** : `Passer` est refusé pendant un blocage de travail verrouillé pour ne pas
   libérer le verrou avant son échéance. Les pauses éventuellement bloquées restent libres : la spec
   verrouille chaque phase de travail. Un saut d’horloge ne coupe pas un verrou prolongé par Blocage.
5. **Sans fin** : Blocage exige une fin ; une séance libre ouverte utilise une lease libre de 60 s,
   renouvelée à 45 s. Aucun verrou infini n’est créé. Les IDs de blocs de phase sont déterministes
   pour restaurer la propriété après relance sans adopter un blocage manuel du membre.
6. **Schémas CLI** : `show` ajoute des faits calculés (`measures`, `estimateRatio` / `facts`) ; `set`
   accepte la même forme mais ignore ces annotations et les recalcule. Les IDs de bilan omis sont
   associés à l’ordre du plan existant, jamais à une tâche inventée. Formats, bornes et erreurs sont
   dans `docs/CLI.md`, `help --json` et `capabilities`.
7. **Stockage borné** : 200 séances/jour, 1 024 événements/séance, 2 MiB/fichier Focus ; catalogue de
   dates limité à 4 096 entrées ; 800 marques de limites et 366 jours d’usage Blocage retenus.
   Dépassement = refus explicite, aucun effacement automatique de séance. Le journal de statut est
   borné à 2 MiB/jour. Le store Blocage refuse désormais une écriture au-delà de sa limite de lecture
   existante de 8 MiB.
8. **Socket** : le socket commun reste disponible quand Temps d’écran est éteint pour répondre aux
   modules indépendants. Chaque route Apple recontrôle son consentement et la pause avant lecture.
   Seuls les nouveaux messages Focus peuvent atteindre 96 KiB d’enveloppe (JSON source ≤ 64 KiB) ;
   les routes historiques gardent 4 KiB. Peers du même UID, au plus 32 clients, délais d’I/O 10 s,
   huit leases watch de 15 s, replay 256 transitions. Un ancien serveur ne peut pas supprimer le
   socket de son remplaçant (identité inode et stop idempotent).
9. **CONTEXTE** : le `CONTEXT.md` partagé a été lu. Il n’est pas modifié : la consigne de ne toucher
   qu’à ce worktree prévaut. Ce rapport contient le passage de relais.

## Vérification

34 tests ajoutés : `ConcentrationRulesTests` (12), `ConcentrationControllerTests` (9),
`BlockingFrictionTests` (6), `GoalongFocusCLITests` (6), `ConcentrationRuntimeCostTests` (1 opt-in).
Ils couvrent les bornes, les phases/skip/cycles/DST, la détection/hystérésis/rafales, plan/mesure et
ratio, limites, modes/atomicité/replay du store, restauration et appClosed, module off sans factory,
blocs travail/pauses, refus app/CLI et saut d’horloge, audio, prompts avec un rappel, toutes les
commandes/erreurs, round trip JSON et watch avec changement/restart réel du socket.

Mesure finale de la règle : `GOALONG_FOCUS_COST=1 swift test --filter ConcentrationRuntimeCostTests`
(exécutée dans la sélection `--filter Concentration`) ; 12 000 échantillons, `getrusage`, cadence
0,75 s, build debug : **0,468329 ms CPU/échantillon = 0,062444 % d’un cœur**. Cible < 0,1 % atteinte.
La mesure concerne la détection, pas AX, une build release ni l’app installée. Aucune nouvelle
observation, permission, sortie réseau ou lancement de processus dans ces modules.

Suite finale du code commité : **1 599 tests, 48 skips, 0 échec**, exit 0, 427,633 s.
Parmi les skips, le test de coût est opt-in et a été exécuté séparément avec succès ; les autres
restent ceux des sources/environnements optionnels de la suite existante. Les deux audits : exit 0.
Logs de preuve : `full-verified.log`, `privacy-verified.log`, `security-verified.log` et
`focused-final.log` dans le répertoire ci-dessous.
Commandes exécutées dans ce worktree : `swift test` (avec `GIT_ALLOW_PROTOCOL=file`, dépendance
résolue depuis les caches locaux), `scripts/audit_privacy_boundaries.sh`,
`scripts/verify_source_security.sh`. Les deux audits passent sans changement de leurs règles.
Les commits sont découpés par dépendances : domaine pur/store, friction Blocage, puis runtime/CLI
et raccordement. L’inventaire de sources est ajusté à chaque étape dans l’index ; les fichiers
de travail et les entrées des checks restent inchangés pendant ce découpage. Ces résultats verts
sont donc réutilisés avant chaque commit ; aucune modification de code ne suit la suite finale.
Le dernier commit ajoute uniquement ce rapport.
Logs locaux ignorés par git : `.build/concentration-logs/`.

## Questions ouvertes / passage de relais

- Brancher l’adapter Ambiance après son merge ; l’option CLI actuelle utilise le no-op et ne joue pas
  de musique. Aucune permission ou dépendance audio ajoutée.
- Design de la page, éditeurs/feuilles, panneaux et barre de menu, puis parcours interactif dans une
  app signée. Les placeholders vérifient la plomberie ; les tests ne prouvent pas l’UX finale ni des
  voiles multi-écran sur la machine du membre.
- Présenter les compteurs Ralentir dans les vues Blocage de design, qui n’ont pas été touchées.
- Rebaser celui qui fusionne après Ambiance : mêmes surfaces `GoalongModules*`, dashboard et Modules.
- Les bornes de rétention et la lecture quota/friction ci-dessus peuvent être ajustées par une
  décision explicite du propriétaire. Elles restent déclarées, sans affaiblir la protection.

## Engagements (2026-10-04)

Plomberie de `docs/CONCENTRATION.md` › Engagements, depuis `3cf203e`, dans le même worktree et
sur `feat/concentration-20261004`. Commits locaux uniquement, aucun push ni opération de PR.
Le `CONTEXT.md` du checkout principal a été lu ; il reste inchangé conformément à la consigne
« Work only there ». Le présent passage de relais contient l'état à reprendre.

### Commits et fichiers

| Commit | Contenu |
| --- | --- |
| `220bed3` | Modèle, règles pures, store, calendrier ISO partagé et tests de règles |
| `0c42fa7` | Origine persistante engagement, deux appels Blocage, refus des autres arrêts et refresh avant désactivation |
| Ce commit de raccordement et de rapport | Contrôleur, mesure/règlement/reprise, cartes/panneau, socket/CLI, contrats, docs CLI et tests |

Le raccordement et ce rapport sont livrés ensemble sous
`feat(focus): wire commitments through controller and CLI`. Son hash, communiqué dans la réponse
finale, se retrouve par `git log -1 --format=%h -- docs/CONCENTRATION-IMPLEMENTATION.md`.

Fichiers de l'app (préfixe `Sources/LocalHistoryApp/`) :

- `Concentration/ConcentrationModel.swift` : `FocusCommitmentPeriod`, `FocusCommitment`, `FocusStake`,
  `FocusCommitmentResult`, `FocusCommitmentProgress`, `FocusCommitmentCard`, `FocusJokerSettings` ;
  réglage additif optionnel `FocusSettings.commitmentJokers` (anciens settings compatibles).
- `Concentration/ConcentrationRules.swift` : `FocusCommitRule.check(old:new:now:calendar:)`,
  `FocusCommitmentRules.progress`, `settle`, `mayCreate`, `series`, `jokerMonth`, `jokersLeft`,
  `stakeEnd`, `stakeWindow` ; limite hebdomadaire ISO.
- `Concentration/ConcentrationStore.swift` : `commitments()` et
  `saveCommitments(_:) -> [FocusCommitment]` sous `Focus/commitments.json`, mêmes accès fd
  sans symlink/hardlink, permissions 0700/0600, écriture atomique et borne de 2 MiB.
  Au plus 800 entrées, retrait des plus anciennes réglées ; trop d'entrées non réglées = refus.
- `Concentration/ConcentrationController.swift` : seul writer, actions communes app/CLI,
  progression, règlement au refresh de mesure, sorties, rejeu entre les deux stores,
  panel commun jour/semaine, refresh aux échéances (pas de nouveau polling).
- `Concentration/ConcentrationRuntime.swift` : chargement des jours nécessaires aux engagements
  non réglés, semaine ISO pour les limites, routes et schemas, garde de consentement lors des
  lectures. Sans historique consenti, le refresh calcule séances/plans et incertitude sans ouvrir
  l'historique. Une erreur de lecture n'est pas remplacée par un succès vide.
- `Blocking/BlockingModel.swift`, `BlockingRules.swift`, `BlockingController.swift` : origine
  `.commitment(UUID)` persistante, ID de bloc = ID d'engagement, verrou obligatoire ; arrêts,
  suppression/réduction de liste et module off refusés selon les protections existantes.
- `Concentration/ConcentrationPanelViews.swift` : seuls ajouts de compilation : case commitment
  dans la largeur et `Text(content.text) // TODO(design)`. `ConcentrationPage.swift` inchangé.

CLI : `Sources/LocalHistoryQueryCLI/GoalongFocusCalendar.swift` (unique helper ISO),
`GoalongCommitmentCLI.swift` (validation partagée), `GoalongFocusCLI.swift`,
`GoalongCLIContract.swift`, `LocalHistoryQueryCLI.swift`, `docs/CLI.md`.
Le broker existant transporte ces routes Focus sans nouvelle voie d'accès ni writer.
`help --json` et `capabilities` exposent les commandes et l'effet explicite sur Blocage.
Le générateur de l'allowlist a été exécuté ; son résultat est inchangé (aucun nouveau fichier app).

### API exacte pour le design

Continuer à obtenir `ConcentrationRuntime.shared.controller`, optionnel ; ne pas créer de store
ni de contrôleur dans les vues. Nouvelles propriétés `@Published private(set)` :

```swift
commitments: [FocusCommitment]             // historique retenu, pas seulement aujourd'hui
commitmentCards: [FocusCommitmentCard]     // annotations calculées et faits réglés figés
commitmentSeries: FocusJokerSettings       // .day / .week = longueurs de série
commitmentJokersLeft: FocusJokerSettings   // .day / .week = réserves du mois courant
```

Lectures : `todayCommitment: FocusCommitmentCard?`, `weekCommitment: FocusCommitmentCard?`,
`hasLockedBlock: Bool` (phase OU enjeu, pour module off/suppression),
`hasLockedSessionBlock: Bool` (phase seulement, pour stop/skip d'une séance).
Le design devra utiliser cette dernière pour les boutons de séance : un enjeu indépendant
n'empêche pas d'arrêter une séance libre. La page existante n'est pas modifiée dans ce lot.

```swift
@discardableResult
func setCommitment(period: FocusCommitmentPeriod, kind: FocusCommitment.Kind, target: Int,
                   task: String? = nil, stake: FocusStake? = nil) throws -> FocusCommitment
func deleteCommitment(period: FocusCommitmentPeriod) throws
func useCommitmentJoker(period: FocusCommitmentPeriod) throws
func declareCommitmentHeld(period: FocusCommitmentPeriod) throws
func commitmentProgress(_ value: FocusCommitment) throws -> FocusCommitmentProgress
func commitCheck(_ value: FocusCommitment, replacing old: FocusCommitment) -> FocusCommitRule.Check
```

`FocusCommitmentPeriod(kind: .day, key: "YYYY-MM-DD")` ou
`FocusCommitmentPeriod(kind: .week, key: "YYYY-Www")` ; `.interval(calendar:)` donne les bornes.
`FocusStake(listIds: [UUID], until: "12:00")` ; `.minute` / `.valid` vérifient l'heure et les listes.
`FocusCommitRule.Check` : `.free`, `.harderOnly`, `.locked(String)` ; suppression : appeler la
fonction pure avec `new: nil` ou lire `card.editMode`.

Une carte fournit `commitment`, `progress` (`measured`, `unmeasuredMinutes`, `usesActiveTime`),
`series`, `jokersLeft`, `canUseJoker`, `canDeclare`, `exitUntil`, `limitHours`,
`editMode` (`free` / `harderOnly` / `locked`), `editUntil`. Les durées sont des minutes, les autres
cibles des comptes. `limitHours` est une annotation neutre, jamais un refus. Les dates d'échéance
sont présentables via TimelineView ; le contrôleur réveille aussi l'état aux échéances, sans timer
rapide. Les actions revalident l'échéance et les réserves, quels que soient les boutons affichés.
Les cartes absentes sont `nil` ; pour demain ou la prochaine semaine, filtrer `commitmentCards`
ou construire la période puis appeler `setCommitment`.

Les réglages se sauvegardent par l'action existante `updateSettings(_:)` :

```swift
var value = controller.settings
value.commitmentJokers = FocusJokerSettings(day: 2, week: 1)
try controller.updateSettings(value)
```

Bornes 0…5 / 0…2. `settings.jokerSettings` fournit les défauts quand la clé optionnelle est absente.

`FocusPanel.Kind.commitment` et `panel.commitmentIDs: [UUID]` identifient tous les résultats du
même refresh. Lire leurs cartes, présenter les faits, l'enjeu et les sorties, puis les actions
ci-dessus. Le panneau utilise les hooks existants, une fois par résultat ; `dismissPanel()`
continue à fermer le panneau. Pas de panneau pendant la période.

Blocage : `startCommitmentBlock(id:listIDs:until:) throws`,
`endCommitmentBlock(id:) throws` (ID = engagement). Seules la résolution joker/déclaration et son
rejeu utilisent la seconde. Elle refuse un bloc manuel ou de programme, même si son ID est fourni.
Les autres arrêts continuent à refuser le verrou ; l'heure protégée de Blocage détermine la fin
réelle d'une fenêtre de sortie.

### Lectures retenues et extensions

- Le mois du joker est celui du dernier jour civil de la période (dimanche pour la semaine),
  pas celui du minuit exclusif suivant ni du règlement. Réserves jour/semaine séparées, calculées
  depuis les résultats ; un engagement absent ne casse ni n'ajoute à la série.
- Un enjeu sauté (`late`, `noList`, `blockingOff`) a la même fenêtre de sortie qu'un résultat sans
  enjeu appliqué : fin du jour de règlement. Pour un enjeu appliqué, c'est la fin réelle du bloc,
  incluant les prolongations anti-saut d'horloge. À l'échéance exacte, les sorties sont fermées.
- Priorité des raisons sautées : late, puis blockingOff, puis noList. Une suppression partielle
  conserve les listes restantes. Actions, quotas et pauses des listes suivent Blocage existant.
- `work` sans définition compte le temps actif ; `task` suit uniquement les segments work avec
  le même matching de nom que le projet du plan. Unclassifié, dissimulé, jours/gaps absents
  restent de l'incertitude. La nuit non observée appartient aussi à cette durée, selon la spec.
  Une séance compte ses phases de travail dans la période, indépendamment de l'outcome.
- Le résultat fige les faits au premier refresh après la fin. Un statut plan renseigné plus tard
  peut passer par déclaration ; il ne réécrit pas la mesure réglée. Joker ne transforme pas missed
  en held ; il préserve la série et affiche `jokerAt`. Déclaration marque held/declared sans joker.
- Extensions additives pour une reprise honnête : `result.usesActiveTime` fige la provenance de
  mesure ; `result.stake.at` sur applied acquitte l'écriture Blocage (nil = intention à rejouer).
  Règlement et annulation sont persistés avant leurs effets Blocage. Une intention non acquittée
  devenue impossible au redémarrage est enregistrée skipped avec sa raison, sans revendiquer une application qui n’a pas eu lieu.
  Une annulation persistée libère son bloc au redémarrage sans consommer une seconde réserve.
- Les séries et réserves historiques portent sur les 800 entrées retenues. `commitments` filtre
  les périodes qui intersectent la plage inclusive de jours, mais garde les totaux globaux.
  File input accepte le show à un sélecteur ; les annotations et métadonnées serveur sont ignorées,
  jamais utilisées pour effacer une fenêtre ou fabriquer un résultat.
- Les anciennes marques hebdomadaires sont converties en clé ISO depuis leur date pour garder
  la règle « une fois par semaine » après passage au helper lundi.

### Vérification et suite complète

26 tests ajoutés : `ConcentrationCommitmentRulesTests` (11),
`ConcentrationCommitmentControllerTests` (10), `GoalongCommitmentCLITests` (5).
Sélection Commitment : 29 tests (dont 3 existants), 0 échec.
Couvre les 4 mesures et clipping, bornes, DST, ISO en-US et année ISO, commit/free/harder/locked,
règlement held/missed et toutes les raisons, séries/jokers mensuels séparés, store 0600/atomicité/
rétention/no-follow, restauration entre stores et intention interrompue, déclaration, réserve zéro,
verrou de tous les arrêts ordinaires et modules, horloge, sorties indépendantes, JSON round trip,
métadonnées forgées, routes off, chaque syntaxe CLI et socket réel, help/capabilities.

Suite finale : **1 626 tests, 46 skips, 0 échec**, exit 0, 677,228 s.
Les cinq checks ont été exécutés avant chacun des trois commits locaux, avec les mêmes sources
complètes dans le worktree pendant le découpage de l'index. Les trois suites :

| Passage | Suite complète | Build / privacy / security / allowlist |
| --- | --- | --- |
| Avant domaine (`*-final.log`) | 1 626 / 46 skips / 0 échec, 368,371 s | tous exit 0 |
| Avant Blocage (`*-c2.log`) | 1 626 / 46 skips / 0 échec, 601,916 s | tous exit 0 |
| Avant raccordement (`*-c3.log`) | 1 626 / 46 skips / 0 échec, 677,228 s | tous exit 0 |

Commandes : `swift build`, `swift test` sans filtre, `scripts/audit_privacy_boundaries.sh`,
`scripts/verify_source_security.sh`, `python3 scripts/generate_support_source_allowlist.py --check`.
Chaque suite utilise un HOME neuf isolé (HOME et CFFIXED_USER_HOME, GIT_ALLOW_PROTOCOL=file).
Le binaire `.build/debug/goalong` a aussi été exécuté : `help --json` et `capabilities` contiennent
les deux commandes (exit 0) ; `commitment show` contre un socket absent renvoie JSON
`appNotRunning` sur stderr, exit 1. Pas de changement de code après ces checks.

Logs complets locaux ignorés : `.build/engagement-logs/` (`build-final.log`, `full-final.log`,
`privacy-final.log`, `security-final.log`, `allowlist-final.log`, `focused-05.log`). HOME de la suite
isolé avec HOME/CFFIXED_USER_HOME ; toutes les racines de fixtures Focus sont sous `/private/tmp`.
Pas de script d'audit modifié, pas de nouvelle observation/permission/réseau/processus dans la
plomberie. L'inventaire reste inchangé et --check passe.

### Questions ouvertes / passage de relais

Aucune question bloquante de plomberie. Le design doit remplacer le Text TODO, dessiner les
cartes/éditeurs/panneaux et relier les actions ci-dessus (dont le verrou propre aux séances).
Aucun parcours de l'app installée ni validation visuelle des Engagements n'est revendiqué ici.
