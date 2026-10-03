---
context_room:
  id: assurance.security.data-flow
---

# Data flow

```mermaid
flowchart LR
  user["User enables one capability"] --> consent["capability-consent.json · 0600"]
  consent --> capture["Computer History recorder"]
  consent --> screen["Apple Screen Time read-only adapter"]
  consent --> agents["Provider direct-source readers"]
  capture --> local["Goalong local stores"]
  local --> days["Closed foreground-day summaries · 0600"]
  days --> view
  local --> retention["Retention: validate summary before event purge"]
  screen --> active["One normalized active-day record · 0600"]
  active --> closed["Completed daily records · no Apple reread"]
  active --> view["UI / bounded projection"]
  closed --> view
  agents --> index["Metadata-only index"]
  index --> view
  view --> optional["Optional bounded daily context"]
  consent --> optional
  optional -. "separate ChatGPT consent" .-> codex["Fixed local Codex app-server"]
  codex --> recap["Bounded derived recap and proof"]
```

The optional website path reads these saved sources only after the user selects the day and
details. It has a separate explicit send boundary:

```mermaid
flowchart LR
  archive["Saved Screen Time day"] --> export["Selected v2/v3 fields · offline preview"]
  domains["Observed Mac domains"] -. "only when included" .-> export
  recap["Selected parts of saved recap"] -. "only when included" .-> export
  rhythm["Reviewed session · optional selected context"] -. "separate field choices" .-> export
  export -. "explicit send plus chosen token file" .-> website["Selected website origin"]
  website --> sharing["Site account sharing rules · unverified data"]
```

No Apple Screen Time database or conversation body is copied into Goalong storage. Goalong keeps
one normalized Screen Time record per observed day: only today's record is updated from Apple;
completed days are served locally and never cause a retrospective Apple read. The CLI reaches the
running app through a `0700` runtime directory and `0600` Unix socket only when the active day must
be refreshed. Completed-day CLI reads open the owner-only daily record directly and create no
response file. If Screen Time consent is off, active-day refresh is unavailable.

The Codex edge is the optional external-analysis boundary; the website edge submits selected data
without starting a new analysis. Neither the offline preview nor continuous capture triggers a
website send. Full provider transcripts and event journals are not website payload inputs. A contextual session may include explicitly selected bounded excerpts of captured context; those excerpts can contain personal text and have their own transmission control.
[`PRIVACY.md`](PRIVACY.md#website-disclosure) owns the disclosure rules and
[`NETWORK.md`](NETWORK.md) owns transport controls. The retired commitment uploader, App Attest
transport and updater remain excluded. Full Disk Access reader isolation remains not shipped.

Foreground analytics reads one bounded journal day at a time, or a matching durable
`activity-days` summary. A stale summary is rebuilt while its journal remains; a purged
journal is represented by the summary origin. Delayed utility backfill and retention
maintenance save settled days only (the next day is closed too). Failed preservation keeps raw events. The new
`activitySummaries` retention category defaults to indefinite; explicit affected-day and
full-history deletion include summaries under the derived-writer barrier. Coverage reasons
and the active-time partition are derived from the same foreground intervals, never from
extra-source durations. See [local analytics](LOCAL-ANALYTICS.md).
