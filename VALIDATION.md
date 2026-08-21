# Validation notes — Goalong History v0.5.1

Validation performed on macOS 26.5.1 with Apple Silicon:

- `swift test`: 21 tests, 0 failures.
- `install.sh --source`: native release build and installation succeeded at `/Applications/Goalong History.app`.
- Installed bundle metadata reports version `0.5.1` and bundle identifier `ai.goalong.localhistory`.
- `codesign --verify --deep --strict`: installed app is valid and satisfies its designated requirement.
- Installed executable is native arm64 for this Mac.
- Clean first launch displayed the five-step setup assistant; live Accessibility and Input Monitoring status updates were observed in the onboarding UI.
- SHA-256 known vector (`abc`).
- Salted commitment modification detection.
- Merkle inclusion and tamper tests.
- Application-only disclosure hides context openings.
- Private-minute disclosure does not reveal the event list or event count.
- Existing URL-redaction and private-browser marker tests preserved.
- Legacy signing keys from ad-hoc builds are no longer reopened after a code-signature change.
- Two consecutive minute seals were created with the replacement scoped Keychain identity and no SecurityAgent/password window appeared.
- Explicit Keychain authentication cancellation suspends further signing attempts for that launch instead of retrying once per minute.
- `python3 -m py_compile` over the Python scripts and reference server.
- `bash -n` over the installer, uninstaller and audit scripts.
- `scripts/audit_privacy_boundaries.sh` passes.
- Reference-server registration, one-time challenge and signed P-256 anchor upload exercised with FastAPI TestClient and a generated P-256 key.
- Public protocol request initializers compiled from a separate test module.
- The macOS quality-gate workflow for the v0.4.0 merge completed successfully on GitHub Actions.

## Interface coverage

The v0.4 source includes:

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

## Distribution limitation

The local source build is ad-hoc signed and is intended for development. The public no-Terminal installation path requires an official Developer ID-signed and notarized GitHub Release. No such v0.5.1 release has been published yet, so `Install.command` currently falls back to the verified source-build path on a Mac with the Swift toolchain installed.

The release workflow builds a universal Intel and Apple Silicon app, signs it with Hardened Runtime, notarizes and staples the package, and publishes checksummed DMG and ZIP artifacts when the required private Apple credentials are configured.

Before production anti-cheat claims, validate the official Developer ID-signed/notarized build on supported Macs and connect a production App Attest verifier to the reference server.
