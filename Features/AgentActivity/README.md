# Agent Activity

Agent Activity analyzes delegated AI work from each provider's original local
storage. It does not maintain a transcript vault, copy hook payloads,
materialize conversations, or retain historical source versions.

## Architecture migration

| Retired capture vault | Current direct-source architecture |
| --- | --- |
| Goalong copied every changed source into manifests, blobs, deltas, and materialized transcripts. | The provider's original file or database remains the only conversation body. |
| Every source version could remain recoverable from Goalong storage. | One metadata entry is logically replaced when the original conversation changes; no historical source version is retained. |
| Hook stdin became an append-only inbox event. | Hook stdin is bounded, drained, discarded, and reduced to one replaceable provider signal. |
| A missing source could still be opened from Goalong's second vault. | `missing` and `inaccessible` are explicit index states; Goalong has no fallback transcript copy. |

The migration does not change the event, memory, seal, receipt, Apple Screen
Time, or semantic stores. It changes only Agent Activity's ownership boundary:
conversation content now belongs exclusively to its configured local source.

## Direct-read adapters

- **Codex Desktop/CLI**: `rollout-*.jsonl` sessions under
  `~/.codex/sessions` and `~/.codex/archived_sessions`;
- **Claude Code**: session JSONL under `~/.claude/projects`;
- **OpenCode**: sessions, messages, and parts queried from
  `~/.local/share/opencode/opencode.db`, plus legacy session JSON when present;
- **Gemini CLI**: canonical
  `~/.gemini/tmp/<project-hash>/chats/session-*.json` files;
- **GitHub Copilot in VS Code**: canonical
  `User/workspaceStorage/<workspace-hash>/chatSessions/*.{json,jsonl}` files;
- **Cursor**: supported conversation and log files under the configured
  `.cursor`, workspace-state, and global-state roots;
- **user-selected folders**: supported conversation and log files at their
  configured original paths.

Default folders are detected only when they already exist. A newly detected
provider is added disabled until the user enables it; an earlier enabled choice
stays enabled. Removing an automatically detected source records a bounded
metadata-only tombstone so it does not silently return after relaunch.

Provider-specific and generic adapters reject symbolic-link traversal and open
regular source files without write access. Generic folders also exclude common
credential, key, cookie, token, backup, cache, and provider-root paths, including
when **Every supported file** is selected.

## Persisted storage contract

```text
~/Library/Application Support/LocalHistory/agent-activity-v2/
├── configuration.json
├── index.json
└── signals/
    ├── .writer.lock                 # created only when a hook writes
    └── <provider>.json              # one replaceable file per signaled provider
```

Directories use owner-only `0700` permissions and files use `0600`.

`configuration.json` is capped at 1 MiB. It stores source paths and bounded
labels, provider/capture-mode/managed flags, enabled choices, scan intervals,
the per-source size limit, the index bound, and bounded discovery tombstones.
At most 512 watched folders and 256 tombstones survive validation. The default
index limit is 10,000 entries and the validated maximum is 50,000.

`index.json` is capped at 12 MiB and contains one replaceable entry per stable
conversation. The configured entry count remains an upper bound: the byte cap
can evict older metadata before the configured 10,000-entry default or 50,000-entry
maximum is reached. The complete persisted entry contract is:

- opaque entry, folder-scoped stable-conversation, and watched-folder identifiers;
- provider label for the watched folder;
- provider;
- original source reference: an absolute file path, or a read-only SQLite path
  plus an opaque session locator;
- a bounded relative source path;
- source creation and modification timestamps;
- provider conversation start and end timestamps when analysis exposes them;
- first-indexed and last-observed timestamps;
- byte count, SHA-256 fingerprint while available, optional filesystem
  device/inode/change-time identity, optional shared-container byte-count and
  modification-time identity, and optional start/end offsets; a source that was
  never readable can have no trustworthy fingerprint;
- `available`, `missing`, or `inaccessible`, plus an optional closed status code
  (`nil` while available).

The index also keeps bounded discovery attempt/failure cursors, handled-signal
timestamps, one metadata-only root availability and transition time per watched
folder, and its update timestamp. It never adds a dedicated conversation title,
excerpt, messages, commands, tool results, touched files, provider error strings,
or any other free-form transcript summary. Original source references and bounded
relative paths can naturally contain user-chosen filesystem names; configured
folder labels remain in `configuration.json`.

