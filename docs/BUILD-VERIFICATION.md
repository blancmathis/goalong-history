---
context_room:
  id: assurance.build.verification
---

# Verify Goalong before downloading or installing

## Fast source review for a user or AI agent

From a clean checkout, run:

```bash
./scripts/verify_source_security.sh --with-tests
```

This checks one app identity, all-off defaults, compile-time exclusion of the retired uploader,
App Attest transport and updater, absence of remote Swift dependencies, read-only provider
boundaries, metadata-only AI indexing, the consent-brokered Screen Time CLI and focused tests.

An independent reviewer should also inspect the small trust spine directly:

```text
Package.swift
Sources/LocalHistoryApp/CapabilityConsentStore.swift
Sources/LocalHistoryApp/AppDelegate.swift
Sources/LocalHistoryQueryCLI/GoalongReadOnlyQueryBroker.swift
Sources/LocalHistoryApp/ChatGPT/CodexAppServerClient.swift
scripts/audit_privacy_boundaries.sh
scripts/verify_security_capabilities.py
```

## Build and inspect the exact app

```bash
LOCALHISTORY_ARCHS="$(uname -m)" ./scripts/build_app.sh
LOCALHISTORY_APP_PATH="dist/Goalong History.app" ./scripts/verify_local_bundle.sh
python3 scripts/verify_security_capabilities.py \
  --manifest dist/security-capabilities.json \
  --app "dist/Goalong History.app" \
  --edition unified
codesign --verify --strict --verbose=4 "dist/Goalong History.app"
codesign -d --entitlements :- "dist/Goalong History.app"
otool -L "dist/Goalong History.app/Contents/MacOS/Goalong History"
```

The build emits the single app plus `security-capabilities.json`, `sbom.spdx.json` and
`release-manifest.json`. The manifest intentionally reports `fullDiskAccessIsolationService` and
`authenticatedSensitiveReader` as `not-shipped`.

These checks prove properties of the inspected revision and artifact. They do not make a future
binary safe, prove full reproducibility or create an OS-enforced network deny.
