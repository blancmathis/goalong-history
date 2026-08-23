# Goalong History — Computer History public-parity work

This document describes Goalong's implementation of the **publicly documented**
Computer History behavior: chronological interaction capture, local causal memories,
source recovery, natural questions about recent work, and reviewed suggestions for
repeatable work.

It does **not** claim access to, or equivalence with, undocumented OpenAI internals.
It also does not claim measured public parity until the live macOS benchmark in
[`COMPUTER_HISTORY_PARITY_MATRIX.md`](COMPUTER_HISTORY_PARITY_MATRIX.md) is complete.

Reference contract: <https://learn.chatgpt.com/docs/customization/computer-history>

## Current validation status

The deterministic model and integration path are exercised in macOS CI. A signed live
session is still required to prove TCC behavior, callback recall, private-mode handling,
third-party Accessibility quality, resource reopening, timeline performance, and answer
accuracy. See the matrix for the exact implemented, CI-proven, live-unproven, and open
gap status of every public behavior.

## Analysis pipeline

```text
CGEventTap + NSWorkspace + AXObserver + bounded fallback polling
                              │
                              ▼
        independent app/site capture policies + privacy guard
                              │
                              ▼
          semantic before → input action → after → settled
                              │
                              ▼
              application and resource continuity gate
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
         JSON + Markdown causal memory + local search/CLI
```

Polling remains a fallback and is never presented as proof that every rapid interaction
was preserved.

## Capture scope

Application and website policies are independent:

- `excludeListed` captures every identifiable source except listed entries;
- `includeOnly` captures only listed identities and fails closed when the required
  bundle identifier or host cannot be verified.

Both modes are exposed in Settings. Existing config files without the new fields migrate
to `excludeListed`, preserving their previous capture scope. This migration does not
enable Rich Context or otherwise enlarge semantic consent.

## Causal interaction attribution

Every eligible click, shortcut, navigation key, grouped typing burst, and grouped scroll
burst receives an interaction identifier. Semantic observations linked to the same
identifier use these phases:

- `before` — shallow state immediately before the action;
- `after` — broader state shortly after the action;
- `settled` — bounded state after the UI has had time to stabilize.

A delayed observation is eligible only when both the application and the concrete
resource remain continuous. Canonical URL, resolved resource IDs, or an unambiguous
window/document title are used in that order. A callback from a new page, document, or
application is rejected rather than silently attributed to the old action.

When an explicit pair is unavailable, the builder may use a nearby semantic observation
within 20 seconds only if the same application and resource continuity checks pass.
Coverage reports distinguish complete pairs from partial or metadata-only interactions.

## Source resolution and retrieval

The resource resolver currently classifies local files, web pages, known cloud
documents, conversations, issues/pull requests, terminal sessions, and applications.
Every reference contains a stable local ID, sanitized locator where available,
confidence, observation times, and source-event provenance.

Search combines lexical evidence, resource type, recency, task continuity, and
provenance. Resource type and recency cannot satisfy a named query by themselves. For
example, asking for a nonexistent “strategic acquisition document” returns no result
rather than the most recent unrelated document.

The read-only CLI exposes:

```bash
swift build -c release --product goalong-history-query

"$(swift build -c release --show-bin-path)/goalong-history-query" \
  computer-history 2026-08-20

"$(swift build -c release --show-bin-path)/goalong-history-query" \
  ask --days 30 "Where was I before my most recent break?"

"$(swift build -c release --show-bin-path)/goalong-history-query" \
  find --days 30 "Find the enterprise launch proposal document"

"$(swift build -c release --show-bin-path)/goalong-history-query" \
  resource --days 30 RESOURCE_ID
```

`find` is evidence-gated resource retrieval. `resource` resolves one stable identifier
and returns its related episodes and provenance. Neither command opens or executes the
captured source.

## Episodes and task status

The primary representation is:

```text
events → causal interactions → chronological episodes → memories → search index
```

Minute aggregates may remain for statistics and UI rendering, but are not the primary
source of task understanding. Episodes retain action order, transitions, resources,
semantic changes, gaps, uncertainty, source event IDs, sequences, and hashes where
available.

Task status is a bounded interpretation, not a verified claim. The latest observable
state has priority over earlier transient evidence. A failed operation followed by a
visible successful retry may be `completed`, while the failure remains in provenance.

## Workflow suggestions

A suggestion now requires:

- at least three interactions;
- at least two significant user actions;
- a concrete resource rather than an application-only trace;
- an observable semantic result, explicit outcome, or meaningful final action;
- at least two similar occurrences.

An application-switch sequence such as ChatGPT → Finder → Safari cannot produce a
workflow suggestion. Suggestions remain proposals for human review; Goalong never
installs or runs a skill or automation automatically.

## Local storage and retention

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

The Markdown mirror may also be written to
`$CODEX_HOME/memories/extensions/goalong/` or
`~/.codex/memories/extensions/goalong/`. The Goalong Application Support copy remains
authoritative.

New configurations default detailed events to two days (48 hours). Existing explicit
retention values are preserved during migration. Memories and cryptographic proof
classes have separate retention policies.

## Privacy boundary

Full context remains permissioned and local. It does not add:

- screenshots or screen video;
- camera, microphone, system audio, or clipboard capture;
- general reconstruction of ordinary typed characters from keycodes;
- private-window content;
- excluded or out-of-scope application/site content;
- Secure Input or protected-field content.

Common credential patterns are redacted before semantic persistence. Captured text is
untrusted observed data and is never executed as an instruction by the summarizer,
query service, or external recap integration.

## Automated validation

The macOS quality gate runs:

```text
script syntax and Python compilation
privacy-boundary audit
full Swift tests
strict deterministic Computer History fixture
release query-CLI build
installable app build
Info.plist lint
strict code-signature verification
package smoke test
```

The strict fixture executes:

```bash
bash scripts/validate_computer_history_fixture.sh
```

It generates an isolated positive store with four actions and four complete
before/after pairs, requires a pair ratio of at least `0.90`, verifies stable
`find`/`resource` lookup, rejects an unsupported named resource query, and confirms the
strict checker fails on a negative fixture with actions but no semantic pairs.

For a real recorded day:

```bash
bash scripts/validate_computer_history_parity.sh \
  --day YYYY-MM-DD \
  --require-real-context \
  --minimum-pair-ratio 0.90
```

The validator is read-only with respect to history and emits a manual real-session
checklist. Deterministic success is necessary but insufficient for a parity claim.

## Real-session proof boundary

Unit and fixture tests cannot prove:

- Accessibility, Input Monitoring, Event Tap, Secure Input, TCC persistence, or stable
  signature identity on the installed app;
- browser private-mode detection across versions/locales;
- third-party Accessibility timing and resource exposure;
- real callback recall, resource reopening, answer correctness, or timeline CPU usage;
- black-box equivalence with Codex Computer History.

A public-parity statement is permitted only after the matrix's live thresholds are
measured on the exact signed build and application set. Until then the accurate status
is **partial parity with deterministic evidence and explicitly listed live gaps**.
