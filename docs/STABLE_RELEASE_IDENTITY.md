# Stable macOS permission identity

The former rolling and tagged release workflows forced ad-hoc signing, while the
last functioning local app used an Apple Development certificate. That changed
macOS's designated requirement on every update. A permission checkbox was not
proof that the running replacement satisfied the previously approved identity.

## Verified recovery

Re-signing the unchanged 0.6.23 app with the original certificate and restarting
normally restored AX trust, the functional AX probe and the direct input preflight
on the affected Mac. No TCC reset, removal/re-addition, permission toggle, trust
store edit or code-requirement weakening was performed. Recording consent stays
separate: recovery never silently enables a source.

## Release boundary

`Distribution/release-signing.json` pins the existing public certificate and team.
`verify_release_identity.sh` requires valid app and CLI signatures under that pin
and refuses ad-hoc and binary-hash-pinned designated requirements. The installer
refuses a downgrade to ad-hoc. Two actually different signed fixture binaries must
satisfy the same designated requirement; `test_stable_release_identity.sh` tests
this without launching them or interacting with TCC.

A new public release must use this identity. CI supports an explicitly configured
encrypted signing identity in repository secrets. It never exports a developer's
key and it never falls back to an ad-hoc **published** build when credentials are
missing. The import is confined to a temporary runner keychain that is deleted at
job completion; no system-wide certificate trust is added.

A maintainer can instead keep the private key on their Mac and explicitly supply
a locally signed archive using `signed_stage` and `signed_sha256` on the rolling
release workflow. That path pins the ZIP hash, validates archive paths and symbolic
links, requires the official main revision in the signed Info.plist, checks the
certificate, and runs source tests before packaging, signing the Sparkle feed and
publishing. A supplied archive must be built from the matching source revision;
when only distribution scripts change, re-signing a previous binary is permitted
only after independently verifying no app source/dependency/resource has changed.
This is an explicit release route, not an unattended local signing daemon.

## Limits

The available certificate is Apple Development, not a notarized Developer ID
Application identity. This fixes changing-binary identity; it does not remove
Gatekeeper's initial developer-approval requirement. A production Developer ID
migration must be planned and tested; never silently rotate the pinned key.

A pre-existing ad-hoc grant cannot be converted into authorization for arbitrary
new code. Some legacy users can require one final approval. The demonstrated
recovery restores an existing certificate-backed grant; it is not a universal
promise that OS consent or macOS bugs can be bypassed.
