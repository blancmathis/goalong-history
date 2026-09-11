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

Exports contain only selected disclosure. Manual exports require an explicit action; the separately enabled website schedule uses its saved reviewed selection.
Optional ChatGPT analysis is a separate consent: Goalong prepares a bounded context, starts the
fixed local Codex `app-server`, and keeps only the bounded derived recap/proof. Disabling analysis
stops the runtime but does not delete an already generated recap; deletion remains explicit.

The retired commitment uploader and automatic update client remain excluded. The optional website
sender is an explicit disclosure path, described below and in [`NETWORK.md`](NETWORK.md).

The [selected website analysis](SITE-ANALYSIS.md) is separate from daily analysis: it
uses only the reviewed JSON file and an isolated ChatGPT login, without reading native
archives or provider conversations. Its editable text draft stays transient until an
explicit protected file export; website import remains a separate user action.

### Website disclosure

`export-site` reads an existing normalized Screen Time archive without refreshing Apple data,
opening provider conversations, modifying source history or contacting a server. Its default v2
payload contains the saved day's device names, kinds, source totals, timezone and provenance.
The user can narrow the devices and explicitly include application durations, measured hourly
usage, domains observed on this Mac, or the saved bounded recap. Missing hourly evidence stays
unknown. Website durations explain browser time and are not added to Screen Time totals.

The website payload contains no conversation transcripts, prompts, captured event bodies, raw
typed text, full URLs, local paths or source fingerprints. Optional recap text is a derived summary
and may still disclose personal information; review the exact preview before sending. Source
consent remains required for every requested detail. Full options and limits belong to
[`CLI.md`](CLI.md#website-export-and-account-submission).

**Send reviewed data**, `send-site`, or the explicitly enabled website schedule sends the selected fields, using the specifically chosen
upload-token file. The native sheet remembers the origin and token-file path, not the token value,
and keeps scheduling off until the reviewed-preview activation button is used. The schedule runs only while the app is open, excludes recaps and domains, sends yesterday after 09:00, and stops on errors. Disabling a native source stops later access; it
does not retract data already submitted to the site. Manage website copies and sharing there.

The native sender cannot grant a sharing audience. Existing website rules for circles, friends,
lists or public sharing can apply to newly submitted dates and fields, so an upload is not a
promise that the data remains private. The receipt states `sharing: "managed-on-site"` and
`verification: "unverified"`. Local signatures and source descriptions do not mint a verified
website badge. Website authenticity verification remains a separate future feature.

### Pre-transmission masking and rhythm

The native mask list matches application names or identifiers exactly, ignoring case. Matching names and IDs are replaced by neutral entries while each source duration remains intact. Any active mask excludes website domains and recap free text from the payload. Source files remain unchanged. The recipient-side mask on the site is a different control.

The native sheet accepts a chosen recap excerpt instead of automatically loading the entire saved recap. Rhythm reads the compact app/timestamp journal stream only after Computer History consent. Project app associations are explicit, timelines and clock times are opt-in, and missing observations remain unknown. This data never certifies attention. See [CLI](CLI.md#session-rhythm-and-pre-transmission-choices).
