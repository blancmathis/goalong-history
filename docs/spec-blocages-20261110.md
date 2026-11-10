# Spec — une page « Blocages », plus de page « Mon travail » (2026-11-10)

Demande du propriétaire (2026-11-10) : une interface plus propre, avec moins de pages.
- A. Une page « Blocages » remplace Concentration, Garde-fous et Jev. Une règle = un déclencheur, une exécution, une sécurité. Une liste de règles, un seul éditeur.
- B. La page « Mon travail » disparaît. Son contenu va dans des pages qui existent. Rien d'utile ne se perd.

Base : `origin/main` = `3a114d2e`. Branche : `feat/blocages-page-unique-20261110`.

## 1. Avant / après

```
AVANT (barre latérale)            APRÈS
  Activité                          Activité
  Mon travail            ──B──►     (Réglages › Définition du travail)
  Historique                        Historique
  Concentration  ┐                  Blocages
   ├ Maintenant  │
   └ Distractions├──A──►
  Garde-fous     │
   ├ Blocages    │
   └ Écran rouge │
  [Ambiance]     │                  [Ambiance]
  Réglages       │                  Réglages
   └ Jev ────────┘                   └ Définition du travail (à la place de Jev)
```

6 entrées fixes deviennent 4. 4 onglets et 1 panneau disparaissent. 5 éditeurs (blocage immédiat, grille de la semaine, plage rouge, séance, paliers Jev) deviennent 1.

## 2. Modèle de règle

```
Règle = QUAND            +  QUOI                         +  SÉCURITÉ
        Maintenant          Bloquer des listes              Libre
        Horaire             (apps, sites, mots)             Difficile (texte à taper)
        Jev                 Écran rouge à x %               Mot de passe
                            Luminosité bloquée à x %        Verrouillé
                            Tout le Mac (Maintenant seul)
```

```swift
struct BlockRule: Identifiable, Hashable {
    enum Trigger: Hashable {
        case once(start: Date, end: Date)                          // « Maintenant » : en cours, ou prévu une fois
        case schedule(weekdays: Set<Int>, start: Int, end: Int)    // jours ISO, minutes
        case jev                                                   // une seule règle Jev
    }
    struct ListPart: Hashable {    // l'état reste liste par liste
        var id: UUID
        var allowOnly: Bool        // liste « autoriser seulement » : le texte dit « Autorise seulement … »
        var state: State           // en cours, arrêtée pour aujourd'hui (`programSkips`), tenue (`heldPrograms`)
    }
    var id: String                 // dérivé du contenu des moteurs (voir 2.1)
    var trigger: Trigger           // fixé à la création : on ne change pas le déclencheur d'une règle
    var lists: [ListPart]
    var redScreen: Double?         // intensité 0…1
    var brightness: Double?        // plafond de luminosité 0…1
    var lock: BlockLock            // verrou stocké (.free, .typing, .password, .locked)
    var effectiveLock: BlockLock   // verrou appliqué, pour l'affichage seulement
    var paused: Bool               // vrai pour une règle « écran rouge seul » désactivée
    var state: State               // .running(until:), .next(Date), .paused, .idle
    var sources: Sources           // identifiants des plages et sessions des moteurs
}
```

### 2.1 Une règle est une vue sur les moteurs, pas un nouveau stockage

Choix : `BlockRule` n'est jamais écrit sur disque. Il est calculé depuis l'état des moteurs existants. Raisons :
- Aucun fichier ne change de format. Un blocage actif ou une plage armée survit donc par construction : rien n'est migré.
- La page ne peut pas afficher une règle que les moteurs n'appliquent pas.
- Une version plus ancienne relit les mêmes fichiers.
- Les sécurités restent celles des moteurs. La page n'ajoute aucun chemin.

