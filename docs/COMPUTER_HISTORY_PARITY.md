# Goalong History — Computer History analysis parity

This document describes the Goalong implementation of the publicly documented
Computer History **capture and evidence** behavior: chronological interaction capture,
local causal evidence, source recovery, and a compact representation that a later agent
can inspect.

It does **not** claim access to, or equivalence with, any undocumented private
implementation. Parity claims must be limited to behavior that has been exercised on
the tested macOS build and applications.

Reference behavior: <https://learn.chatgpt.com/docs/customization/computer-history>

## Scope: capture parity, not background-agent parity

Computer History has two separable planes:

1. the **capture/evidence plane** observes eligible local interactions and context, keeps
   chronology and provenance, represents gaps, and makes the original evidence readable;
2. the **interpretation plane** lets an AI answer questions or generate a human-facing
   summary from that evidence.

Goalong's parity target is the first plane. Goalong does not run a background language
model to interpret every interval. Its recorder, reduction, indexing, search preparation,
and agent-context projection are deterministic and local. When an explicitly invoked
agent needs the day, Goalong renders a transient token-bounded evidence pack; the optional
Daily Recap feature is a separate user-triggered integration and is not part of the
Computer History capture loop.

Accordingly, the primary quality measures are capture richness, chronological and source
coverage, explicit uncertainty, reopenable provenance, and information per approximate
token. A polished generated summary is not evidence that capture parity was achieved.

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
| clicks, grouped typing, shortcuts, scrolling, app/window/site context | one local input pipeline with event-time action metadata plus bounded asynchronous settled/observer context | deterministic capture tests pass; an exact-final-build repeat-key interval retained 20 causal actions with 80.0% semantic coverage, matched every Codex-classified bucket and reported zero explicit gaps or read issues |
| searchable chronology and local memories | causal episodes plus exact coverage totals and a bounded representative projection | parity/evidence/storage tests and installed UI inspection pass |
| compact evidence for a later agent | deterministic on-demand evidence pack with exact totals, distributed high-value episodes, causal changes, and deduplicated source locators | unit evals and a real read-only day probe enforce token bounds and measure evidence slots per approximate token; no LLM runs in the capture loop |
| resume after a break and summarize recent work | intent-aware local search over causal episodes, including French resume phrasing and explicit today/yesterday/week scoping | English/French query tests and real local source-query measurements pass |
| recover a file, page, document, conversation, issue, or terminal context | stable source references with direct-source fallback and provenance | resource-resolution and query tests pass; unavailable locators stay explicit |
| distinguish completed, in-progress, blocked, waiting, planned, and unknown work | cautious evidence-derived status with latest visible state taking priority | deterministic status scenarios pass; status remains an interpretation |
| suggest skills or automations from repeated work | bounded cross-day workflow clustering; suggestions never auto-run | repeatability scenarios pass; real multi-day usefulness remains data-dependent |
| choose contributing apps and websites | exclusion lists plus fail-closed include-only app/domain scopes; exclusions, private browsing and protected apps always win | configuration and recorder-policy tests pass; old configs decode with allow-all include scopes |
| pause, resume, exclude, and delete at documented scopes | menu-bar/UI controls, app/domain exclusions, private/secure suppression, 10-minute/hour/day/all deletion, exact Computer History-item deletion, and most-recent/selected app-session deletion | targeted fixtures prove full provenance recovery, exact raw/semantic removal, other-day preservation, malformed-row refusal, and bounded streaming; the installed stable-signature UI exposes item/session deletion, while a physical deletion exercise remains intentionally unperformed |
| avoid screenshots, audio, clipboard, keystroke reconstruction, and private browsing | Accessibility text and interaction metadata only, with credential redaction | privacy audit and suppression tests pass |
| stay unobtrusive and recoverable | one process, no helper, health state, bounded queues/caches, AX storm debounce, polling fallback | the Apple Development-signed installed build retained all TCC preflights and passed the 10-minute resource gate; post-fix physical wake/input recovery remains unproved |

## Architecture migration

