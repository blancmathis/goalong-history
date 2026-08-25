# Goalong History — Computer History analysis parity

This document describes the Goalong implementation of the publicly documented
Computer History analysis behavior: chronological interaction capture, local causal
memories, source recovery, natural questions about recent work, task status, and
repeatable-workflow suggestions.

It does **not** claim access to, or equivalence with, any undocumented private
implementation. Parity claims must be limited to behavior that has been exercised on
the tested macOS build and applications.

Reference behavior: <https://learn.chatgpt.com/docs/customization/computer-history>

## Observable target and public-use signals

The parity target is the public product surface, not a guessed private design. The
official documentation establishes the interaction stream, Accessibility context,
timeline, memories, source recovery, natural questions, repeated-workflow suggestions,
pause/exclusion/deletion controls, local persistence, and the absence of screenshots or
audio. Public discussion emphasizes two useful outcomes — resuming work without manually
restating context and recovering a vaguely remembered source — plus a non-negotiable
failure mode: repeated Accessibility work must not make foreground applications lag.

Public evidence used for this acceptance surface:

- OpenAI Computer History documentation:
  <https://learn.chatgpt.com/docs/customization/computer-history>
- public workflow/recall discussion:
  <https://www.reddit.com/r/CodexAutomation/comments/1vnzmkf/chatgpt_computer_history_gives_codex_a_searchable/>
- public macOS performance report:
  <https://www.reddit.com/r/codex/comments/1vwyyo9/computer_history_was_slowing_down_my_mac/>
- public capture-loss report after an Accessibility observer crash:
  <https://github.com/openai/codex/issues/39183>

These reports are individual public signals, not representative user research. They are
used to strengthen the local acceptance criteria, not to infer undocumented behavior.

| Publicly observable capability | Goalong behavior | Current proof boundary |
| --- | --- | --- |
| clicks, grouped typing, shortcuts, scrolling, app/window/site context | one local input pipeline with event-time, near-event, after, and settled observations | deterministic capture tests pass; the installed signed identity still needs a fresh physical-input/TCC run |
| searchable chronology and local memories | causal episodes plus exact coverage totals and a bounded representative projection | parity/evidence/storage tests and installed UI inspection pass |
| resume after a break and summarize recent work | intent-aware local search over causal episodes, including French resume phrasing | English/French query tests and a real local source query pass |
| recover a file, page, document, conversation, issue, or terminal context | stable source references with direct-source fallback and provenance | resource-resolution and query tests pass; unavailable locators stay explicit |
| distinguish completed, in-progress, blocked, waiting, planned, and unknown work | cautious evidence-derived status with latest visible state taking priority | deterministic status scenarios pass; status remains an interpretation |
| suggest skills or automations from repeated work | bounded cross-day workflow clustering; suggestions never auto-run | repeatability scenarios pass; real multi-day usefulness remains data-dependent |
| pause, resume, exclude, and delete | menu-bar/UI controls, app/domain exclusions, private/secure suppression, and 10-minute/hour/all deletion | privacy audit and deletion tests pass |
| avoid screenshots, audio, clipboard, keystroke reconstruction, and private browsing | Accessibility text and interaction metadata only, with credential redaction | privacy audit and suppression tests pass |
| stay unobtrusive and recoverable | one process, no helper, health state, bounded queues/caches, AX storm debounce, polling fallback | resource measurements pass; final physical wake/input recovery is pending TCC refresh |

## Architecture migration

| Before this hardening | Current architecture |
| --- | --- |
| Derived days could retain the complete causal arrays and a second local Markdown copy. | An eligible day is analyzed completely only when it fits the documented source-integrity, row, byte, and working-set bounds; then one compact JSON keeps exact totals plus a bounded representative projection, and only one optional Codex Markdown projection remains. |
| Search depended on retained derived detail. | Stored-memory search is complemented, for lexical questions, by a bounded read-only pass over the original journals. |
| Repeated refreshes could independently decode the same day and retain large integrity arrays in memory. | Activity Analysis and Computer History share one day pass, drop regenerable per-field commitments from transient copies, and use a small revision cache plus append debounce. |
| A live append during a full-day pass invalidated the whole refresh even when the recorder only extended the same journal. | The runtime pins the probed event and semantic byte ceilings, reads exactly those validated prefixes, accepts only same-inode append-only growth, and catches up on the following cycle. Replacement, truncation, same-size mutation, or an incomplete row boundary still fails closed. |
| Every application build number changed the analysis revision, and timestamp jitter could invalidate an otherwise intact append cursor. | The revision is scoped to the analysis algorithm, physical journal order is verified by sequence/hash continuity independently of timestamp sorting, and a maintenance-only append reads just its pinned suffix even while newer bytes arrive. |
| Whitespace cleanup created one Foundation regular-expression result per ordinary match and retained a complete pass of autoreleased temporaries. | Layout normalization is one linear Unicode-scalar pass; credential patterns remain compiled regexes, and their temporary Foundation objects drain once per bounded observation. |
| The Computer History page eagerly built every retained episode card and rebuilt the same source dictionary for each card. | The timeline and page body are lazy, one source index is shared by all visible cards, transient dashboard caches are cleared on close, and free allocator pages are returned after the window graph drains. |
| Missing or unsafe raw input could erase or replace the useful derived view. | The last known-good memory remains visible with an explicit `absent` or `inaccessible` source state. |

