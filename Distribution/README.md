# Distribution assets

`AppIcon.svg` and `DMGBackground.svg` are reviewable vector source previews.

`scripts/generate_distribution_assets.swift` renders the production 1024×1024 app icon and 2× Finder DMG background with native AppKit during a macOS build. `build_app.sh` converts the generated icon into the internal `LocalHistory.icns` resource; `package_release.sh` passes the generated background to `create-dmg`.

The public release is one universal `arm64 + x86_64` Community Build. It is ad-hoc code signed for bundle-integrity checks, not Apple-notarized, packaged as both DMG and ZIP, and published with SHA-256 files, manifests, an SPDX SBOM and Sigstore-backed GitHub provenance.
