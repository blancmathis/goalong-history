# Activity analysis and agent brief

LocalHistory keeps the append-only event journal as its source of truth. The analysis layer is a deterministic, local derivative designed for two readers at once:

1. the person reviewing the day in the macOS dashboard;
2. an agent that needs the highest useful information density for a bounded context window.

No language model is required to build the analysis.

## Data flow

```text
sealed JSONL events
        │
        ├─ reduce noisy events to one representative record per active minute
        │
        ├─ group adjacent, related minutes into focus blocks
        │
        ├─ aggregate applications, sites and pages
        │
        ├─ deduplicate likely requests and visible-context highlights
        │
        └─ render a token-budgeted Markdown brief + structured JSON cache
```

The minute reduction is the primary token-saving mechanism. Clicks, scrolling, typing bursts, focus changes and repeated heartbeats can produce many event rows while describing the same minute of work. The agent never needs those repetitions in its default recap input.

## Generated files

The runtime refreshes today and yesterday when the source event file changes:

```text
~/Library/Application Support/LocalHistory/analysis/
├── YYYY-MM-DD.analysis.json
└── YYYY-MM-DD.agent.md
```

- `*.analysis.json` is the versioned structured representation used by the dashboard.
- `*.agent.md` is the compact, chronological input intended for a daily agent.
- Both files are local derived caches, not a replacement for the sealed event journal.
- When the corresponding detailed event file is deleted, orphaned analysis files are removed as well.

## Focus blocks

A focus block contains:

- start and end time;
- estimated active minutes;
- a concise deterministic title;
- dominant applications, sites, pages and category;
- event and input counts;
- optional visible-context and likely-request snippets.

Blocks merge changing pages on the same site and related app switches in common workflows. Long gaps, unrelated sites and unrelated contexts split blocks. If a day contains more blocks than the configured maximum, the engine keeps the most informative blocks—including blocks with detected requests—and restores chronological order.

## Token budget

The Markdown renderer has a hard approximate budget. It estimates tokens from UTF-8 length and appends information in this priority order:

1. day headline and compact metrics;
2. chronological focus blocks;
3. requests and intentions;
4. sites and top pages;
5. application totals;
6. additional visible context;
7. coverage and source-chain reference.

The dashboard exposes 800, 1,600, 3,000 and 6,000-token presets. The renderer stops adding lower-priority rows before exceeding the selected budget.

## Rich Context

Rich Context is **off by default**. When explicitly enabled, LocalHistory periodically reads selected and visible text that macOS Accessibility already exposes for the foreground window. This is useful for understanding page content, coding-agent conversations and user requests that cannot be inferred from a URL or title alone.

The collector:

- never decodes keyboard characters;
- never uses screenshots, screen recording, the clipboard, microphone or system audio;
- does not run while LocalHistory is paused;
- does not run for private browsing, excluded applications, excluded domains or secure fields;
- limits and deduplicates captured text;
- redacts common credentials such as API keys, access tokens, passwords and card-like number sequences;
- records the snapshot through `EventRecorder`, so metadata is included in the existing event hash, chain and minute seal.

Rich Context does not make every accessible string safe or non-sensitive. The toggle is therefore deliberately explicit and remains local-only.

## Trust and provenance

The analysis JSON and Markdown are derived files and can be regenerated. Coverage includes the first and last source event sequence plus the last event hash when integrity data is available. An external verifier should validate the underlying event chain and minute seals rather than treating the Markdown text itself as an independent cryptographic proof.

Private/suppressed periods contribute only coverage minutes. Their hidden content is never included in requests, highlights, sites, pages or focus-block text.

## Schema evolution

`ActivityDayAnalysis.schemaVersion` versions the structured cache independently from `HistoryEvent.schemaVersion`. Additive fields should remain decodable where possible. A breaking semantic change requires incrementing the analysis schema version and updating the renderer tests.
