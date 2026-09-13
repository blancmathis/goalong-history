---
context_room:
  id: assurance.supply-chain.dependencies
---

# Dependencies

The only remote Swift package is Sparkle **2.9.6**, exact-pinned in `Package.swift` and
`Package.resolved` (revision `ac2def288cbff5cfc7df3ffef6abdf45b72bcb0a`). SwiftPM verifies the binary
artifact checksum declared by that revision. Its bundled tools sign feeds and update archives.
The non-sandboxed app omits optional Sparkle XPC services and signs nested helpers inside-out.
No network, Mach exception, get-task-allow or library-validation-disabling entitlement is added.

`scripts/audit_update_dependency.py` and `scripts/verify_source_security.sh` reject an extra or
unpinned dependency, the retired uploader, a second app identity, or the no-op updater returning
to the active build graph. `scripts/verify_local_bundle.sh` verifies the embedded version, dynamic
linkage, nested signatures and exact update policy. Source builds without a public key have no feed.

Each release includes `security-capabilities.json`, `sbom.spdx.json`, `release-manifest.json` and
GitHub build-provenance attestations. These explicitly inventory Sparkle and its network capability.
CI actions remain pinned to commit SHAs. See `UPDATE-SECURITY.md` for residual trust boundaries.
