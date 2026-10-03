# Sources système — contrat et API pour l’interface

Flux S1–S7 de `DATA_DEPTH.md`, 2026-10-03. Aucune nouvelle durée n’est ajoutée au temps actif.
Les tests utilisent des répertoires temporaires ; les titres d’agenda restent uniquement en mémoire.

| API | Fichier | Usage |
| --- | --- | --- |
| `GoalongSystemSourceStatus` | `Sources/LocalHistoryCore/GoalongSystemSources.swift` | disabled / permissionDenied / unsupported / noData / partial / ready / failed(reason) |
| `GoalongCallLane` | même fichier | intervals, unionSeconds, secondsPerApplication |
| `GoalongCallStore` | même fichier | save / load, découpage à minuit, lecture bornée et privée |
| `GoalongDayNoteStore` | même fichier | get / set / delete ; 280 caractères, fichiers 0600, conservation sans purge automatique |
| `GoalongCallPresenceMonitor` | `Sources/LocalHistoryApp/GoalongCallPresenceMonitor.swift` | configure(enabled:config:), stop(), lane(day:enabled:privacy:) ; transitions par listeners |
| `GoalongCalendarSource` | `Sources/LocalHistoryApp/GoalongCalendarSource.swift` | actor ; read(day:enabled:), requestAccess(enabled:), invalidate(), disable(), authorization(for:) |
| `GoalongCalendarLane` | même fichier | status, calendarStatus, remindersStatus, events, completedReminders, openDueReminderCount, plannedBusySeconds |
| `GoalongOtherDevicesSource` | `Sources/LocalHistoryApp/GoalongSystemSourcesReader.swift` | load / build ; device scope, screenOnSeconds, duringMacGapsSeconds, duringMacActivitySeconds, lastUpdatedAt, estimated |
| `GoalongHealthSource` | même fichier | load / decode ; sleepSeconds, sleepStages, steps, workoutCount, workoutSeconds, timeZone, sleepLabel |
| `GoalongSystemSourcesReader` | même fichier | actor ; read(day:callsEnabled:calendarEnabled:screenTimeEnabled:) |
| `GoalongSystemSourcesDay`, `GoalongOtherDevicesLane`, `GoalongHealthLane` | même fichier | valeur du jour ; statuts et données de chaque lane, note et noteStatus |
| `GoalongSystemSourcesModel` | même fichier | ObservableObject MainActor ; value, loading, error, calendarEnabled, callPresenceEnabled, calendarPermission, remindersPermission ; refresh(day:), setCalendarEnabled, requestCalendarPermissions, setNote, deleteNote |
| `GoalongSystemRecapSelection` | `Sources/LocalHistoryApp/GoalongSystemRecapSections.swift` | cinq choix indépendants, tous désactivés par défaut ; `GoalongAnalysisSelection.systemSources` optionnel pour migrer les choix existants |

`GoalongCapability.calendar` est le consentement Goalong, séparé des deux autorisations macOS.
Le réglage `RecorderConfig.captureCallPresence` migre les anciennes configurations vers activé,
mais l’autorisation Historique de ce Mac et les pauses continuent de bloquer la capture.
Il se change par le brouillon des réglages (`DashboardSettingsDraft.captureCallPresence`, interrupteur
« Appels » de Réglages › Données enregistrées), hors du compteur du profil d’enregistrement : la
configuration en mémoire reste la seule source, et `applyConfiguration` reconfigure le moniteur.
`AppDelegate` relie le moniteur au consentement, aux pauses, à la configuration et à l’arrêt.
L’interface peut utiliser le modèle sans déclencher de demande de permission pendant une lecture.

L’archive Temps d’écran existante est lue sans ouvrir les bases Apple. La présence d’un appareil
pendant une lacune ne démontre pas que l’utilisateur l’utilisait ; un segment grossier est proratisé
et signalé estimé. Un agrégat opaque est omis si les exclusions ne peuvent pas être appliquées.
L’import Santé découpe le sommeil à minuit dans son fuseau ; il ne l’affecte pas au jour du réveil.
Les imports restent des instantanés partiels des sources choisies, même quand leur lecture réussit.

Les notes sont incluses uniquement si le nouveau choix de bilan est activé. Le flux F peut lire
`GoalongDayNoteStore.get(root:day:)` pour son paramètre de note du classificateur ; ce branchement
est laissé à l’intégration, car F modifie le même agent. Notes et appels sont supprimés par le
plan durci de suppression des jours et de l’historique (le moniteur est arrêté pendant la suppression pour ne pas recréer les intervalles) ; les appels ont la rétention des événements.

## Permissions et limites