Transcript-derived summaries exist only in process memory while the original
source is analyzed. The full-summary LRU is limited to 256 entries, 4 MiB of
estimated UTF-8 payload, and a five-minute sliding lifetime renewed when an
entry is retrieved through the record cache. Content-free aggregate metrics may
remain in that process for up to 4,096 indexed revisions in a separate access-
ordered LRU, but they do not have their own byte ceiling or TTL. Neither form is
written to `index.json`.

Signal files are metadata-only, replaceable, and capped at 16 KiB. They contain
the provider, a bounded event name, signal time, process identifier, and the
number of hook-input bytes discarded. They never contain hook stdin or a source
body.

## Incremental discovery and read budgets

Ordinary polls rotate through at most 256 known index entries per scanner cycle.
When source creation time, modification time, size, and the available
device/inode/change-time identity still match the index, Goalong may open the
source descriptor to verify metadata but does not read or rehash body bytes. A
changed source replaces its existing conversation entry; no prior version is
retained.

The 256-entry rotation is an index-entry bound, not necessarily 256 provider-
catalog rows. OpenCode keeps an identity-validated, process-local metadata cache
of at most 256 sessions per database and 512 sessions overall. A warm lookup can
therefore resolve cached opaque locators without revisiting the catalog; a cache
miss can still walk the session metadata table until every requested locator is
found, subject to the shared 50,000-row/two-second traversal budget below. This
metadata resolution never reads conversation bodies.

Provider discovery runs for initial or incomplete ingestion, after a hook
signal or explicit rescan, and on the full-discovery cadence. It is not a
recursive full-tree scan on every short poll. Scheduled reconciliation is fixed
to at most once every 24 hours; initial discovery, a manual rescan, a provider
signal, or continuation of an already bounded inventory may run sooner.
Production traversal shares one budget across all providers and folders in a
scanner cycle:

- 50,000 filesystem nodes or SQLite rows;
- 16 MiB of traversal metadata;
- two seconds of monotonic elapsed time.

An inventory stopped by its node/row, metadata-byte, elapsed-time, or
cancellation budget is retried, and its persisted failure count expands a later
per-cycle budget deterministically, up to 1,000,000 nodes or rows, 256 MiB of
metadata, and 30 seconds. Such an unfinished traversal does not mark unseen
conversations missing and does not acknowledge an unfinished hook signal. A
completed traversal can still retain only the configured number of most-recent
candidates; this bounded index projection is recorded as `candidateLimit` and
can acknowledge the signal because the underlying inventory did finish.
Traversal also stops with an explicit incomplete state beyond 64 directory
levels or an 8,192-byte relative path. These structural safety ceilings do not
expand with retries; the source remains conservatively incomplete until its
layout changes.

Only one unfinished discovery inventory is retained process-wide. It is capped
at 512 combined candidates, potentially missing entries, and seen identifiers,
with a 4 MiB estimated-memory ceiling. While that inventory drains, other
folders can still receive their rotating metadata checks, but Goalong does not
accumulate another retained inventory per watched folder.

Source-body work shares one scanner-cycle budget across all providers and
folders: at most 256 candidate/session body-read attempts, 512 MiB streamed, and
ten seconds. OpenCode session-row analysis can perform more than one low-level
read for one candidate, but those bytes and elapsed time consume the same cycle
budget. A candidate that cannot fit the remaining byte budget is deferred
without starving a smaller later candidate. Unfinished work remains eligible for
a later cycle. A cycle commits all provider changes and signal cursors with at
most one atomic rewrite of the complete metadata JSON index. Each source is also
subject to the configured per-source ceiling, which defaults to 256 MiB and is
validated to at most 512 MiB.

Selecting a day prioritizes sources whose known file or provider interval
overlaps that day. A source with no trustworthy interval may still need a direct
read. A manual integrity rescan can rehash otherwise metadata-identical sources;
ordinary warm polls deliberately do not pay that cost.

Regular JSONL, text, and Markdown sources are read in 128 KiB chunks with an
incremental SHA-256. The streaming line buffer is capped at 512 KiB. A monolithic
JSON document is semantically parsed only when it is at most 8 MiB. A larger
monolithic document can still be fingerprinted as available by a metadata-only
background scan; when semantic analysis is requested it is reported as
inaccessible/unanalyzed rather than shown with an empty analyzed summary.
An already-indexed file that is still growing is left on its previous complete
fingerprint until it has been quiet for two minutes, then reread once as a stream.
This prevents a large active JSONL conversation from being rehashed in full at
every 30-second metadata poll. New files, truncations, same-size replacements,
forced reconciliation, direct reads, and explicit selected-day analysis bypass
the delay. The settled source replaces the same index entry; the optional index
offsets do not form a copied delta log.

