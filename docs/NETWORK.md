---
context_room:
  id: assurance.security.network
---

# Network boundary

## One application

Goalong has one public build, not Local and Connected editions. The app target physically excludes
the retired commitment uploader and App Attest transport. It declares no network client entitlement
and embeds one framework: the pinned Sparkle 2.9.6 updater.

## Intentional external paths

Software updates use Sparkle. Checks run at launch and hourly unless disabled in Settings. They
fetch one fixed feed,
`https://github.com/blancmathis/goalong-history/releases/download/latest-main/community-appcast.xml`,
then the signed release archive it names on GitHub or its CDN, or a smaller signed delta from the
same release when one matches the installed build. They send no activity data or system
profile, and installation needs the user's approval. See [`UPDATE-SECURITY.md`](UPDATE-SECURITY.md).

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

### Ambiance packs — explicit download

The optional Ambiance module defaults to off. Its compiled catalog pins the HTTPS
archives `orchestra.tar` and `textures.tar` under
`https://github.com/blancmathis/goalong-history/releases/download/ambiance-packs-v1/`.
The release has not been created or uploaded by this task. An explicit `download(id)`
action starts one ephemeral GET in `AmbiancePackDownloader.swift`. There is no launch,
activation, timer or background download, retained session, cookie, cache, credential,
custom header, member/Mac identifier or automatic retry. The initial request must be
the exact catalog URL on `github.com`, without a query. Only one redirect, from that
URL to `https://release-assets.githubusercontent.com` on port 443, is allowed. An
omitted port means HTTPS port 443. A second redirect, another host, HTTP, another
port, or a first request to the asset host is refused. The security inventory
includes this sixth intentional external path.

The owner's clarification of 2026-10-04 permits GitHub's own signed redirect query,
preserved exactly as received. Goalong never constructs or changes a query string,
logs, stores or displays the signed URL. The redirected request is a fresh plain
GET without forwarded headers or a body. Transport errors are replaced by a pack
error before reaching the UI, since Foundation errors can contain the failing URL.
The earlier HEAD observation identified this release-asset host; no GitHub pack is
downloaded by this task. See [`AMBIANCE-IMPLEMENTATION.md`](AMBIANCE-IMPLEMENTATION.md).

An explicit install action can instead read pinned archives from the absolute local
folder `GOALONG_AMBIANCE_PACK_DIR`. It verifies the exact size and SHA-256, extracts only
regular flat files into a private staging directory, then renames the complete pack to
`AppPaths.applicationSupportDirectory/Ambiance/<packId>/`. This development override
makes no network request. Debug builds also accept `GOALONG_AMBIANCE_PACK_TEST_URL`,
strictly `http://127.0.0.1:<port>/`, for the same catalog archives served locally.
That seam refuses every redirect and is absent from Release builds. Downloaded
temporary files are deleted after installation, failure or cancellation. Personal
audio remains at its original path and is never uploaded.

## Honest limitation

The main app is not App-Sandboxed. Source-level restrictions on these reviewed paths are not an
OS-enforced network deny. The chosen website receives the disclosed fields and token; its account
isolation, token revocation and sharing enforcement require separate server-side validation.
Verify the exact source and bundle with [`BUILD-VERIFICATION.md`](BUILD-VERIFICATION.md).
