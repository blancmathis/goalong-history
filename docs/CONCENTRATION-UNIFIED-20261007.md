# Concentration unifiée (2026-10-07)

Demande du propriétaire : rendre plus clair le lien Blocage ↔ Concentration (« dans Concentration on
peut utiliser les listes de blocage mais on ne sait pas comment en ajouter si on ne connaît pas
Blocage ») et intégrer la surveillance temps réel (Jev).

## Décisions (propriétaire, 2026-10-07)
1. **Une seule entrée « Concentration »** dans la barre latérale, 4 onglets, une question par onglet :
   - **Maintenant** : séance (plan, minuteur, bilan), engagements, limites.
   - **Distractions** : les listes (sites/apps), seule source ; + les exemples en mots pour Jev
     (champ « Ce que je considère comme de la procrastination », déplacé ici).
   - **Programme** : plages horaires, blocages programmés, verrous, mot de passe (ex-page Blocage).
   - **Surveillance** : Jev (clé, activation, pause, rappels et effets, repères productifs).
   Les entrées `.blocking` et `.monitoring` quittent la barre latérale ; les liens/menus existants
   (menu Surveillance, CLI, notifications) ouvrent l'onglet correspondant.
   Modules : Blocage et Concentration restent des modules distincts (activation, coût zéro éteint).
   Un onglet dont le module est éteint montre une seule phrase + bouton « Activer ».
2. **« Nouvelle liste… » partout** où une liste se choisit (séance, enjeu d'engagement, plage,
   blocage programmé) : crée la liste sur place (feuille), puis la sélectionne.
3. **Jev « seulement pendant mes séances »** : réglage `scope` = `always` (défaut, comportement
   actuel) | `sessionsOnly`. En `sessionsOnly`, aucun appel, rappel ni effet hors séance
   Concentration active ; état affiché « En attente d'une séance ». Changer de scope ne donne aucun
   consentement, ne réactive rien ; fin de séance = mêmes nettoyages qu'une pause (effets retirés,
   série remise à zéro, aucun arriéré).