OpenCode is opened through a `mode=ro&immutable=1` SQLite URI with
`SQLITE_OPEN_READONLY`, `query_only`, and memory-only temporary storage. A
non-empty live WAL or rollback journal is reported as deferred instead of being
checkpointed or ignored. Database and sidecar identity are verified around the
query, and message/part rows are hashed and parsed while `sqlite3_step`
advances. Goalong does not hash or copy the complete `opencode.db` container:
device, inode, size, modification time, and change time identify that container,
while the selected session's exact message and part rows produce its own byte
count and SHA-256 fingerprint. A hook signal triggers discovery but does not
turn the database into a copied snapshot. The separate session-metadata cache
described above is identity-validated, access-ordered, and never persisted. No
second database or complete transcript buffer is created.

## Hooks and processes

Hooks are optional discovery hints. Codex, Claude Code, and Cursor may provide
JSON on stdin, but Goalong drains at most 1 MiB for at most 500 ms and discards
it without decoding. OpenCode's plugin sends no payload and coalesces signals.
A hook overwrites one small provider signal file and exits; it does not append an
event, start a transcript service, or control the provider.

Installed hooks are limited to durable session boundaries: `PreCompact`,
`Stop`, and `SessionEnd` for Codex and Claude Code; `preCompact`, `stop`, and
`sessionEnd` for Cursor; and `session.idle`, `session.compacted`, and
`session.deleted` for OpenCode. Ordinary tool calls and file edits do not spawn
a Goalong hook process. Hook configuration reads and writes are capped at 1 MiB;
the installer retains at most three owner-only Goalong backups for each provider
configuration it changes.

Folder polling and signal watching run inside the Goalong History process; Agent
Activity does not require a resident helper process. Without hooks, provider
changes are still found by bounded polling, with less immediate wake-up. The
runtime applies a minimum 30-second poll interval even if an older configuration
contains a smaller value.

Startup, timer, and hook-signal background scans update settled metadata and
fingerprints without building transcript-derived summaries. A growing known file
continues to be checked by metadata and is fingerprinted after the quiescence
window above. Selected-day
content analysis runs on demand while the Agent Activity section is visible or
after an explicit refresh. Hiding the dashboard window clears the transient
full summaries while retaining compact per-revision aggregate metrics and the
lightweight index. Reopening an unchanged selected day can rehydrate summaries
directly from the original sources, with at most 64 such rehydrations and 32 MiB
of source bytes admitted per scanner cycle; remaining work stays eligible for a
later visible scan.

## Upgrade and failure states

The retired `manifests/`, `blobs/`, `materialized/`, and `hook-inbox/` layouts
are never created or used as conversation input by Agent Activity v2. Upgrade
preparation inventories the retired layout only to apply its safety migration;
only a validated metadata-only configuration and index are eligible for reuse.
Recognizable legacy-vault content is removed only after a complete safety
preflight. Ambiguous or partially migrated legacy content is quarantined and
preserved, and preparation fails closed rather than guessing that it is safe to
delete. An earlier v2 index without folder-root status is normalized once;
existing `rootStatusByFolder` metadata and the `sourceContainer*` identity tuple
are preserved during later path preparation.

After migration, the retired `agent-activity` path is an owner-only regular-file
barrier. A legacy binary therefore cannot recreate
`agent-activity/blobs`. Legacy configuration keys `captureFullContents`,
`keepEveryVersion`, and `maximumDeltaDepth` are ignored and removed when the
configuration is next saved.

If an individual indexed source is removed, unreadable, replaced during a read,
too large, or otherwise unsafe, Goalong retains the single metadata entry with a
closed `missing` or `inaccessible` state and retries conservatively. An unreadable
provider root persists one folder-level `missing` or `inaccessible` transition
while existing child entries remain unchanged; Goalong does not falsely mark
every conversation inaccessible. Repeated unavailable checks use a process-local
exponential backoff from 60 seconds to 15 minutes, and the unchanged root state
does not rewrite the index on every retry. No previous body can be duplicated
because no previous body exists in Goalong storage.

The normal Goalong History event, memory, seal, receipt, Apple Screen Time, and
semantic stores are outside this scanner's storage contract and remain
unchanged by Agent Activity index maintenance.

The optional [ChatGPT recap](../../docs/CHATGPT_RECAP.md) is a separate product
flow. From Agent Activity it receives only bounded, content-free provider counts
and source metadata, never provider transcript bodies or working summaries; the
recap sends its wider bounded Goalong context to OpenAI and stores the generated
result. Sanitization covers common credential patterns, not an exhaustive secret
detector. Its explicit ChatGPT-export import is also a separate, opt-in normalized
content copy. Neither changes what Agent Activity is allowed to persist in its
index.

