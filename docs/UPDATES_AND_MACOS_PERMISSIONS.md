# Updates and macOS permission continuity

> Current build defaults and the key-preserving local publication workflow: [FREE-UPDATES.md](FREE-UPDATES.md). Normal source builds now include the committed public update key; no paid Apple membership or developer-key export is required.

Goalong has one bundle identity, `ai.goalong.localhistory`. Local builds use a stable Apple
Development identity when one is already available. The free public Community Build is
signed with a pinned Apple Development identity (team 2L5SSLPX46, see
`Distribution/release-signing.json` and [STABLE_RELEASE_IDENTITY.md](STABLE_RELEASE_IDENTITY.md)),
not Apple-notarized and not sandboxed. Releases signed with the same pinned identity keep the same
designated requirement, so macOS should not ask for Goalong permissions again after a normal
update. The request can come back only on the one-time move from an older ad-hoc build, or if the
signing identity changes in the future (for example to Developer ID). The installer reports that
consequence before replacing the app; history and settings remain preserved. Permission continuity
is still not a guarantee: always verify the capture state after an update.

The app never assumes permission from a switch alone. It verifies functional Accessibility/input
health and separately requires the corresponding Goalong capability consent. Replacing the app
does not intentionally reset history or consent data.

Community updates use the signed in-app Sparkle flow. Automatic checks run at launch and hourly
unless disabled in Settings; clicking the sidebar badge or Check for Updates opens the native
installation flow. An old build with no updater needs one initial reinstall. Source builds without
a release public key never contact the feed. Neither Sparkle Ed25519 authentication nor GitHub
provenance grants a stable Apple signing identity, so permission continuity is not guaranteed.
See [`UPDATE-SECURITY.md`](UPDATE-SECURITY.md) and [`BUILD-VERIFICATION.md`](BUILD-VERIFICATION.md).
