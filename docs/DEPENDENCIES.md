---
context_room:
  id: assurance.supply-chain.dependencies
---

# Dependencies

The single Goalong Swift package currently declares no remote Swift package dependency.
`Package.resolved` therefore contains an empty `pins` list. System frameworks and libraries are
listed in `Package.swift`; CI actions are pinned to immutable commit SHAs.

Every built release publishes:

- `security-capabilities.json` for inspected code objects, entitlements and capability states;
- `sbom.spdx.json` for the exact artifact inventory;
- `release-manifest.json` for artifact hashes.

`scripts/verify_source_security.sh` fails if a remote Swift dependency, second app identity,
retired transport or updater re-enters the active build graph.
