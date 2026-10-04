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
