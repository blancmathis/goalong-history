# Releasing the single Goalong app

Goalong’s public installation path is one universal free Community Build inside a DMG/ZIP. It is
ad-hoc code signed for bundle-integrity validation, but it is not Apple-notarized. Users are not
asked to install Xcode or pay for Apple Developer Program membership.

Required GitHub configuration:

- Actions must have `contents: write`, `id-token: write`, `attestations: write` and
  `artifact-metadata: write` permissions;
- the repository must remain public for GitHub Free artifact attestations;
- no Apple signing or notarization credential is used.

The rolling and stable workflows:

1. run tests, privacy/source audits and script validation;
2. build `Goalong History.app` for arm64 and x86_64;
3. require the expected ad-hoc trust mode and verify bundle identity, signatures, entitlements and
   the all-off capability manifest;
4. create the DMG/ZIP and their SHA-256 files;
5. generate a Sigstore-backed GitHub build-provenance attestation;
6. publish DMG, ZIP, SHA-256 files, SBOM, capability manifest and release manifest.

There is no Sparkle key, appcast or automatic update channel. Release notes and installation docs
must say that Gatekeeper can require **Privacy & Security → Open Anyway** and that a changed ad-hoc
identity can make macOS request Goalong permissions again. Never recommend disabling Gatekeeper
globally. Preserve the stable bundle identifier, exact-source manifest and GitHub provenance, and
test a real replacement before broad publication.

The trust boundary is explicit: SHA-256 files on the same release protect against accidental
corruption but do not independently authenticate GitHub. The GitHub/Sigstore attestation binds each
artifact digest to the repository workflow and commit; it still does not make the build notarized or
byte-for-byte reproducible.
