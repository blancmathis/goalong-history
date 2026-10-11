# Panneau barre de menu — données et intégration (2026-10-11)

Statut : terminé pour le lot données/intégration, avec les adaptations d’API ci-dessous. Branche locale `feat/menubar-panel-20261011`, aucun push, aucune installation ni relance de l’app.

## Livré

- Contrat `MenuBarPanelModel` conservé : mêmes propriétés, types et méthodes. Les dépendances sont injectables pour les tests ; l’app utilise les contrôleurs réels.
- Suivi : état de capture, consentement local, pause globale, santé de capture et suppression courante. L’action reprend exactement la confirmation et le traitement de pause du menu existant. Une confirmation annulée ne change aucun état.
- Journée : `GoalongAnalyticsReader.shared.readToday`, cache incrémental partagé et verdicts réels de `GoalongWorkStore`. Totaux Travail/Hors travail conservés ; seuls les segments actifs sont dessinés, sans remplir les périodes privées, inactives ou non observées. Les coordonnées suivent les heures locales 0–24. Une lecture est en cours au maximum ; sa publication est invalidée à la fermeture ou au changement de jour.
- Concentration : contrôleur de `ConcentrationRuntime.shared`, Pomodoro 25/50/90 min, quatre cycles, séance libre sans fin, phase/minuteur/progression réels et arrêt par les validations existantes.
- Ambiance : même `AmbianceModule` que le tableau de bord, état de lecture et dernière source réels, catalogue incluant les textures non installées, volume borné écrit dans le contrôleur. `playNext` reste dans la famille de la source courante/dernière, ignore les sources indisponibles et boucle. Aucun téléchargement automatique.
- Blocage : contrôleur de `BlockingRuntime.shared`, états/verrous calculés par le moteur. Chaque action revalide le verrou ; aucun défi, mot de passe ou verrou de séance n’est contourné.
- Clic gauche : `NSPopover.transient` contenant la vue de Claude, largeur portée par `MenuBarPanelView` (340). Clic droit, Option-clic et bouton « ⋯ » : menu natif existant. `setFocusTitle` est inchangé. Rafraîchissement immédiat puis toutes les secondes pendant l’ouverture ; minuterie et lecture annulées à la fermeture.

## Adaptations et limites du contrat

1. `ConcentrationController` ne propose aucune pause/reprise et `FocusSession.Event.Kind` ne contient que `start`, `skip`, `stop`. `pauseOrResumeFocus()` ouvre donc Concentration ; `FocusRun.isPaused` reste `false`. Aucune fausse pause ni modification du moteur/persistence. Pour un véritable bouton de pause, il faudra une décision et une évolution du moteur ; la vue peut adapter son libellé.
2. `BlockingController.start` exige une date de fin. Une liste libre activée depuis le panneau est bloquée jusqu’au prochain minuit local ; cette échéance devrait être explicitée dans la vue si nécessaire. Une liste verrouillée ne peut pas être activée/désactivée par `setBlockList` ; `requestStopBlocking` ouvre la page Blocage où les protections existantes s’appliquent.
3. Une séance libre partageant plusieurs listes ne peut pas être arrêtée pour une seule liste avec l’API actuelle. Le panneau ouvre Blocage au lieu d’arrêter les autres listes.
4. Le contrat ne partage pas la sélection visuelle d’onglet Ambiance avec le modèle. La famille courante pour `playNext` est celle de la source en lecture ou dernière écoutée, Focus par défaut ; changer seulement l’onglet local de la vue ne change pas cette famille.

## Fichiers de ce lot

- `/Users/mathisblanc/Developer/goalong-menubar-20261011/Sources/LocalHistoryApp/MenuBar/MenuBarPanelModel.swift`
- `/Users/mathisblanc/Developer/goalong-menubar-20261011/Sources/LocalHistoryApp/MenuBarController.swift`
- `/Users/mathisblanc/Developer/goalong-menubar-20261011/Sources/LocalHistoryApp/AppDelegate.swift`
- `/Users/mathisblanc/Developer/goalong-menubar-20261011/Tests/LocalHistoryAppTests/MenuBarPanelModelTests.swift`
- `/Users/mathisblanc/Developer/goalong-menubar-20261011/docs/MENUBAR-PANEL-DATA-REPORT-20261011.md`

Le contexte local partagé a été actualisé à `/Users/mathisblanc/Documents/Codex/2026-09-05/gpt/outputs/terminal-mac/workspace/goalong-permissions-diagnostics-20260926/CONTEXT.md` ; il reste exclu de git. `MenuBarPanelView.swift` et la spécification fournie n’ont pas été modifiés ni inclus dans le commit de ce lot. La vue de Claude était présente lors des vérifications.

## Vérification

- `swift build` : code de sortie 0. Journal `/private/tmp/goalong-menubar-build-20261011.log`.
- `swift test` : code de sortie 0 ; 1 846 tests, 62 ignorés, 0 échec, dont les 9 tests de `MenuBarPanelModelTests`. Journal `/private/tmp/goalong-menubar-tests-20261011.log`.
- Tests ajoutés : pause/annulation, pause globale/consentement/santé, Pomodoro et séance libre, arrêt de séance verrouillée refusé, listes Difficile/Mot de passe/Verrouillé non modifiables, échéance minuit et blocage partagé, `playNext`/volume/catalogue, conservation des totaux et trous de couverture, lecture coalescée et résultat tardif après fermeture.
- `git diff --check` : aucune erreur.

Pas de validation visuelle interactive des clics/AppKit ni de sortie audio réelle dans ce lot. La finalisation de la vue et la vérification manuelle du panneau restent au lot UI de Claude.