The raw Goalong event and semantic journals remain the authoritative evidence.
Compaction changes only derived storage and search working sets; it does not
rewrite or shorten those journals.

## Product behavior

With **Full Computer History context** enabled, Goalong History can reconstruct:

- the ordered stream of clicks, grouped typing, shortcuts, navigation keys, scrolling,
  app changes, windows, pages, and focused controls;
- bounded semantic state observed chronologically before an interaction when available,
  near the event, shortly after it, and after the UI has settled;
- visible changes caused by the interaction without reconstructing ordinary characters
  from keyboard keycodes;
- task-shaped work episodes rather than one representative event per minute;
- likely source resources: files, pages, cloud documents, conversations, issues,
  terminal sessions, and applications;
- observable intentions, outcomes, and a cautious task status;
- repeated action sequences that may justify a reviewed skill or automation;
- natural local answers such as:
  - “Where was I before my break?”
  - “Find the proposal document.”
  - “What is completed, in progress, blocked, or waiting?”
  - “Summarize yesterday.”
  - “Which repeated workflow could become a skill?”

The existing compact day recap remains available for fast reporting. It is no longer
the primary causal representation.

## Analysis pipeline

```text
CGEventTap + NSWorkspace + AXObserver + foreground polling
                         │
                         ▼
             privacy-aware context sampler
                         │
                         ▼
 prior observation → input action + near-event → after → settled
                         │
                         ▼
           ComputerHistoryInteractionBuilder
                         │
                         ▼
             ComputerHistoryResourceResolver
                         │
                         ▼
              ComputerHistoryEpisodeBuilder
                         │
                         ▼
             ComputerHistoryWorkflowDetector
                         │
                         ▼
 compact structured JSON + one Codex Markdown projection + local search
```

### Interaction capture

Every eligible click, drag, shortcut, special key, grouped typing burst, and grouped
scroll burst receives an interaction identifier. Semantic observations use these phases:

- `before` — explicitly linked state accepted only when its timestamp is not later than
  the action;
- `near_event` — shallow state sampled close to the input callback; it is not represented
  as guaranteed pre-action evidence;
- `after` — broader state shortly after the action;
- `settled` — full bounded state after the UI has had time to settle.

When no explicit chronological `before` exists, the interaction builder may use the
nearest earlier eligible observation from the same application. A delayed callback can
never masquerade as a causal pre-state.

The budgets are intentionally phase-aware so full analysis does not make the event tap
unresponsive:

| Phase | Maximum characters | AX nodes |
|---|---:|---:|
| before / near-event | 2,400 | 72 |
| after | 4,800 | 160 |
| settled | 6,000 | 260 |
| event-driven AX observation | 4,800 | 180 |
| periodic fallback | 6,000 | 260 |

`AXObserver` also reacts to focused-element, focused-window, window-created, title,
value, and selected-text changes. These observations are debounced and fingerprint-
deduplicated. Polling remains a fallback rather than the only source.

When the cached Accessibility preflight/functional pair is unavailable, the observer
stays detached instead of issuing and logging four failed registrations on every
foreground-app switch. The permission watchdog remains on its three-second recovery
cadence, and the context fallback also sleeps at least three seconds in that degraded
state. A later app activation attaches the observer after the cached permission becomes
usable; no extra helper or TCC probe loop is introduced.

### Causal interactions

`ComputerHistoryInteractionBuilder` analyzes every admitted action and links its semantic
evidence. It never replaces all admitted activity within a minute with one representative
row. For an accepted day that remains within the documented evidence bounds, the complete
admitted sequence is used for status, workflow, coverage and resource analysis, then the
persisted derived memory keeps a bounded chronological projection; the raw event journal
remains the exact reopenable source while its own retention policy keeps it.

Each retained representative interaction stores:

- action kind and human-readable label;
- start and end;
- application, site, and source resource IDs;
- bounded before and after context;
- semantic lines visible only after the action;
- confidence and source-event provenance.

When an explicit before/after pair is unavailable, the builder may use the nearest
eligible semantic observation from the same application within a bounded 20-second
window and on the correct side of the action timestamp. Coverage reports distinguish
complete pairs from partial context.

