# Distribution assets

`AppIcon.svg` and `DMGBackground.svg` are reviewable vector source previews.

`scripts/generate_distribution_assets.swift` renders the production 1024×1024 app icon and 2× Finder DMG background with native AppKit during a macOS build. `build_app.sh` converts the generated icon into `LocalHistory.icns`; `package_release.sh` passes the generated background to `create-dmg`.

The public release is built as a universal `arm64 + x86_64` app, signed with Developer ID, submitted to Apple's notary service, stapled, packaged as both DMG and ZIP, and published with SHA-256 checksum files.
