# Changelog

## 0.6.44 — appels et lectures au premier plan

- Délai d’inactivité lu sur tous les événements d’entrée macOS, plutôt que sur l’événement null.

- Les appels, vidéos et présentations observés au premier plan restent comptés sans frappe ni mouvement de souris.
- Signaux locaux liés au processus visible, sans comptabiliser les applications simplement ouvertes en arrière-plan.
- Calcul harmonisé entre Activité, statistiques locales, sites et observations utiles aux analyses.
- Lecture/appel reconnu par les contrôles réutilisé pour la surveillance temps réel déjà activée ; un signal navigateur global n’invente pas le site regardé.
- Verrouillage, veille, pauses, exclusions et choix de confidentialité conservés ; aucune capture audio ou vidéo.

## 0.6.43 — repères personnels de procrastination

- Champ facultatif dans Surveillance temps réel pour donner des exemples certains de procrastination.
- Exemples transmis séparément aux analyses autorisées, sans limiter la détection à cette liste.
- Correspondance sur l’usage réel, prioritaire sur une autorisation générale ; les autres usages ne sont pas automatiquement productifs.
- Critères existants conservés, édition annulable et retrait des exemples sans effacer les projets.
- Budgets, pauses, exclusions et autorisations inchangés.

## 0.6.30 — enregistrement complet dès l’activation

- Proposition complète des huit types de détails à la première activation, depuis chaque entrée de l’application.
- Validation et démarrage du suivi local dans le même parcours ; texte affiché visible immédiatement.
- Choix explicitement désactivés conservés après arrêt, reprise et relancement.
- Profil réellement enregistré affiché : Complet 8/8, Personnalisé ou Applications seules.
- Suppression du raccourci qui désactivait plusieurs enregistrements sans confirmation.
- Enregistrement vérifié des choix et retour au profil précédent en cas d’échec.


## 0.6.29 — aperçu des journées sans sites

- Une catégorie vide ne bloque plus l’aperçu lorsque l’autre contient une sélection explicite.
- Les listes vides restent strictement vides : aucune autorisation implicite n’est ajoutée.
- La suggestion initiale de sites attend une journée contenant réellement des domaines.
- Tests du parcours applications seules avec l’option Sites activée.

## 0.6.28 — fiabilité des fenêtres et finition des réglages

- La fenêtre d’envoi conserve la journée demandée dès sa première ouverture.
- Les raccourcis ChatGPT ouvrent directement le bon onglet, sans état périmé.
- Choix de détails immédiatement visibles, grilles accessibles et cartes de largeur cohérente.
- Recherche étendue aux outils avancés ; remplacement incomplet signalé avant validation.
- Dates et principaux états de l’historique harmonisés en français ; icônes d’appareils distinctes.
- Tests natifs des ouvertures, de la date, des retours et des sélections, sans envoi de données personnelles.

## 0.6.27 — contrôles détaillés et parcours vérifiés

- Trois grandes entrées distinctes : enregistrement, envoi à Goalong et analyse ChatGPT.
- Onboarding : tous les détails proposés, texte visible inclus, puis validation explicite ; choix existants conservés.
- Sélection ChatGPT par application et type de données, appareils et dossiers ; remplacements locaux et consignes de rédaction.
- Aperçu local après filtrage, remplacements avant troncature et protection des champs exclus.
- Présélection du partage sans envoi, gestion des domaines locaux et aperçu utilisable sans connexion.
- Correction de l’affichage vide lors d’un changement de fenêtre ; la lecture en arrière-plan reste suspendue.
- Retour au bon écran après connexion, état de configuration exact, fenêtres réduites et grands aperçus progressifs.
- Tests des combinaisons de champs, de la persistance, des contrôles natifs et du transport local.


## 0.6.26 — réglages et confidentialité simplifiés

- Pause globale persistante pour les sources, analyses et envois ; protection des requêtes en attente à la reprise.

- Cinq rubriques de réglages, recherche, états courts et onboarding en trois étapes.
- Réglages immédiats, catalogue d’applications et exclusions explicites.
- Sélection ChatGPT indépendante, connexion sans installation manuelle de Codex.
- Envoi Goalong unifié, aperçu lisible et choix par application sans fuite via les totaux.
- Conservation simplifiée ; effacement et activation des envois toujours confirmés.
- Les anciennes programmations dont le périmètre change demandent une nouvelle validation.


## Unreleased

- Fixed local Analyses rejecting an entire day when buffered typing or scrolling
  events arrive a few seconds behind newer observations. Only the derived timeline
  is stably sorted; the source journal and genuine incomplete-read protections stay intact.
- Made the first seconds/minutes visible with adaptive chart scales and distinct
  first-observation, empty, and unreadable-source states.
- Added an explicitly opt-in developer mode in Settings → Advanced, off by default.
  Its Analyses preview uses deterministic in-memory fixtures for 1/7/28 days and
  all project modules, never writes to history, and disables sharing/AI actions.