| Déclencheur | Source lue | Écriture (API existante) |
|---|---|---|
| Horaire, listes | `BlockList.program.ranges` | `BlockingController.editCheck` puis `saveAll` |
| Horaire, écran rouge et luminosité | `RedScreenProgram.program.ranges`, `intensities`, `brightness`, `disabled` | `BraiseController.refusal(for:)`, `saveRanges` (voir 2.3), `deleteRange`, `setRangeEnabled` |
| Maintenant, listes | `activeBlocks` (origine `manual`, `focus`, `commitment`, `trigger`), `freeze`, `scheduledBlocks` | `start(listIDs:until:lock:)`, `schedule(...)` (début plus tard), `startFreeze` (modes et apps permises), `stop(id:typed:password:)`, `cancelScheduled` |
| Maintenant, séance | `ConcentrationController.currentSession` | `startSession(...)`, `stopSession(...)` |
| Maintenant, écran rouge | `BraiseController.windows`, `active`, `ranges.holds` | `setManual` (Libre) ; fenêtre ponctuelle protégée (voir 2.3) ; `stopActiveRanges` |
| Maintenant, luminosité | `ranges.brightnessLock` | `setBrightnessLock(BrightnessLockState(level:lock:end:))`, `stopBrightnessLock` |
| Jev | consentement `.jevMonitoring`, `JevMonitoringScope`, `JevInterventionSettings`, `JevWorkContext` | `JevMonitor.setEnabled`, `setScope`, `JevInterventionPreferences.update` |

Regroupement des plages en règles « Horaire » : même clé = une règle. C'est l'idée du propriétaire : des ajouts sur une même chose.
- Clé de base : (jours, début, fin, verrou **stocké**). Le verrou effectif change avec le mot de passe et avec `lockedUntil` ; il ne sert qu'à l'affichage. La clé et l'écriture utilisent le verrou stocké : une réécriture ne transforme jamais « Mot de passe » en « Verrouillé ».
- Les plages de listes de même clé de base forment une règle (plusieurs listes).
- Une plage rouge porte en plus (intensité, luminosité, active ou non). Elle rejoint la règle des listes de même clé de base seulement si elle est active et seule à avoir cette clé. Sinon elle forme sa propre règle « écran rouge ». Deux plages rouges aux mêmes heures et aux réglages différents restent donc deux règles.
- `disabled` n'existe que pour l'écran rouge. Le bouton « Mettre en pause » n'existe donc que pour une règle « écran rouge seul ». Une règle avec des listes n'a pas de pause.
- `programSkips` et `heldPrograms` s'appliquent liste par liste : l'état de la règle reste liste par liste (`ListPart.state`). La ligne dit par exemple « Jeux : arrêtée jusqu'à demain ».
- Une liste en mode « autoriser seulement » ne bloque pas ses éléments : le texte dit « Autorise seulement … ».
- `id` = la clé, en texte. Il est stable tant que la règle ne change pas.
- Chaque moteur garde ses propres identifiants de plage. `programSkips`, `heldPrograms`, `holds` et `skips` restent attachés.
- Modifier les heures ou les jours d'une règle modifie les plages en place (mêmes identifiants). Rien n'est supprimé puis recréé. Le déclencheur d'une règle existante ne se change pas : pour passer d'« Horaire » à « Maintenant », on crée une autre règle.
- Deux règles créées avec la même clé s'affichent comme une seule. L'effet réel est le même.

### 2.2 Ce qui reste une propriété de liste, pas de règle

Une liste dit **quoi** (sites, apps, mots, exceptions) et ses tolérances : quota par jour, pauses, « gagner du temps », déclencheur par app ouverte, mode « autoriser seulement », verrou du programme (`lockedUntil`). Ces réglages restent dans l'éditeur de liste, sans changement. Une règle qui contient une liste au programme verrouillé affiche « Verrouillé jusqu'au … » ; `editCheck` refuse déjà de l'affaiblir.

### 2.3 Extensions des moteurs (petites, additives)

