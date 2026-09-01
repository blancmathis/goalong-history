---
context_room:
  id: assurance.security.reproducible-builds
---

# Reproducible-build scope

## Summary

Goalong publishes the inputs and hashes needed for comparison, but byte-for-byte independent reproducibility is not yet proven. macOS timestamps, Developer ID signatures, notarization tickets and DMG metadata are expected sources of nondeterminism.

## Defines

Current reproducibility scope, build inputs, comparison procedure and known nondeterminism.

## Does not define

Release signing custody or a SLSA provenance level not yet achieved.

## Current comparison surface

- exact Git commit and dirty state in `release-manifest.json`;
- exact Swift package revision/version in `Package.resolved` and the SPDX SBOM;
- executable SHA-256 values, linked libraries, entitlements, Team ID, CDHash and designated requirement in `security-capabilities.json`;
- pinned GitHub Actions commits;
- declared app version, build number, architectures and edition.

## Independent comparison

Check out the recorded commit, use the Xcode/Swift versions reported by CI, build the same edition and compare the unsigned executable/library contents before signing. Then compare semantic signing properties and entitlements separately. Do not expect timestamped signatures, notarization staples or the final DMG bytes to match.

## Not yet proven

- a hermetic build environment;
- normalized `SOURCE_DATE_EPOCH` across Swift, asset generation and packaging;
- independent third-party reproduction of a release;
- signed SLSA/in-toto provenance;
- deterministic pre-signature bundle root across arm64 and x86_64 builders.

Until those exist, release notes must say “verifiable inventory” rather than “reproducible build.”
