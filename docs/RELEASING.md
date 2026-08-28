# Shipping macOS releases

Goalong History's normal installation path must never ask users to install Xcode or compile source code. Rolling releases are universal, distributed as a drag-to-Applications DMG, authenticated for in-app updates with Sparkle EdDSA, Developer ID signed, and notarized by Apple. The publication job is skipped until every Apple signing credential is configured.

## Required rolling-release configuration

Sparkle update signing:

- Actions variable `SPARKLE_PUBLIC_ED_KEY` — base64 Ed25519 public key printed by Sparkle's `generate_keys`
- Actions secret `SPARKLE_PRIVATE_ED_KEY` — exact contents of the private-key export produced by Sparkle's `generate_keys -x`

This pair authenticates the Sparkle archive and feed, but is not sufficient by itself to publish a public macOS update. The Apple values below are also required.

Each rolling publication reads the last version from the live signed appcast and increments its patch component once: `0.5.1` becomes `0.5.2`, then `0.5.3`, and so on. The repository [`VERSION`](../VERSION) file is a version floor for intentional larger jumps. For example, setting it to `0.6.0` makes the next rolling publication use `0.6.0`; later publications continue automatically with `0.6.1`, `0.6.2`, etc. Sparkle keeps using the separate `5000.x.y` bundle build number for monotonic update ordering.

## Required Apple verification

Configure the complete set below for Developer ID, Hardened Runtime, notarization, and stapling:

- `MACOS_CERTIFICATE_P12` — base64-encoded Developer ID Application certificate (`.p12`)
- `MACOS_CERTIFICATE_PASSWORD` — password for that certificate
- Actions variable `APPLE_API_KEY_ID` — App Store Connect API key ID
- Actions variable `APPLE_API_ISSUER_ID` — App Store Connect issuer ID
- `APPLE_API_PRIVATE_KEY` — base64-encoded `.p8` private key

The workflow detects the Developer ID identity from the imported P12. It rejects a partially configured Apple set instead of silently publishing a partly signed release.

The EdDSA private key is independent of the Apple Developer ID certificate. Back it up in the same class of credential store as the Developer ID signing material. Never commit it, paste it into an issue, or ship it in the app bundle.

## One-time Sparkle bootstrap

On a trusted maintainer Mac:

```bash
./scripts/setup_sparkle_keys.sh
```

This creates or reuses the `goalong-localhistory` Sparkle key in the login Keychain and prints only the public key. Add that value to the `SPARKLE_PUBLIC_ED_KEY` GitHub Actions variable.

To transfer the private key into GitHub Actions, export it temporarily to a secure path:

```bash
./scripts/setup_sparkle_keys.sh /secure/temporary/path/sparkle-private-key
gh secret set SPARKLE_PRIVATE_ED_KEY < /secure/temporary/path/sparkle-private-key
rm -f /secure/temporary/path/sparkle-private-key
```

Store a separate encrypted backup before deleting the temporary export. The app embeds only the public key.

Existing installations that predate Sparkle cannot discover Sparkle by themselves. Users must install the first Sparkle-enabled release through the existing DMG/update path once. Every later EdDSA-authenticated release can then be installed in-app.

## Rolling release

1. Merge a green pull request into `main`.
2. The **Continuous Sparkle macOS release** workflow:
   - increments the last published visible version by one patch, unless `VERSION` requests a larger jump;
   - builds both architectures;
   - embeds the exact-pinned Sparkle framework;
   - explicitly signs Sparkle's nested helpers and the app without `--deep`;
   - skips publication when any Apple credential is absent, without building an ad-hoc artifact;
   - applies Developer ID signing and notarization;
   - creates the DMG and ZIP;
   - generates an EdDSA-signed Sparkle enclosure and signed appcast;
   - replaces `latest-main` and its release assets.
3. Download the DMG from the release and test it on a clean standard macOS account.
4. From the previous rolling version, use the in-app update button and verify the complete N-1 → N download, validation, install, relaunch, and data-preservation path.

Rolling clients read:

```text
https://github.com/blancmathis/goalong-history/releases/download/latest-main/appcast.xml
```

## Update policy

- Sparkle is exact-pinned in `Package.swift`; CI fails if another remote Swift dependency is added or the pin drifts from `scripts/sparkle_release.env`.
- Scheduled checks are enabled by default once per day. They use Sparkle's gentle-reminder flow, so a background check only exposes the small in-app update indicator instead of stealing focus.
- Automatic download/install is disabled. The user explicitly opens Sparkle's standard update UI to review and install.
- System profiling and profile submission are disabled.
- The update feed is HTTPS and requires Sparkle's signed-feed validation.
- Update archives require the EdDSA key embedded as `SUPublicEDKey`. Developer ID signing and notarization are additionally required for publication so macOS can recognize updates as the same app for privacy permissions.

## Key rotation and recovery

Treat EdDSA rotation as a compatibility migration, not as a normal secret replacement. An installed old app trusts the public key already embedded in that old build. Therefore a replacement key needs an intermediate release that old clients can authenticate and that introduces the new trust material according to Sparkle's supported key-rotation procedure.

Do not rotate the Developer ID identity and Sparkle EdDSA key in the same release. Keep at least one previously shipped, working signing path stable during every trust transition, and test the transition from a real older build before publishing broadly.

If the Sparkle private key is lost with no recoverable backup, do not invent or silently substitute a new key in CI. Stop automated release publication, recover the key if possible, and plan an explicit bootstrap release/update path.

Never remove quarantine attributes, sign with `--deep`, or disable Sparkle signature verification to make a release pass. Once Developer ID is enabled, never bypass a failing notarization step.
