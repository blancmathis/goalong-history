# Activation Blocage — diagnostic et correctif local (2026-10-11)

Worktree : `/Users/mathisblanc/Developer/goalong-menubar-fix-20261011`, branche `fix/menubar-panel-20261011b`, base `main` `5d54471`. La vue du panneau et le dimensionnement du popover appartiennent au lot parallèle de Claude ; aucun changement de ce lot dans ces fichiers.

## Défaut reproduit et correctif

`MenuBarPanelView` passe un setter synchrone `Binding` à `GoalongSwitch`. En mode Swift 5, cette closure peut appeler `MenuBarPanelModel.setBlockList` hors du MainActor malgré l’annotation `@MainActor` du modèle. Le chemin appelle alors `BlockingController.refresh`, `start` et les publications `@Published` sur le thread appelant. En production, il peut aussi démarrer l’observation et toucher les interfaces AppKit du backend.

La régression `MenuBarPanelModelTests.testBlockListBindingHopsToMainActorBeforePublishing` exécute le même setter `Binding` depuis une tâche détachée et contrôle le thread de publication de `activeBlocks` : échec avant le correctif, succès après. Ce test établit le défaut de thread ; il ne reproduit pas à lui seul une terminaison du processus installé.

`setBlockList` est désormais une entrée `nonisolated` qui réachemine toute l’action vers la queue principale avant de lire les contrôleurs ou de publier leur état. L’action reste synchrone quand elle est déjà sur le thread principal. Le traitement existant des listes, verrous, échéances et erreurs est conservé dans une méthode privée isolée au MainActor.

## Preuves locales

App installée vérifiée : `/Applications/Goalong History.app`, version **0.6.71**, UUID arm64 `DA374B27-FBFC-3114-A3FD-0EA758BBAC63`, processus `49625` lors du diagnostic.

- À **18:35:24**, ses logs unifiés signalent `Updating ObservedObject` depuis un thread de travail et l’accès d’un `Binding` à une valeur isolée au MainActor depuis un autre acteur. Les traces sont privées et ne donnent pas une pile applicative exploitable. Elles sont cohérentes avec le défaut reproduit, sans prouver quelle closure déclenchait ces avertissements.
- L’exception `NSInternalInconsistencyException` dans `NSMenu.m:1338`, à **18:34:10**, appartient au processus précédent `659`, UUID `21E8542F-7C92-35EF-A034-1DC2B6F9816A`. Cet UUID diffère du binaire 0.6.71 actuellement installé : ne pas présenter cette exception comme preuve du crash de cette version.
- Aucun rapport `.ips` Goalong trouvé dans `~/Library/Logs/DiagnosticReports` ni `/Library/Logs/DiagnosticReports`. Les anciens `.diag` présents ne décrivent pas cet incident. Le processus 0.6.71 était encore vivant pendant le diagnostic.

Journaux complets, conservés localement et ignorés par git, sous `.build/goalong-blocking-crash/` :

- `unified-before-fix.log`, `unified-fault-detail.json` : processus précédent et exception NSMenu.
- `unified-current-app.log`, `unified-current-fault-detail.json` : avertissements du processus installé en 0.6.71.
- `binding-before-fix.log` : régression rouge, publication hors main.
- `binding-after-fix.log` : les 10 tests du modèle passent après correction.
- `native-after-fix.log` : test natif en debug, activation/arrêt par AXPress dans un vrai NSPopover et démarrage direct par l’entrée utilisée par le compositeur Blocage de l’app.

Le test natif utilise une liste en mémoire, un domaine `.invalid`, un PID fictif, des préférences isolées et le backend réel. Il vérifie également l’activation avec une observation de navigateur déjà présente, donc la création du voile. Il ne démarre pas les migrations, l’enregistrement ou les données de l’app installée. Commande : `GOALONG_BLOCKING_UI_TESTS=1 swift test --filter BlockingActivationRegressionTests`. La CI l’exécute dans l’étape « Exercise the blocking activation regression » de `.github/workflows/macos.yml`, qui échoue si le test est ignoré.

## Vérification et limite

Vérifications demandées : `swift build && swift test` (code 0, **1 849 tests, 64 ignorés, 0 échec**, journal `build-and-test.log`) et `./scripts/audit_privacy_boundaries.sh` (code 0, journal `privacy-audit.log`). Le test natif opt-in a aussi passé séparément en debug. `git diff --check` ne signale aucune erreur.

Le défaut de publication hors main est corrigé et couvert par une régression. La terminaison complète signalée par le propriétaire n’a pas été reproduite en interaction native isolée, et son lien exact avec ce défaut reste à confirmer par un nouvel essai de l’app empaquetée. Aucune installation, modification du binaire installé ou publication effectuée ; commit local seulement.

## Fichiers de ce lot

- `/Users/mathisblanc/Developer/goalong-menubar-fix-20261011/Sources/LocalHistoryApp/MenuBar/MenuBarPanelModel.swift`
- `/Users/mathisblanc/Developer/goalong-menubar-fix-20261011/Tests/LocalHistoryAppTests/MenuBarPanelModelTests.swift`
- `/Users/mathisblanc/Developer/goalong-menubar-fix-20261011/Tests/LocalHistoryAppTests/BlockingActivationRegressionTests.swift`
- `/Users/mathisblanc/Developer/goalong-menubar-fix-20261011/docs/BLOCKING-ACTIVATION-CRASH-20261011.md`

Le `CONTEXT.md` du checkout principal est actualisé et reste local, exclu de git.