### Source resolution

`ComputerHistoryResourceResolver` turns observed locators into stable source objects:

- `file` for `file://` and local paths;
- `document` for known cloud-document products or document-like app windows;
- `conversation` for chat and thread URLs;
- `issue` for issue and pull-request systems;
- `webPage` for other sanitized URLs;
- `terminalSession` where a terminal exposes a stable window context;
- `application` as a fallback when no more precise source exists.

Every resource includes first/last observation time, locator confidence, and source
provenance. A query result can offer a local path or sanitized URL, but opening it requires
an explicit user action. Analysis never treats captured content as an instruction or an
executable command.

### Episode reconstruction

`ComputerHistoryEpisodeBuilder` groups interactions only when evidence supports a
continuous task. It considers:

- shared resources;
- same site;
- same application with compatible source continuity;
- semantic similarity;
- elapsed time;
- suppressed/private gaps.

Different browser hosts are separated by default unless the switch is immediate and the
semantic context is clearly related. Different specific resources in the same app are
also prevented from becoming one generic app block.

Before day-level compaction, every episode contains its complete chronological
interaction sequence, applications, sites, resources, requests or intentions,
observable outcomes, and source provenance. In a compacted day, an entire low-signal
episode may be omitted; each retained episode keeps a chronological representative
subset plus its exact source-interaction count.

### Task status

Status is a bounded interpretation, never a verified claim. Possible values are:

- `planned`
- `inProgress`
- `completed`
- `blocked`
- `waiting`
- `unknown`

The latest visible state has priority over earlier transient evidence. For example, a
failed deployment followed by a visible successful retry is `completed`, while the
failure remains in the action history.

### Repeated workflows

A workflow candidate requires at least three meaningful interactions. Similar sequences
are clustered across locally retained causal memories. A suggestion appears only after
at least two observed occurrences:

- a **skill** for a reusable reviewed procedure;
- an **automation** only for stronger repeated cross-application evidence.

Suggestions contain the source episode IDs, observed sequence, rationale, confidence,
and a proposed request. Goalong does not create or run an automation automatically.
The app supplies at most 30 preceding Computer History days to workflow detection; a
shorter retained history naturally limits cross-day evidence. The read-only CLI can use
the explicit `--days` horizon, up to 365 days, when it reconstructs its transient answer.

## Local storage

Causal memories are stored separately from raw events and regenerable compact analyses:

```text
~/Library/Application Support/LocalHistory/
├── events/
├── semantic/
├── memories/
├── analysis/
└── computer-history/
    └── YYYY-MM-DD.computer-history.json
```

One optional deterministic Markdown projection per day is maintained, when possible, at:

```text
$CODEX_HOME/memories/extensions/goalong/
```

or to `~/.codex/memories/extensions/goalong/` when `CODEX_HOME` is not configured.
The compact Goalong JSON remains authoritative and deliberately omits its regenerable
Markdown body. The Markdown is regenerated from that structure and rewritten only when
its bytes change; it is not another authoritative history store.

A missing raw event day does not implicitly delete an already retained Computer History
memory. Source absence removes the regenerable minute-level analysis for that day, but
preserves its retained activity memory and Computer History. An inaccessible, unstable,
oversized, or linked raw source leaves the last known-good derived views in place and is
shown as a source-status warning in the Computer History UI.

Computer History-owned JSON and Markdown are removed by the explicit clear-history path.
They belong to the retention schema's `memories` data class, but the current Settings
flow updates only detailed events, semantic snapshots, and analysis caches; it preserves
memories indefinitely and does not expose a finite Computer History retention control.
Legacy retention migration also keeps memories indefinitely and does not activate memory
cleanup. Explicit deletion preflights exact owned filenames across all derived categories
before unlinking. It does not target seals, receipts, Screen Time, Agent Activity, or
unrelated files.

Large accepted derived days are bounded after a complete analysis pass within the
documented input and evidence limits. Coverage keeps exact source-event, action,
interaction, episode, resource, and continuity/suppression counts for admitted evidence.
When compaction is active, the JSON stores at most 256 representative episodes, 640
representative interactions, 384 representative resources, and 64 workflow patterns.
The workflow detector emits at most eight suggestions in either mode. Below the
compaction thresholds, episodes keep their complete interaction arrays and workflow
patterns do not have that separate 64-item projection cap; the 32 MiB file ceiling still
applies. The Markdown and UI distinguish complete analyzed totals from the retained
projection. Raw events and semantic payloads remain governed by their own retention
classes; projection does not delete or rewrite them.