L’entitlement Calendars documenté par Apple est conservé dans
`Distribution/GoalongHistory.entitlements`. Les builds signées avec certificat l’embarquent par
défaut ; ni réseau, ni automation, ni exemption de validation des bibliothèques n’est ajouté.
Les quatre textes Info.plist sont exactement ceux du plan. L’artefact sécurité liste ces textes
et les permissions Calendars / Reminders. Aucun entitlement Reminders distinct n’est ajouté :
la documentation publique décrit l’accès EventKit par Calendars ; le prompt Reminders doit être
vérifié par une personne sur une build signée, avec le consentement explicite.
[Documentation Apple de Calendars](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.personal-information.calendars).

Avant macOS 14.2, le bit matériel `DeviceIsRunningSomewhere` n’indique pas une direction.
Seuls les périphériques audio d’entrée sans flux de sortie peuvent donc prouver un usage micro ;
un périphérique duplex est omis et la source est partielle. Sur macOS 14.2+, les processus
utilisant l’entrée sont identifiés puis rattachés à leur app extérieure. La caméra est connue
seulement au niveau du périphérique ; elle ne peut pas être attribuée à une application.
Ce sont des usages micro/caméra, pas une preuve de réunion. Aucun flux n’est ouvert.
Une couverture partielle du jour reste partielle même sans intervalle détecté ; le statut
matériel courant ne remplace pas celui des archives des jours précédents.

Un état ouvert au crash n’est jamais prolongé jusqu’au relancement : une borne interrompue
est conservée au dernier état confirmé, sans inventer la durée pendant l’arrêt. Les intervalles en cours vivent dans
le moniteur et sont ajoutés uniquement à sa lecture en cours ; les fichiers sont bornés à 2 Mio/jour.
Les captures du navigateur sans provenance de domaine sont omises si un filtre de domaine est actif.
Un bundle vide reste une application inconnue ; les usages sans attribution sont omis à la
lecture et à la persistance dès qu’une exclusion globale est active.

Le builder de bilan existant est synchrone. L’agenda est obtenu hors du fil principal par une
attente unique bornée à 9 secondes ; un appel accidentel sur le fil principal donne un état partiel.
Les lectures Santé sont mises en cache par empreinte de fichier ; les appareils ont un cache de huit jours qui inclut les segments du Mac, la configuration et les exclusions. Les lecteurs EventKit ont un cache de 64 jours, invalidé par EKEventStoreChanged. Les rappels
ont un timeout de 3 secondes par requête et une limite de 1000 éléments ; les événements sont
énumérés sur un jour, avec 1000 éléments et un budget de deux secondes. Les limites sont visibles.

