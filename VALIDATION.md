# Validation notes — LocalHistory v0.3.2

Validation performed in the build workspace:

- `swift test`: 13 tests, 0 failures.
- SHA-256 known vector (`abc`).
- Salted commitment modification detection.
- Merkle inclusion and tamper tests.
- Application-only disclosure hides context openings.
- Private-minute disclosure does not reveal the event list or event count.
- Existing URL-redaction and private-browser marker tests preserved.
- `swiftc -frontend -parse -target x86_64-apple-macosx13.0` over every macOS app Swift file.
- `python3 -m py_compile` over the Python scripts and reference server.
- `bash -n` over the installer, uninstaller and audit scripts.
- Installer no longer expands an empty Bash array under `set -u`; release build/bin-path commands use explicit compatibility-mode branches suitable for macOS Bash 3.2.
- `scripts/audit_privacy_boundaries.sh` passes.
- Reference-server registration, one-time challenge and signed P-256 anchor upload exercised with FastAPI TestClient and a generated P-256 key.
- Public protocol request initializers compiled from a separate test module.
- Package manifest regenerated and verified before archive creation.

## Interface coverage

The v0.3 source includes:

- onboarding;
- dashboard navigation;
- runtime/permission status;
- day metrics and timeline;
- searchable activity sessions and local inspector;
- selective-disclosure editor and exact reveal/hide preview;
- safe private-only fallback when detailed events are unavailable;
- privacy, storage, identity and deletion controls;
- editable settings with validation, save and discard state;
- menu-bar entry points to the dashboard and sharing interface.

## Environment limitation

The build workspace is Linux. Therefore AppKit, SwiftUI for macOS, Core Graphics event taps, Secure Enclave and the real macOS App Attest runtime could not be executed here. The macOS-only branches were syntax-parsed for a macOS target, while the cross-platform cryptographic core and tests were built and executed normally.

`Install.command` performs native Swift tests and a native release build on the destination Mac before installing anything. A macOS GitHub Actions workflow is also included for repository-based validation.

Before production anti-cheat claims, validate the official Developer ID-signed/notarized build on supported Macs and connect a production App Attest verifier to the reference server.