- Made the Goalong CLI self-describing through a canonical machine-readable command catalog,
  structured nonzero errors and explicit per-command write effects. Its metadata-only `status`
  now diagnoses Computer History, Screen Time, AI-conversation indexing, saved recaps and optional
  ChatGPT analysis without opening Apple stores or provider conversation bodies, and distinguishes
  a ready Screen Time broker from independently proven Apple-source quality.
- Improved the Settings CLI guide with exact installed-link verification, a back path, copyable
  quick commands, an optional full-instruction preview and accessibility announcements. The shared
  agent brief now requires the exact executable, pagination, least disclosure and honest limits on
  foreground, missing and privacy-filtered evidence.
- Prevented a sub-three-second stale `loginwindow` accessibility sample after secure-input recovery
  from becoming a false user activity, while retaining sustained lock/login intervals and the
  untouched raw source evidence.
- Added a dedicated CLI guide from Settings with quick-start commands, live link status and one
  complete copy-ready instruction block for safe, coverage-aware local agent use.
- Removed the Screen Time presentation oracle that could activate System Settings and synthesize
  menu, mouse or keyboard input. Screen Time now uses only read-only Apple stores in the
  background, with an explicit private-aggregate or reconstructed provenance state.
- Added one compact normalized Screen Time record per observed day. Only the active day is
  refreshed from Apple; completed-day UI, recap and CLI reads stay local and never reopen Apple
  history or create query-specific copies.
- Preserved subsecond Apple activity timestamps in stored JSON and atomically repairs a malformed
  active-day record from an earlier build without modifying completed days.

## 0.6.0

### One private, auditable application

- Replaced the former split/local-edition and Sparkle update paths with one `Goalong History`
  application whose sensitive capabilities are all off on a new install.
- Removed the first-party HTTP uploader, App Attest transport, in-app updater, remote Swift
  dependencies and retired Sparkle release tooling from the compiled public target.
- Added separate Goalong consent for Computer History, Apple Screen Time, AI conversations and
  optional ChatGPT analysis; existing macOS permission switches never substitute for consent.
- Added an auditable capability manifest, SPDX SBOM, release manifest, threat model, network and
  permission documentation, pinned GitHub Actions and a single free Community release policy with
  explicit Gatekeeper limits and Sigstore-backed GitHub provenance.

### Direct-source AI conversations and bounded agent access

- Added read-only direct-source adapters for Codex, Claude and OpenCode with incremental discovery,
  stable opaque identities and explicit missing, inaccessible, changing and deleted-source states.
- Kept only a bounded metadata index in Goalong storage; transcript bodies, snapshots and versions
  remain in their provider-owned locations and are read transiently only for an explicit day.
- Added the `goalong` CLI for bounded JSON access to Computer History, Screen Time, AI
  conversations, available dates, daily recaps and offline proof verification without a second
  background process or history vault.
- Added selected-day projection for very large conversations, reducing repeated source reads while
  preserving the user-message/final-answer boundary used by daily analysis.

### Clearer daily history and lower overhead

- Consolidated the dashboard around Today, History and Settings, with factual ten-minute Computer
  History windows and simpler AI-conversation presentation using provider conversation names.
- Added incremental bounded day loading, cache reuse, event-stream backpressure, background wakeup
  reduction and performance guards for large histories.
- Improved Screen Time device naming, active-versus-inactive accounting, website usage projection,
  browser/site reconciliation and compact most-used views that exclude inactive system rows by
  default.

### Verifiable AI analysis and sharing

- Added bounded five-line daily assessments through the separately consented local Codex bridge,
  using only user prompts and final agent answers rather than tool/process transcripts.
- Added canonical ES256 proofs, chained run attestations, encrypted bounded response capsules and
  strict offline `.goalong-proof` export/verification without copying prompts or transcripts.
- Hardened selective share construction against source replacement, malformed input, stale caches,
  cancellation and partial output while preserving the original event, memory, seal and Screen Time
  stores.

## 0.5.1

### Keychain authorization loop

- Stopped reusing legacy signing keys created by earlier ad-hoc builds, which could make macOS request the login-keychain password on every minute signature after an app-signature change.
- Namespaced replacement Keychain keys by the app's designated signing requirement, so a development-to-production certificate transition creates a visible identity rotation instead of reopening an incompatible key.
- Prefer the modern Data Protection Keychain when the signed bundle carries authorized application-identity entitlements; stable signed builds otherwise use a newly scoped, non-exportable login-Keychain key.
- Made ad-hoc source builds use a user-only local key file rather than a legacy Keychain item that would become inaccessible after the next recompile.
- Suspended signing for the rest of a launch after an explicit authentication cancellation, preventing an authorization failure from creating a new password dialog every minute.
- Added share-package identity-rotation metadata and made the uploader register and replay seals for each identity represented in existing history.

## 0.5.0

### Apps, websites, and sharing rules

