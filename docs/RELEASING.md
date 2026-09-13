# Releasing the single Goalong app

The public app is one universal Community Build (ad-hoc signed, not Apple-notarized). Every
successful `main` push runs tests, builds arm64/x86_64 and publishes an authenticated update.

Required GitHub secrets are `SPARKLE_PRIVATE_ED_KEY` and `SPARKLE_PUBLIC_ED_KEY` (the public
key may alternatively be a repository variable for compatibility). No Apple credential is required.
The repository remains public; Actions need contents, id-token, attestations and artifact-metadata
write permissions. Private keys must never be logged, committed, or passed on command lines.

The rolling workflow runs the full test suite, audits the bundle and capabilities, creates ZIP/DMG,
signs the archive and appcast, checks the signature against the embedded key, then generates
inventories and GitHub provenance attestations. It uploads the ZIP to an immutable `main-RUN_ID-ATTEMPT`
release. Manual-download assets follow; the authenticated `community-appcast.xml` is uploaded last,
then `latest-main` moves to the commit. Do not overwrite immutable archives or reorder these steps.
Publication is not cancelled midway when a new commit arrives.

Build numbers use migration epoch `20260913`, followed by `RUN_ID / 10000` and
`(RUN_ID % 10000) * 100 + ATTEMPT`. GitHub run IDs order both tagged installers and rolling
releases; workflow-local run numbers cannot safely order two workflows. Attempts must be 1–99.
Do not revert to `5000.x.y`: public `20260912.4` installs compare newer than that old range.
Marketing versions alone cannot fix detection. Superseded or non-main runs cannot replace the feed.

Before publication run `swift test`, `python3 scripts/test_update_policy.py`,
`python3 scripts/test_site_submission_policy.py`, `scripts/verify_source_security.sh` and the
release/signing script checks. Export integration tests run under UTC, America/Chicago and Europe/Paris;
their synthetic fixtures must use the runtime timezone, while DST-specific fixtures remain fixed.
Never weaken the production timezone/privacy checks or skip failing tests to publish an update.

Release notes must disclose initial bootstrap installation for old no-updater builds, user-approved
installation, configurable hourly checks, and the ad-hoc macOS permission limitation. Preserve
bundle identity and application data. Never claim Apple notarization or guaranteed permission continuity.
See `UPDATE-SECURITY.md` for authentication and remaining publisher trust.
