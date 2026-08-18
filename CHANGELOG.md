# Changelog

## 0.4.0

### Installation and onboarding

- Replaced the target-Mac compilation flow with a universal prebuilt macOS application as the primary distribution path.
- Added a branded drag-to-Applications DMG for Intel and Apple Silicon Macs.
- Added a Developer ID signing, Hardened Runtime, notarization, stapling, verification, checksum, and GitHub Release workflow.
- Added a five-step native setup assistant inspired by the calm, focused installation experience of modern developer tools.
- Added a full privacy-boundary screen before any permission request.
- Split Accessibility and Input Monitoring into separate contextual permission steps with live state, direct System Settings links, retry controls, and graceful deferral.
- Added a final readiness check and an explicit start-at-login choice.
- Replaced the legacy hand-written LaunchAgent with Apple `SMAppService` login-item management.
- Added migration cleanup for the old LaunchAgent while preserving existing activity and settings.
- Reworked `Install.command` and `install.sh` as polished fallback installers that download and verify the signed release before using a source-build fallback.
- Reworked uninstallation with a native keep-data/remove-data choice and login-item cleanup.

### Product polish

- Added a production app icon and branded DMG background.
- Added release, distribution, and installation-experience documentation.
- Updated the English README and French guide around the no-Terminal public installation path.
- Expanded CI to validate shell scripts, build a real app bundle, verify signing metadata, and smoke-test packaging.

### Unchanged trust boundary

- Event schema, local-only detailed storage, private-browser suppression, cryptographic commitments, minute anchors, P-256 signatures, and selective-disclosure behavior are unchanged.
- Raw typed characters, screenshots, audio, camera, and clipboard capture remain prohibited.

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

### Preserved

- v0.2 cryptographic event commitments, Merkle roots, chains, minute sealing and P-256 signatures.
- Opaque live-anchor network boundary.
- Selective disclosure and private-only periods.
- Private-browser fail-closed behavior and no raw typed text.
