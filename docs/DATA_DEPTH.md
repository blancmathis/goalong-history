# Data depth: a more complete analysis from data already on the Mac

Status: plan approved by Mathis on 2026-10-03 ("applique tout"). Source audits: agent view and
GPT-6 Pro report (local task `3352a2`), each claim checked against the code and real local data.

## Why

Goalong already collects far more than Activité uses (36–44 k events on a busy day). The gaps
that matter, in order:

1. Activité forgets everything after 30 days: it reads only detailed events, which retention
   deletes after 30 days. The 28-day comparison needs 56 days and can never be shown.
2. Signals already collected never reach Activité: input texture (keyboard, pointer), passive
   evidence (call, media, display assertion), agent sessions, other Apple devices, imported Health.
3. Three dimensions are missing: what was planned (calendar), what was produced (code, files),
   what interrupted (calls).

## Non-negotiable rules

1. **One main duration.** The foreground model (`GoalongLocalAnalytics`, method
   `local-observed-rhythm-v4`) stays the only source of active time. Every new source is a
   separate *lane* with its own meaning. No lane adds seconds to active time.
2. **Absence of evidence is not inactivity.** Every lane exposes a status: `disabled` (Goalong
   consent off), `permissionDenied`, `unsupported` (macOS version or source format),
   `noData`, `partial`, `ready`, `failed(reason)`.
3. **Descriptive words only.** Never productivity, effort, focus quality or distraction scores.
4. **Smallest derived representation.** Sources are read in place, read-only, bounded (rows,
   bytes, time), off the main thread, cached per day by source fingerprint, never on every render.
   No text, title or path is persisted unless stated below.
5. **Consent and permission are separate.** Each new source sits behind a Goalong consent
   (`CapabilityConsentStore`) or recorder setting, plus its macOS permission when one exists.
6. **No new dependency, no network, no subprocess** for new sources (never run `/usr/bin/git`:
   on a Mac without the Command Line Tools it opens an install dialog).
7. **Excluded:** screenshots, OCR, audio or video content, clipboard, typed characters, shell
   command text, Messages, Mail, CallHistory, notification contents, browser-history backfill.

## Workstreams and ownership

| Stream | Owner | Branch |
|---|---|---|
| F — Foundations (core analytics) | Codex job | `feat/data-foundations-20261003` |
| S — System sources | Codex job | `feat/data-sources-20261003` |
| D — Developer sources | Codex job | `feat/data-developer-20261003` |
| P — Derived analysis on busy days | perf thread (`feat/perf-lean-20261003`) | — |
| UI — every SwiftUI view, Settings row, Activité view | this session (Claude) | integration `feat/data-depth-20261003` |

Codex jobs never design or restyle SwiftUI views. They expose models and view-model APIs; they
may touch a view file only to keep it compiling after a model change, without visual change.
Every job keeps new code in new files and keeps edits to shared files (consent store, retention,
recap context, docs) small and additive, because the three branches are merged together.

---

## F — Foundations

### F1. Durable day summary (`activity-days/`)

Persist the Activité day so that it survives the 30-day purge and loads instantly.

- File: `<root>/activity-days/<yyyy-MM-dd>.json`, mode 0600, atomic write, same hardened file
  helpers as the other stores. Schema `goalong.activity-day.v1`.
- Content: `schema`, `method` (`GoalongLocalAnalytics.method`), `timeZone`, `date`, `start`,
  `end`, `state`, `eventCount`, `classifierVersions`, `sourceRevision` (the string
  `GoalongAnalyticsReader.sourceRevision` already computes), a string table, the segments
  (start offset, duration, kind, application, bundle identifier, host, context key, coverage
  reason — indices into the string table), and the breakdown (F3). Context keys are the FNV
  hashes of `GoalongWorkContext.key`: no window title is stored. Caps: 20 000 segments, 2 MiB.
- Write: for each complete past day (strictly before today) that loads as `.ready` and has no
  valid summary or a different `sourceRevision`. Never for today.
- Read: for a past day, use the summary when its day journal no longer exists (purged), or when
  its `sourceRevision` still matches (fast path, replaces the 2 s read). Otherwise rebuild from
  the journal and rewrite. A day restored from a summary is marked (`Day.origin = .summary`) so
  the UI can say that details were deleted after the retention period.
- Never lose a day: a low-priority backfill (utility QoS, cancellable, one day at a time, starts
  a few minutes after launch and after each day change) writes missing summaries for every past
  day that still has a journal. Retention enforcement writes the summary of a day right before
  it purges that day's events.
- Deletion: day, interval and timeline-entry deletion remove the summaries of affected days (they
  are rebuilt from whatever remains). Clearing history removes the directory. New retention
  category `activitySummaries`, default indefinite, deletable like memories.
