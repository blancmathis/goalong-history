---
context_room:
  id: assurance.privacy.local-history
---

# Privacy model

## Default state

On a new install, Computer History, Apple Screen Time, AI conversations, ChatGPT analysis,
external verification, automatic updates and launch at login are all off. The canonical state is
`~/Library/Application Support/LocalHistory/capability-consent.json`, written atomically with
mode `0600`. A missing, unreadable or future-version file fails closed to everything off.

## Data Goalong may keep after consent

- foreground app, bundle identifier and accessible window/control context;
- cleaned website address when exposed by the browser and allowed by the user;
- clicks, grouped scrolling, coarse shortcut/navigation activity, typing count and duration;
- lock, sleep, focus, pause and suppression transitions;
- local seals, memories, one normalized record per observed Screen Time day, bounded Computer History and daily recap output;
- for AI conversations only: provider, stable ID, original source reference, timestamps, size,
  fingerprint, status and bounded offsets.

Goalong does not record screenshots, video, microphone, system audio, clipboard contents,
passwords, raw typed characters, exact key codes or reconstructed text.

## Direct-source conversations

Codex, Claude, OpenCode, Gemini and Copilot adapters read the provider’s original local storage
in read-only mode. Conversation text may exist transiently in memory for the current view or an
explicit daily analysis. It is never written as a Goalong transcript, blob, snapshot, version or
normalized conversation archive. Missing, deleted, inaccessible, replaced or changing sources
produce explicit bounded states.

## Disclosure and external processing

Exports are created only by an explicit user action and contain only the selected disclosure.
Optional ChatGPT analysis is a separate consent: Goalong prepares a bounded context, starts the
fixed local Codex `app-server`, and keeps only the bounded derived recap/proof. Disabling analysis
stops the runtime but does not delete an already generated recap; deletion remains explicit.

The shipped app contains no Goalong first-party HTTP uploader or automatic update client.
