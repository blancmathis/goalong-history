# Updates and macOS permissions

This document describes the release behavior implemented for **Goalong History**. The public bundle, executable, Finder name, Dock name, app menus, permission labels, and release assets all use **Goalong History**. The bundle ID and existing data-folder names intentionally remain compatible with `LocalHistory` so existing history and settings are not split into a new installation identity. Until Developer ID is configured, macOS may require a one-time **Open Anyway** approval for the downloaded app. TCC may separately require a one-time permission approval when the running binary or its location changes.

## Product name and compatibility identity

The physical bundle is `Goalong History.app`, its executable is `Goalong History`, and both `CFBundleDisplayName` and `CFBundleName` are `Goalong History` in the base property list and the English and French localizations. The stable bundle ID remains `ai.goalong.localhistory`, and existing data remains under `~/Library/Application Support/LocalHistory/`.

This gives users one exact searchable product name without creating a second data directory or changing the update identity. Installers safely remove an older `LocalHistory.app`, `Go Long History.app`, or `GoLong History.app` copy after the replacement has been installed. The release DMG is mounted as **Goalong History**.

## Rolling updates from `main`

Every successful merge to `main` runs `.github/workflows/continuous-release.yml`.

The workflow:

1. builds a universal `arm64` + `x86_64` app;
2. ad-hoc code signs the app so Sparkle's nested helpers have a consistent local signature;
3. generates an EdDSA-signed update archive and Sparkle appcast;
4. moves the `latest-main` tag to the merged commit;
5. replaces the assets on the `latest-main` prerelease.

When the complete optional Apple credential set is present, the same workflow instead applies Developer ID, Hardened Runtime, notarization, and stapling before publishing. App Store distribution is not involved in either mode.

Installed update-enabled builds read this fixed feed URL:

```text
https://github.com/blancmathis/goalong-history/releases/download/latest-main/appcast.xml
```

Sparkle starts a quiet background update session at launch and when the dashboard becomes active. No dialog is shown when the app is current. The small update button appears only after Sparkle's standard user driver has prepared the detected release for presentation, so its first click opens the signed installation flow immediately. Every update action is serialized through one pending-request state: a click received while Sparkle is checking, presenting, or closing a previous session is retained until Sparkle either gives the update alert real user attention or reports a terminal result. If the user dismisses that alert, a later button click transparently prepares a new session in the background and opens the installer from that same click as soon as it is ready. Both the update badge and the footer check action show progress and reject repeated input while their request is pending. Choosing **Skip This Version** removes the matching badge immediately; choosing **Remind Me Later** keeps the release available for a later one-click retry.

### Required GitHub Actions configuration

The rolling workflow deliberately fails closed when either side of the Sparkle trust chain is absent:

Private GitHub Actions secret:

- `SPARKLE_PRIVATE_ED_KEY`

Non-secret GitHub Actions variable:

- `SPARKLE_PUBLIC_ED_KEY`

These are sufficient for the free release mode. The private key signs every archive and feed; the matching public key is embedded in the app so Sparkle can reject modified or untrusted updates.

### Optional Apple verification

Developer ID signing and notarization turn on automatically only when the complete Apple set is configured.

Optional private GitHub Actions secrets:

- `MACOS_CERTIFICATE_P12`
- `MACOS_CERTIFICATE_PASSWORD`
- `APPLE_API_PRIVATE_KEY`

Optional non-secret GitHub Actions variables:

- `APPLE_API_KEY_ID`
- `APPLE_API_ISSUER_ID`

The workflow rejects a partially configured Apple set, detects the exact signing identity after importing the P12, and refuses to continue unless it contains exactly one valid `Developer ID Application` identity. It validates the App Store Connect key with `notarytool` before building. Temporary P12 and API-key files are created with mode `600` and securely removed after use.

Never commit private values. The repository contains only their names, public configuration, and the release process.

## Development/source builds

A privacy-audited source build deliberately disables its update controls. The currently published `latest-main` DMG predates Agent Activity's direct-source, no-transcript-copy contract, so neither the app nor the installer may download or install it as an upgrade. Install the current checkout with the audited source workflow documented in the root README; it preserves the same bundle ID and data paths, so local history and settings remain available. Update controls may be enabled again only in a compatible release that carries the direct-source privacy marker and passes the installer's identity, signature, checksum, and update-policy checks.

The normal installer no longer silently falls back to a source build when a release is missing. Developers can still opt in explicitly with:

```bash
./install.sh --source
```

Source builds remain ad-hoc by default. A developer may explicitly supply an existing
local certificate through `LOCALHISTORY_CODESIGN_IDENTITY`. An `Apple Development`
identity produces a certificate-backed designated requirement without claiming Developer
ID distribution or notarization. Local identities are signed with Hardened Runtime and
`--timestamp=none`, so source installation does not contact Apple's timestamp service.
Only an explicit `Developer ID Application:` identity requests a trusted distribution
timestamp. The certificate's private key is never copied into the repository or
installer. TCC persistence must still be proved by replacing one build with another
signed by the same certificate and exercising real Accessibility and input callbacks.

## Permission readiness

The app requires Accessibility for foreground UI context. On macOS, Accessibility also grants the event-listening capability used by the recorder. `CGPreflightListenEventAccess()` reports only the narrower direct Input Monitoring grant, so it must not be treated as a second independent hard requirement.

Effective readiness is therefore:

```text
Accessibility available
AND
(event listening available directly OR provided through Accessibility)
```

This removes the false **Setup required** state where recording works but the direct Input Monitoring preflight returns false.

## Guided permission flow

Opening a permission now:

1. invokes the corresponding macOS request API;
2. opens the exact Privacy & Security pane;
3. displays a floating guide beside System Settings;
4. shows the exact path of the running app copy;
5. refreshes status automatically;
6. explains how to resolve stale or duplicate entries.

macOS TCC switches cannot be toggled silently by a normal third-party app. The user must make the final approval, but the app keeps that action to one clearly guided click and immediately detects completion.
