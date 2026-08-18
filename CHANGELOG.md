# Changelog

## 0.3.2

- Fixed `Install.command` on the macOS system Bash (3.2) when App Attest compatibility flags are empty.
- Replaced optional empty-array expansion under `set -u` with explicit scalar compatibility-mode branches.
- Applied the same fix to the macOS CI workflow.
- No event schema, cryptographic proof, privacy setting, or stored-history migration changed in this patch.

## 0.3.1

- Fixed macOS compilation of `DeviceIdentity.swift` by using an explicit `OSStatus` conversion.
- Fixed the Activity page module import required for `SuppressionReason`.
- Added public initializers for verification protocol request models used by the app target.
- Added a regression test for the cross-module protocol API.
- Improved installer diagnostics so unrelated compiler failures are no longer mislabeled as App Attest SDK issues.

## 0.3.0

### Added

- Native SwiftUI dashboard hosted in a reusable AppKit window.
- First-run onboarding and permission guidance.
- Overview with runtime status, daily metrics, 24-hour coverage timeline, top apps and recent sessions.
- Searchable/filterable Activity browser with detailed session inspector.
- Visual selective-disclosure editor with four privacy levels, bulk presets and exact share preview.
- Privacy & Security center covering permissions, data flow, storage, signing identity and safe deletion.
- Settings interface for capture, retention, verification, App Attest preference and exclusions.
- Menu-bar shortcuts to open the dashboard and Share section.
- Dashboard data reader that turns local JSONL/seals/receipts into understandable sessions and metrics.

### Changed

- Installer now builds and labels version 0.3.0 and opens the dashboard after installation.
- Main window minimum size and layout tuned for the complete dashboard.
- Configuration can be safely saved from the UI.
- Detailed deletion callbacks are marshalled back to the main thread before UI updates.

### Preserved

- v0.2 cryptographic event commitments, Merkle roots, chains, minute sealing and P-256 signatures.
- Opaque live-anchor network boundary.
- Selective disclosure and private-only periods.
- Private-browser fail-closed behavior and no raw typed text.