- Keep the hook in `GoalongAnalyticsModel` small (store in its own file): the perf thread is
  changing the same reader (incremental read of today's journal).

### F2. Coverage reasons

Every `.unobserved` or `.concealed` segment carries a reason, set in `GoalongLocalAnalytics.build`
from the event that opens it: `beforeFirstObservation`, `afterLastObservation`, `gap` (> 120 s
without evidence), `observationGap` (recorder-reported), `recorderStopped`, `paused`, `sleep`,
`locked`, `accessibility`, `sessionUnavailable`, `noVisibleForeground`, `privateBrowsing`,
`excludedApplication`, `excludedDomain`, `secureInput`, `historyCleared`. Day-level states map to
`notRecorded` (no journal), `unreadable` (incomplete read), `purgedWithoutSummary` (older than
retention, no summary). The reason is part of the segment merge key. Add `GoalongDayCoverage`
(observed, active, idle, concealed and unobserved seconds, each split by reason; first and last
observation; origin) and its period aggregate.

### F3. Breakdown of active time (input texture and passive evidence)

Split active time, never add to it. Per calendar minute, active seconds go to exactly one mode,
by precedence: `call` > `media` > `display` (passive evidence on the foreground event, see
`ForegroundActivityEvidence`) > `keyboard` (keyPressed, typingBurst, keyboardShortcut in the
minute) > `pointer` (mouseClick, scrollBurst) > `reading` (active through the presence policy,
no input in the minute). Expose totals and per-hour values on `Day` and `Period`, persisted in the
summary. The `.localAnalytics` projection already keeps input rows (payloads stripped) and the
evidence metadata: no projection change is expected. Totals must equal `activeSeconds` exactly.

### F4. Re-ask "unclear" verdicts when evidence changes

Today an automatic `unclear` verdict is never asked again for the same definition
(`GoalongWorkClassification.pending`). New rule: an automatic (not owner-set) `unclear` context is
pending again when it has at least 5 minutes on the analysed day, it was not already asked that
day, and it has had fewer than 3 automatic attempts. Store `attempts` and `lastAskedDay` in the
entry (backward-compatible decode). A re-ask carries new evidence: a visible-context excerpt
(most recent semantic snapshot text for that context, redacted with the existing redaction,
clipped to 240 characters) only when the « Données pour ChatGPT » privacy filter permits that
application and site. Leave a parameter for a user day note (S5), wired at integration.

### F5. Documentation

`docs/LOCAL-ANALYTICS.md` still describes method v2: align it with v4 (presence policy, passive
evidence, reasons, breakdown, summary). Update `docs/PRIVACY.md`, `docs/DATA-FLOW.md` (summary
store and retention) and `docs/WORK_DEFINITION.md` (re-ask rule).

---

## S — System sources

### S1. Calls: microphone and camera in use

- Monitor (app target) with property listeners, no steady polling: CoreAudio process objects
  (`kAudioHardwarePropertyProcessObjectList`, `kAudioProcessPropertyIsRunningInput`, `…PID`,
  `…BundleID`; macOS 14.2+, checked on 2026-10-03: readable without any permission, positive
  case seen on Aside's helper for output). Camera: CoreMediaIO
  `kCMIODevicePropertyDeviceIsRunningSomewhere` per video device (device level, no app). Before
  macOS 14.2: device-level input state only, app unknown.
- Map helper processes to their app (outer `.app` bundle of the process, else strip helper
  suffixes such as `.helper`).
- Never open an audio or video stream. Store transitions only, in `<root>/calls/<day>.jsonl`
  (start/end, app bundle and name, microphone, camera), detailed-events retention. Close open
  intervals at launch from the last known state. Stop while recording is paused or Computer
  History consent is off. Recorder setting `captureCallPresence`, default on.
- Lane: intervals, union seconds, seconds per app, status.
- `docs/PRIVACY.md`: Goalong notes when an app uses the microphone or camera; never sound or image.
  Keep `scripts/audit_privacy_boundaries.sh` strict on capture APIs.

### S2. Calendar and Reminders (EventKit)

- Capability `calendar` (« Agenda et rappels ») in `CapabilityConsentStore`; permission through
  `EKEventStore` (full access APIs on macOS 14+, `requestAccess(to:)` on macOS 13).
- Info.plist (`scripts/build_app_core.sh`): `NSCalendarsUsageDescription` and
  `NSCalendarsFullAccessUsageDescription` = « Goalong lit vos événements (heures et titres) pour
  comparer le temps prévu au temps observé sur ce Mac. Rien n'est modifié. Rien ne quitte ce Mac
  sans votre accord. » ; `NSRemindersUsageDescription` and `NSRemindersFullAccessUsageDescription`
  = « Goalong lit vos rappels terminés pour montrer ce que vous avez accompli dans la journée.
  Rien n'est modifié. Rien ne quitte ce Mac sans votre accord. »
- Hardened Runtime needs the resource-access entitlement
  `com.apple.security.personal-information.calendars` (verify whether Reminders needs another
  key). Add `Distribution/GoalongHistory.entitlements`, sign certificate-backed builds with it by
  default (`build_app.sh`, `build_app_core.sh`, release workflows), and update the security
  artifacts and their tests. Release signing today ships no entitlements at all: keep every
  forbidden entitlement forbidden.
- Lane: events of the day (start, end, all-day, availability, title, calendar name, attendee
  count), read on demand, cached per day, invalidated on `EKEventStoreChanged`. Titles live only
  in memory for display. Derived: planned busy seconds (union, excluding all-day and free).
  Reminders: completed that day (time, title), due that day and still open (count).

### S3. Other Apple devices during Mac gaps

From the Apple Screen Time store, per non-Mac device of the day: screen-on seconds, seconds during
Mac gaps (overlap with unobserved or idle segments), seconds during Mac activity, freshness
(`lastUpdatedAt`). When a segment is coarser than the overlap, prorate and mark the value
`estimated`. Respect the Screen Time consent and device scope.

### S4. Health context

Read `health/<day>.json` (explicit import, archive v2): sleep seconds (and stages), steps,
workouts (count, duration). Check how the import attributes a night to a date and expose a
truthful label. Status `noData` until the user imports.

### S5. Day note

`<root>/notes/<day>.json`: one short text (≤ 280 characters) written by the user, « ce que le Mac
ne voit pas ». Get, set, delete; indefinite retention; removed by day deletion and history
clearing. Included in the recap and passed to the work agent (F4 hook) when present.

### S6. Browsers

Add Aside (`at.studio.AsideBrowser`) and other common browsers to the known browser identifiers,
and add missing known browsers to saved configs (not a privacy setting). Check the effects on
website attribution (`ForegroundActivityProbe`) and URL capture (`ContextProvider`).

### S7. Recap

Bounded recap sections for calls, agenda, other devices, health and the day note, each behind a
recap selection flag and the privacy filter.

---

## D — Developer sources

### D1. T3 Code metadata

- Source `~/.t3/userdata/statev2.sqlite` (WAL, ~1.8 GB). Open read-only in place (pattern of the
  OpenCode SQLite reader in AgentActivity): read-only flags, `query_only`, short busy timeout,
  short transaction, bounded day queries. Never copy or write the database.
- The schema moved on 2026-10-03: `projection_turns` (v1) ends at 00:36, `orchestration_v2_*`
  starts at 08:15. Read both, deduplicate, and fingerprint the schema (`unsupported` if columns
  are missing).
- Read only: projects (`project_id`, `title`, `workspace_root`, `deleted_at`), threads (id,
  project), turns and runs (requested, started, completed, status). Never thread titles,
  messages, `payload_json`, checkpoints or diffs.
- Per day and project: agent busy seconds (union of running turns), prompts (requests), waiting
  seconds (from a completed turn to the next request in the same thread, capped at 2 h), maximum
  parallel turns, first and last activity.
- Gate: AI conversations consent; T3 appears as an agent source (metadata only), discovered when
  the database exists.

### D2. Agents by project

Group AgentActivity documents of the day by canonical repository (resolve a linked worktree
through its `.git` file to the main checkout): sessions, active span, tokens, tool calls, errors,
providers. Merge with D1 per project. Never count agent time as the person's time.

### D3. Git activity from reflogs

- Capability `developerActivity` (« Activité de développement »). Projects chosen by the user;
  suggestions from T3 project roots and agent project paths.
- Parse reflogs directly, bounded (tail of each file): `.git/logs/HEAD`, `.git/logs/refs/heads/*`,
  `.git/worktrees/*/logs/HEAD`. Keep timestamps and the action word only (commit, amend, merge,
  rebase, checkout, reset, pull, cherry-pick); never read the commit subject. Deduplicate commits
  by new hash across logs.
- Per day and project: commits (count, times), other actions, first and last.

### D4. File modifications

FSEvents on the chosen project roots (file events, 30 s latency, utility queue). Ignore `.git`,
`.build`, `node_modules`, `DerivedData`, `dist`, `build`, caches and `.DS_Store`. Store counts of
distinct modified files per project per 5 minutes in `<root>/developer/<day>.jsonl` (no paths).
Persist the last event id to replay offline periods at launch. Stop while Goalong is paused.

### D5. Recap

Bounded « Développement » section per project, behind a recap selection flag.

---

## P — Derived analysis on busy days (perf thread)

`analysis/` and `computer-history/` stop around midday on busy days: the derived loader refuses a
day above 32 768 retained rows (`ActivityAnalysisDayLoadLimits.production`,
`ComputerHistoryEvidenceLoadLimits.production`). 2026-10-02 stopped at 14:33 (19 621 of 36 641
events); 2026-10-03 already has 44 128 events and 16 082 semantic rows. Remembering the refusal
saves CPU but freezes the afternoon. Target: complete busy days with bounded memory, and a
visible partial state if a day still exceeds the ceiling.

## Not done, and why

- **Notifications:** no public API; the Accessibility probe of 2026-10-03 exposed no banner; the
  private `usernoted` database depends on Full Disk Access, which Apple announced it will tighten
  (2026-10-02).
- **Focus:** `INFocusStatusCenter` only gives a boolean and needs a Focus-status capability this
  distribution (Apple Development identity, no provisioning profile) cannot embed safely; the
  private history is fragile.
- **Aside extension:** Accessibility already reads 98 % of Aside URLs; S6 covers attribution.
- **Browser-history backfill, Messages, Mail, CallHistory, shell history:** sensitive, private
  formats, low gain over the live recorder.
