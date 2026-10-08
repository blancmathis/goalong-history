# Blocage + : raison, tentatives, déclencheurs, temps gagné (2026-10-08)

Owner choice after #77. Base: `docs/BLOCKING.md`, `docs/BLOCKING-EXCEPTIONS-KEYWORDS-20261008.md`,
`docs/CONCENTRATION.md`. Stacked on `feat/blocage-exceptions-20261008` (PR #77).
Schema stays version 1; every new field is optional and old files load unchanged.

## 1. Raison + tentatives

- `BlockList.reason: String?` — the member's own sentence, trimmed, 1…140 characters. Editable even
  under a lock (it never loosens anything).
- Veil (site) and app notice show it under the list name, in quotes. No reason = nothing shown.
- Attempt = one blocked event for a list: a target that becomes blocked (site veil shown or app
  blocked). Same list + same target (host, or bundle id) within 10 s counts once. Slow-down shows
  keep their own counters.
- `BlockDayUsage.blocked: [UUID: Int]?`, kept in `usageHistory` like the others.
- Veil line: « 3ᵉ tentative aujourd’hui » (from the 2nd on). Controller exposes today's count per list
  and the total, for the page (UI later).
- Local only. Never sent to Jev, analytics or the site in this task.

## 2. Déclencheurs automatiques

`BlockList.triggers: BlockTriggers?` with:
- `apps: [BlockAppRule]` — while one of these apps is **running** (not only frontmost), the list is
  active. Session origin `.trigger(listID)`, lock `free`, ends within 5 s after the last app quits.
  Reuse the existing NSWorkspace launch/terminate path, no new observer. Goalong and never-blocked
  apps cannot be triggers; a trigger app cannot also be blocked by the same list (refuse).
- `focus: Bool` — macOS Focus filter: when a Focus whose filter selects this list turns on, the list
  is active until it turns off. Origin `.focus`, lock `free`.
- Stricter-only (lock): adding triggers allowed, removing refused.

Shortcuts actions: « Démarrer un blocage » (lists, duration, lock free/typing) and « Arrêter les
blocages libres ». Never stop a typing/locked/password block from Shortcuts.

**Feasibility gate first.** The app builds with SwiftPM + `scripts/build_app.sh`, no Xcode project.
Focus filters (`SetFocusFilterIntent`) and Shortcuts need App Intents metadata
(`Metadata.appintents`, normally made by Xcode's `appintentsmetadataprocessor`). Prove it works in
the built bundle (metadata present, intent listed by `shortcuts`/system) before building on it.
If it cannot be made reliable: ship app triggers only; for Shortcuts document the existing CLI via
« Exécuter un script shell »; report why for Focus. Do not add an Xcode project.

## 3. Temps gagné

For a list with `quotaMinutesPerDay`:
- `BlockList.earn: BlockEarn?` = `{ workMinutes: 25, rewardMinutes: 5, capMinutes: 60 }`
  (workMinutes 10…120, reward 1…30, cap 5…240).
- A Concentration session **finished normally** (not abandoned/cancelled) adds
  `floor(focused minutes / workMinutes) × rewardMinutes` to today's quota of every list with `earn`,
  capped per day per list. A session spanning midnight credits the day it ends.
- `BlockDayUsage.earnedSeconds: [UUID: Double]?`. Effective quota = quota + earned.
- Lock: turning `earn` on or raising reward/cap is looser (refused); off or lower is stricter.
- Controller exposes earned minutes today per list (UI later). Veil quota line may say
  « +10 min gagnées ».

## Tests

Attempt dedup (10 s, per list/target), reason limits, lock checks for every new field, trigger
start/stop with app launch/quit (fake workspace), trigger refusals, earn arithmetic (cap, midnight,
abandoned session = 0), old-file decoding, `validate` limits.
