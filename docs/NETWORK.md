---
context_room:
  id: assurance.security.network
---

# Network boundary

## One application

Goalong has one public build, not Local and Connected editions. The app target physically excludes
the retired commitment uploader, App Attest transport and Sparkle updater. It declares no network
client entitlement and embeds no framework.

## Intentional external paths

When the user separately enables ChatGPT analysis, Goalong may launch the reviewed local Codex
binary with the fixed `app-server` argument. Codex owns its authenticated ChatGPT transport.
Goalong passes a bounded daily context and does not expose arbitrary commands, executables,
workspace roots or inherited cloud/API credentials to that child process.

For [selected website analysis](SITE-ANALYSIS.md), the context is only the selected
JSON request. Contextual session analysis uses the same confined transport with a separately reviewed native interval and selected evidence excerpts. A separate local login profile and restricted temporary workspace are
required; the exported draft is never automatically sent to the website.

The optional website connector is a separate first-party HTTP path. Explicit `goalong send-site`, reviewed native send buttons, and the separately enabled schedule send selected saved data. `export-site` and the native preview stay offline; enabling a source or
remembering a website does not enable scheduling. The opt-in schedule sends the previous day after the chosen hour only while the app runs, using the reviewed device/field/mask selection and one destination. Selected numbered parts of saved recaps and domains are eligible; an active mask excludes both. One-off comments and past contextual-session analyses are never repeated. A failed or uncertain attempt stops scheduling and is never retried automatically. Source consent is checked again immediately before sending. The exact command contract is in
[`CLI.md`](CLI.md#website-export-and-account-submission); the field and audience boundary is in
[`PRIVACY.md`](PRIVACY.md#website-disclosure).

The sender posts to `/api/goalong/v1/import` at the user-selected HTTPS origin, using an upload-only
bearer token read from a specifically selected, owner-owned regular file with mode `0600`.
The file remains local; its token is sent in the Authorization header, never in command arguments,
stdout or error messages. The ephemeral session uses no cookies, cache or ambient credentials,
refuses redirects and performs no automatic retry. Remote plain HTTP is rejected; literal loopback
and `localhost` HTTP origins are permitted only for development. The client bounds the request
duration and receipt size. An uncertain failure requires checking the site's import history before
retrying. Review the implementation in
[`GoalongSiteSubmission.swift`](../Sources/LocalHistoryQueryCLI/GoalongSiteSubmission.swift).

Goalong may also open a reviewed HTTPS documentation or account-login URL after an explicit user
action. It does not perform that HTTP request itself.

## Honest limitation

The main app is not App-Sandboxed. Source-level restrictions on these reviewed paths are not an
OS-enforced network deny. The chosen website receives the disclosed fields and token; its account
isolation, token revocation and sharing enforcement require separate server-side validation.
Verify the exact source and bundle with [`BUILD-VERIFICATION.md`](BUILD-VERIFICATION.md).
