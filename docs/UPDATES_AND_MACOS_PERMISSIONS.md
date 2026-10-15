# Updates and macOS permission continuity

> Current build defaults and the key-preserving local publication workflow: [FREE-UPDATES.md](FREE-UPDATES.md). Normal source builds now include the committed public update key; no paid Apple membership or developer-key export is required.

Goalong has one bundle identity, `ai.goalong.localhistory`. Local builds use a stable Apple
Development identity when one is already available. The free public Community Build is signed
with the pinned Apple Development identity (team 2L5SSLPX46, see `STABLE_RELEASE_IDENTITY.md`) and is
not notarized. Its designated requirement stays stable across updates, so macOS permissions normally
persist. Only a migration from a legacy ad-hoc build may request fresh Goalong permissions; the installer
reports that before replacing the app, and history and settings remain preserved.

The app never assumes permission from a switch alone. It verifies functional Accessibility/input
health and separately requires the corresponding Goalong capability consent. Replacing the app
does not intentionally reset history or consent data.

Community updates use the signed in-app Sparkle flow. Automatic checks run at launch and hourly
unless disabled in Settings; clicking the sidebar badge or Check for Updates opens the native
installation flow. An old build with no updater needs one initial reinstall. Source builds without
a release public key never contact the feed. Neither Sparkle Ed25519 authentication nor GitHub
provenance grants a stable Apple signing identity, so permission continuity is not guaranteed.
See [`UPDATE-SECURITY.md`](UPDATE-SECURITY.md) and [`BUILD-VERIFICATION.md`](BUILD-VERIFICATION.md).
