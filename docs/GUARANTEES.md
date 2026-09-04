---
context_room:
  id: assurance.security.guarantees
---

# Current guarantees and non-guarantees

## Shipped architecture

Goalong ships one public macOS application: `Goalong History`, bundle identifier
`ai.goalong.localhistory`. For an exact bundle whose generated manifest and published verifier
pass, the project supports these claims:

- every sensitive Goalong capability is off on a new install;
- a macOS permission never substitutes for Goalong consent;
- the app target contains no Goalong first-party HTTP uploader, App Attest transport, Sparkle
  framework/feed or automatic updater;
- Apple Screen Time and provider-owned conversation stores are opened through bounded,
  read-only adapters;
- Goalong stores one normalized owner-only Screen Time record per observed day; only the active
  day is updated from Apple, and completed-day UI, recap and CLI reads never reopen Apple history;
- AI conversation bodies remain in provider storage; Goalong persists only a bounded metadata
  index and never a transcript body, snapshot, version or second conversation vault;
- the Screen Time CLI asks the running, consented app through a user-only Unix socket only for the
  active day; completed days are read from Goalong's daily archive without opening Apple stores;
- optional ChatGPT analysis launches only the reviewed Codex executable with the fixed
  `app-server` argument after a separate consent.

## Required qualifications

- The app is not App-Sandboxed. Source/binary inspection shows the reviewed paths are absent,
  but this is not an operating-system network deny.
- Full Disk Access belongs to the main process today. The separate narrow reader service is a
  documented target, not shipped evidence.
- Codex may use the user’s ChatGPT account to process a bounded daily context when ChatGPT
  analysis is enabled. This is an intentional external-processing boundary.
- Generated manifests prove properties of one artifact; they do not prove byte-for-byte
  reproducibility or that every future source revision is safe.
- Local signatures prove consistency, not official-build origin, provider authorship, human
  identity, attention or productivity.

## Prohibited claims

Do not claim that Full Disk Access is narrow, that Goalong can never exfiltrate data, that XPC
reader isolation is shipped, that the build is reproducible, or that a local model name proves
provider authorship. Those claims require evidence the current artifact does not have.