- Made **Apps & sites** the primary Activity view while keeping the detailed session timeline one click away.
- Added a complete local list of observed applications and websites with estimated foreground time, input-active minutes, category, and event count.
- Replaced minute-by-minute sharing controls with persistent per-app and per-website rules: **Show name**, **Category only**, or **Hidden**.
- Made website rules override their browser rule and defaulted new subjects to **Category only**.
- Added event-level mixed disclosure so several apps or websites in the same sealed minute can follow different privacy rules without rewriting the original evidence.
- Added event schema v3 with a separately salted website-host commitment. New shares can prove a host without revealing the full URL, page title, or browser name.
- Kept v2 history verifiable and made older website identity requests fall back to category-only instead of opening the broader legacy context commitment.
- Replaced activity-event winner estimates with bounded foreground observation time; unobserved gaps are never filled beyond 75 seconds.
- Added capability-based browser URL discovery and bundle-name detection so wrappers and previously unknown browsers such as Aside can expose accessible URLs without a dedicated extension.
- Fixed source-built Sparkle bundles failing at launch because Hardened Runtime library validation cannot match Team IDs for ad-hoc signatures; production Developer ID builds still require Hardened Runtime.

### Software updates

- Added Sparkle 2.9.6 as an exact-pinned macOS update dependency.
- Added quiet daily signed update checks with a compact dashboard button that appears only when a new release is available.
- Kept explicit user control over installation: automatic download/install remains disabled, while clicking the update indicator opens Sparkle's standard release-notes and installation flow.
- Added a stable GitHub Releases appcast, EdDSA archive signing, signed-feed enforcement, and explicit nested Sparkle code signing in the release pipeline.
- Added CI checks for the embedded framework, app-relative rpath, updater privacy settings, dependency pin, and signed release metadata.
- Enabled Sparkle's required verify-before-extraction policy for signed appcasts.
- Added maintainer tooling and documentation for Sparkle key generation, backup, release publication, N-1 → N testing, and key rotation/recovery.

## 0.4.0

### Installation and onboarding

- Replaced the target-Mac compilation flow with a universal prebuilt macOS application as the primary distribution path.
- Added a branded drag-to-Applications DMG for Intel and Apple Silicon Macs.
- Added a Developer ID signing, Hardened Runtime, notarization, stapling, verification, checksum, and GitHub Release workflow.
- Added a five-step native setup assistant inspired by the calm, focused installation experience of modern developer tools.
- Added a full privacy-boundary screen before any permission request.
- Split Accessibility and Input Monitoring into separate contextual permission steps with live state, direct System Settings links, retry controls, and graceful deferral.
- Added a final readiness check and an explicit start-at-login choice.
- Replaced the legacy hand-written LaunchAgent with Apple `SMAppService` login-item management.
- Added migration cleanup for the old LaunchAgent while preserving existing activity and settings.
- Reworked `Install.command` and `install.sh` as polished fallback installers that download and verify the signed release before using a source-build fallback.
- Reworked uninstallation with a native keep-data/remove-data choice and login-item cleanup.

### Product polish

- Added a production app icon and branded DMG background.
- Made diagnostics, uploads, the dashboard footer, and the reference server report the v0.4.0 bundle/protocol version instead of stale v0.3.2 metadata.
- Added release, distribution, and installation-experience documentation.
- Updated the English README and French guide around the no-Terminal public installation path.
- Expanded CI to validate shell scripts, build a real app bundle, verify signing metadata, and smoke-test packaging.

### Unchanged trust boundary

- Event schema, local-only detailed storage, private-browser suppression, cryptographic commitments, minute anchors, P-256 signatures, and selective-disclosure behavior are unchanged.
- Raw typed characters, screenshots, audio, camera, and clipboard capture remain prohibited.

## 0.3.2

- Fixed `Install.command` on the macOS system Bash (3.2) when App Attest compatibility flags are empty.
- Replaced optional empty-array expansion under `set -u` with explicit scalar compatibility-mode branches.
- Applied the same fix to the macOS CI workflow.
- No event schema, cryptographic proof, privacy setting, or stored-history migration changed in this patch.

## 0.3.1

- Fixed macOS compilation of `DeviceIdentity.swift` by using an explicit `OSStatus` conversion.
- Fixed the Activity page module import required for `SuppressionReason`.
- Added public initializers for verification protocol request models used by the app target.
- Added a regression test for the cross-module protocol API.
- Improved installer diagnostics so unrelated compiler failures are no longer mislabeled as App Attest SDK issues.

## 0.3.0

### Added

- Native SwiftUI dashboard hosted in a reusable AppKit window.
- First-run onboarding and permission guidance.
- Overview with runtime status, daily metrics, 24-hour coverage timeline, top apps and recent sessions.
- Searchable/filterable Activity browser with detailed session inspector.
- Visual selective-disclosure editor with four privacy levels, bulk presets and exact share preview.
- Privacy & Security center covering permissions, data flow, storage, identity and safe deletion.
- Settings interface for capture, retention, verification, App Attest preference and exclusions.
- Menu-bar shortcuts to open the dashboard and Share section.
- Dashboard data reader that turns local JSONL/seals/receipts into understandable sessions and metrics.

### Preserved

- v0.2 cryptographic event commitments, Merkle roots, chains, minute sealing and P-256 signatures.
- Opaque live-anchor network boundary.
- Selective disclosure and private-only periods.
- Private-browser fail-closed behavior and no raw typed text.
