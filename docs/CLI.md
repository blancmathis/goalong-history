# Goalong CLI

The app bundle includes a read-only `goalong` command for users and local agents. The installer creates the stable link `~/.local/bin/goalong` when that directory is safe and writable. It never replaces an unrelated command already present there.

```bash
goalong help
goalong status
goalong days
goalong computer-history today
goalong computer-history yesterday
goalong computer-history 2026-08-27
goalong computer-history-context yesterday --tokens 2000
goalong screen-time today
goalong screen-time 2026-08-27 --mac-only
goalong recap yesterday
goalong recap 2026-08-27
goalong recaps
goalong ask --days 30 "What did I work on yesterday?"
```

Every command emits sorted JSON. Dates accept `today`, `yesterday`, or an explicit local `YYYY-MM-DD` value. Missing recaps return `status: "notGenerated"`; missing or protected Screen Time data returns the exact Apple-source status rather than an empty success claim.

## Data boundaries

- Computer History is reconstructed transiently from Goalong's original append-only event and semantic journals. `computer-history-context` emits a bounded agent projection without saving it.
- Screen Time is read once by the bundled CLI, signed with the same certificate-backed designated requirement as Goalong History so it can satisfy the same Full Disk Access decision. The response contains the complete available per-device reports, time segments, and application durations, plus a convenient aggregate summary.
- Daily recaps are loaded from the bounded canonical JSON already stored under `chatgpt/recaps`; the CLI never creates another report copy.
- `days` lists existing Computer History, event, and recap dates. Apple Screen Time remains an on-demand query because Apple controls its retention and availability.

The CLI does not start a daemon, mutate Goalong settings, refresh an AI recap, or write query results. A normal invocation exits after the JSON response, so it adds no persistent process or idle RAM cost.

## Agent integration

An agent should begin with `goalong days`, request the narrowest relevant day, and prefer `computer-history-context` when token budget matters. It should preserve `loadIssues`, Screen Time `status`, recap `status`, and all stated limitations; missing coverage is unknown, not inactivity.