Each Computer History JSON file is limited to 32 MiB. Recent-memory loading accepts at
most 32 MiB per day, uses a 64 MiB cumulative encoded-byte budget for the normal 30-day
window, and never exceeds a 96 MiB cumulative budget for wider reads. Corrupt or
oversized candidates consume bounded attempts/bytes and cannot turn a directory into an
unbounded decode loop. Production listing is lazy, visits at most 20,000 directory
entries for at most two seconds, and selects at most 512 newest files for bounded decode
attempts. If the listing is interrupted, changed, or exceeds either budget, the
exact-newest API returns no partial subset and the write path refuses to replace a derived
day from that incomplete prior context. After decoding, it revalidates the memory
directory and every examined candidate's identity. Corrupt recent files can therefore be
backfilled from older candidates within the fixed 512-attempt window, while an unstable
snapshot or a window too small to prove the exact newest requested days fails closed.

The recent-memory result is typed as `memories`, `isComplete`, and bounded `issues`.
Readable last-known-good memories may still support an answer when one candidate is bad,
but the answer and UI label that coverage as incomplete and do not treat absence as
exhaustive. The build/runtime write paths require complete prior context before mutating
any derived output. Memory directories are pinned as capabilities, files are opened
relative to them with no-follow descriptors, and root, ancestor, directory, and file
identities are revalidated. A legacy-format read migrates only through compare-and-swap;
all in-process Computer History mutations are serialized, and the temporary file plus
current destination are rechecked immediately before atomic rename. A concurrent newer
write or unsafe path therefore leaves the readable last-known-good file unchanged.

Those are per-file and per-read bounds, not a global retention byte cap. While memories
are retained indefinitely, one compact JSON and one optional Codex Markdown projection
can accumulate per day until the user uses clear-history. The storage layer can enforce
an explicitly saved and activated `memories` policy, but the current app does not expose
that control.

### Bounded incremental runtime

In the application-managed refresh cycle, Activity Analysis, Computer History, and the
optional compact activity memory share one exact-day JSONL decoding pass. Maintenance
rows are counted for source coverage but can be discarded before causal analysis;
eligible daily events and semantic snapshots are still assembled in memory for the
current engine. Transient event copies discard the per-field integrity-commitment arrays
after decoding; the authoritative raw journal keeps them, while the derived pass retains
the event sequence, event hash, and observable fields it actually consumes. The shared
application-managed pass rejects a day before writing when retained useful events and
referenced semantic payloads exceed 32,768 values or 64 MiB estimated from their encoded
size, inline stride, and a fixed per-value margin. This is a retained-evidence estimate,
not a constant-RSS guarantee: streaming decode buffers, temporary values, and engine output
still require separate runtime measurement.

The background runtime uses:

- a metadata-only revision cache capped at four entries and 64 KiB, pruned to today,
  yesterday, and the selected historical day during an analysis refresh;
- a ten-minute debounce for append-only background changes, while explicit refreshes
  verify immediately;
- one process-wide cycle service per source root; requests with the same normalized day,
  token budget, force/activity-memory options, and source probe join the same active
  execution and receive the same success or failure, while different requests wait for
  that root's active cycle instead of decoding concurrently; the normal runtime and a
  ChatGPT recap therefore reuse the same source pass when their requests are identical;
  queued work rechecks the current source revision before writing, and a reentrant call
  from the active same-root leader fails immediately instead of waiting on itself;
- a ten-minute app-level derived-analysis cadence for today and yesterday, with a
  30-second timer tolerance; the coordinator uses the same ten-minute minimum
  debounce for background refreshes, while an explicit user refresh bypasses it;
- no dashboard-specific refresh tasks while the dashboard is closed, miniaturized,
  hidden with the app, or occluded;
- a five-second lightweight dashboard runtime refresh and a sixty-second dashboard data
  reread only while the window is actually visible; the latter is enabled for the
  current day, while a visible historical day keeps only the lightweight runtime task.
  That sixty-second reread is not an Activity Analysis cadence.

The revision cache stores metadata plus a bounded source-tail identity, not decoded event
content. A verified append containing only recorder maintenance rows can be consumed as a
suffix and update exact source coverage without rebuilding causal results. Any append
containing user-facing evidence, any replacement, or any tail-integrity uncertainty
falls back to streaming the changed day again from byte zero. The debounce reduces how
often that full cost is paid; it is not a general suffix-only causal engine.

The source tail follows physical JSONL append order and verifies every adjacent sequence,
previous hash, event root, and event hash. Event timestamps are still sorted for causal
analysis, but normal asynchronous timestamp jitter no longer discards a valid physical
cursor. The maintenance suffix continues that exact integrity chain and may finish against
a pinned prefix while the same inode grows again; the later bytes remain pending for the
next cycle. The engine revision changes only when the derived algorithm or persisted
contract changes, so an unrelated application build no longer forces a full-day rebuild.