## Installation guard

The app bundle must contain the Boolean
`LocalHistoryAgentActivityDirectSourceV2` privacy marker and pass the source-code
privacy audit. The public installer also verifies the bundle identifier, code
signature, checksum, and Sparkle update policy before replacing an installed
app. A downloaded legacy bundle without the direct-source marker is refused; the
installer never falls back silently to building another variant.

Until the public `latest-main` asset carries this contract, install this checkout
explicitly from source:

```bash
./install.sh --source
```

That path runs the full test and privacy gates, builds and validates the app,
stages it on the destination filesystem, and retains rollback protection during
replacement. Source builds deliberately do not self-update. The repository
[README](../../README.md) owns the current public-release notice.

## Tests

The focused suites are:

```bash
swift test --filter AgentActivityTests
swift test --filter AgentActivityAdvancedTests
swift test --filter AgentActivityMetadataPrivacyTests
swift test --filter AgentActivityScannerLoadTests
swift test --filter AgentSourceCapabilityTests
swift test --filter AgentSourceTraversalBudgetTests
swift test --filter AgentHookIngestTests
swift test --filter IntegrationInstallerChurnTests
swift test --filter OpenCodeSQLiteReadOnlyTests
swift test --filter AgentActivityDiscoveryConsentTests
swift test --filter AppPathsTests
```

They cover Codex, Claude Code, and OpenCode reads at original paths; absence of
transcript and hook bodies in the Agent Activity v2 storage tree; source
replacement without versions; missing and inaccessible states; index and
transient-cache bounds; incremental warm scans; traversal/body deadlines and
restart progress; legacy
configuration migration; hook churn; and SQLite source/sidecar immutability.
The ordinary load fixture indexes 10,000 synthetic conversations through a
process-local traversal cursor. Every cycle exposes at most 512 newly discovered
candidates, reads at most 256 source bodies, visits at most 50,000 source nodes or
rows, and retains at most 24 MiB of metadata-only continuation state. A deliberate
scanner reconstruction may revisit its lost process-local prefix once; the new
cursor then resumes without repeatedly walking that prefix. A 512-root fixture
opens at most 32 roots per cycle and eventually services every root. A separate
long-metadata stress fixture is byte-trimmed to 5,148 entries and 12,581,943 bytes,
969 bytes below 12 MiB; it reloads validly and an identical upsert does not rewrite
it. Those are logical file lengths measured with `lstat`, not a persistent `du`
measurement of a retained fixture directory.

Regular-file hashing uses one reusable 128 KiB POSIX buffer. The incremental JSONL
and text parsers consume that borrowed buffer directly and drain Foundation parsing
objects one line at a time, so hashing a large source batch does not retain one
Foundation `Data` allocation per chunk until the batch ends.

The 2026-08-25 local privacy freeze for this checkout passed all 108 Agent Activity
tests present in the complete run (two expected skips: a case-insensitive-volume
fixture and the opt-in real-source benchmark; zero failures). The complete package
run passed 561 tests with the same two skips and zero failures. The opt-in benchmark
was then run separately against the real Codex root and passed in 5.012 seconds. Its
test process was sampled at 34,496 KiB RSS; `/usr/bin/time -l` reported a 20,267,752-
byte peak memory footprint (the 126,091,264-byte maximum RSS includes the Swift test
driver). Before the reusable-buffer change, the first installed-app scan reached a
1.1 GiB peak physical footprint while hashing the same local catalog.

At that freeze, the installed metadata tree contained 792 entries (777 Codex, one
Claude Code, and 14 OpenCode). Its four regular files occupied 775,126 logical bytes:
`index.json` was 773,348 bytes, `configuration.json` was 1,632 bytes, the signal hint
was 146 bytes, and the writer lock was empty. There was no `blobs`, `manifests`,
`materialized`, or `hook-inbox` path. The retired `agent-activity` path remained a
78-byte regular-file barrier, so the empty vault was not reconstructed.

Those focused suites intentionally measure logical byte budgets rather than the
installed process's physical RAM, CPU, or idle filesystem footprint. Filesystem
providers retain open, no-follow directory cursors in process; OpenCode retains a
rowid cursor and rejects a changed database identity before combining pages. A
bounded bootstrap page plus the persisted incomplete-attempt count preserves
forward progress across a relaunch without persisting directory handles or chat
content. Each index mutation still sorts, encodes, and atomically rewrites the
bounded monolithic `index.json`, which can amplify CPU, transient RAM, and writes
near the 12 MiB ceiling.