| Before this hardening | Current architecture |
| --- | --- |
| Derived days could retain the complete causal arrays and a second local Markdown copy. | An eligible day is analyzed completely only when it fits the documented source-integrity, row, byte, and working-set bounds; then one compact JSON keeps exact totals plus a bounded representative projection, and only one optional Codex Markdown projection remains. |
| Search depended on retained derived detail, while generic questions could repeatedly scan wide raw-journal ranges and repeat the same source text. | Stored memory is searched first. A bounded read-only raw pass runs only when no retained evidence matches and the intent needs lexical recovery; explicit today/yesterday/week questions scope reconstruction to that interval, while result snippets are capped at 240 characters and repeated source locators merge their provenance. |
| Repeated refreshes could independently decode the same day and retain large integrity arrays in memory. | Activity Analysis and Computer History share one day pass, drop regenerable per-field commitments from transient copies, and use a small revision cache plus append debounce. |
| A live append during a full-day pass invalidated the whole refresh even when the recorder only extended the same journal. | The runtime pins the probed event and semantic byte ceilings, reads exactly those validated prefixes, accepts only same-inode append-only growth, and catches up on the following cycle. Replacement, truncation, same-size mutation, or an incomplete row boundary still fails closed. |
| Every application build number changed the analysis revision, and timestamp jitter could invalidate an otherwise intact append cursor. | The revision is scoped to the analysis algorithm and embedded in every compact day projection. App, search, and CLI readers refuse an older projection and fall back to the original journal or regeneration instead of serving stale conclusions. Physical journal order is verified by sequence/hash continuity independently of timestamp sorting, and a maintenance-only append reads just its pinned suffix even while newer bytes arrive. |
| Whitespace cleanup created one Foundation regular-expression result per ordinary match and retained a complete pass of autoreleased temporaries. | Layout normalization is one linear Unicode-scalar pass; credential patterns remain compiled regexes, and their temporary Foundation objects drain once per bounded observation. |
| The Computer History page eagerly built every retained episode card and rebuilt the same source dictionary for each card. | The timeline and page body are lazy, one source index is shared by all visible cards, transient dashboard caches are cleared on close, and free allocator pages are returned after the window graph drains. |
| Missing or unsafe raw input could erase or replace the useful derived view. | The last known-good memory remains visible with an explicit `absent` or `inaccessible` source state. |
| The optional Codex Markdown mirror could exceed 2 MB for one busy day and the ChatGPT recap could repeat the same causal text in its legacy minute digest. | The mirror now uses a deterministic 3,000-token ceiling, the on-demand agent pack accepts an 800–12,000-token budget, sources are aliased once, and a recap with causal history keeps only complementary duration aggregates from the legacy view. |
| A compact episode retained only representative provenance, so deleting one visible summary would otherwise require an unsafe broad interval clear. | Explicit item deletion re-reads the original local journal on demand, rebuilds complete episode provenance, removes only the resolved event IDs and linked semantic snapshot IDs, invalidates only the affected day’s derived files, and records a continuity boundary while preserving seals, receipts, Screen Time and Agent Activity. |
| An already indexed agent transcript that was still growing could be re-hashed in full on every 30-second metadata poll. | Background scans retain the prior complete fingerprint while the same inode grows, then perform one streaming re-hash after two minutes of quiescence. New files, truncation, replacement, forced reconciliation, explicit analysis, and direct reads bypass the delay. No body, version, or snapshot is persisted. |
| A privacy, stale-input, or context boundary cancelled the open interaction and also emptied every later queued callback; those defensive discards were then mislabeled as `bounded_ingress_overflow`, amplifying one boundary into hundreds of apparent losses. | Boundaries still cancel every open burst, gesture, and deferred semantic capture, but later queued inputs remain bounded and independently repeat event-time privacy, target, protected-control, private-window/domain, and freshness checks. Only a proven capacity overflow discards the remaining queue and records `bounded_ingress_overflow`. |
| A missing explicit `before` snapshot left many otherwise continuous interactions context-poor, and the validator compared provider-specific raw row counts one-to-one. | The prior settled outcome becomes the next eligible interaction's bounded before-state without another AX read; app switches may carry the last chronological public state but never cross a continuity/privacy barrier or browser-host boundary. Physical comparison uses bounded occupied time buckets and numeric burst spans, while raw row counts remain informational. |
| The first callback of an interaction synchronously traversed Accessibility up to three times (`near_event`, `after`, and `settled`) on the main queue, so a slow application could age later callbacks out of the bounded ingress window. | Event-time action metadata remains immediate; rich AX traversal runs on one in-process utility queue with at most two admitted captures, is invalidated across stop/clear generations, and crosses a fresh public-boundary check before commit. Physical interactions request one full `settled` state after inactivity, while debounced AXObserver and periodic observations retain intervening semantic evidence. No helper process or durable queue is added. |
| Every drained input also forced a complete foreground context sample; Electron web wrappers such as WhatsApp could be mistaken for full browsers and repeatedly walk browser chrome before the next callback was admitted. | The immutable callback-time public context is accepted only while its PID remains frontmost. Admission separately rechecks global Secure Input, the focused protected-control state, app exclusions, and private-window/domain policy. Ordinary web wrappers skip browser-chrome traversal; configured or recognizable browsers retain the browser privacy probe. |
| The periodic semantic fallback walked a complex but unchanged foreground AX tree every 15 seconds, creating regular CPU spikes even while the user was idle. | Actions and AXObserver notifications remain immediate. Only the fallback adapts to whole-session idle time: configured cadence while active, then 30, 60, and at most 120 seconds. This changes no durable schema and wakes less when no new user evidence can exist. |
| Fine-grained observations could be projected as many one-interaction episodes, so a later agent spent most of its budget on repeated app/window scaffolding instead of the user's work. | Episode boundaries now combine temporal continuity, app/resource continuity, interaction causality, public UI state, and explicit stop/switch signals. Every reconstructed activity remains pageable, while the bounded agent pack keeps a complete lightweight episode skeleton and progressively adds the highest-value evidence. |
| Each progressive rendering level repeatedly rescored and resorted every interaction, and read-only history analysis rebuilt every per-field disclosure commitment plus an ICU timestamp formatter for each row. | One immutable interaction ranking is computed per episode and reused at every detail level. The specialized read-only analysis path validates packed integrity without retaining regenerable commitment arrays, uses an allocation-light canonical UTC parser, and falls back to Foundation for legacy timestamp variants. Full export/default decoding still reconstructs the complete integrity material. |
| Repeated AX captures could persist semantically identical focused/viewport text even when identifiers differed. | A bounded semantic fingerprint removes exact intra-interaction duplicates while preserving chronology, source provenance, and distinct visible states. Focused-control/viewport overlays add future high-value context without copying a transcript or widening protected/private capture. |

