# Updates and macOS permissions

This document describes the release behavior implemented for **Go Long History**. Internal executable, bundle ID, data-folder, and legacy migration names intentionally remain `LocalHistory` so existing history and settings are not split into a new installation identity. Until Developer ID is configured, macOS may require a one-time **Open Anyway** approval for the downloaded app. TCC may separately require a one-time permission approval when the running binary or its location changes.

## Product name and compatibility identity

The physical compatibility bundle remains `LocalHistory.app`, with executable `LocalHistory` and bundle ID `ai.goalong.localhistory`. Its English and French `InfoPlist.strings` localizations expose **Go Long History** to Finder, the Dock, app menus, permission panels, and the app UI. The unlocalized `CFBundleDisplayName` and `CFBundleName` intentionally remain `LocalHistory` so they match the physical bundle filename; Finder can then honor the localized public name.

This gives users the correct product name without creating a second data directory, changing the update identity, or abandoning the existing installation path. The release DMG is mounted as **Go Long History**.

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

Sparkle performs a probe at launch and when the dashboard becomes active. No dialog is shown when the app is current. When a newer build exists, a small button appears at the bottom-left of the sidebar; clicking it opens Sparkle's signed installation flow.

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

A source build does not contain the release Sparkle public key and cannot safely self-update. It now shows **Enable app updates** in the sidebar. That button downloads the current release DMG once. The release app keeps the same bundle ID and data paths, so local history and settings remain available. Until Apple verification is added, macOS may require **Open Anyway** on this first downloaded copy. The guided permission flow handles any separate one-time permission requests for the replacement copy.

The normal installer no longer silently falls back to a source build when a release is missing. Developers can still opt in explicitly with:

```bash
./install.sh --source
```

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
