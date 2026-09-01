# Releasing the single Goalong app

Goalong’s public installation path is one universal, Developer ID signed and Apple-notarized app
inside a DMG/ZIP. Users are not asked to install Xcode.

Required GitHub credentials:

- `MACOS_CERTIFICATE_P12` and `MACOS_CERTIFICATE_PASSWORD`;
- the configured Developer ID signing identity;
- App Store Connect API key ID, issuer ID and private key for notarization.

The rolling and stable workflows:

1. run tests, privacy/source audits and script validation;
2. build `Goalong History.app` for arm64 and x86_64;
3. verify the unified bundle identity, signatures, entitlements and all-off capability manifest;
4. notarize and staple the app/DMG;
5. publish DMG, ZIP, SHA-256 files, SBOM, capability manifest and release manifest.

There is no Sparkle key, appcast or automatic update channel. A release must not publish an ad-hoc
artifact. Preserve the stable bundle identifier and signing identity; test a real replacement to
check macOS permission continuity before broad publication.
