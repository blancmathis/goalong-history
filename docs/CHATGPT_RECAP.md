# ChatGPT recap integration

Goalong History can use a user's ChatGPT plan through the local `codex
app-server` protocol to synthesize an evidence-aware daily recap. This is not an
OpenAI API-key integration: API credentials are rejected and the app starts the
Codex browser flow with `type: "chatgpt"`.

This feature has two different data contracts:

- local agent conversations follow the [Agent Activity direct-source
  contract](../Features/AgentActivity/README.md): Goalong reads the provider's
  original storage and never puts transcript bodies or summaries in the Agent
  Activity index;
- importing a ChatGPT data export is a separate, explicit opt-in operation that
  writes a normalized local copy of selected conversation content.

In the app, open **Settings → AI analysis with ChatGPT → Connect ChatGPT**. Goalong
opens OpenAI's browser sign-in and uses the Codex usage included with the selected
ChatGPT plan. It does not ask for or accept an OpenAI API key. The same setup is
also reachable from the **AI recap** card on Overview.

## Daily recap data flow

1. Goalong runs the selected day's local Activity Analysis and Computer History
   pass against the raw local journal. If that source is absent, Activity
   Analysis is empty while a retained last-known-good Computer History view can
   still be reused; that retained view counts as meaningful recap evidence and
   the source manifest explicitly labels the local journal unavailable.
2. It adds Apple Screen Time, content-free counts and source metadata computed
   by bounded direct reads of enabled local agent sources, and selected-day
   messages from an optional normalized ChatGPT import.
3. Common credential-like patterns are redacted from every assembled section.
   Independent section quotas prevent one source from displacing all others; the
   rendered data is capped at 175,000 characters and the complete prompt at
   180,000.
4. Goalong starts a locally discovered `codex` executable as `codex app-server`
   over JSONL stdio using an app-owned, isolated `CODEX_HOME`.
5. On explicit connection, Codex performs the ChatGPT browser login; normal
   account checks and generation can ask Codex to refresh account state. Goalong
   reads account metadata but never parses or copies OAuth token values.
6. One ephemeral Codex thread receives the assembled context inline and is asked
   to return Markdown with fixed sections. Goalong accepts any non-empty final
   text within the output bounds; it does not validate that section structure.
7. Goalong commits the generated recap locally as canonical JSON plus a
   regenerable Markdown mirror, then makes a best-effort attempt to remove the
   temporary run directory. Persistence runs common-pattern redaction again and
   rejects Markdown above 1 MiB or its recap JSON above 8 MiB.

The app-server bridge rejects an incoming or outgoing protocol line above 8 MiB,
a stdout buffer above 8 MiB plus one 64 KiB read chunk, more than 20,000 decoded
messages, or a deferred queue above 512 messages/16 MiB. Recap collection allows
at most 2 MiB of candidate streamed/final text and accepts at most 1 MiB of final
Markdown; stderr capture is clipped at 64 KiB and surfaced error detail at 4 KiB.
Empty protocol lines have separate 4,096-line/64 KiB bounds. Request writes use
non-blocking polling under the request deadline, so a child that stops reading
stdin cannot hold the app indefinitely. Streaming preview publishes only complete
redacted lines, retaining a bounded tail until it can safely decide whether a
credential-like pattern crosses protocol deltas. Exceeding a limit fails the run
instead of persisting or displaying an unbounded raw response.

Agent transcript bodies and direct-read working summaries are excluded from the
recap context as well as Agent Activity storage; the recap sees only content-free
agent counts and metadata. The assembled prompt is not written into Agent
Activity storage. The generated recap is a persisted derived output and may
repeat or paraphrase other selected evidence, including Computer History and an
imported ChatGPT day. Generating it necessarily sends the bounded context to
OpenAI through the user's ChatGPT/Codex account. Common-pattern redaction is
applied to the complete assembled context, but it remains a bounded pattern
filter rather than proof that every possible secret was found. The separate
Activity Analysis section can contain bounded semantic detail derived from the
raw Goalong event journal; the no-body statement here is specific to provider
transcripts in Agent Activity.

Computer History contributes its bounded derived projection. For a compacted day
that projection contains at most 256 episodes, 640 interactions, and 384
resources; omitted raw-event detail is not sent through this path. The rendered
quotas are 90,000 characters for Computer History detail, 40,000 for Activity
Analysis, 8,000 each for Screen Time and Agent Activity, 20,000 for imported
chats, and 8,000 reserved for the source manifest. Exact Computer History
coverage is placed outside the clipped detail inside its quota, and the manifest
uses the same `sourceCounts` that the saved recap records. Every section and the
manifest therefore remain present even when one source is truncated.

After the shared source cycle, the recap rereads the stored Activity Analysis
through a stable no-follow regular-file read capped at 32 MiB. A replacement,
linked node, inaccessible file, or oversized stored analysis fails the recap
instead of decoding an untrusted or unbounded artifact.

## Existing ChatGPT conversations: explicit copy exception

Connecting a ChatGPT account does not expose existing ChatGPT conversations to
Goalong. To include them, the user must separately choose `conversations.json`
from a ChatGPT data export.

That import is intentionally different from Agent Activity's no-copy model. It
creates:

```text
~/Library/Application Support/LocalHistory/chatgpt/history/
└── normalized-conversations.json
```

The normalized archive stores:

- a stable bounded conversation identifier derived from the source export or a
  positional fallback, and a stable bounded message identifier derived from the
  source message or its mapping-node key;
- conversation title;
- `user` or `assistant` role;
- message timestamp;
- sanitized message text, bounded to 16,000 characters per message;
- import time, conversation/message counts, time range, and the source-file
  SHA-256.

Safe source identifiers containing only ASCII letters, digits, `.`, `_`, or `-`
are preserved up to 256 UTF-8 bytes. An oversized or suspicious conversation,
message, or mapping-node identifier is replaced deterministically by a
kind-prefixed SHA-256 digest before tuple construction, so raw identifiers and
credential-like values do not amplify or enter the normalized archive.
System messages, unsupported content, and roles other than `user` and
`assistant` are discarded. A message without its own date inherits the
conversation's update or creation time when available; it is discarded only
when neither level provides a usable date. Import preflight rejects a source
whose pinned size exceeds 512 MiB. The source is opened without following a
symbolic link, must be a regular file, is read to that exact size in 64 KiB
chunks, and has its descriptor and path identity revalidated before parsing. A
concurrent replacement, shrink, or growth fails the import. The import is also
rejected above 250,000 retained messages or when the encoded normalized archive
would exceed 512 MiB. The full normalized archive remains on disk; recap prompt
construction selects only the requested day and includes at most 120 imported
messages, clipped to 1,800 characters per message before the overall prompt
limit.

Import is not a streaming parse: it holds the complete bounded export, maps its
object graph, and encodes the complete normalized archive. Peak import memory can
therefore scale to multiple representations of the 512 MiB source/archive and
250,000-message limits; the smaller per-day prompt limits do not bound the stored
archive.
Generating a recap also decodes the complete normalized archive before filtering
messages to the selected day, so its peak memory can scale with that archive even
though only the bounded day selection enters the prompt. Loading the import
summary at recap-runtime initialization and configuration also decodes that
complete archive.

Later normalized-archive reads reuse the same no-symbolic-link, regular-file,
stable-identity read with the 512 MiB ceiling. Startup, summary display, and
recap generation therefore keep a source-byte bound, although decoding and
filtering the complete archive can still require several in-memory
representations. Reimporting an identical source and parsed message set returns
the existing archive summary without rewriting the archive or changing its
original import time.

Deleting the import removes `normalized-conversations.json` only when that final
node is a regular file; a symbolic link, directory, or unexpected node is refused.
It does not delete already generated recaps, because those are separate derived
outputs. The
normal history-retention and clear-history flows do not remove this import or the
recap directory. Recaps replace the same selected day's files but can accumulate
one canonical JSON and one regenerable Markdown file per generated day until
removed manually. Internal archive and recap storage traverses each absolute
directory component from `/` with `openat(O_NOFOLLOW)` and retains the final
directory descriptor throughout write or removal. A newly created directory is
owner-only and its parent is synchronized after `mkdirat`; an ancestor symbolic
link is refused, and replacing the path after it is pinned cannot redirect the
operation to the replacement directory.
Persistence writes the Markdown mirror first and commits the JSON atomically last;
if that canonical commit fails, it restores or removes the mirror while leaving the
prior JSON authoritative. Revealing files regenerates the mirror from the accepted
JSON. Atomic writes use the pinned parent descriptor, refuse a non-regular
destination, create a no-follow temporary file, and verify owner-only `0600`
permissions before installing it. File and containing-directory synchronization
failures are surfaced instead of being reported as durable success. Later
recap/archive reads likewise require a stable no-follow regular file within their
byte limit.
Temporary recap run-directory cleanup is best-effort and no stale-run sweep is
currently documented or proven.

## Security boundary

The integration does not fall back to broad Codex permissions and fails when the
capabilities it explicitly attests are missing:

- Goalong executes the selected path directly with the fixed `app-server`
  argument rather than interpolating a shell command; the selected executable
  can itself be an external script or binary;
- the child process gets a strict environment allow-list, excluding API keys,
  cloud credentials, proxy secrets, and SSH-agent sockets;
- `CODEX_HOME` is redirected to an app-managed path under Goalong's
  application-support directory;
- initialization must report that exact resolved `codexHome` path or the session
  is closed before account or recap work continues;
- Goalong rewrites the app-managed Codex config before every session;
- web search, skills, MCP orchestration, login shells, and tool network access
  are disabled;
- Goalong requests a custom experimental permission profile limited to Codex's
  platform-minimal runtime files and the empty per-run workspace;
- every thread is requested as ephemeral, and Goalong verifies the returned
  `activePermissionProfile` identifier, `runtimeWorkspaceRoots`, and
  `thread.ephemeral` values before sending the recap prompt;
- execution environments are requested disabled and approval policy is
  requested as `never`; the current app-server response does not independently
  attest those two requested fields;
- generated outputs and normalized imports enforce verified owner-only filesystem
  permissions.

The model request sends only the selected bounded context. Goalong does not send
the unrestricted raw event journals, arbitrary local files, the complete Agent
Activity source set, or the complete ChatGPT export in one recap request.

The managed ChatGPT, Codex-home, history, recap, and run paths must resolve to
real directories. Their final nodes are opened without following symbolic links
and verified at owner-only `0700`; a symbolic link or unexpected node fails
preparation. File reads pin and revalidate their descriptor/path identity; file
writes operate relative to a pinned directory descriptor and refuse a
non-regular destination.

The current executable locator searches bundled/helper locations, common local
install paths, and `PATH`; the process environment can override that search in
all current builds with `GOALONG_CODEX_PATH`. It verifies that the selected path
is executable but does not cryptographically authenticate the binary or its
package identity. The restricted environment and checked runtime assertions
still apply after launch,
but they do not prove that the executable itself is the official Codex CLI.
Opening the recap page performs the passive account refresh; app startup,
`configure`, and `start` alone keep cached state and do not locate or launch
Codex. Explicit connection/generation and an enabled automatic recap can also
launch it. Use only a trusted local Codex installation; a production
distribution should bundle and verify a reviewed signed helper.

## Product behavior

The AI recap page provides:

- ChatGPT connect, account-state refresh, and disconnect;
- manual recap generation for a selected day;
- optional automatic generation for today, checked immediately when enabled,
  after the app has been running for about 45 seconds, and then every 15 minutes,
  with successful stored output suppressing another refresh for four hours;
- explicit import and removal of normalized ChatGPT history;
- source counts, redacted complete-line streaming preview, saved canonical JSON
  with its Markdown mirror, and local file reveal.

Removing an imported history archive or disconnecting ChatGPT does not silently
delete existing generated recaps. Stopping the runtime cancels its delayed
automatic attempt, and changing the selected day invalidates the active run,
session, callbacks, and preview before loading that day's stored recap.

## Packaging and compatibility

Current source builds and releases locate a trusted-by-the-user Codex CLI
installed on the Mac, without authenticating its identity. A future production
release should bundle a reviewed, signed Codex helper or provide a first-party
installer, then pin and test a minimum Codex version that supports experimental
permission profiles, runtime workspace roots, and ephemeral app-server threads.
The current bridge also requires `initialize.codexHome`, then verifies the active
profile identifier, runtime roots, and ephemeral-thread response at runtime and
refuses to generate a recap when those checked capabilities are missing. It does
not receive equivalent response attestation for every requested policy field.

For an enterprise distribution, register Goalong's app-server
`clientInfo.name` with OpenAI so compliance-log attribution uses a known client
identity.