A full rebuild also uses an immutable read boundary instead of chasing the live end of
file. The coordinator refreshes its prior-memory processing key after any bounded legacy
compaction, pins the event and optional semantic file identities and byte sizes, then the
loader reads only those prefixes through no-follow descriptors. Growth is accepted only
when the device and inode are unchanged and size is monotonic; an unchanged size must
also retain the exact modification timestamp. A prefix that ended in a row still being
written is deferred rather than decoded. The cached revision describes exactly the
accepted prefix, so later bytes remain visible to the next incremental cycle without
duplicating any derived row.

The standalone reader makes the same distinction between identity and membership. The
application-support root must retain its exact device/inode path identity, while the
`events` and `semantic` directories must also retain their complete listing snapshot.
Creating an unrelated derived/cache entry under the root therefore cannot reject a
read-only source pass; replacing the root, either source directory, or an examined source
file still rejects the complete projection.

The rendered Computer History page uses lazy stacks for the outer page and causal
timeline. It constructs one resource-ID lookup per memory instead of one copy per
episode. Closing the dashboard removes its hosting controller, clears decoded dashboard
and Agent Activity summaries, then requests allocator pressure relief after those
references drain. These steps bound work by visible rows and allow the menu-bar recorder
to return transient UI pages to macOS; measured RSS still depends on SwiftUI/macOS and is
validated separately on the installed build.

Semantic layout cleanup collapses spaces/tabs, CRLF, and long newline runs in a single
bounded scalar pass before the credential expressions run. The regex rules remain ordered
and behavior-equivalent under the sanitizer regression corpus. Each observation owns a
small autorelease pool, so match objects and bridged Foundation strings do not accumulate
until the complete day finishes. This changes transient allocation only; the sanitized
text, redaction patterns, clipping limits, and persisted result are unchanged.

The prior-memory dependency revision is also discovered lazily: it visits at most 20,000
entries for at most two seconds, retains only the latest 30 eligible names, and caches at
most four day-key results in process memory. A cache hit rechecks the selected file stamps
and the directory stamp; an incomplete or changing inventory fails the cycle rather than
hashing a partial directory view.

The dashboard journal reader keeps at most one day snapshot and a shared cache across
events, seals, and receipts capped at 100,000 decoded rows and an estimated 32 MiB. The
derived dashboard collections have a separate estimated 8 MiB ceiling. Its per-type file
caps are four event journals, four seal journals, and 32 receipt journals. An unavailable
or unstable component prevents a fresh/LKG hybrid: the reader returns one coherent
last-known-good snapshot when available, otherwise an explicit unavailable or
budget-exceeded state. It remembers an over-budget source revision so an unchanged warm
refresh does not repeat the same expensive read. The receipt results and caches are
bounded: the names-only directory inventory visits at most 4,096 entries for at most
0.25 seconds, one lookup examines at most 64 prioritized journals, and the reader keeps
at most 32 decoded receipt-file cursors plus four compact lookup results. Exhausting any
of those limits produces an explicit budget state instead of silently treating unvisited
receipts as absent. One residual freshness limit remains: a negative cached lookup does
not watch every older non-contributing journal it examined, so an append to such an old
file may remain unseen until a watched file or the directory changes, the cache is
discarded, or the lookup is otherwise rebuilt.

The Share preview/export path has a separate direct, read-only JSONL contract. It streams
only event roots referenced by the selected seals, with production limits of 384 MiB per
source, 2 MiB per line, 2,880 retained seals, 131,072 required roots, 256 MiB of referenced
events retained for an export, and a process-local summary cache capped at 32 MiB across
two days. Boundary-seal and receipt lookup is separately bounded to 4,096 auxiliary files,
262,144 decoded rows, and 256 MiB of auxiliary sources. An
unchanged warm preview rereads zero event bytes; a verified append scans only the suffix.
A replacement, truncation, deletion, unstable or malformed source, exhausted limit, or
cancellation cannot publish or cache a partial result. Leaving the Share tab cancels its
active preview but deliberately retains the bounded cache. Actually hiding the dashboard
cancels preview and export work, clears rendered segments, and asynchronously discards the
Share cache; the next preview is therefore a bounded cold scan. The standalone Share
window also performs initial loading and export work off the main thread, asks for the
destination before building, and suppresses cancelled or late results. No Share cache is
persisted. Duplicate committed field names fail closed during seal/event verification,
and a receipt can elevate trust only when its anchor sequence, device identifier, and
anchor hash all match the seal. Export still materializes the encoded package `Data` in
addition to retaining up to 256 MiB of referenced events, so that byte ceiling is not a
strict upper bound on Swift heap usage.

