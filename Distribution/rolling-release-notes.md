Goalong History `{version}` (build `{build}`), built from `{commit}` on `main`.

This is the single free Community Build. It is signed with a pinned, stable Apple Development identity. It is not Developer ID notarized. On first launch, macOS may require **System Settings → Privacy & Security → Open Anyway**. Never disable Gatekeeper globally.

Verify the downloaded SHA-256 file and `release-manifest.json`. GitHub also publishes a Sigstore-backed build-provenance attestation; with GitHub CLI, run `gh attestation verify <downloaded-file> --repo blancmathis/goalong-history`.

Updates are offered in the app through an Ed25519-authenticated Sparkle feed and archive. Click **Update available** or **Check for Updates…**, then approve installation. The first replacement of an older build without an updater must be installed once manually. Automatic installation is disabled.

Subsequent builds keep the same signing identity so updates do not intentionally invalidate permissions. Migration from old ad-hoc builds may require one final macOS approval. Existing history and settings remain in place. No activity contents or system profile are sent by the updater.