1. **Écran rouge ponctuel protégé.** Aujourd'hui l'écran rouge manuel est toujours libre. Pour « Maintenant + écran rouge + sécurité », `BraiseController` gagne `holdNow(intensity:brightness:until:lock:)`. Il écrit un `RedScreenProgram.Hold` avec un identifiant neuf. Format de `ranges.json` inchangé.
   - Un `hold` dont l'identifiant n'est dans aucune `program.ranges` compte même si « Suivre mes horaires » est décoché, dans `RedScreenRules.activeWindows` et dans `nextBoundary`. `holdNow` ne coche jamais ce réglage : il n'allume pas les plages que le membre ne suivait pas. Un test par fonction.
   - `holdNow` écrit `deadline` et `boot` dès la création. Sinon un saut d'horloge avant la première évaluation effacerait le `hold`.
   - `RedScreenRules.weakening` ne compare ni `holds` ni `skips`. Toute écriture de plages part donc de l'état vivant et garde ses `holds` et `skips` ; aucune API de la page n'écrit le programme entier.
   - Garde, `GoalongProtection`, curseur, pause, ⌃⌥⌘R, arrêt (`stopActiveRanges`), panne et redémarrage suivent déjà le chemin des plages (revue du 2026-11-10). Tests : Quitter refusé, baisse refusée, fin à l'heure, couleurs rendues après panne, survie à un redémarrage et à un saut d'horloge.
   - Retour à une version plus ancienne : elle ignore un `hold` sans plage quand « Suivre mes horaires » est décoché. La fenêtre ponctuelle protégée serait alors perdue. Sparkle ne rétrograde jamais : noté, pas codé.
   - `holdRefusal` (contrôle sans écriture) couvre tous les refus de `holdNow`, y compris la limite de 8 fenêtres et un rouge sous 5 % sans luminosité. « Maintenant » ne lance donc pas un blocage que son écran rouge refuserait.
   - Supprimer une plage efface aussi son `hold` et son `skip` : un `hold` orphelin serait lu comme une fenêtre ponctuelle.
   - Repli si un de ces tests ne passe pas : « Maintenant » propose l'écran rouge en « Libre » seulement, et la page le dit.