Les navigateurs Aside, Dia et Zen sont ajoutés aux configurations enregistrées à leur validation,
sans changer les exclusions ni l’enregistrement privé.
[Identifiants de navigateurs publiés par Apple](https://github.com/apple/password-manager-resources/blob/main/quirks/web-browser-extension-distribution-information.json).

Les validateurs de sécurité CLI acceptent désormais les worktrees Git : leur ancien contrôle
exigeait un répertoire `.git`, alors qu’un worktree possède un fichier `.git`.

## Fichiers du flux S

- Stockage et configuration : `Sources/LocalHistoryCore/GoalongSystemSources.swift`, `Sources/LocalHistoryCore/Config.swift`.
- Lecteurs et modèle : `Sources/LocalHistoryApp/GoalongCallPresenceMonitor.swift`, `GoalongCalendarSource.swift`, `GoalongSystemSourcesReader.swift`.
- Intégration app : `Sources/LocalHistoryApp/AppDelegate.swift`, `CapabilityConsentStore.swift`, `HistoryRetentionStore.swift`, `DerivedHistoryCleaner.swift`.
- Bilan : `Sources/LocalHistoryApp/GoalongSystemRecapSections.swift`, `GoalongAnalysisSelection.swift`, `ChatGPT/GoalongGranularContext.swift`, `ChatGPT/ChatGPTRecapContext.swift`.
- Allowlist et tests : `Sources/LocalHistoryApp/SupportSourceAllowlist.swift`, `Tests/LocalHistoryAppTests/GoalongSystemSourcesTests.swift`.
- Distribution : `Distribution/GoalongHistory.entitlements`, `scripts/build_app.sh`, `scripts/build_app_core.sh`, `scripts/generate_security_artifacts.py`, `scripts/audit_privacy_boundaries.sh`.
- CI : `.github/workflows/macos.yml`, `release.yml`, `continuous-release.yml`, `prepare-local-signed-release.yml`, `scripts/validate_computer_history_upgrade.sh`, `scripts/validate_computer_history_parity.sh`.
- Documentation : `docs/PRIVACY.md`, `docs/SYSTEM_SOURCES.md`.

Le changement concurrent de `Tests/LocalHistoryAppTests/ChatGPTRecapTests.swift` (saut de deux
tests quand HOME isolé n’a pas de trousseau login) est conservé mais n’appartient pas aux commits S.
Le checkout principal et son `CONTEXT.md` restent à mettre à jour par l’intégrateur : ce job
ne modifie pas les autres worktrees.

## Validation locale — 2026-10-03

Code validé : `d1f4466` (les cinq commits S depuis `9cab47c`). Logs privés et artefacts :
`/tmp/goalong-system-sources-qa/`. Aucun déploiement, installation, push ou PR.

- Dernière suite complète, HOME et CFFIXED_USER_HOME isolés : `Executed 1445 tests, with 31 tests skipped and 0 failures (0 unexpected) in 631.028 (631.474) seconds` ; `full-suite-post-attribution.log`, exit 0.
- Tests S ciblés : `Executed 10 tests, with 0 failures (0 unexpected) in 0.027 (0.029) seconds` ; `system-sources-attribution.log`. Ils couvrent notamment les fichiers privés, liens refusés, suppression des notes, union et minuit, exclusions des usages inconnus, migration des navigateurs, choix de bilan, masquage, imports et permissions désactivées.
- Allowlist `--check`, `verify_source_security.sh` et audit strict : exit 0 ; `allowlist-latest.log`, `security-post-attribution.log`. La liste des fichiers source n’a pas changé depuis le contrôle d’allowlist.
- Bloc « Validate scripts » de `macos.yml` : exit 0 ; `validate-scripts-2.log`. Vérification cryptographique des mises à jour : exit 0 ; `update-verification.log`.
- Contrôles UI existants : disclosure 1/0, analytics 2/0, Jev effects 1/0, parcours natifs 3/0 ; `disclosure-2.log`, `analytics-render.log`, `jev-render.log`, `journey.log`. Aucun fichier SwiftUI modifié.
- Relaunch permissions : trois vrais cycles quit/reopen, quatre PID distincts ; le helper manquant ne quitte pas le parent ; `permission-relaunch.log`.
- Fuseaux UTC, America/Chicago et Europe/Paris : 27 tests/0 échec chacun ; `timezone-*.log`.
- Build release arm64 sur le dernier code, un job, identité Apple Development existante : exit 0 ; `signed-build-final.log`. `codesign --verify --deep --strict`, vérification du bundle unique, manifeste de sécurité, quatre textes français exacts et entitlement vérifiés. Hardened Runtime présent ; le dictionnaire d’entitlements contient uniquement `com.apple.security.personal-information.calendars = true` ; `bundle-final.log`.
- CLI du bundle, HOME isolé : exit 0 et aucune écriture de source ; `cli-final.log`.
- Packaging de `macos.yml` : exit 0, via hdiutil (`create-dmg` absent) ; `package-final.log`. ZIP : **101764442 octets**, DMG : **113045801 octets**, dans `/tmp/goalong-system-sources-qa/dist/`. Les noms historiques « universal » sont conservés ; cette build locale contient **arm64 uniquement**.

Deux tests Keychain ont d’abord donné exactement `keychainFailure(-60006)` (exception autorisée
par le brief). Le changement concurrent de `ChatGPTRecapTests.swift` les saute maintenant sous
HOME isolé : `No login Keychain under HOME (isolated test run).` Il explique les deux skips
supplémentaires du résultat final et reste hors des commits S.

Un passage intermédiaire a échoué au test préexistant de latence avec `149042416` ns contre
`100000000` ns ; les 20 tests du groupe ont ensuite passé isolément, puis la suite complète
sur le dernier code. Le premier essai disclosure a échoué avec
`Clicking the empty right side must expand the section` ; le second, sans changement, a passé.
La reconstruction intermédiaire a été arrêtée (exit 130) pour intégrer la correction de
provenance ; la reconstruction finale a passé. Le contrôle d’architecture a été corrigé
pour lire `CFBundleExecutable` au lieu de supposer le nom `LocalHistory`.

À vérifier manuellement avant diffusion : invites Calendar/Reminders sous Hardened Runtime,
éventuelle nécessité d’une clé Reminders distincte, vrais usages micro/caméra, fallback sur
macOS 13. Aucune invite TCC réelle n’a été déclenchée par ce job. L’intégrateur doit brancher
F4 sur le getter de note et mettre à jour le CONTEXT.md du checkout principal. Les uploads
GitHub de la CI ne sont pas exécutés : seuls ses contrôles locaux sont réalisés.