The analysis JSONL reader rejects every line above 2 MiB before decoding, including a
newline-terminated line, and caps the unterminated pending buffer at the same size. The
application-managed and standalone `ComputerHistoryStore.buildAndWrite` paths each admit
at most 32,768 useful event/semantic values and 64 MiB of estimated retained evidence into
one engine pass. A very large raw day can still require a long streaming scan, and the
estimate does not include every decoder or engine allocation. Cancellation, a source identity change, an
exhausted evidence budget, or any source-load issue aborts the replacement and leaves the
existing JSON and Markdown last-known-good pair untouched. The standalone compact
`LocalActivityMemoryStore` build path uses the same half-open one-day bounds and failure
checks, but requests the derived-analysis projection so it preserves classification,
input origin, and bounded metadata needed by activity memory instead of applying Computer
History-only compaction. On success it writes only that day's `memory.json` and
`memory.md` pair; on any incomplete-source state it writes neither file. These guarantees
do not describe the separate legacy inspector and generic CLI loader helpers.

In the application-managed runtime path, a source replacement, deletion, inaccessible
path, or symbolic link is handled as an explicit state. The last known good derived views
are retained when a read cannot be trusted, instead of being overwritten or duplicated.

## Local query interface

Build the CLI:

```bash
swift build -c release --product goalong-history-query
```

Generate one day’s causal memory:

```bash
"$(swift build -c release --show-bin-path)/goalong-history-query" \
  computer-history 2026-08-21
```

This direct reconstruction reserves its transient evidence before retaining it:
at most 32,768 useful event/semantic rows and 64 MiB estimated from the compact
encoded values actually retained, their inline stride, and fixed per-row accounting enter
one day pass.
Raw integrity openings and unrelated metadata are discarded before this accounting;
the original journal is never rewritten. Exceeding either bound,
or encountering an unreadable, malformed, oversized, or replaced source during the
read, rejects the complete day instead of analyzing a partial projection. This is a
working-set estimate, not
a strict measurement of Swift heap overhead. Rows are admitted only when their
source interval intersects the half-open local-day interval `[dayStart, nextDayStart)`;
files whose names are broader or undated do not make out-of-day rows survive. The
evidence reader pins the supplied
root and its `events` and `semantic` directories with no-follow directory descriptors,
enumerates and opens files relative to those descriptors, and revalidates their
identities. A linked, swapped, or inaccessible root, parent directory, or final source
rejects the complete projection with an explicit coverage state. This guarantee belongs
to the bounded Computer History evidence reader used here; it is not a blanket claim
about every generic local-store helper.

Ask a natural local question over recent days:

```bash
"$(swift build -c release --show-bin-path)/goalong-history-query" \
  ask --days 30 "Where was I before my most recent break?"
```

Responses include evidence limitations, and hits expose whatever source provenance the
bounded projection retained. A compacted workflow or suggestion can survive after its
source episode IDs are omitted, so provenance is not guaranteed non-empty for every hit.
Search requires a real content, resource-kind, host, or status match before recency can
increase a result's score. An unrelated query therefore cannot receive a recent source
merely because it is recent.

Query preparation is also bounded before matching begins. The raw and normalized query
are each limited to 4,096 UTF-8 bytes; at most 64 distinct literal tokens and 64 semantic
expansion tokens survive, with 128 tokens total and 128 UTF-8 bytes per token. These
limits apply to both stored-memory ranking and the direct raw-source fallback.

The app's `ask` path loads up to 30 stored memories and is subject to the 32 MiB per-file
and 64 MiB cumulative encoded-memory budgets above. For lexical resource, task-status,
and generic questions, it also makes a direct read-only pass over the original event and
semantic journals. JSONL is streamed in 64 KiB chunks with an 8 MiB per-row ceiling; at
most one row plus one chunk is buffered, and at most 100 semantic candidates plus 100
matching hits survive in transient memory. Each source-directory listing visits at most
8,192 entries and retains at most 4,096 candidate files. No search index, cache, or source
copy is written. The app pass stops after 384 MiB of event journals or 128 MiB of semantic
journals and uses a 45-second cooperative deadline checked during enumeration and
streaming; one in-progress row decode is not forcibly preempted. A source root, directory,
or file that is itself a symbolic-link node is refused. The pinned root, source
directories, and every examined file are revalidated after the complete pass. Any
refusal, unreadable or malformed row, identity change, or exhausted budget produces an
explicit bounded coverage gap, so the answer does not present readable rows as an
exhaustive absence.

