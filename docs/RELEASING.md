# Shipping a trusted macOS release

LocalHistory's normal installation path must never ask users to install Xcode or compile source code. Production releases are universal, Developer ID signed, notarized, and distributed as a drag-to-Applications DMG. Starting with the first Sparkle-enabled release, the same release also publishes a signed in-app update feed.

## Required repository secrets

Apple distribution:

- `MACOS_CERTIFICATE_P12` — base64-encoded Developer ID Application certificate (`.p12`)
- `MACOS_CERTIFICATE_PASSWORD` — password for that certificate
- `MACOS_CODESIGN_IDENTITY` — exact identity shown by `security find-identity -v -p codesigning`
- `APPLE_API_KEY_ID` — App Store Connect API key ID
- `APPLE_API_ISSUER_ID` — App Store Connect issuer ID
- `APPLE_API_PRIVATE_KEY` — base64-encoded `.p8` private key

Sparkle update signing:

- `SPARKLE_PUBLIC_ED_KEY` — base64 Ed25519 public key printed by Sparkle's `generate_keys`
- `SPARKLE_PRIVATE_ED_KEY` — exact contents of the private-key export produced by Sparkle's `generate_keys -x`

The EdDSA private key is independent of the Apple Developer ID certificate. Back it up in the same class of credential store as the Developer ID signing material. Never commit it, paste it into an issue, or ship it in the app bundle.

## One-time Sparkle bootstrap

On a trusted maintainer Mac:

```bash
./scripts/setup_sparkle_keys.sh
```

This creates or reuses the `goalong-localhistory` Sparkle key in the login Keychain and prints only the public key. Add that value to `SPARKLE_PUBLIC_ED_KEY` in GitHub Actions secrets.

To transfer the private key into GitHub Actions, export it temporarily to a secure path:

```bash
./scripts/setup_sparkle_keys.sh /secure/temporary/path/sparkle-private-key
gh secret set SPARKLE_PRIVATE_ED_KEY < /secure/temporary/path/sparkle-private-key
rm -f /secure/temporary/path/sparkle-private-key
```

Store a separate encrypted backup before deleting the temporary export. The app embeds only the public key.

Existing installations that predate Sparkle cannot discover Sparkle by themselves. Users must install the first Sparkle-enabled release through the existing DMG/update path once. Every later signed release can then be installed in-app.

## Release

1. Update `CHANGELOG.md` and the default version in `scripts/build_app.sh` when appropriate.
2. Merge a green pull request into `main`.
3. Create and push an annotated stable tag, for example `v0.5.0`.
4. The **Signed macOS release** workflow:
   - builds both architectures;
   - embeds the exact-pinned Sparkle framework;
   - explicitly signs Sparkle's nested helpers and the app without `--deep`;
   - signs with Developer ID and Hardened Runtime;
   - notarizes and staples the app;
   - creates the DMG and ZIP;
   - notarizes the DMG;
   - generates an EdDSA-signed Sparkle enclosure and signed appcast;
   - publishes `appcast.xml` beside the release artifacts.
5. Download the DMG from the release and test it on a clean standard macOS account.
6. From the previous production version, use the in-app update button and verify the complete N-1 → N download, validation, install, relaunch, and data-preservation path.

Stable clients read:

```text
https://github.com/blancmathis/goalong-history/releases/latest/download/appcast.xml
```

GitHub's `latest` release does not point at prereleases, so prerelease tags do not enter the stable feed.

## Update policy

- Sparkle is exact-pinned in `Package.swift`; CI fails if another remote Swift dependency is added or the pin drifts from `scripts/sparkle_release.env`.
- Scheduled checks are enabled by default once per day. They use Sparkle's gentle-reminder flow, so a background check only exposes the small in-app update indicator instead of stealing focus.
- Automatic download/install is disabled. The user explicitly opens Sparkle's standard update UI to review and install.
- System profiling and profile submission are disabled.
- The update feed is HTTPS and requires Sparkle's signed-feed validation.
- Update archives require the EdDSA key embedded as `SUPublicEDKey`, in addition to normal Apple code signing and notarization.

## Key rotation and recovery

Treat EdDSA rotation as a compatibility migration, not as a normal secret replacement. An installed old app trusts the public key already embedded in that old build. Therefore a replacement key needs an intermediate release that old clients can authenticate and that introduces the new trust material according to Sparkle's supported key-rotation procedure.

Do not rotate the Developer ID identity and Sparkle EdDSA key in the same release. Keep at least one previously shipped, working signing path stable during every trust transition, and test the transition from a real older notarized build before publishing broadly.

If the Sparkle private key is lost with no recoverable backup, do not invent or silently substitute a new key in CI. Stop automated release publication, recover the key if possible, and plan an explicit bootstrap release/update path.

Never bypass notarization, remove quarantine attributes, sign with `--deep`, or disable Sparkle signature verification to make a release pass.
