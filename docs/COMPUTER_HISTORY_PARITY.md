# Goalong History — Computer History analysis parity

This document describes the Goalong implementation of the publicly documented
Computer History analysis behavior: chronological interaction capture, local causal
memories, source recovery, natural questions about recent work, task status, and
repeatable-workflow suggestions.

It does **not** claim access to, or equivalence with, any undocumented private
implementation. Parity claims must be limited to behavior that has been exercised on
the tested macOS build and applications.

Reference behavior: <https://learn.chatgpt.com/docs/customization/computer-history>

## Product behavior

With **Full Computer History context** enabled, Goalong History can reconstruct:

- the ordered stream of clicks, grouped typing, shortcuts, navigation keys, scrolling,
  app changes, windows, pages, and focused controls;
- bounded semantic state before an interaction, shortly after it, and after the UI has
  settled;
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
   semantic before → input action → after → settled
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
        JSON + Markdown causal memory + local search
```

### Interaction capture

Every eligible click, shortcut, special key, grouped typing burst, and grouped scroll
burst receives an interaction identifier. Semantic observations linked to the same
identifier use these phases:

- `before` — shallow, low-latency state captured before the action;
- `after` — broader state shortly after the action;
- `settled` — full bounded state after the UI has had time to settle.

The budgets are intentionally phase-aware so full analysis does not make the event tap
unresponsive:

| Phase | Maximum characters | AX nodes |
|---|---:|---:|
| before | 2,400 | 72 |
| after | 4,800 | 160 |
| settled | 6,000 | 260 |
| event-driven AX observation | 4,800 | 180 |
| periodic fallback | 6,000 | 260 |

`AXObserver` also reacts to focused-element, focused-window, window-created, title,
value, and selected-text changes. These observations are debounced and fingerprint-
deduplicated. Polling remains a fallback rather than the only source.

### Causal interactions

`ComputerHistoryInteractionBuilder` keeps every action and links its semantic evidence.
It never replaces all activity within a minute with one representative row.

Each interaction stores:

- action kind and human-readable label;
- start and end;
- application, site, and source resource IDs;
- bounded before and after context;
- semantic lines visible only after the action;
- confidence and source-event provenance.

When an explicit before/after pair is unavailable, the builder may use the nearest
eligible semantic observation from the same application within a bounded 20-second
window. Coverage reports distinguish complete pairs from partial context.

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
provenance. Query results may reopen a local path or sanitized URL, but never execute
captured content.

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

An episode contains the full chronological action sequence, applications, sites,
resources, requests or intentions, observable outcomes, and source provenance.

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

## Local storage

Causal memories are stored separately from raw events and regenerable compact analyses:

```text
~/Library/Application Support/LocalHistory/
├── events/
├── semantic/
├── memories/
├── analysis/
└── computer-history/
    ├── YYYY-MM-DD.computer-history.json
    └── YYYY-MM-DD.computer-history.md
```

The Markdown mirror is also written, when possible, to:

```text
$CODEX_HOME/memories/extensions/goalong/
```

or to `~/.codex/memories/extensions/goalong/` when `CODEX_HOME` is not configured.
The Goalong Application Support copy remains authoritative.

## Read-only query interface

Build the CLI:

```bash
swift build -c release --product goalong-history-query
```

Generate one day’s causal memory:

```bash
"$(swift build -c release --show-bin-path)/goalong-history-query" \
  computer-history 2026-08-21
```

Ask a natural local question over recent days:

```bash
"$(swift build -c release --show-bin-path)/goalong-history-query" \
  ask --days 30 "Where was I before my most recent break?"
```

All responses include evidence limitations and source provenance. Search requires a real
content, resource-kind, host, or status match before recency can increase a result’s
score. An unrelated query therefore cannot receive a recent source merely because it is
recent.

## Privacy boundary

Full context remains permissioned and local. It does not add:

- screenshots or screen video;
- camera, microphone, or system audio;
- clipboard capture;
- raw character reconstruction from keyboard keycodes;
- private-window content;
- excluded application or domain content;
- Secure Input or protected-field content.

Common credential patterns are redacted before semantic persistence. Captured text is
untrusted observed data and must never be treated as an instruction by the local
summarizer, query service, or external recap agent.

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
10. latest success overriding an earlier transient failure.

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
  --minimum-pair-ratio 0.80
```

`check_computer_history_memory.py` validates that:

- every action event becomes exactly one interaction;
- no interaction is duplicated across episodes;
- episode and interaction provenance is non-empty;
- resources, workflows, and suggestions reference valid IDs;
- episodes and interactions are chronological;
- coverage counts equal the actual stored arrays;
- optional semantic-pair thresholds are met.

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