The CLI's `ask` path rereads raw journals one day at a time, analyzes each completed day
and the elapsed portion of today, and passes each bounded projection to the same search
service. Each reconstruction day uses the same 32,768-row/64 MiB estimated evidence
working-set bound as the direct command. A day that exceeds it is rejected, and that day
plus later requested days are reported unvisited rather than treated as absence. When a
lexical pass is useful, the CLI then performs a separate direct-source pass with the same
384 MiB event, 128 MiB semantic, symlink, line, and 100-hit bounds described above.
Reconstruction and lexical search share a 45-second cooperative ask budget, so the second
pass receives only the time left after reconstruction. The second pass adds I/O but avoids
retaining several decoded days merely for keyword matching and gives app and CLI source
search the same cumulative source-byte limits. Resume, summary, workflow, and interpreted
status answers remain derived from the projection. A detail omitted by compaction is
therefore searchable only when the lexical pass runs and the original journal still
contains a readable matching row; exact aggregate coverage alone cannot recover it.

`ask --days` accepts up to 365 days. Reconstruction checks the shared deadline between
days and retains projections until their encoded JSON sizes total 128 MiB, but it does
not cumulatively byte-cap the raw journals read to build those projections. The deadline
is not an interrupt during directory materialization/sorting or inside the engine analysis
that follows one bounded evidence load. One expensive day can therefore overrun 45
wall-clock seconds. Neither the per-day evidence estimate nor encoded projection size is
a strict heap-memory measurement, so a wide request can use more transient RAM than its
64 MiB/128 MiB accounting.
Any exhausted budget is returned as a coverage limitation rather than evidence of
absence.

## Privacy boundary

Full context remains permissioned and local. It does not add:

- screenshots or screen video;
- camera, microphone, or system audio;
- clipboard capture;
- raw character reconstruction from keyboard keycodes;
- private-window content;
- excluded application or domain content;
- Secure Input or protected-field content.

Before semantic persistence, Goalong samples fresh foreground context, checks Secure
Input and suppression state, performs the bounded Accessibility read, then samples and
validates again. The payload is persisted only when process, bundle, context fingerprint,
privacy state, and protected-field state still match. Common credential patterns are
redacted before persistence. Captured text is untrusted observed data and must never be
treated as an instruction by the local summarizer, query service, or external recap
agent.

A user may choose **Metadata-only history** during onboarding. That preserves apps,
windows, sanitized URLs, controls, clicks, shortcuts, scrolling, and grouped typing
signals, but exact intentions, semantic changes, status, and resume answers may remain
unknown.

## Automated validation

The macOS quality gate runs:

```text
swift test
privacy-boundary audit
installable app build
bundle validation
package smoke test
```

Reproduce the installed-app resource measurement after closing the dashboard:

```bash
bash scripts/measure_computer_history_runtime.sh --enforce-targets
```

The read-only script waits 60 seconds, takes 600 one-second samples, verifies that no
layer-zero Goalong window is on screen at the start and end, and reports CPU, raw RSS,
physical/lifetime-peak footprint, child processes, process wakeups, disk I/O, and logical
storage deltas by data class. Its output contains numeric metadata only; it does not
launch or control the app or read any history body. The interval precondition is still
operational: do not reopen the dashboard during the run.

Dedicated deterministic scenarios verify:

1. before/action/after linkage;
2. full preservation of several actions inside one minute;
3. file, document, conversation, and issue resolution;
4. natural resource lookup;
5. resume-before-break behavior;
6. separate completed and blocked work;
7. repeated workflow suggestions;
8. zero reconstruction of suppressed private content;
9. separation of unrelated browser tasks;
10. latest success overriding an earlier transient failure;
11. drag classification distinct from a click;
12. late “before” observations rejected as causal pre-state;
13. recorder callback loss represented by a bounded observation-gap event;
14. raw maintenance events counted for source coverage but excluded from causal episodes;
15. one source read feeding both recap views without deleting retained memory when raw
    events are absent;
16. compact memory retention, corrupt-file fallback, and explicit owned-only deletion;
17. a 10,000-action day retaining exact coverage with a bounded representative JSON.

Run the focused validator:

```bash
bash scripts/validate_computer_history_parity.sh \
  --day YYYY-MM-DD
```

For a controlled real-input day:

```bash
bash scripts/validate_computer_history_parity.sh \
  --day YYYY-MM-DD \
  --require-real-context \
  --minimum-pair-ratio 0.80 \
  --codex-event-root /path/from/computer_history_status \
  --start-utc YYYY-MM-DDTHH:MM:SSZ \
  --end-utc YYYY-MM-DDTHH:MM:SSZ \
  --confirm-physical-user-input
```

The optional Codex↔Goalong probe is enabled only when `--codex-event-root`,
`--start-utc`, and `--end-utc` are supplied together. It performs bounded, read-only
source scans and emits only counts, first/last observation timestamps, time buckets,
tolerances, coverage states, and limitations; it emits no event bodies, paths, snapshots,
or index. When a broad source root is selected, canonical ten-minute Codex segment
directories are reduced to the segment covering the interval start plus segments begun
inside it, and canonical Goalong daily journals are reduced to the UTC/local dates that
overlap the interval. Unrecognized layouts remain eligible, and the metadata output
reports how many dated entries were skipped. The validator requires
`--confirm-physical-user-input` for this probe. Synthetic
input, Computer Use, or other automation cannot satisfy that attestation or support a
live parity claim.