The raw Goalong event and semantic journals remain the authoritative evidence.
Compaction changes only derived storage and search working sets; it does not
rewrite or shorten those journals.

## Product behavior

With **Full Computer History context** enabled, Goalong History can reconstruct:

- the ordered stream of clicks, grouped typing, shortcuts, navigation keys, scrolling,
  app changes, windows, pages, and focused controls;
- bounded semantic state observed chronologically before an interaction when available,
  by debounced AX notifications during work, and once after the UI has settled;
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

Settings expose both exclusion lists and optional include-only lists for applications
and website domains. Empty include-only lists preserve the existing allow-all behavior.
Once an include-only list is populated, missing application identity or browser host
fails closed; exclusions and private/secure suppression retain priority. The menu bar
offers the same documented bulk-clear windows: last 10 minutes, last hour, last day,
or all detailed history. An expanded Computer History card can delete that exact item,
the activity timeline can delete a selected app session, and Privacy offers the most
recent app session. Those targeted paths resolve exact source IDs before mutation; they
never translate a visible card into a broad timestamp cutoff.

## Analysis pipeline

```text
CGEventTap + NSWorkspace + AXObserver + foreground polling
                         │
                         ▼
             privacy-aware context sampler
                         │
                         ▼
 prior observation → input action → asynchronous settled/AX observation
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
 compact structured JSON + bounded Codex projection + local search
                         │
                         ▼ explicit request only
       transient token-bounded agent evidence pack (no LLM, no write)
```

### Information per token

`ComputerHistoryAgentContextRenderer` builds the agent-facing view from structured local
evidence. It never reads or trusts a previously rendered Markdown body. Exact coverage and
the source sequence/hash boundary are reserved first. Within the remaining budget it:

- samples across the day so early, middle, and late work can remain represented;
- prioritizes observable outcomes, intentions, before/after pairs, semantic changes, and
  reopenable sources;
- treats completion as an outcome only after a causally linked visible action state;
  words the user typed and ambient window text can never prove that work completed;
- caps representative interactions per episode;
- emits each selected source locator once and references it with a short alias;
- labels status as inferred and omits workflow suggestions from the evidence plane;
- redacts common credentials again at render time.

The reported `informationFactsPerThousandTokens` is a deterministic regression proxy. A
"fact" is one emitted evidence slot, such as a coverage value, episode field, interaction,
semantic change, or source locator. It does not claim to measure an LLM's comprehension.
The pack can be read without persistence:

