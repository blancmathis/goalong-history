# Concentration (spec, 2026-10-04)

Concentration is an optional module. It adds five things around the measure Goalong already has:
focus sessions (free or Pomodoro), the morning plan and the evening review, a live focus status,
limits the member sets, and engagements (a goal for the day or the week, with an optional stake). Everything is also a `goalong` CLI command, so the member can drive it from
any device or tool (a tablet, a desk light, a script). Friction « Ralentir » belongs to the Blocking
module: see [`BLOCKING.md`](BLOCKING.md#ralentir-friction).

Why these four (research, 2026-10-04): an if-then plan raises goal attainment (Gollwitzer & Sheeran,
d ≈ 0.65); monitoring progress helps, more when it is recorded (Harkin 2016, d ≈ 0.40); a plan for an
unfinished task stops intrusive thoughts (Masicampo & Baumeister 2011); a start/end-of-day dialogue
gave fewer after-hours emails and a more productive first hour (Williams et al., CHI 2018); feedback
on past estimates reduces the planning fallacy; an automatic « busy » light cut interruptions by 46 %
(FlowLight, CHI 2017). Pomodoro breaks are not better than free breaks (Biwer 2023), so both exist. Engagements: see
[Engagements](#engagements).

## Module convention (same as Blocking and Ambiance)

- `GoalongModule.concentration`, key `goalong.module.concentration.enabled`, default `false`.
  Title « Concentration », summary « Séances, Pomodoro, plan du jour et bilan, statut. »,
  symbol `scope`.
- Off: no controller, timer, observer, panel, file under `Focus/`, socket route answers
  `moduleDisabled`. A unit test proves it. Data already saved stays until the member deletes it
  (Settings › Modules › « Supprimer les données Concentration »).
- On: the sidebar shows « Concentration » after « Blocage ». Nothing starts until the member starts
  a session or a prompt time arrives.
- Off is refused while a session holds a locked block (the Blocking rule applies).

## Rules

- The member writes every plan item, intention and limit. Goalong never invents them (same rule as
  Blocking lists). It may show facts next to them (measured time, past estimate ratio).
- Never moralise. Panels show facts and actions, not advice. No streaks, except the engagement series
  the member opts into (see Engagements), shown only on its card.
- Reuse the existing observation (`ContextMonitor`, `EventTapMonitor` counts, work verdict cache)
  and the `JevWarningPanel` technique for every panel. No second foreground observer, no polling
  timer faster than the existing sample.
- Data stays on this Mac under `~/Library/Application Support/LocalHistory/Focus/`. It is not added
  to `export-site`, the website, the ChatGPT recap or Jev in this version.
- No network, no process launch, no new permission. `audit_privacy_boundaries.sh` passes unchanged.
- Visual design (page, sheets, panels, menu bar item) is done by the design session. Plumbing never
  edits `ConcentrationPage*.swift` or `ConcentrationPanelViews.swift`; it exposes an
  `ObservableObject` (`ConcentrationController`) with the state and actions they need.

## Sessions

A session = an intention (« Je fais : … », 1…140 characters), optionally linked to a plan item, plus
a timing mode.

| Mode | Settings | Ranges |
| --- | --- | --- |
| « Libre » | a duration, or « sans fin » (stops by hand) | 5…240 min |
| « Pomodoro » | work / short break / long break / long break every N | 5…120, 1…30, 5…60, 2…8; default 25/5/15/4 |

Pomodoro also takes an optional number of work cycles (1…16); without it, the session runs until
stopped. « Passer » moves to the next phase. There is no pause: stop and start again.

Options per session, each shown only when its module is on:
- **Blocking**: one or more of the member's lists (`block` or `slowDown`). The session starts a block
  for each work phase, ending at the phase end. Breaks are not blocked unless « Bloquer aussi pendant
  les pauses ». « Verrouiller » locks each work-phase block (Blocking lock rules; a free session « sans
  fin » cannot lock). Stopping a session whose current block is locked is refused, CLI included.
- **Ambiance**: plays Focus during work phases, fades out at breaks, stops at the end. Ambiance is
  not on `main` yet: define `FocusSessionAudio` (`startWork()`, `startBreak()`, `stop()`) with a no-op
  default; the Ambiance adapter is added after Ambiance merges.

Phase changes show a non-activating panel for 6 s (« Pause — 5 min », « On reprend : <intention> »)
with an optional system sound (Settings, default on). The menu bar item shows the phase and the time
left.

**End.** At the end (or stop), the review panel asks « C'est fait ? » : « Oui », « En partie »,
« Non », plus an optional one-line note. It shows measured facts for the session interval: active
time, work / hors travail / non classé (member's definition through the verdict cache), app
switches, longest stretch on one task. Dismissing records `outcome: nil`.

**Model** (`Sources/LocalHistoryApp/Concentration/ConcentrationModel.swift`): `FocusSession { id,
intent, planItemId?, mode, blockListIds, blockDuringBreaks, lock, ambiance, startedAt, plannedEndAt?,
events: [start | skip(at) | stop(at, reason)], outcome?, note? }`. Phases are computed from the mode
and events (pure function, tested), never stored. Storage: one JSON file per local day
`Focus/sessions/YYYY-MM-DD.json`, atomic writes, at most 200 sessions per day. A session running at
launch is restored (phase recomputed from the clock); a session whose planned end passed while the app
was closed ends with reason `appClosed`.

## Plan and review

**Plan** (« Plan du jour »): an optional one-line intention for the day and 1…10 items. Item:
`{ id, title (1…140), project? (free text, matched by name to « Mon travail » tasks), estimateMinutes?
(5…600), status: open | done | dropped | moved(toDay) }`. File `Focus/plans/YYYY-MM-DD.json`.

**Review** (« Bilan »): per item done / partly / not done / moved to a day; « Demain, je commence
par : … » (≤ 140, becomes tomorrow's first item); a note (≤ 500). Items marked moved are copied into
the target day's plan. File `Focus/reviews/YYYY-MM-DD.json`.

**Plan against measure.** For each item: session minutes linked to it, plus measured work minutes
on its project that day when a project is set. With an estimate, the review shows « prévu 60 min,
mesuré 95 min ». Over the last 20 items with both values, the plan screen shows the median ratio
(« Vos estimations : ×1,6 ») next to the estimate field. Nothing else is inferred.

**Prompts** (Settings of the module, each off-able): « Plan du matin » at the first activity after a
chosen time (default 06:00) if today has no plan; « Bilan du soir » at the chosen end-of-day time
(the Limits time when set, else 18:30) if today has no review. A prompt is a non-activating panel
with « Faire maintenant » and « Plus tard » (one reminder after 30 min, then nothing that day).

## Focus status

One state at a time, with hysteresis so it does not flicker:

| State | When |
| --- | --- |
| `focus` (`source: session`) | a session work phase |
| `break` | a session break phase |
| `focus` (`source: detected`) | detection rule below, outside a session |
| `away` | idle ≥ 2 min, screen locked, display asleep |
| `active` | anything else while Goalong observes |
| `off` | Goalong does not observe (consent off, pause, privacy stop) and no session runs |

**Detection v1** (member setting « Détecter la concentration », default on; only while Computer
History captures normally, never starts observation): enter when, over the last 20 minutes, at least
16 minutes had input, the foreground stayed on contexts not judged « hors travail » by the verdict
cache (unknown counts as not « hors travail »), and there were at most 20 foreground switches. Stay
at least 5 minutes. Leave on `away`, on a « hors travail » context in front for 60 s, or on more than
3 switches per minute for 3 minutes. Thresholds live in one `FocusDetectionRule` value, tested on
synthetic timelines. Each transition is appended (state, at) to `Focus/status/YYYY-MM-DD.jsonl` so
the rule can be tuned on real days. Cost target: under 0.1 % of a core; measure it like
`BlockingRuntimeCostTests`.

## Limits

Each limit is off until the member sets it. Goalong only warns: it never blocks work for a limit (a
member who wants that builds a Blocking program).

- « Travail par semaine » (10…80 h) and « Travail par jour » (2…16 h): measured work under the
  member's definition; without a definition, active time, and the panel says so.
- « Fin de journée »: a time and weekdays. It also triggers « Bilan du soir ».
- When a limit is crossed: one non-activating panel (« 50 h de travail cette semaine — votre limite. »),
  at most once per limit per day (weekly limit: once per week), and a mark in Activity. Starting a
  session past a limit shows one line in the start sheet; it is never refused.
- The setting may show one neutral reference line (output per hour drops past about 50 h a week,
  Pencavel). The member chooses the number; no default value is pre-filled.

## Engagements

An engagement is a goal the member commits to for one day or one week. Goalong measures it; an
optional stake, chosen in advance, applies if it is missed. At most one day engagement per day and
one week engagement per week. Owner decision, 2026-10-04: both day and week, and everything by CLI.

Why (research, 2026-10-04): self-imposed deadlines help, less than external ones (Ariely &
Wertenbroch 2002); a commitment contract with a stake raised follow-through (Giné, Karlan & Zinman
2010; stickK data is only observational); a Monday is a natural fresh start (Dai, Milkman & Riis
2014); hard goals with a few « emergency reserves » keep people going longer (Sharif & Shu 2017); a
broken streak makes people drop out (Silverman & Barasch 2023), hence jokers.

**Goal kinds.** All are « at least ». A maximum is a Limit or a Blocking quota, not an engagement.

| `kind` | Sentence | Measure in the period | Day | Week |
| --- | --- | --- | --- | --- |
| `work` | « Travailler 7 h » | `.work` segments (member's definition; without one, active time, and the card says so) | 30 min…16 h | 1…80 h |
| `task` | « 3 h sur Goalong » | `.work` segments whose task matches `task` (same matching as a plan item `project`) | 15 min…16 h | 30 min…80 h |
| `sessions` | « 4 séances » | sessions with at least 15 min of work phases inside the period | 1…12 | 1…60 |
| `plan` | « Finir 3 tâches du plan » | plan items with status `done` in the period's plans | 1…10 | 1…70 |

Durations step by 15 min. `target` is stored in minutes or as a count.

**Periods.** Day = local day, same key as plans. Week = Monday to Sunday whatever the Mac region,
key ISO `YYYY-Www`. The weekly limit uses the same week (one helper for both; today it follows the
region, and an en-US Mac starts weeks on Sunday). A day engagement is set for today or one of the
next 7 days; a week engagement for this week or the next. Setting one during its period is allowed;
the card shows when it was set.

**Commit rule.** Free edit or delete until the later of (a) 10 minutes after creation and (b) the
start of its period. After that, only harder: raise `target`, add a stake list, move `until` later.
Delete and any easier change answer `locked`, in the page and in the CLI. One pure function
(`FocusCommitRule.check(old, new, now)`) returns `free`, `harderOnly` or `locked` with the reason;
the UI greys controls from it.

**Stake** (optional; offered only when Blocking is on and has lists): one or more Blocking lists and
an end time `until` (`HH:mm`, default 12:00; « toute la journée » = 23:59). When the result is
`missed`, Goalong starts one block of these lists at settle time, locked, ending at `until` that same
day. Each list keeps its own action (`block` or `slowDown`). Skipped cases, recorded with a reason:
`late` (`until` already passed at settle: Goalong was not running), `noList` (every list was
deleted), `blockingOff`. Blocking gets two calls: `startCommitmentBlock(id:listIDs:until:)` and
`endCommitmentBlock(id:)`. Every other stop path refuses that block as locked; while it runs, the
locked-block rule also refuses turning Blocking or Concentration off.

**Result.** A period settles at the first measurement refresh after it ends while the app runs
(usually the next morning's first activity). `held` when measured ≥ target, else `missed`. The
result stores `measured`, `unmeasuredMinutes` (period time while Goalong did not observe, plus
unclassified time, for `work` and `task`) and `settledAt`. After `missed`, two exits stay open until
the stake block ends (no stake: until the end of the settle day):
- « Utiliser un joker »: uses one joker, cancels or ends the stake, keeps the series. Jokers per
  calendar month of the period end: day 2, week 1 by default; settings 0…5 and 0…2.
- « J'ai tenu, hors mesure »: offered only when `unmeasuredMinutes > 0` or for kind `plan` (a status
  may be set late). Outcome becomes `held` with `declared: true`; cancels or ends the stake; uses no
  joker. Card and CLI show « déclaré ».

**Series.** Consecutive settled periods that are `held` (a joker keeps the series and shows as
joker). A period without an engagement neither adds nor breaks. Day and week series are separate.

**Where it shows** (drawn by the design session):
- Page: section « Engagements », cards « Aujourd'hui » and « Cette semaine »: the sentence, measured
  against target, the stake, the series, jokers left. Empty card: « Prendre un engagement ».
- Morning plan: optional « Engagement du jour »; on the first morning of a week, also « Engagement de
  la semaine ». Evening review: today's progress (facts only) and optional « Engagement de demain ».
- Result panel, new `FocusPanel.Kind.commitment`: non-activating, once per result, at settle time.
  « Hier : 6 h 10 de travail sur 7 h. », the outcome, the stake, the open exits. A day and a week
  settling together share one panel. Nothing is shown during a period.
- A `work` or `task` target above a set work limit shows one neutral line (« Au-dessus de votre
  limite de 8 h par jour. »). It is never refused.

**Model.** `FocusCommitment { id, period: day(YYYY-MM-DD) | week(YYYY-Www), kind, target, task?,
stake: FocusStake?, createdAt, edits: [{at, target, stake}], result? }`, `FocusStake { listIds,
until }`, `FocusCommitmentResult { settledAt, measured, unmeasuredMinutes, outcome: held | missed,
declared, jokerAt?, stake: none | applied(blockId) | skipped(reason) | cancelled(at) }`. File
`Focus/commitments.json` (atomic, `0600`, at most 800 entries; oldest settled dropped first). Jokers
left are counted from results, never stored. Pure, tested functions: progress, settle, commit rule,
series, jokers left, stake window.

## CLI

All new commands go through the running app over the existing owner-only socket
(`GoalongReadOnlyQueryBroker`, `0600`), extended with Concentration routes. The app is the only
writer. Output: sorted JSON on stdout like every data command; errors as JSON on stderr, nonzero exit
(`appNotRunning`, `moduleDisabled`, `invalidArgument`, `locked`, `notFound`). Text arguments are
bounded and control characters are rejected; `--file -` reads stdin, at most 64 KB.

```bash
goalong focus status                 # one JSON object
goalong focus watch                  # NDJSON: current state, then one line per change
goalong session start --intent "Rédiger le chapitre 2" --minutes 50
goalong session start --intent "Révisions" --pomodoro            # 25/5/15/4
goalong session start --intent "Code" --pomodoro 50/10/20/3 --cycles 4 --block LIST_ID --lock --ambiance
goalong session start --intent "Lire" --open --plan-item ITEM_ID
goalong session current
goalong session skip
goalong session stop [--outcome done|partly|not-done] [--note TEXT]
goalong sessions [today|yesterday|YYYY-MM-DD]
goalong plan show [DAY]
goalong plan add "Envoyer le devis" [--day DAY] [--project NAME] [--estimate 30]
goalong plan done|drop ITEM_ID [--day DAY]
goalong plan move ITEM_ID --to DAY
goalong plan set [--day DAY] --file PATH|-        # replace the whole plan (JSON below)
goalong review show [DAY]
goalong review set [--day DAY] --file PATH|-
goalong limits
goalong commitment show [--day today|tomorrow|DAY] [--week this|next|YYYY-Www]   # no flag: today and this week
goalong commitment set --day DAY|--week WEEK --kind work|task|sessions|plan --target 7h|7h30|90m|4
                       [--task NAME] [--stake LIST_ID]... [--until 12:00]
goalong commitment set --day DAY|--week WEEK --file PATH|-      # the shape printed by show
goalong commitment delete --day DAY|--week WEEK                  # `locked` after the commit window
goalong commitment joker --day DAY|--week WEEK
goalong commitment declare --day DAY|--week WEEK                 # « J'ai tenu, hors mesure »
goalong commitments [--from DAY] [--to DAY]                      # history, series, jokers left
goalong block-lists                                # id, name, mode, action, locked
goalong friction [DAY]                             # « Ralentir » counts per list
```

`focus status` and every `focus watch` line:

```json
{"schema":1,"state":"focus","source":"session","since":"2026-10-05T09:12:00+02:00",
 "session":{"id":"…","intent":"Rédiger le chapitre 2","phase":"work","cycle":2,
 "phaseEndsAt":"2026-10-05T09:37:00+02:00"}}
```

`session` is present only during a session. When the app is not running, `focus status` prints
`{"schema":1,"state":"unavailable"}` and exits 0 (a light or script needs a stable answer).
`focus watch` then prints that line, retries every 5 s and goes on until interrupted; at most 8
watchers at once. `plan set` / `review set` take exactly the shapes that `plan show` / `review show`
print (ids optional on input). Document the commands and schemas in `docs/CLI.md`, in `help --json`
and `capabilities`.

## Tests and checks

- Off by default: module off creates no object, file, timer or panel; routes answer `moduleDisabled`.
- Pure functions: Pomodoro phases (skip, long break, cycles, DST day), detection rule, plan against
  measure, estimate ratio, limit crossing (once per period).
- Stores: atomic write, bounds, restore after relaunch, `appClosed`.
- Blocking link: work-phase blocks, breaks unblocked, lock refuses stop (app and CLI).
- Engagements: progress per kind, settle (held, missed, late, noList, blockingOff), commit rule
  (free, harderOnly, locked), series with jokers and periods without engagement, jokers per month,
  ISO week on an en-US calendar, stake block refuses every stop path except joker and declaration.
- CLI: every command, every error, JSON round trip of `plan set` ← `plan show`, `watch` emits on
  change and survives an app restart.
- `swift test`, `scripts/audit_privacy_boundaries.sh`, `scripts/verify_source_security.sh` green;
  measured CPU of detection in the report.