Validation does not create a complete
`YYYY-MM-DD.computer-history.json` artifact in its output directory. The transient CLI
JSON is piped directly into the invariant checker over standard input and discarded. The
durable validation directory contains environment metadata, metadata-only checker/probe
logs, and the manual checklist, not a second Computer History body store. `--output`
chooses that directory; it must be new or empty and not a symbolic link.

`check_computer_history_memory.py` validates internal consistency of the CLI JSON:

- persisted exact action and linked-interaction counters are equal;
- retained interactions are not duplicated across retained episodes;
- retained episode and interaction provenance is non-empty;
- retained episode and interaction resource IDs reference valid retained resources;
- suggestions reference valid retained workflow and episode IDs;
- retained episodes and interactions are chronological;
- retained episode, interaction, and resource array sizes match their explicit retained
  counters when representative projection is active;
- optional semantic-pair thresholds are met.

The checker does not independently reread the raw journal, prove that every operating-
system action was captured, validate workflow-pattern episode IDs, or inspect details
omitted from a representative projection. The controlled real-input validation remains
necessary for those claims.

## Measured local acceptance snapshot

The following measurements were taken on 2026-08-25 on macOS 26.5.1 (25F80), an
Apple M4 Pro with 24 GB RAM, using the installed source build
`20260825.202039` (`CDHash c28d23d6409a54598985d607eb23fd91d1d011a3`). The
application was one process with no child/helper process. Before idle sampling, the
dashboard was closed through its real close button, its absence from the on-screen
window list was verified, and more than 60 seconds elapsed.

| Surface | Measured result |
| --- | --- |
| background CPU, 600 one-second samples | median 0.2%, p95 1.3%, maximum 99.7%; 8 samples exceeded 15%, with a longest consecutive run of exactly 5 seconds |
| closed-window memory | macOS physical footprint 44 MB; lifetime physical peak 146 MB; raw `ps` RSS median 150.1 MiB, p95 203.5 MiB, maximum 222.6 MiB |
| UI peak improvement | lifetime physical peak 146.1 MB versus the prior measured 476.3 MB view peak, a 69.3% reduction |
| derived Computer History storage | 4 compact JSON days, 3,431,360 logical bytes / 3,360 allocated KiB after the final installed-UI read, down from 33,536 allocated KiB before legacy-derived compaction |
| direct-source Agent Activity index | 792 entries in 773,900 bytes (977.1 bytes per entry) after the final direct-source UI read: Codex 777, Claude Code 1, OpenCode 14; all available |
| transcript duplication check | zero files and zero bytes in `agent-activity/blobs`; durable Agent Activity files are the bounded index, configuration, one small wake-up signal, and an empty lock |
| real French resume query | one current day reconstructed in 3.07 seconds; maximum RSS 83,361,792 bytes and physical footprint 74,842,712 bytes; 12 source-backed episode hits |
| complete automated suite | 575 tests, 2 skipped, 0 failures; Agent Activity selection 93 tests, 1 skipped, 0 failures |
| parity validator | 9/9 parity scenarios, 3/3 episode-quality scenarios, privacy audit, checker regressions, and 18/18 metadata-probe tests passed; output directory was 52 allocated KiB and contained metadata/checklists only |

Raw RSS includes reclaimable mappings and allocator pages and is therefore reported
separately from macOS `phys_footprint`, the memory-pressure measure used for the
closed-window budget. The single one-second CPU maximum is not hidden; the sustained
limit is satisfied because no run above 15% lasted more than five samples.

The current installed identity still reports Accessibility functional/preflight and
Input Monitoring preflight as unavailable. Consequently these measurements prove the
degraded-permission idle path, bounded analysis, storage, queries, build, launch, and UI
behavior. They do **not** prove current-build physical input capture, live
Codex-versus-Goalong coverage, permission recovery after a real TCC grant, or third-party
application AX quality. That final claim remains gated on the controlled real-input
checklist below and must be rerun after any reinstall that changes the app's ad-hoc
`CDHash`.

## Real-session proof boundary

Unit tests cannot prove macOS TCC behavior, third-party Accessibility quality, browser URL
exposure, private-mode detection, or the timing of a live UI transition. Before a
measured parity claim is published, run the generated real-session checklist against the
signed app identity and the applications included in that claim.

A passing real-session validation supports this statement:

> On the tested macOS build and applications, Goalong History reproduced the publicly
> documented analysis behaviors covered by the parity suite.

It does not support this statement:

> Goalong is byte-for-byte or internally identical to a private proprietary
> implementation.
