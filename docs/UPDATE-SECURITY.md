---
context_room:
  id: assurance.supply-chain.updates
---

# Update security

The single app contains no in-app updater, Sparkle framework, feed URL or background update
check. Updates are manual replacements from the free GitHub Community release.

Public workflows require an ad-hoc signature, reject a certificate/notarization trust-mode mismatch,
and publish SHA-256 inventories, an SBOM, a generated capability manifest, an exact source-commit
manifest and a Sigstore-backed GitHub provenance attestation. Never disable Gatekeeper globally,
remove quarantine attributes as an installation shortcut or use `codesign --deep` to hide a
nested-signature failure. If macOS blocks the first launch, use only **System Settings → Privacy &
Security → Open Anyway** after verifying the artifact.

Manual updates trade convenience for a smaller standing trust surface: a future publisher cannot
silently deliver code through the running app’s own updater. Users still must verify the release
source, digest and GitHub provenance before installing it. Because this free build has no stable
Apple-issued signing identity, a replacement may require the user to grant Goalong permissions
again; this is disclosed rather than hidden.