```bash
goalong-history-query computer-history-context YYYY-MM-DD --tokens 1600
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

The reader keeps all four phase labels for backward compatibility and direct-source
analysis. Current physical-input capture emits one linked `settled` snapshot per quiet
interaction instead of synchronously walking AX at `near_event` and `after`. This removes
redundant reads from the latency-critical path; event-driven and periodic observations
still supply chronological public state between interactions.

When no explicit chronological `before` exists, the interaction builder may use the
nearest earlier eligible observation from the same application or the bounded settled
outcome of the prior interaction on the same resource. An application switch may use the
latest chronological public state from the application being left. These fallbacks never
cross a suppression/integrity boundary, a browser-host boundary, or the 64-candidate
carry-forward bound. A delayed callback can never masquerade as a causal pre-state, and
the fallback performs no new Accessibility read.

The supported budgets remain phase-aware. Rich traversal itself runs outside the input
queue, with at most two captures admitted across running and queued work:

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
window and on the correct side of the action timestamp, or the barrier-safe prior outcome
described above. Coverage reports distinguish complete pairs from partial context.

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

New schema-v5 event rows keep the complete observed event and one reversible base64
material block containing the chain/root hashes, raw-event digest, and ten independent
salts. They do not repeat the same event values inside ten commitment openings or expand
fixed 32-byte values as JSON arrays and hexadecimal strings. A read reconstructs those
openings and hashes deterministically in memory before existing Merkle/share verification
runs. Historical schema-v2–v4 rows and the earlier schema-v5 `salts-v1` envelope remain
directly readable and are not migrated or rewritten. Projecting the real 2026-08-25
journal into the exact `material-v1` representation measured 10,610,976 bytes instead of
30,793,467 bytes (-65.5%) with the same 7,246 events, including a further 1,383,986-byte
reduction from `salts-v1`. This is a format projection, not a destructive rewrite or a
measurement from the not-yet-installed build. A newly recorded rich test event measured
1,423 bytes versus 1,614 bytes with `salts-v1` and 4,277 bytes with full duplicated
openings (-66.7% versus full openings).

New schema-v2 minute seals apply the same reconstruct-on-read rule to their four
commitment openings and fixed-width hashes. One material block retains the event roots,
minute/anchor hashes, and four independent salts; local day/time-zone coverage,
signature, and device material remain separately readable. Existing verification,
sharing, dashboard, and upload code receives the same reconstructed values. Historical
schema-v1 seals and the earlier schema-v2 `salts-v1` envelope remain readable and are
never rewritten. Projecting the real 2026-08-25 seal journal into the exact
`material-v1` representation measured 1,416,715 bytes instead of 2,653,761 bytes (-46.6%)
across the same 1,127 seals, a further 336,408-byte reduction from `salts-v1`. A newly
persisted test seal measured 841 bytes versus 1,034 bytes with `salts-v1` and 1,833 bytes
with full duplicated openings (-54.1% versus full openings). These are format/test
measurements from the source build, not yet an installed-build growth measurement.

An isolated optimized Release micro-benchmark over 50,000 event-integrity envelopes
measured `salts-v1` encoding at 8.750 microseconds per row and `material-v1` packing plus
encoding at 9.925 microseconds; `salts-v1` decoding plus salt validation took 8.725
microseconds and `material-v1` decoding plus unpacking took 5.352 microseconds. The
write-then-read pair was therefore 12.6% faster in this narrow benchmark despite the
1.175-microsecond write cost, before accounting for reduced filesystem I/O. This is not a
substitute for the installed ten-minute whole-process measurement.

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

For a single Computer History item, Goalong reconstructs the complete episode provenance
from the original bounded day source because compact memory may retain only 16
representative event references. A read-only preflight must find every selected event ID
and classify every candidate row before any raw file is replaced. The raw JSONL pass uses
64 KiB chunks with a 2 MiB maximum row and a 32,768-ID selection ceiling; timestamps only
bound candidate day files and never broaden the match. Linked semantic payload IDs are
then removed from their own captured-at day files, and only the source event day’s
Activity Analysis, Activity Memory, Computer History JSON, and optional Codex projection
are invalidated for rebuild.
Malformed, oversized, linked, missing, changed, incomplete, or over-budget sources fail
closed. Cryptographic seals and receipts remain as explicit private/gap evidence.

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
after decoding; schema-v5 journals retain the salts and event fields needed to reconstruct
those arrays for verification or selective disclosure, while the derived pass retains
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
and 64 MiB cumulative encoded-memory budgets above. It asks that compact projection
first. Only when the retained answer has no hits and the intent is a lexical resource,
task-status, or generic question does it make a direct read-only pass over the original
event and semantic journals. Explicit today, yesterday, and this-week wording also
narrows that fallback to the requested interval. JSONL is streamed in 64 KiB chunks with
an 8 MiB per-row ceiling; at most one row plus one chunk is buffered, and at most 100
semantic candidates plus 100 matching hits survive in transient memory. Results with
the same stable local path or canonical URI are presented once, with representative
combined provenance capped at 16 references per provenance field, and every presented
snippet is bounded to 240 characters. Each source-directory listing
visits at most 8,192 entries and retains at most 4,096 candidate files. No search index,
cache, or source copy is written. The app pass stops after 384 MiB of event journals or
128 MiB of semantic journals and uses a 45-second cooperative deadline checked during
enumeration and streaming; one in-progress row decode is not forcibly preempted. A source
root, directory, or file that is itself a symbolic-link node is refused. The pinned root,
source directories, and every examined file are revalidated after the complete pass. Any
refusal, unreadable or malformed row, identity change, or exhausted budget produces an
explicit bounded coverage gap, so the answer does not present readable rows as an
exhaustive absence.

The CLI's `ask` path rereads raw journals one day at a time, analyzes each completed day
and the elapsed portion of today, and passes each bounded projection to the same search
service. It applies the same retained-answer-first rule as the app before deciding
whether a separate lexical source pass is necessary. Explicit today, yesterday, and
this-week questions override a wider `--days` request and reconstruct only that interval.
Each reconstruction day uses the same
32,768-row/64 MiB estimated evidence working-set bound as the direct command. A day that
exceeds it is rejected, and that day plus later requested days are reported unvisited
rather than treated as absence. When a lexical pass is useful, the CLI then performs a
separate direct-source pass with the same 384 MiB event, 128 MiB semantic, symlink, line,
and 100-hit bounds described above.
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
substantial layer-zero Goalong window (at least 640×480) is on screen at the start and
end, and reports CPU, raw RSS, physical/lifetime-peak footprint, child processes, process
wakeups, disk I/O, and logical storage deltas by data class. The size floor excludes
non-capturable macOS thumbnails while remaining well below Goalong's 1080×680 dashboard
minimum. CPU percentages are calculated from per-interval
`proc_pid_rusage` CPU-time deltas divided by `mach_continuous_time`; macOS `ps %cpu` is
deliberately not used because it is a decaying average over up to one prior minute and
can misattribute pre-benchmark activity. The process-time totals are converted from Mach
absolute-time units to nanoseconds. The output contains numeric metadata only; it does
not launch or control the app or read any history body. The interval precondition is
still operational: do not reopen the dashboard during the run.

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
17. a 10,000-action day retaining exact coverage with a bounded representative JSON;
18. a deterministic agent pack respecting 800- and 3,000-token budgets, retaining exact
    coverage/provenance, spreading selected episodes chronologically, redacting secrets,
    ignoring stale Markdown, and increasing represented facts monotonically with budget.

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

Provider rows are first projected into bounded occupied time buckets. Numeric interaction
start/duration metadata can cover several buckets for one grouped typing, scrolling, or
drag burst, up to a fixed 60-second span; raw row counts remain visible but do not decide
parity because providers use different granularities. Bucket intervals are then paired
one-to-one within the configured tolerance, so one bucket cannot falsely cover several
distinct Codex buckets. The oracle is intentionally directional: missing or unmatched
Codex-classified evidence in Goalong fails; comparable bucket coverage passes as
`observed_within_tolerance`; and complete Codex coverage plus extra Goalong-classified
context passes separately as `goalong_at_least_codex`. Goalong-only activity cannot
establish a Codex baseline, explicit capture gaps remain insufficient, and extra evidence
is not automatically claimed to be useful merely because it exists.

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

### Latest information-density and performance iteration (2026-08-30)

This iteration addresses the 2026-08-29 failure mode where Goalong retained more raw
observations than Codex but returned a fragmented, repetitive story under the same token
budget. The authoritative journals remain unchanged. Only segmentation, compact derived
memory, read-only decoding, search, progressive rendering, CLI projection, and the factual
10-minute UI were changed.

| Surface | Current measured result |
| --- | --- |
| complete Swift suite | 677 tests, 6 expected environment-dependent skips, 0 failures in 108.965 seconds; the previous complete run on the same source path took 189.400 seconds, a 42.5% reduction |
| strict parity validator | 9 causal-parity, 11 episode-quality, and 3 agent-context scenarios passed, followed by the privacy audit, causal checker regressions, 28 metadata-probe tests, runtime-measurement tests, signing/network policy, Release CLI build, causal invariants, and four natural-query metadata checks; the final real-context run required a 0.80 semantic-pair ratio and passed at 95.8% on the attested physical window |
| dense compact-reader regression | the 10,000-event fixture fell from 76.619 seconds to 8.787 seconds; the 640-interaction progressive-render fixture completed in 0.081 seconds under its 2-second guard |
| episode coherence | on the shared regression interval, the prior reconstruction produced 100 episodes including 75 single-interaction episodes; the current rules produce 4 coherent episodes and 0 single-interaction episodes while retaining the exact interaction/provenance totals |
| installed identity | Goalong History `0.5.1` build `20260830.041918`, Apple Development signed, Team `2L5SSLPX46`, CDHash `6992839f931bd8efcf310935bc70ba6795851d05`; Accessibility preflight, functional probe, and Input Monitoring preflight are true and the event tap is `createdEnabled` |
| installed idle process | one process, no child, 4 threads, 0.0% sampled CPU, 20.3 MiB physical footprint and 54.9 MiB lifetime physical peak after the final installed build settled |
| installed stale-day fallback | because the pre-v7 2026-08-29 projection is deliberately refused, the complete `computer-history-context` first-read path used the authoritative journals in 6.53 seconds with 98,516,992-byte maximum RSS and 86,606,520-byte peak physical footprint; this is the bounded one-day rebuild path, not the fast path for a current projection |
| installed exact 10-minute CLI | the authoritative-journal interval completed in 1.13 seconds with 46,415,872-byte maximum RSS and 34,423,384-byte peak physical footprint, down from about 28.4 seconds before the ranking/integrity/parser work |
| 10-minute information density | 1,391 approximate tokens expose 139 selected facts from 312 available facts across 12 interactions and 10 resources (99.9 selected facts per thousand approximate tokens); the removal of an unproved fallback outcome reduced both available and emitted noise |
| shared-window provider probe | four physical 10-minute windows all report `goalong_at_least_codex`: Codex/Goalong rows were 162/557, 139/969, 113/518, and 66/461; every source read was complete and issue-free, and the metadata-only probe performed no writes or snapshot/index creation |
| persisted complete day | the retained pre-v7 2026-08-29 file is 1,052,821 bytes, has no `analysisRevision`, and is therefore reported stale instead of being served; the CLI reads the original journals and the app will regenerate that disposable projection when the day is next opened while unlocked |
| real full-day invariants | 6,119 actions equal 6,119 interactions across 102 activities and 169 resources; 4,920 interactions have paired semantic state (80.4%), and the compact projection retains all 102 activity shells plus 640 representative interactions |
| direct-source AI conversations | the final 2026-08-29 query visited the 5 indexed candidates that had activity that day, returned all 5 with 0 omitted and 0 issues, and verified 245,697,468 current source bytes; three conversations began before that local day and every displayed title was user-facing rather than a rollout filename, proving selection by day activity rather than creation date |
| lightweight Agent Activity index | 811 entries in 793,694 bytes (about 979 bytes per entry): Codex 796, Claude Code 1, OpenCode 14; durable companion files are a 1,632-byte configuration, a 146-byte signal, and an empty writer lock |
| no transcript duplication | after the real AI-conversation read, the 10-minute Computer History render, and a 30-second installed-runtime observation, every Agent Activity file hash and the index size/mtime were unchanged; no `blobs` directory exists anywhere under the Goalong root |
| 30-second logical storage growth | after a real AI-conversation read and a real 10-minute Computer History render, events (399,032 KiB), semantic evidence (35,448 KiB), seals (23,072 KiB), Computer History (8,204 KiB), analysis (5,772 KiB), memories (34,156 KiB), Agent Activity (784 KiB), and Screen Time (4 KiB) were all unchanged while the locked/secure-input state was idle |

The shared-window probe proves one-way classified raw-evidence coverage on those physical
intervals, not private implementation identity or the usefulness of every additional row.
The bounded pack was also compared with the corresponding Codex 10-minute memory: it
retained the applications, source files/pages, chronological switches, and recoverable
resources needed to resume the observed work. A historical Control Center value that was
not present in Goalong's original journal cannot be reconstructed retroactively; the new
focused-control/viewport overlay improves that class of future evidence only.

The final app launch occurred while macOS was locked and Secure Input was active. The
installed identity and permissions are verified, but a fresh physical callback and a new
unlocked screenshot of this exact build remain outside this snapshot. The earlier attested
physical window remains valid source evidence and passed the final metadata validator, but
it predates this exact signed build. Apple Screen Time is
preserved but currently reports that Full Disk Access is required; this is a separate Apple
data-source limitation, not a Computer History journal or Agent Activity regression.

### Current development verification (2026-08-28)

The current `main` source adds bounded automatic recap retries and a read-only
`goalong ai-conversations` query. The CLI opens only the existing lightweight index,
then reads matching provider sources in place for the selected local day. It emits only
user prompts and final assistant replies; it neither discovers providers nor rewrites the
index. OpenCode dialogue is filtered by row timestamp while its complete logical source
size and fingerprint remain verified.

| Surface | Current measured result |
| --- | --- |
| complete Swift suite | 653 tests, 5 expected environment-dependent skips, 0 failures |
| release CLI against the real 2026-08-27 sources | 7 relevant Codex conversations; 6 available and 1 clearly inaccessible; 7 returned, 0 omitted, no rollout filename used as a title |
| bounded output | 96,952 JSON bytes under the requested 160,000-byte/approximately 40,000-token ceiling |
| release CLI resources | 0.60 seconds wall time and 23,887,872-byte maximum resident set; invocation exits with no persistent process |
| direct-source working set | 399,171,152 logical source bytes verified across the selected conversations; output retains only bounded transient dialogue projections |
| lightweight index | 809 entries in 791,663 bytes (about 979 bytes per entry); configuration 1,632 bytes and wake-up signal 146 bytes |
| no-duplication proof | every file below `agent-activity-v2` had the same SHA-256 before and after the real CLI query; no `blobs` directory exists |
| package validation | arm64 release bundle 29,420 allocated KiB; embedded CLI 7,382,128 bytes; bundle, CLI and Sparkle components passed strict signature and privacy validation |

That package was built ad hoc only as an isolated validation artifact and was not installed,
because replacing the installed app with an ad hoc identity would make macOS privacy grants
unstable. It is therefore build/package proof, not current installed-capture or TCC proof.

### Current installed verification

The final source installation measured on 2026-08-26 is Goalong History `0.5.1`
build `20260826.195517`, signed by `Apple Development: mathis-blanc@hotmail.fr
(M6Y4HJP9L3)` with Team `2L5SSLPX46` and CDHash
`5d21d4fa119cf70f094998dae62e0d13fea06d9b`. The exact installed identity reports
Accessibility preflight/functional probe and Input Monitoring preflight all true, with
the event tap in `createdEnabled` state.

The final reader additionally treats a live JSONL as a pinned prefix: when the same inode
grows, Goalong hashes the exact prefix it consumed and accepts it only if those bytes are
unchanged. The next read sees the appended rows. Replacement, truncation, in-place prefix
mutation, symlinks, and inaccessible paths still fail closed. This lets the dashboard,
causal query, raw fallback, and metadata-only parity probe read an active recorder without
copying the journal or waiting for a quiet window.

| Surface | Current measured result |
| --- | --- |
| complete source-installer suite | 619 tests, 3 expected environment-dependent skips, 0 failures; source, staged, and installed bundles each passed signature and privacy validation |
| exact-final-build closed-window CPU, 60 one-second kernel-delta samples | median 0.007%, p95 3.974%, maximum 4.833%; 0 samples exceeded 15% and every enforced resource target passed |
| exact-final-build closed-window memory | macOS physical footprint 30,180,312 bytes (28.8 MiB); lifetime physical peak 142,148,592 bytes (135.6 MiB); raw resident size median 53,152 KiB, p95/maximum 62,272 KiB |
| exact-final-build one-minute process activity | one process, 0 child/helper; 204,800 bytes read, 122,880 bytes written; 2 idle and 60 interrupt wakeups |
| exact-final-build one-minute logical storage growth | startup/foreground context produced events +43,125 bytes, semantic +4,832 and seals +1,828; Computer History, analysis, memories, Agent Activity and Screen Time each +0 bytes |
| direct-source Agent Activity | 797 entries / 778,752 bytes: Codex 782, Claude Code 1, OpenCode 14; one bounded Codex slice and the Claude source matched their stored hashes when reread from the original files, and all 14 OpenCode opaque locators resolved from SQLite in read-only/query-only mode with 0 changes |
| transcript duplication check | no persisted body-like keys in the live index, index bytes and modification time unchanged during direct reads, and zero `agent-activity/blobs` directories |
| exact-final-build repeat-key physical interval | 10 public seconds produced 32 Goalong rows, 20 causal actions, 16 semantic pairs (80.0%), 1 episode and 1 resource; the surrounding stress retained 20 navigation keys plus typing, scroll and click activity with zero `stale_ingress` or other explicit observation-gap rows |
| provider-granularity probe | `goalong_at_least_codex`; all 5 Codex typing observations paired in time, Goalong retained additional settled-semantic evidence, and both bounded source reads were complete, metadata-only and issue-free |
| active-source concurrency | a causal query and the metadata-only provider probe both completed while Goalong continued appending; tests prove the first pass returns one stable prefix, the next pass sees the append exactly once, and prefix mutation plus growth is rejected |
| real installed runtime/UI boundary | one signed process, healthy real callbacks, and the full Computer History view were observed: 583 episodes, 3,274 interactions, 54 source links, 47% paired semantic states, 118 completion signals, 174 unfinished/blocked/waiting episodes, 8 workflow suggestions, and 1,217 explicit coverage gaps |
| direct dashboard reader on the live root | fresh snapshot; 7,889 retained events, 298 active minutes, 17 applications, 96 timeline buckets, 0 partial sources and 0 budget failures; 4,407,226 cached estimated bytes plus 1,198,678 derived estimated bytes |
| final ingress optimization | longer WhatsApp navigation-key stress after the first successful mini-interval exposed 17 stale callbacks on the preceding candidate build. The final build still keeps every navigation action, but cancels redundant per-key semantic timers and captures one settled state after the repeat burst; it also tolerates a bounded two-second activation stall while retaining event-time context, fresh foreground/secure/private/domain checks, and the independent 256-entry memory cap. The exact-build repeat-key stress and focused tests both pass without an explicit observation gap. |

The exact-final-build resource rows use the 60-second enforced sampler. The longer
600-second closed-window run on build `20260826.144939` separately measured 0.000% median
CPU, 0.696% p95, a 38.7 MiB physical footprint, no child/helper and no growth in Computer
History, events, semantic, analysis, memories, Agent Activity, or Screen Time; only seals
grew by 10,769 bytes. On the final reader source, the verified 17-second causal query plus invariant
checker completed in 3.92 seconds with a 33,488,896-byte maximum resident set and left the
Agent Activity index size and modification time unchanged; this is foreground query
evidence, not a replacement for the closed-window background sample.

The strict validator passed 9 causal-parity scenarios, 3 episode-quality scenarios,
2 token-density scenarios, the privacy audit, causal invariant checker, 28 metadata-probe
tests, runtime sampler tests, signing policy, Release CLI build, and all four real local
questions. The earlier broad physical interval remains documented because it contains 29
pre-fix gaps. A later 69-second interval on the preceding candidate was gap-free, but
longer navigation-key stress exposed 17 stale callbacks and motivated the final
coalescing/tolerance change. The exact-final-build repeat passed at the causal 80% threshold,
returned `goalong_at_least_codex`, and contained no explicit gap or source-read issue.

### Earlier optimization baseline

The following measurements were taken on 2026-08-26 on macOS 26.5.1 (25F80), an
Apple M4 Pro with 24 GB RAM, using the installed source build
`20260826.111916` (`CDHash b57bd30ac80a9d9aa8eb0690bfbda0cc3a48df00`, Team
`2L5SSLPX46`). The
application was one process with no child/helper process. Before idle sampling, the
dashboard was closed through its real close button, its absence from the on-screen
window list was verified, and more than 60 seconds elapsed.

| Surface | Measured result |
| --- | --- |
| background CPU, 600 one-second kernel-delta samples | median 0.246%, p95 1.029%, maximum 103.449%; 2 samples exceeded 15% in one contiguous 2-second run, below the 5-second sustained limit |
| closed-window memory | macOS physical footprint 97,027,104 bytes (92.5 MiB); lifetime physical peak 224,330,760 bytes (213.9 MiB); raw resident size median 109,200 KiB, p95/maximum 139,296 KiB |
| peak improvement | lifetime physical peak 213.9 MiB versus the prior measured 453.8 MiB view peak, a 52.9% reduction |
| ten-minute process I/O | 6,602,752 bytes read and 3,031,040 bytes written; reads fell 98.75% from the 529,399,808-byte pre-quiescence measurement of the same active Codex transcript workload |
| ten-minute storage growth | Computer History +1,428 bytes; Agent Activity 0 bytes; events +975 bytes; memories +14,007 bytes; seals +11,068 bytes; semantic/analysis/Screen Time 0 bytes |
| derived Computer History storage | 5 compact JSON days, 3,404,131 logical bytes / 3,332 allocated KiB; the 5 optional Codex projections total 59,428 logical bytes / 60 allocated KiB, down 97.7% from the 2,604 allocated KiB legacy mirror |
| direct-source Agent Activity index | 797 entries in 778,752 bytes (977.1 bytes per entry): Codex 782, Claude Code 1, OpenCode 14; all available; the index is 0.0075% of the 9.65 GiB allocated by the three configured source roots |
| transcript duplication check | zero files and zero bytes in `agent-activity/blobs`; durable Agent Activity files are the bounded index, configuration, one small wake-up signal, and an empty lock |
| real English today-summary query | before: 35.26 seconds, 370,524,160-byte maximum RSS, 308,118,320-byte physical peak, repeated raw-source matches; after: one day reconstructed in 0.63 seconds, 20,709,376-byte maximum RSS, 11,977,256-byte physical peak, 12 hits over 5 unique resources, 240-character maximum snippet, and no raw-source pass |
| real French resume query | one current day reconstructed in 3.07 seconds; maximum RSS 83,361,792 bytes and physical footprint 74,842,712 bytes; 12 source-backed episode hits |
| complete automated suite | 609 tests, 3 expected environment-dependent skips, 0 failures; Agent Activity selection 116 tests, 2 skips, 0 failures |
| installed UI | 12 observed sources, 180 causal episodes, 1,101 interactions, 12 retained source links, 17 observable completion signals, 10 unfinished/blocked/waiting episodes, 8 workflow suggestions, 617 explicit coverage gaps, and 757 raw sessions; selected-session deletion is visible |
| real direct-source probe | the opt-in scanner read the canonical `~/.codex` source root in 5.55 seconds with bounded streaming, a metadata-only temporary index, no cached transcript records, no `blobs`, and 0 failures |
| parity validator | 9/9 parity scenarios, 3/3 episode-quality scenarios, privacy audit, checker regressions, and 22/22 metadata-probe tests passed; the validator also runs the 2 token-density/context-pack scenarios, the sleeping-versus-saturated kernel CPU sampler regression, and the offline local-signing policy; output contains metadata/checklists only |

An additional read-only development-source probe on 2026-08-26 reconstructed the real
2026-08-25 day and rendered a 1,600-token pack without exposing its body: 1,553 approximate
tokens / 6,071 characters, 138 emitted evidence slots, 88.9 slots per 1,000 approximate
tokens, 6 episodes, 9 interactions, and 8 sources. The source/storage metadata fingerprint
was identical before and after the command, and `/usr/bin/time -l` reported 83,886,080
bytes maximum RSS and 74,678,872 bytes peak physical footprint for the complete on-demand
source reconstruction plus rendering. This proves a bounded local projection and a
no-write read path; it does not prove that 1,600 tokens retain every useful semantic fact
or that an arbitrary downstream model will interpret them correctly.

The same 2026-08-26 source revision passed the complete Swift suite: 591 tests executed,
3 expected environment-dependent skips, and 0 failures in 96.5 seconds. The focused
validator also passed 9 causal-parity, 3 episode-quality, 2 context-density, 22 metadata-
probe, privacy-boundary, checker-regression, release CLI build, and four real local query
checks without emitting history bodies.

Raw resident size includes reclaimable mappings and allocator pages and is therefore reported
separately from macOS `phys_footprint`, the memory-pressure measure used for the
closed-window budget. CPU comes from `proc_pid_rusage` deltas, not macOS `ps %cpu`'s
one-minute decaying average. One preceding run during live screen-lock/TCC transitions
measured a 6.220% CPU p95 and therefore failed the 5% guard. A 90-second stack sample then
found the process asleep in every main-thread sample, with one permission-watchdog and one
Agent Activity sample; the stable unlocked rerun above passed. The one-second maximum is
not hidden; the sustained limit is satisfied because the only run above 15% lasted two
seconds.

That earlier build initially reported the TCC preflights as unavailable; the signed
reinstallation documented in the current snapshot above now reports all three checks true
and the event tap enabled. The exact-final-build physical interval proves gap-free capture
for the tested public browser workflow and observes the new bounded queue behavior. It
does **not** prove complete Accessibility quality across every third-party application,
every browser's private-mode signal, or a visual dashboard inspection on this exact final
bundle. Those broader claims remain gated on the controlled real-input checklist below
and a functioning UI inspection surface.

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
