# Shipping a trusted macOS release

LocalHistory's normal installation path must never ask users to install Xcode or compile source code. Production releases are universal, Developer ID signed, notarized, and distributed as a drag-to-Applications DMG.

## Required repository secrets

- `MACOS_CERTIFICATE_P12` — base64-encoded Developer ID Application certificate (`.p12`)
- `MACOS_CERTIFICATE_PASSWORD` — password for that certificate
- `MACOS_CODESIGN_IDENTITY` — exact identity shown by `security find-identity -v -p codesigning`
- `APPLE_API_KEY_ID` — App Store Connect API key ID
- `APPLE_API_ISSUER_ID` — App Store Connect issuer ID
- `APPLE_API_PRIVATE_KEY` — base64-encoded `.p8` private key

## Release

1. Update `CHANGELOG.md` and the default version in `scripts/build_app.sh`.
2. Merge a green pull request into `main`.
3. Create and push an annotated tag, for example `v0.4.0`.
4. The **Signed macOS release** workflow builds both architectures, signs, notarizes, staples, packages, verifies, and publishes the release.
5. Download the DMG from the release and test it on a clean standard macOS account.

Never bypass notarization, remove quarantine attributes, or sign the app with `--deep`. Sign the final app deliberately after all bundle contents are in place.
