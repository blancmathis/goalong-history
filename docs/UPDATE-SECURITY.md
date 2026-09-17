---

> Current build defaults and the key-preserving local publication workflow: [FREE-UPDATES.md](FREE-UPDATES.md). Normal source builds now include the committed public update key; no paid Apple membership or developer-key export is required.
context_room:
  id: assurance.supply-chain.updates
---

# Update security

The Community app includes exact-pinned Sparkle 2.9.6. Its only update feed is
`https://github.com/blancmathis/goalong-history/releases/download/latest-main/community-appcast.xml`.
The real updater starts at launch; checks default to enabled and recur hourly. Users can disable
background checks in Settings and still perform a manual check. Installation is never silent:
the sidebar button and menu lead to Sparkle's native, user-approved installation/relaunch flow.
No activity contents or optional system profile are sent by the updater. GitHub/CDN necessarily
receive update requests and ordinary connection metadata such as IP address and the updater user agent.

## Authentication and publication

`SURequireSignedFeed` and `SUVerifyUpdateBeforeExtraction` are mandatory. A 32-byte public
Ed25519 key is embedded in release builds. The private key remains a GitHub Actions secret and
is passed to signing tools on stdin, never as a command-line argument. CI verifies the generated
feed signature and verifies the ZIP signature against the public key **inside the shipped app**.
A missing key, mismatched pair or invalid configuration fails publication; there is no unsigned fallback.

The feed is exposed only after an immutable per-build ZIP release has been uploaded. It never
points at a replaceable latest-main ZIP: an already-open update prompt therefore keeps a valid
archive and signature while a newer release is published. The rolling tag is moved after publication.
Package version, feed URL, signature requirements and disabled profiling/automatic installation are
audited. Source builds without a public key embed the framework but cannot query the live feed.
The new Community feed is separate from the retired pre-Community `appcast.xml` channel.

## Remaining trust and macOS limits

The app trusts code signed by the release Ed25519 key and the release pipeline. This is a real
standing code-update capability, not a network sandbox. GitHub/Sigstore provenance and SHA-256
inventories remain available; neither is a substitute for protecting the private signing key.

Community artifacts are ad-hoc code signed, **not Apple-notarized**. Ed25519 authenticates the
update but does not supply a stable Apple identity or guarantee macOS permission continuity.
An update may require fresh Goalong permissions. Existing history and settings are preserved.
Never disable Gatekeeper globally or remove quarantine to hide an installation problem. For a
blocked first launch, use **System Settings → Privacy & Security → Open Anyway** after verification.
Do not use `codesign --deep` to sign; nested components are signed explicitly. Deep signature
*verification* is used to reject a broken nested component.

An installed pre-updater build cannot update itself: it requires a single bootstrap reinstall.
See `UPDATES_AND_MACOS_PERMISSIONS.md` and `RELEASING.md`.
