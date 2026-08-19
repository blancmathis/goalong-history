# Updates and macOS permissions

This document describes the production behavior implemented for **Go Long History**. Internal executable, bundle ID, data-folder, and legacy migration names intentionally remain `LocalHistory` so existing history and settings are not split into a new installation identity. macOS may still require a one-time approval for a newly signed app copy because TCC also evaluates the running binary and its location.

## Product name and compatibility identity

The physical compatibility bundle remains `LocalHistory.app`, with executable `LocalHistory` and bundle ID `ai.goalong.localhistory`. Its English and French `InfoPlist.strings` localizations expose **Go Long History** to Finder, the Dock, app menus, permission panels, and the app UI. The unlocalized `CFBundleDisplayName`/`CFBundleName` intentionally match the physical filename because Finder ignores a localized display name when the base bundle name and filename disagree.

This gives users the correct product name without creating a second data directory, changing the update identity, or abandoning the existing installation path. The release DMG is also mounted as **Go Long History**.

## Rolling updates from `main`

Every successful merge to `main` runs `.github/workflows/continuous-release.yml`.

The workflow:

1. builds a universal `arm64` + `x86_64` app;
2. signs it with Developer ID and Hardened Runtime;
3. notarizes and staples the app and DMG;
4. generates an EdDSA-signed Sparkle appcast;
5. moves the `latest-main` tag to the merged commit;
6. replaces the assets on the `latest-main` prerelease.

Installed signed builds read this fixed feed URL:

```text
https://github.com/blancmathis/goalong-history/releases/download/latest-main/appcast.xml
```

Sparkle performs a probe at launch and when the dashboard becomes active. No dialog is shown when the app is current. When a newer build exists, a small button appears at the bottom-left of the sidebar; clicking it opens Sparkle's signed installation flow.

### Required GitHub Actions secrets

The rolling workflow deliberately fails closed when any release credential is absent:

- `MACOS_CERTIFICATE_P12`
- `MACOS_CERTIFICATE_PASSWORD`
- `MACOS_CODESIGN_IDENTITY`
- `APPLE_API_KEY_ID`
- `APPLE_API_ISSUER_ID`
- `APPLE_API_PRIVATE_KEY`
- `SPARKLE_PUBLIC_ED_KEY`
- `SPARKLE_PRIVATE_ED_KEY`

Never commit those values. The repository contains only their names and the public release process.

## Development/source builds

A source build does not contain the production Sparkle public key and cannot safely self-update. It now shows **Enable app updates** in the sidebar. That button downloads the current signed DMG once. The signed app keeps the same bundle ID and data paths, so local history and settings remain available. The guided permission flow handles any one-time approval macOS requests for the signed copy.

The normal installer no longer silently falls back to a source build when a signed release is missing. Developers can still opt in explicitly with:

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