4. **Suggestions pour les listes** : pendant une séance, chaque fenêtre Jev `procrastination`
   confirmée compte 15 s pour son site (domaine enregistrable, ex. `youtube.com`) ou son app (bundle
   ID). Au bilan : jusqu'à 3 suggestions « Ajouter youtube.com à <liste> ? » pour ce qui n'est dans
   aucune liste, triées par durée, seuil ≥ 2 min. Le membre valide une par une ou ignore ; rien n'est
   ajouté sans clic (règle 2026-10-04 : l'agent ne choisit jamais les listes). « Ignorer toujours »
   mémorise le domaine. Données locales seulement, dans le fichier de la séance ; jamais envoyées au
   site ; jamais en navigation privée ni contexte exclu.

Refusé pour l'instant : bloquer automatiquement ce que Jev détecte ; bilan mesuré par Jev.

## Répartition
- Cœur (Codex) : `scope` Jev + persistance/migration, gating par séance active, comptage des
  distractions par séance, API des suggestions (lister, accepter → ajout à une liste via le contrôleur
  Blocage en respectant `editCheck`/verrous, ignorer, ignorer toujours), tests.
- Interface (Claude) : onglets, déplacement des pages, « Nouvelle liste… », affichage des
  suggestions au bilan, réglage scope.

## API pour l'UI
Cœur implémenté dans cette branche ; vues à raccorder par Claude. Toutes les API suivantes sont
sur le `MainActor`. Aucun ajout à une liste n'est déclenché par l'enregistrement des observations.

### Scope Jev

- Observer `JevMonitor.shared` (`ObservableObject`). `@Published private(set) var scope:
  JevMonitoringScope`, enum `String, Codable, CaseIterable` : `.always`, `.sessionsOnly`.
  Écrire avec `setScope(_ value: JevMonitoringScope)` ; ne pas appeler `setEnabled` pour changer le
  périmètre. Ce choix ne donne aucun consentement et ne réactive ni Jev ni l'historique.
- `status: String` est déjà publié. Jev activé et scope `.sessionsOnly` hors séance :
  `« En attente d’une séance »`. Jev éteint : `« Surveillance désactivée »`. Une pause explicite reste
  prioritaire ; connexion, confidentialité, exclusions et autres prérequis restent nécessaires.
- `JevMonitoringPreferences.shared` persiste le choix dans UserDefaults,
  `storageKey = "goalong.jev.scope.v1"`, JSON `{schema: 1, scope: "always"|"sessionsOnly"}`.
  Absence = `.always` sans écriture sur lecture ; valeur illisible/version inconnue = suspension
  jusqu'à un `setScope` explicite (`error: String?`).
- La séance active vient de `ConcentrationRuntime.shared.controller?.jevSessionID: UUID?`.
  Les pauses Pomodoro font partie de la séance ; le focus détecté hors séance n'en est pas une.
  Début/fin/restauration/désactivation du module notifient `.goalongFocusSessionDidChange` ; le
  moniteur annule immédiatement la requête, vide le tampon et retire rappels/effets. Chaque retour
  réseau revalide aussi l'identité de séance et la génération de confidentialité. Aucun rattrapage.

### Suggestions au bilan

Utiliser le `ConcentrationController` déjà exposé par `ConcentrationRuntime.shared.controller`.

| API exacte | Résultat / usage |
| --- | --- |
| `distractionSuggestions(sessionID: UUID) throws -> [FocusDistractionSuggestion]` | Seulement une séance terminée. 0…3 cartes, triées par secondes confirmées décroissantes, puis `id` croissant en cas d'égalité. |
| `acceptDistractionSuggestion(sessionID: UUID, targetID: String, listID: UUID) throws` | Un clic explicite et une liste choisie ; appelle `BlockingController.addDistraction(_:to:)`, qui réutilise `editCheck` et `save`. |
| `ignoreDistractionSuggestion(sessionID: UUID, targetID: String, always: Bool = false) throws` | Ignore cette carte ; `always: true` mémorise la cible pour les futures séances et les autres bilans. |

`FocusDistractionSuggestion: Equatable, Identifiable` contient :

- `id: String` (= `target.id`, `"site:<domaine>"` ou `"app:<bundleID>"`) ; passer cet id à `targetID`.
- `target: JevDistractionTarget` (`LocalHistoryCore`, `Codable, Equatable, Hashable, Sendable,
  Identifiable`) : `kind: JevDistractionTarget.Kind` (`.site` / `.app`), `value: String` (domaine
  enregistrable ASCII/Punycode ou bundle ID exact), `name: String` (domaine ou nom de l'app).
- `confirmedSeconds: Int`, multiple de 15, ≥ 120. C'est un total de fenêtres contenant une
  distraction, pas une mesure de toutes les secondes hors travail ; ne pas l'ajouter aux faits du bilan.

Au clic Accepter, proposer les `controller.blockLists.filter { $0.mode == .block }` et laisser le
membre choisir `listID`. Les actions `.block` et `.slowDown` sont compatibles. Une liste
`.allowOnly` est refusée : y ajouter une cible lui donnerait accès. Une liste verrouillée peut
recevoir une restriction supplémentaire uniquement si `editCheck` l'autorise ; aucun verrou,
programme, quota, pause ni action ne change.

Erreurs : `FocusFailure.notFound` (séance absente/en cours, carte déjà traitée ou devenue
inéligible), `.moduleDisabled` (Blocage éteint à l'acceptation), `.storageFailed`, `.invalidArgument`
(borne des préférences). Les refus Blocage sont des `BlockingListAdditionFailure` (`Error,
LocalizedError, Equatable`) : `.notFound`, `.invalidTarget`, `.notBlockList`, `.storageFailed`,
`.refused(String)`. Afficher leur `localizedDescription` ; ne pas masquer un échec. Si l'écriture de
la séance échoue après celle de Blocage, l'ajout validé reste enregistré dans Blocage ; la carte
est alors filtrée par son appartenance à une liste, sans annoncer un bilan sauvegardé.

Après chaque action, relire `distractionSuggestions(sessionID:)`. `sessions: [FocusSession]`
est publié et mis à jour pour la journée affichée. La sélection est figée à la fin : traiter une
carte ne fait jamais apparaître un quatrième candidat. Les cibles déjà présentes dans une liste
(quel que soit son mode/action, y compris une règle site avec chemin) ou ignorées toujours sont
filtrées à nouveau lors de la lecture.

### Persistance et comptage

`FocusSession.distractions: FocusDistractionRecord?` est absent dans les anciens fichiers, sans
réécriture ni compte rétroactif. Le champ reste dans `Focus/sessions/YYYY-MM-DD.json` (0600).
`FocusDistractionRecord` contient `schema: Int = 1`, `counts: [FocusDistractionCount]` (≤ 200),
`lastWindowEnd: Date?` et `suggestedTargetIDs: [String]?` (nil pendant la séance, sélection de
0…3 ids à sa fin). `FocusDistractionCount` expose `target`, `confirmedSeconds`,
`state: FocusDistractionCount.State` (`.pending`, `.accepted`, `.ignored`) et
`acceptedListID: UUID?` (uniquement `.accepted`). Le choix « toujours » est dans
`FocusSettings.ignoredDistractionTargets: [JevDistractionTarget]?` (≤ 2 000, nil pour les anciens
réglages), sous `Focus/settings.json`, effacé avec les données du module.

Hook réservé au moniteur :
`recordJevDistraction(window: JevWindow, verdict: JevVerdict, sessionID: UUID) throws`.
Chaque fenêtre fraîche confirmée `.procrastination`, de 15 s, entièrement dans la même séance,
compte une seule fois. Les générations privées/exclues et résultats annulés/tardifs sont rejetés
avant le hook. Les identités locales `JevSample.distractionTarget: JevDistractionTarget?` ne sont
jamais sérialisées dans `JevPayload` ; ce contrat réseau reste identique.

**Attribution conservatrice** : Jev classe la fenêtre entière, pas chaque ligne. Une fenêtre avec
plusieurs cibles distinctes ou une cible manquante n'alimente pas les suggestions. Elle conserve
le comportement de rappel existant. Les sous-domaines d'un même domaine enregistrable comptent
ensemble ; une copie locale de la [Public Suffix List](https://publicsuffix.org/list/), y compris
ses suffixes privés, évite de suggérer `co.uk` ou de fusionner tous les membres de `github.io`.
Aucune actualisation réseau de cette liste au runtime.

Vérification : tests `JevDistractionTargetTests`, `JevMonitoringScopeTests`,
`ConcentrationDistractionTests`, suite complète `swift test`, puis
`./scripts/verify_source_security.sh`. Aucun lancement de l'app construite.

