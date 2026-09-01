---
context_room:
  id: assurance.supply-chain.updates
---

# Update security

The single app contains no in-app updater, Sparkle framework, feed URL or background update
check. Updates are manual replacements from a signed and notarized GitHub release.

Public release workflows fail closed unless Developer ID and Apple notarization credentials are
complete. Each release includes SHA-256 inventories, an SBOM and a generated capability manifest
so users can inspect the exact artifact before replacement. Never bypass notarization, remove
quarantine attributes or use `codesign --deep` to hide a nested-signature failure.

Manual updates trade convenience for a smaller standing trust surface: a future publisher cannot
silently deliver code through the running app’s own updater. Users still must verify the release
source and signing identity before installing it.
