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
  screen --> active["One normalized active-day record · 0600"]
  active --> closed["Completed daily records · local reads only"]
  active --> view["UI / bounded projection"]
  closed --> view
  agents --> index["Metadata-only index"]
  index --> view
  view --> optional["Optional bounded daily context"]
  consent --> optional
  optional -. "separate ChatGPT consent" .-> codex["Fixed local Codex app-server"]
  codex --> recap["Bounded derived recap and proof"]
```

No Apple Screen Time database or conversation body is copied into Goalong storage. Goalong keeps
one normalized Screen Time record per observed day: only today's record is updated from Apple;
completed days are served locally and never cause a retrospective Apple read. The CLI reaches the
running app through a `0700` runtime directory and `0600` Unix socket only when the active day must
be refreshed. Completed-day CLI reads open the owner-only daily record directly and create no
response file. If Screen Time consent is off, active-day refresh is unavailable.

The dotted Codex edge is the sole intentional external-analysis boundary. The shipped app has no
first-party HTTP uploader or updater. Full Disk Access reader isolation remains not shipped.
