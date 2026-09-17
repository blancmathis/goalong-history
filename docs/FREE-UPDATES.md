# Signed updates without a paid Apple subscription

## What is installed

Normal source builds and public releases include the **public** Ed25519 verification key
from `Distribution/sparkle-public-ed-key.txt`. It is the same key as the existing released
app; no key rotation or private-key export is performed. A conflicting CI override fails
closed. `LOCALHISTORY_DISABLE_UPDATES=1` explicitly builds without a feed and is rejected
when a configured release is required.

The fixed HTTPS feed and each unopened archive must authenticate successfully. Signed-feed
failures never expire into an unsigned fallback. The app checks at most hourly and installs
only after user approval. System profiling, background downloads, silent installation and
activity submission by the updater remain disabled. The real recording/sharing consent
settings are separate and are not changed by update configuration.

The update build namespace begins at `30000000`, followed by the GitHub run ID and attempt.
This migration epoch is deliberately higher than legacy date-numbered local builds, including
`20260916.084704`; it is not a date and must never be decreased. Version comparisons do not
mistake a newly published app for an older locally compiled app.

## Release signing without exporting the developer's private key

The two signatures serve different purposes:

- Ed25519 authenticates the feed and archive. Its existing private key stays in GitHub's
  encrypted `SPARKLE_PRIVATE_ED_KEY` release secret. Only the public key is committed.
- The app's existing pinned Apple Development code-signing identity is retained for macOS
  permission continuity. Using a certificate already available on the owner's Mac does not
  require a new paid subscription. It is not Developer ID notarization.

When an explicitly configured code-signing certificate is available in CI, the existing
hosted release path remains supported. When it is not, pushes to `main` prepare and test a
universal **unpublished signing input**, instead of failing on a missing Apple credential or
silently switching users to an ad-hoc identity. No new LaunchAgent, runner or persistent
process is installed on the owner's Mac.

Once that main run succeeds, the owner signs and authorizes publication with:

```sh
./scripts/publish_local_release.sh --run-id RUN_ID --publish
```

Without `--publish`, the script only prepares and verifies the locally signed bundle. With
it, the script checks the run, source revision, archive checksum, path safety, architecture,
embedded update policy, and the exact pinned app/CLI identity. It signs inside-out using
`codesign` locally, uploads **only the signed application**, then requests the existing CI
publication workflow. The private signing key is never exported.

The publication run independently validates the supplied ZIP and exact current main revision,
runs tests, generates Ed25519 signatures, and publishes an immutable archive before replacing
the feed. The final public-feed check downloads the actual served feed and archive, verifies
both signatures using only the shipped public key, and compares them with the tested build.
An uploaded staging archive or a queued workflow is **not** a published update.
The signing-input ZIP may be repackaged by CI. `verify_published_update.sh` expects
CI’s final packaged distribution, not the intermediate locally signed ZIP; its
exact archive checksum comparison must not be used across different ZIP packaging.

## Existing installations

An old app built without an updater needs one initial, verified replacement; pushing source
code cannot modify the installed bundle. Both public and source installers accept the
strict signed-update configuration and reject tampered policies, missing frameworks and
invalid bundle signatures. Replacements are staged with rollback support. The source
installer preserves the existing designated requirement rather than replacing it with a
changing ad-hoc identity.

Keep the data directory and existing login-item/recording choices intact. A changed code
identity may require explicit macOS reapproval; preserving an exact identity avoids an
intentional reset but is not a guarantee about every macOS permission decision. Never
reset TCC, disable Gatekeeper, grant permissions, or enable collection silently.

The distributed app is not Apple-notarized. A first download may need the normal macOS
**Privacy & Security → Open Anyway** confirmation. Notarization and Developer ID are distinct
from Sparkle's cryptographic update authentication.

References: https://sparkle-project.org/documentation/ and
https://sparkle-project.org/documentation/customization/ .