2. **Écriture de plusieurs plages rouges en une fois.** `BraiseController` gagne `saveRanges([…])` : une validation (`refusal(for:)`), une écriture. `saveRange` l'appelle avec une plage. Il renvoie une erreur si l'écran rouge ne tourne pas : aujourd'hui `commitRanges` ne fait rien et ne dit rien dans ce cas.
3. **Jev lance un blocage** (PR 3, séparée, **seulement après accord écrit du propriétaire transmis par l'orchestrateur**). Le refus du 2026-10-07 (« bloquer automatiquement ce que Jev détecte ») peut se lire de deux façons : l'agent ne choisit pas *quoi* bloquer, ou l'agent ne choisit pas non plus *quand*. L'idée du 2026-11-10 (Jev comme déclencheur d'un blocage de listes choisies) va dans le premier sens, mais le refus est écrit : je ne tranche pas seul. Sans accord, la règle Jev garde ses effets actuels (rappel, voile sombre, voile rouge) et la PR 3 n'existe pas.
   Si l'accord arrive : quand la série hors travail atteint le délai choisi, `JevMonitor` lance un blocage des listes choisies par le membre, pour la durée choisie (5 à 60 min), en sécurité **Libre** seulement. L'identifiant de la session est dérivé de la série (comme `startFocusBlock`) : une seule session par série, même après une relance. Origine `manual` : aucun nouveau cas dans `blocking.json`. Le texte d'accord de Jev décrit cet effet avant qu'il soit actif (nouvelle version du texte).
   - Les paliers actuels restent tels quels. Ce sont des voiles, pas le filtre gamma : la page les nomme « voile ».

Hors périmètre (noté, pas fait) : 4 niveaux de sécurité pour une séance (le moteur n'en a que 2 : libre ou verrouillée) ; plusieurs règles Jev ; règles « Maintenant » enregistrées comme raccourcis.

## 3. Migration sans perte

Aucune donnée n'est réécrite. Le tableau dit où chaque chose se voit après la mise à jour.

| Existant | Après |
|---|---|
| Blocage en cours (toute origine), gel « Tout le Mac » | « En cours », même fin, même sécurité, même arrêt |
| Blocage planifié une fois (`scheduledBlocks`) | « En cours », ligne « Aujourd'hui, de 14 h à 16 h », annulable comme avant |
| Créer un blocage ponctuel futur | éditeur, « Maintenant » : « Début » = maintenant ou une heure plus tard (`schedule(...)`) |
| Gel « Tout le Mac » : modes et apps permises | éditeur, « Quoi » : « Tout le Mac » ouvre le choix du mode et des apps permises (mêmes contrôles) |
| Séance : « bloquer aussi pendant les pauses » | éditeur, option de la séance Pomodoro |
| Blocage d'une séance (session d'origine `focus`) | replié sous la ligne de la séance dans « En cours » ; il s'arrête avec la séance (`stopSession`), jamais seul |
| Écran rouge : ouverture de session, raccourci d'urgence ⌃⌥⌘R, texte de confidentialité et de panne | section « Protection », bloc « Écran rouge » |
| Écran rouge : « n'a pas pu démarrer », avis de récupération des couleurs | bandeau en haut de la page (même vue, `BraiseUnavailableView` et l'avis existant) |
| Plage de la semaine d'une liste | règle « Horaire » |
| Plages de listes aux mêmes heures et même sécurité | une seule règle, plusieurs listes |
| Plage rouge protégée (intensité, luminosité) | règle « Horaire », exécution écran rouge / luminosité |
| Plage rouge désactivée (`disabled`) | règle « écran rouge seul » affichée « En pause », bouton « Réactiver » |
| Deux plages rouges aux mêmes heures, réglages différents | deux règles |
| Plage d'une liste « autoriser seulement » | règle « Horaire » ; le texte dit « Autorise seulement … » |
| Plage de liste arrêtée pour aujourd'hui (`programSkips`) ou tenue (`heldPrograms`) | inchangé ; l'état s'affiche pour cette liste, pas pour toute la règle |
| Plage rouge tenue (`holds`) ou arrêtée pour aujourd'hui (`skips`) | inchangé ; la ligne dit « Arrêtée jusqu'à demain » |
| Écran rouge manuel, « suivre les plages » | « En cours » (interrupteur et curseur), menu de la barre des menus inchangé |
| Verrou de luminosité manuel | « En cours » |
| Séance en cours, Pomodoro | « En cours », avec sa phase et son minuteur |
| Plan du jour, séances passées, bilan du soir, limites, engagements | section « Séances » de la page (dépliants), mêmes vues |
| Listes, mots de distraction, suggestions de Jev | section « Listes » |
| Mot de passe de blocage, navigateurs, état du garde | section « Protection » |
| Jev activé, portée, paliers, pause | règle « Jev » ; pause = bouton de la ligne |
| Jev : ce qui est envoyé, dernières vérifications | dépliants dans l'éditeur de la règle Jev |
| Modules Blocage / Concentration désactivés | la page reste ; les exécutions et sections du module sont absentes, avec un lien vers Réglages › Modules |

Navigation :
- Les cas `.concentration`, `.distractions`, `.braise`, `.monitoring` restent dans `DashboardSection` (liens, CLI, menu, tests). Ils ouvrent la page « Blocages ». `.monitoring` ouvre en plus l'éditeur de la règle Jev.
- `.work` reste aussi. Il ouvre Réglages › Définition du travail.
- Barre des menus : « Plages… » ouvre « Blocages ». `BlockingRuntime.onOpen`, `ConcentrationRuntime.onOpen`, `BraiseRuntime.onOpen` aussi.
- La CLI (`goalong focus`, `session`, `braise`, `block-lists`…) ne change pas.

Tests de migration (fichiers d'exemple au format actuel) :
- ouvrir la page n'écrit rien : `blocking.json` et `Braise/ranges.json` identiques à l'octet ;
- un blocage actif « Verrouillé », une plage armée et un `hold` donnent la même `GoalongProtection.until` et la même règle « Quitter » avant et après ;
- chaque plage existante apparaît dans exactement une règle ; aucune plage n'est orpheline ; un `hold` sans plage compte comme une entrée « Maintenant » ;
- le verrou stocké de chaque plage est le même après une modification des heures (« Mot de passe » reste « Mot de passe », avec ou sans mot de passe utilisable) ;
- une sélection enregistrée sur une ancienne section ouvre la bonne page.

## 4. Maquette

Page (largeur de lecture 760, marge 32, une seule action lime) :

```
Blocages
Ce que Goalong bloque, quand, et ce qu'il faut pour l'arrêter.

En cours
┌───────────────────────────────────────────────────────────────────────┐
│ En cours  Réseaux sociaux, Jeux    jusqu'à 12:00   Difficile [Arrêter…]│
│ En cours  Écran rouge à 60 %       jusqu'à 07:00   Verrouillé          │
│ En cours  Séance « Spec blocages » Pomodoro 2/4, 18 min    [Terminer]  │
│           bloque Réseaux sociaux                                      │
│ Prévu     Jeux                     de 14:00 à 16:00  Libre   [Annuler] │
└───────────────────────────────────────────────────────────────────────┘
(rien en cours : « Rien n'est bloqué. Prochaine règle : lundi à 9 h. »)
(l'état est un mot, jamais un point de couleur seul ; « Arrêter… », « Terminer » et « Annuler » sont des
 boutons secondaires : le seul bouton lime de la page est « Nouvelle règle ».)

Règles                                                  [ Nouvelle règle ]
┌───────────────────────────────────────────────────────────────────────┐
│ Du lundi au vendredi, de 9 h à 12 h                    Difficile    › │
│ Bloque Réseaux sociaux et Jeux                                        │
├───────────────────────────────────────────────────────────────────────┤
│ Tous les jours, de 22 h à 7 h                          Verrouillé   › │
│ Écran rouge à 60 %, luminosité à 30 %                                 │
├───────────────────────────────────────────────────────────────────────┤
│ Quand Jev me voit décrocher                            Libre        › │
│ Rappel, puis voile sombre après 5 min                                 │
└───────────────────────────────────────────────────────────────────────┘
(aucune règle : une phrase et le même bouton lime.)

Listes
  Réseaux sociaux    12 sites, 3 apps                                  ›
  Jeux               4 apps                                            ›
  Nouvelle liste…
  ▸ Mots de distraction
  ▸ Suggestions de Jev (2)

Séances                          (module Concentration)
  ▸ Plan du jour (2 sur 5)
  ▸ Engagements et limites
  ▸ Séances passées et bilan du soir

Protection
  ▸ Mot de passe, navigateurs, garde
  ▸ Écran rouge : ouverture de session, raccourci d'urgence, confidentialité
```
Chaque dépliant est une ligne de 44 pt.

Éditeur unique (feuille, `.goalongControls()`), trois blocs dans l'ordre du modèle :

```
Nouvelle règle
Quand      [ Maintenant | Horaire | Jev ]
  Maintenant : Début [Maintenant ▾ | À 14:00]   Durée [25 min ▾]  ou  Jusqu'à [12:00]
               [ ] Séance de travail : Objectif [______]  Rythme [Continu | Pomodoro]  [ ] Ambiance
                   Pomodoro : [ ] Bloquer aussi pendant les pauses
  Horaire    : Jours (L)(M)(M)(J)(V)(S)(D)   De [09:00] à [12:00]
  Jev        : Après [5] min hors travail.  Portée [Toujours | Pendant une séance]
               Définition du travail : « … »   Modifier…  (Réglages › Définition du travail)
Quoi
  [x] Bloquer des listes     (Réseaux sociaux) (Jeux) (Nouvelle liste…)    [ ] Tout le Mac
                             Tout le Mac : Mode [… ▾]   Apps permises (…)   (Maintenant seul)
  [x] Écran rouge            ────●────  60 %
  [ ] Luminosité bloquée     ──●──────  30 %
  Jev : [x] Rappel   [x] Voile sombre après [5] min   [ ] Voile rouge après [10] min
Sécurité   [ Libre | Difficile | Mot de passe | Verrouillé ]
           Une phrase dit ce qu'il faut pour arrêter (texte existant).
           Texte d'accord du garde si la règle peut l'armer.
[Supprimer la règle]                              [Annuler] [Démarrer | Enregistrer]
```

- Le bouton principal dit « Démarrer » pour « Maintenant », « Programmer » si le début est plus tard, « Enregistrer » sinon.
- Le choix « Quand » n'existe qu'à la création. Sur une règle existante, le déclencheur est un texte (« Horaire »), pas un contrôle.
- « Mettre en pause » n'existe que pour une règle « écran rouge seul » (voir 2.1).
- « Séance de travail » et un début plus tard s'excluent : une séance commence maintenant (moteur inchangé).
- Une règle protégée en cours ouvre le même éditeur. Les contrôles qui affaibliraient sont actifs ; le refus du moteur s'affiche en clair à l'enregistrement, comme aujourd'hui.
- « Séance de travail » cochée : sécurité à deux niveaux (Libre, Verrouillé), ceux du moteur.
- Jev : sécurité « Libre » seulement. Une phrase le dit.
- États : vide, en cours, en pause, refusé, erreur d'écriture, module désactivé, Jev non connecté (`JevConnectHint`), mot de passe absent (« Mot de passe » grisé avec lien vers Protection).
- Clavier : ordre Quand, Quoi, Sécurité, boutons. Chaque ligne de règle est un bouton avec un libellé complet pour VoiceOver (« Du lundi au vendredi, de 9 h à 12 h. Bloque Réseaux sociaux et Jeux. Sécurité : Difficile. »). La sécurité ne repose jamais sur la couleur seule.
- Vitesse : la page est gardée en mémoire (`keptPage`) et préchauffée. Les dépliants ne construisent leur contenu qu'ouverts. Budget : premier clic < 100 ms, vérifié par `ViewSwitchBudgetTests`.

## 5. Sécurités

Règle générale : la page et l'éditeur n'appellent que les API gardées des moteurs. Aucun nouveau prédicat.

| Cas | Comportement | Garanti par |
|---|---|---|
| « Quitter », garde, SIGTERM | inchangés | `GoalongProtection` seul (aucun appel ajouté ailleurs) |
| Affaiblir une règle protégée en cours : retirer une exécution ou une liste, réduire les heures ou les jours, baisser la sécurité, baisser le rouge, monter la luminosité, supprimer | refusé avec le message du moteur | `editCheck` / `programWeakening`, `RedScreenRules.weakening` via `refusal(for:)` |
| Renforcer | libre | idem |
| Règle sur deux moteurs | tout est validé avant toute écriture, y compris « le moteur tourne » (module Blocage actif, écran rouge démarré) ; puis Blocage, puis Écran rouge (`saveRanges`, une écriture). Si la 2e écriture échoue : erreur affichée, la liste montre l'état réel. Pas de retour en arrière : annuler la 1re écriture pourrait affaiblir une règle déjà armée | plan d'écriture `BlockRulePlan` + tests |
| Sécurité ≠ Libre et accord du garde manquant | l'éditeur affiche `GuardConsent.text` ; enregistrer vaut accord. C'est la porte actuelle de l'éditeur de plage (`BraisePage.swift:272-277`, `522-549` ; `BlockingPageLists.swift:691-720`) : même texte, même appel | `guardNeedsConsent`, `recordGuardConsent` (inchangés) |
| « Mot de passe » sans mot de passe utilisable | traité et affiché comme « Verrouillé » | `RedScreenRules.effectiveLock` |
| Panne technique de l'écran rouge | les couleurs reviennent ; vaut aussi pour la fenêtre ponctuelle | chemin d'urgence de Braise, inchangé |
| Arrêt d'une règle en cours | feuilles existantes (texte à taper, mot de passe) ; « Verrouillé » n'a pas de bouton | `stop(id:typed:password:)`, `stopActiveRanges` |
| Jev lance un blocage (PR 3, seulement après accord écrit) | listes et durée choisies par le membre ; sécurité Libre ; une session par série (identifiant dérivé) ; accord Jev mis à jour ; fin affichée | chemin de `startFocusBlock` |
| Processus de fond | aucun nouveau | — |
| Mise à jour pendant un blocage ou une plage armée | rien n'est réécrit | tests de migration (§ 3) |
| Minuteurs | chaque fin est affichée dans « En cours » | décision du 2026-10-13 |

Tests de protection : affaiblissement refusé par l'éditeur pour chaque exécution ; refus sans écriture partielle ; identifiants de plage conservés après modification ; fenêtre ponctuelle protégée (Quitter refusé, baisse refusée, fin à l'heure, couleurs rendues après panne) ; `GoalongProtection` reste la seule lecture.

## 6. « Mon travail » : où va chaque élément

| Élément de « Mon travail » | Destination | Raison |
|---|---|---|
| Ma définition du travail (texte, applications, contenus, repères) | Réglages › **Définition du travail** (nouveau panneau, à la place de « Jev ») | Elle sert à Activité et à Jev : un réglage commun |
| Classement par l'agent (interrupteur, état, ce qui est envoyé) | même panneau | C'est un accord d'envoi : il va avec les réglages |
| « Comment fonctionne le classement ? » | même panneau, dépliant | Explication du réglage |
| « Vérifier et corriger » (carte et feuille « Corriger le classement ») | même panneau ; et Activité, qui ouvre déjà la feuille (`GoalongWorkReviewSheet`) | On corrige là où on voit le classement |
| Résumé « Ce qui compte comme travail » (`GoalongWorkDefinitionSummary`) | éditeur de la règle Jev (le « prompt ») et Activité | Lien vers le panneau |

- `DashboardSection.work` reste comme alias : `selectSection(.work)` ouvre Réglages › Définition du travail. Aucun fichier d'Activité n'a besoin de changer pour que rien ne casse.
- Réglages garde 8 panneaux : « Jev » sort, « Définition du travail » entre. Le panneau Connexions garde une ligne « Jev » qui ouvre la règle Jev.
- `PRODUCT.md` et `docs/WORK_DEFINITION.md` : le nom du lieu change.

### Demandes au fil « Activité » (`feat/activite-refonte-20261110`)

À poser après sa fusion, puis un seul rebase sur `main` :
1. Garder une entrée « Corriger le classement » qui ouvre `GoalongWorkReviewSheet`.
2. Le lien vers la définition peut rester `model.selectSection(.work)` ; son libellé devient « Définition du travail ».
3. Ne plus écrire « Mon travail » dans Activité.
Si son code ne fait pas 1 à 3 après fusion, je le fais dans `GoalongAnalyticsPage*.swift` après mon rebase. Je ne touche pas à `ActivityPage.swift`.

## 7. Découpage et contrôles

| PR | Contenu | Fichiers nouveaux |
|---|---|---|
| 1 (A) | Page « Blocages », modèle `BlockRule`, éditeur unique, routage, fenêtre rouge ponctuelle ; retrait des anciennes coques et éditeurs | `Blocages/BlockRule.swift`, `Blocages/BlockRulePlan.swift`, `Blocages/BlocagesPage.swift`, `Blocages/BlockRuleEditor.swift` |
| 2 (B) | Panneau « Définition du travail », alias `.work`, retrait de la page « Mon travail » | — (déplacement dans `GoalongWorkPage.swift` → vues de panneau) |
| 3 (A, suite) | Jev lance un blocage ; texte d'accord Jev. **Seulement après accord écrit du propriétaire** (voir 2.3) | — |

Retirés en PR 1 : `SafeguardsPage`, coque `ConcentrationHubPage`, composeur « Bloquer » et grille « Semaine » de `BlockingPage`, `RedScreenRangeEditor`, composeur de séance, coque `JevMonitoringPage`. Les vues de section réutilisées restent.

Contrôles par PR : `make check`, `make audit`, `make gallery-compare` (écarts voulus déclarés : pages retirées, entrées `blocages/*` nouvelles), tests de migration et de protection, puis revue Opus du diff. Captures avant/après sur données de galerie seulement.

## 8. Revue de la spec (enfant Opus, 2026-11-10)

Verdict : « à corriger avant de coder » (1 bloquant, 7 importants, 5 mineurs). Tout est repris dans ce texte :
- bloquant : un `hold` sans plage n'avait aucun effet si « Suivre mes horaires » est décoché → 2.3 (1) ;
- `deadline` / `boot` à la création, écritures depuis l'état vivant → 2.3 (1) ;
- écriture rouge en une fois, erreur si le moteur ne tourne pas, pas de retour en arrière → 2.3 (2), § 5 ;
- clé de regroupement (verrou stocké, intensité, luminosité, état actif), état liste par liste, « autoriser seulement » → 2.1 ;
- « Jev lance un blocage » : sorti du lot tant que le propriétaire n'a pas dit oui par écrit → 2.3 (3) ;
- fonctions qui se perdaient (blocage futur, modes du gel, pauses d'une séance, réglages et états de l'écran rouge) → § 3, § 4 ;
- blocage d'une séance replié sous la séance → § 3, § 4 ;
- déclencheur fixé à la création → 2.1, § 4 ;
- mineurs : boutons secondaires, un dépliant par ligne, état en mots, porte d'accord vérifiée, test des `holds` → § 3, § 4, § 5.
