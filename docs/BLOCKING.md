# Blocage (Cold Turkey intégré)

Blocage is an optional module. The member blocks websites and apps, now or on a weekly program, can
lock a block so it cannot be stopped before its end, and can freeze the whole Mac. The whole
experience is one page of Goalong (`DashboardSection.blocking`).

Target: parity with Cold Turkey Blocker Pro, as far as macOS allows.

| Cold Turkey Pro | Goalong |
| --- | --- |
| Block websites and applications | Lists of sites and apps |
| Start now / schedule (hours, days) | « Bloquer maintenant » + weekly program per list |
| Allowlist ("block everything except") | List mode « Tout bloquer sauf » |
| Locked block, cannot stop, survives quit/restart/uninstall | Lock kinds + program lock; Standard level in the app, Strict level with a system component (see « Niveau strict ») |
| Frozen Turkey | « Geler le Mac » |
| Breaks and allowances | Breaks (N × M min per day) and quota (X min per day) per list |
| Unsupported browsers blocked | Browsers whose address Goalong cannot read are covered during a site block |

## Module convention (shared with Ambiance)

- `UserDefaults` key `goalong.module.blocking.enabled`, default `false`. Read through
  `GoalongModuleStore` (`Sources/LocalHistoryApp/GoalongModules.swift`), cheap, never starts anything.
- Off: no `BlockingController`, no timer, no observer, no window, no file under `Blocking/`, no
  permission request, no system component. The sidebar entry is hidden.
- On: the sidebar shows « Blocage » after « Surveillance temps réel ». Turning the module on creates
  the controller and reads the store; nothing is blocked until the member starts a block or a
  program.
- Off is refused while anything is locked (locked session, locked program, freeze). Off with nothing
  locked stops every block, removes every window and unregisters any system component.
- Settings › Modules holds the switch (one row per module).

## Rules from the owner

- Lists come from the member only. Never from the « Mon travail » agent, Jev, analytics or history.
  Static suggestions (a fixed catalog the member taps to add) are allowed; nothing is added without a
  tap.
- Reuse the existing observation (`ContextMonitor` / `ContextProvider`) and the Jev window technique
  (`JevWarningPanel`: non-activating `NSPanel`). No second polling observer of the foreground.
- Visual design (page, veils, shield) is done by the design session. Plumbing never edits
  `BlockingPage*.swift` or `BlockingShieldViews.swift`.

## Vocabulary (French UI)

| Concept | UI word |
| --- | --- |
| List (Cold Turkey "block") | Liste |
| Mode block / allowlist | « Bloquer ces éléments » / « Tout bloquer sauf ces éléments » |
| Manual session | Blocage (« Bloquer maintenant ») |
| Weekly windows | Programme |
| Lock kinds | Libre / Difficile / Verrouillé |
| Program lock | « Programme verrouillé jusqu'au … » |
| Quota | « X min par jour » |
| Breaks | « Pauses » |
| Frozen Turkey | « Geler le Mac » |
| Protection level | Standard / Renforcée |

## Data model

Code: `Sources/LocalHistoryApp/Blocking/BlockingModel.swift` (types are fixed; logic may be added in
extensions elsewhere).

Store: `~/Library/Application Support/LocalHistory/Blocking/blocking.json`, directory 0700, file
0600, no symlinks, schema version 1. Each save swaps the new file in atomically (`RENAME_SWAP`) and
keeps the replaced generation as `blocking.previous.json`. At launch, an unreadable, unknown-version
or missing `blocking.json` gives way to the previous generation; a damaged file is set aside as
`*.damaged.json`, never deleted. When neither is usable the state starts empty and the page says
so. While Goalong runs, its in-memory state is the reference: a file changed under it is set aside
and rewritten. A store error refuses edits; it is never a lock and never stops « Quitter ».
`locked-until` holds the end of the latest lock (Unix seconds) for `uninstall.sh`; absent = no lock.

- `BlockList`: `id`, `name`, `mode` (`block` | `allowOnly`), `sites: [BlockSiteRule]`,
  `apps: [BlockAppRule]`, `program: BlockProgram`, `quotaMinutesPerDay: Int?` (1…720),
  `breaks: BlockBreaks?` (count 1…12 per day, minutes 1…30).
- `BlockSiteRule.pattern`: normalized `host[/path]`. Normalization: trim, lowercase, drop scheme,
  `www.`, credentials, port, query, fragment and trailing `/`; IDN to punycode; reject IPs, empty
  hosts and hosts without a dot (except `localhost` is rejected too). `youtube.com` matches
  `youtube.com` and every subdomain; `youtube.com/shorts` matches that path prefix on a segment
  boundary (`/shorts`, `/shorts/x`, not `/shortsx`).
- `BlockAppRule`: `bundleIdentifier`, `name`.
- `BlockProgram`: `ranges: [BlockProgramRange]` (`id`, `weekdays: Set<Int>` ISO 1 = Monday … 7,
  `startMinute`, `endMinute` in 0…1440; `end <= start` means it ends the next day), `lockedUntil:
  Date?`.
- `BlockSession`: `id`, `listIDs`, `start`, `end`, `lock` (`free` | `typing` | `locked`),
  `origin` (`manual` | `program(rangeID)`).
- `BlockDayUsage`: per local day, per list: quota seconds used, breaks taken, current break end.
- `BlockFreeze`: `start`, `end`, `mode` (`shield` | `lockScreen`), `allowedApps: [BlockAppRule]`.
- `BlockingDocument`: `version`, `lists`, `sessions` (manual), `usage`, `freeze`, `clock` (see
  « Clock »).

## Rules

**Matching.** A target is the foreground app (bundle id) plus, for a browser, its URL. A list is
*active* when a manual session includes it or one of its program ranges contains now. For an active
list that is not on break and has no quota left:

- `block` mode: the app is blocked if its bundle id is listed; the site is blocked if a rule matches.
- `allowOnly` mode: every regular app is blocked unless listed, except browsers, which follow the
  site rules: a site is blocked unless a rule matches. Browser internal pages (`about:`,
  `chrome://newtab`, `edge://newtab`, Safari start page without URL, `favorites://`) stay allowed.

Several active lists combine: blocked if any active list blocks.

**Never blocked.** Goalong itself, Finder, Dock, `loginwindow`, SystemUIServer, Control Center,
Notification Center, Spotlight, `SecurityAgent`/`coreautha` prompts, screensaver, and any process
whose activation policy is not `.regular`. The list is a constant reviewed in tests.

**Quota.** For an active list with `quotaMinutesPerDay`, targets the list would block stay allowed
until today's used seconds reach the quota. Usage grows only while such a target is in the
foreground, unlocked screen, not idle more than 2 min. Day boundary: local midnight.

**Breaks.** For an active list with `breaks`, the member may take a break (`count` per day, `minutes`
each). During a break the list blocks nothing. Breaks are allowed even when locked: they were chosen
before the lock. A break cannot start inside a freeze.

**Lock kinds (manual sessions).**
- `free`: « Arrêter » ends it.
- `typing`: « Arrêter » asks to retype a random 120-character text (letters and digits, no
  look-alike characters, paste refused). Correct = ends.
- `locked`: cannot be stopped. It ends at `end`.

**Program lock.** While `program.lockedUntil > now`, the list can only get stricter: adding sites or
apps, adding or lengthening ranges, lowering the quota, removing breaks are allowed; removing,
shortening, raising the quota, adding breaks, changing the mode, deleting the list are refused.
Program sessions of a locked program are `locked`; of an unlocked program, `free`.

A locked manual session also makes its lists stricter-only until its end.

**Freeze.** `shield`: a full-screen Goalong shield on every display, kiosk presentation options
(no Dock, menu bar, app switching, force quit, session termination); allowed apps can be opened from
the shield and are the only apps allowed to the front. `lockScreen`: lock the session at start and
again within 2 s of every unlock until the end. Both: maximum 24 h, minimum 5 min, always locked.
Shut down and restart stay possible (never trap the Mac); at the next login the freeze resumes if not
over.

**Clock.** Locks end at a wall-clock `end`. Within one boot, keep `(wall, continuous uptime)` pairs:
if the wall clock jumps forward more than 60 s beyond the elapsed continuous time, push every locked
end forward by the jump. Persist the last seen wall time every minute; after a reboot, a wall clock
earlier than the last seen time keeps the remaining durations. Documented limit: across a reboot a
forward clock change cannot be detected by the app alone.

## Observation (reuse, no second observer)

`ContextMonitor` gains a blocking-only mode:

- It runs when `BlockingController.needsObservation` is true (an active or upcoming-in-60-s list with
  apps or sites, or a freeze), even if Computer History is off, manually paused or under the
  privacy stop.
- In that mode it samples and calls the blocking sink, but records nothing, feeds neither Jev nor
  activity analysis, and keeps no snapshot after the sample.
- When Computer History is capturing normally, the same samples feed the sink: no extra sampling.
- The sink receives `BlockingObservation`: bundle id, pid, window frame (AX, screen coordinates),
  browser flag, URL (host + path only) when readable, private-window flag, at.
- Private windows are never read: the provider only reports the flag. The private check runs for
  every app that may show a page (known browser, configured browser or web content) before any
  address read. An unknown app with a private window counts as a browser only when it shows an
  address field, found without reading its value. Exclusions of Computer History
  do not hide URLs from the blocking sink (they are privacy choices for history), but the URL never
  reaches the recorder.

App launches and activations also arrive through the existing `NSWorkspace` notification path in
`AccessibilityEventMonitor`; reuse it, do not add another one.

## Enforcement, Standard level (in the app)

- **App blocked**: `terminate()`, then `forceTerminate()` after 1 s if still running; show the app
  notice (`BlockedAppNotice`) for 4 s, non-activating, top centre of the active screen. A blocked app
  that relaunches is terminated again (no loop limit while blocked).
- **Site blocked**: cover the browser window frame with the site veil (`BlockedSiteVeil`), a
  non-activating panel that absorbs clicks, follows the window frame on every sample, and sits above
  the window (level `.floating`). Then stop the page: press the browser's « Fermer l'onglet » menu
  item through AX (fallback: `⌘W` posted to that pid). The veil stays 1.5 s after the tab changes,
  then fades.
- **Private window during a site block**: covered with the site veil (« Navigation privée »), tab
  closed the same way.
- **Unsupported browser**: a known browser (the configured browser list plus
  `BlockingRules.otherBrowsers`) whose URL stays unreadable for 3 s while a site block is active is
  treated as blocked (« Navigateur non pris en charge »). An app that only shows web content
  (Electron apps, Mail) is not a browser: app rules apply to it, so « Tout bloquer sauf » blocks it
  unless listed. An unknown app becomes a browser for one sample only when its address is read.
- **Accessibility missing**: app blocks still work; site blocks are flagged on the page
  (`siteBlockingAvailable == false`) and every known browser is treated as unsupported.
- **Persistence**: on launch, the controller restores sessions, usage and freeze before the first
  window appears. Launch at login is required while anything is locked: the controller registers
  `SMAppService.mainApp` if needed and shows its state.
- **Quit**: while anything is locked, « Quitter Goalong » explains it cannot quit and offers to
  close the window. (A forced quit is covered by the Strict level.)

Windows: reuse the `JevWarningPanel` technique. Blocking windows sit above Jev's.

## Strict level (Renforcée)

Decision 2026-10-04 (owner, after GPT Pro `gptpro#bfb651`): **later**. Standard ships first. Strict
is decided together with a move to Developer ID + notarization, which every variant needs: the SDK
states « Apps that contain LaunchDaemons must be notarized » (`SMAppService.h`), a root component
must not ship from the current non-notarized build, and Network Extension needs Developer ID. The
move changes the designated requirement (leaf « Apple Development: … » today), so every member grants
macOS permissions again once.

Target design when it starts (Pro's plan, checked against the code):
- **A package, not the app bundle.** A root daemon `blockingd` (`/Library/PrivilegedHelperTools`,
  `/Library/LaunchDaemons`, root:wheel) keeps commitments, deadlines and quotas, and refuses early
  unlocks. A session companion `Goalong Protection.app` (root-owned, its own `SMAppService.agent`)
  owns observation, veils and app termination under the member's UID. A separate signed `.pkg`
  installs both only when the member turns Strict on; « off » means none of it is installed. A daemon
  inside the main bundle was rejected: moving the app to the Trash then force-quitting ends it
  without a password, so it adds little over Standard.
- **Root keeps commitments, not commands.** XPC with `setCodeSigningRequirement` (macOS 13) per
  role. The app and the CLI share one signing identity, so neither gets mutation rights: only the
  companion. Messages: `hello`, `status`, `prepareCommit`, `commit`, `tighten`, `requestBreak`,
  `endBreak`, `requestRemoval`, `reportHealth`; never a path, command, URL, PID or end date from a
  client. `BlockingEnforcementBackend` is an effects adapter and is not exposed to root as is.
  Visited URLs never reach root.
- **One observer.** `ContextMonitor` sampling is extracted; in Strict the companion owns it and feeds
  history only under its existing consent. The companion needs its own Accessibility approval.
- **Time.** Deadlines on `mach_continuous_time` + boot id; across a reboot the remaining time never
  grows. A forward clock change plus a reboot can still end a lock early (accepted: no time server).
- **Safety.** Freeze ≤ 24 h, locked program horizon ≤ 7 days, a store failure leads to recovery and
  never to an endless lock, a visible and slow safety exit from the freeze, an admin recovery tool
  outside the app. No `hosts`, `pf`, immutable flags or configuration profiles.
- **Network, later.** Blocking before page load and in background tabs needs a
  `NEFilterDataProvider` system extension: a separate phase with its own consent and tests.
- **Promise.** Strict makes « quit Goalong » an act that needs the admin password. It does not stop an
  administrator who wants to remove it.

Lots: 0 contract and distribution, 1 `BlockingPolicyCore`, 2 IPC + daemon, 3 observation extraction
+ companion, 4 product integration, 5 packaging and lifecycle, 6 network filter. No merge to `main`
before Developer ID and recovery tests on a dedicated Mac.

## API for the UI

`@MainActor final class BlockingController: ObservableObject`, created only when the module is on.

- Published state: `lists`, `activeBlocks: [BlockingActiveBlock]` (session or program window: lists,
  start, end, lock, breaks left, break end, quota left), `freeze: BlockFreeze?`,
  `nextProgramStart: (listID, Date)?`, `siteBlockingAvailable`, `browsers:
  [BlockingBrowserSupport]` (name, bundle id, supported), `protection: BlockingProtectionState`,
  `error: String?` (French).
- Lists: `save(_:)`, `delete(_:)`, `editCheck(_ new: BlockList) -> BlockingEditCheck`
  (`allowed` | `refused(String)`), `suggestions: [BlockSuggestion]` (static catalog).
- Sessions: `start(listIDs:until:lock:)`, `stop(_:typed:)`, `typingChallenge(for:)`,
  `takeBreak(listID:)`, `endBreak(listID:)`.
- Program: part of `BlockList`; `lockProgram(listID:until:)`.
- Freeze: `startFreeze(until:mode:allowedApps:)`.
- Installed apps for pickers: `installedApps() async -> [BlockAppRule]` (Applications folders, with
  icons fetched by the view).

Every refusal returns a short French reason the page shows as is.

## Tests

- Module off: building the app model creates no controller, timer, window or file under `Blocking/`,
  requests no permission.
- Normalization and matching (subdomains, path boundary, IDN, rejected inputs).
- Activity: overnight ranges, ISO weekdays, DST days, several lists, allowOnly with internal pages,
  never-blocked set.
- Quota and breaks across midnight; breaks while locked; no break in a freeze.
- Locks: stop refused; typing challenge; stricter-only edit matrix; program lock.
- Clock jump forward within a boot extends locked ends; unreadable store never unlocks.
- Blocking-only observation records nothing and feeds neither Jev nor analysis.
- All existing checks stay green: `.github/workflows/macos.yml` commands,
  `scripts/verify_source_security.sh`, `scripts/generate_support_source_allowlist.py --check`.

## Engine handoff (Standard level)

The design commit ships the page, the veils, the frozen shield, the module switch, the model and an
in-memory `BlockingController` skeleton. The engine work completes it without changing the UI.

- **Do not edit** (design owner): `Blocking/BlockingPage.swift`, `Blocking/BlockingPageLists.swift`,
  `Blocking/BlockingWeek.swift`, `Blocking/BlockingShieldViews.swift`, `GoalongModulesSettings.swift`.
  Host these views in windows; do not restyle them. If the UI API above must change, keep it
  source-compatible and say so in the report.
- **Scope**: the store (path, modes, atomic writes, versioning, unreadable = stays locked); controller
  timers (refresh at each boundary and at least every 15 s while something is active or upcoming;
  nothing at all while idle), `needsObservation`; the blocking-only mode of `ContextMonitor` and the
  sink; every item of « Enforcement, Standard level »; quota accounting and breaks (the veil's
  `onBreak` calls `takeBreak`); the freeze (shield on every screen with kiosk presentation options,
  kept apps launchable; lockScreen mode with relock); the clock-jump rule; launch at login while
  locked; quit refusal; the browser support list; `BlockingEnforcementBackend` with the Standard
  backend only. No privileged component, helper, daemon, pf or hosts change: that is the Strict
  level, decided separately.
- **Module off** must stay inert (see « Module convention »): no controller, timer, window, file,
  observer or permission request.
- **Tests**: everything in « Tests » above, and fix the existing tests the design commit broke (the
  sidebar now uses `DashboardSection.sidebarSections(modules:)`; Réglages has a new `.modules` pane).
- **Inventories**: add new sources to the support allowlist and the security artifacts
  (`scripts/generate_security_artifacts.py`); update `docs/PERMISSIONS.md` and `docs/GUARANTEES.md`
  for what the module may do once on. No network use.
- **Checks**: `swift build`; the full suite with an isolated `HOME` (two `ChatGPTRecapTests` keychain
  failures are known there); `scripts/verify_source_security.sh`;
  `scripts/generate_support_source_allowlist.py --check`; `./scripts/audit_privacy_boundaries.sh`.
  Never run two `swift build` at once in one worktree.

## Standard engine implementation notes (2026-10-04)

- The page API and design-owned views are preserved. Schema 1 gains optional `clock`,
  `heldPrograms` (locked program windows extended after a clock jump), and `programSkips`
  (a free program stopped for its current window); old schema-1 files remain readable.
- An unreadable/invalid store preserves the last good in-process state and refuses all edits,
  module-off and ordinary quit. Scheduled deadlines still end normally; an initially unreadable
  store reports an error because missing rules cannot be reconstructed. No store is created while
  the module is off or an enabled module is completely empty.
- Locked allowlists can only shrink by set inclusion (replacing one allowed rule with another is
  refused); quotas can decrease or be removed (no quota means immediate blocking). Removing a
  program lock is refused. A freeze cannot be replaced or shortened while it runs.
- Breaks end at local midnight; usage and break counters reset then. Private/unreadable browser
  URLs fail closed during an eligible site block, including while a quota remains, because no
  address can establish eligible quota accounting. Explicit browser internal pages stay allowed.
- Program times use civil calendar times: a missing DST time advances to the next valid time;
  a repeated time uses its first occurrence. Touching/overlapping windows are merged.
- Screen-lock freeze uses the fixed macOS Control-Command-Q shortcut (no private API, executable,
  helper or shell), with a one-second relock timer while unlocked. Starting it without
  Accessibility is refused in French. If Accessibility is revoked during the freeze, enforcement
  falls back to the shield until it becomes available again. The Standard level cannot prove that the shortcut actually
  locked the session; use shield mode if the OS shortcut is changed or ineffective.
- Shield uses hideDock/hideMenuBar, disableProcessSwitching/disableForceQuit/disableHideApplication.
  `disableSessionTermination` is deliberately omitted: Apple documents that it also disables
  shutdown/restart, contrary to the owner's escape requirement. Kiosk options apply only while
  Goalong is foreground. Allowed apps are launched explicitly from the shield.
  Reference: [Apple presentation options](https://developer.apple.com/documentation/appkit/nsapplication/presentationoptions-swift.struct).
- Continuous time is `mach_continuous_time` (includes sleep). Login-item registration is the main
  app only, with actual SMAppService status published and approval/failure exposed through the page error; permission approval remains the member's action.
- A dormant scheduled program keeps one one-shot boundary timer (next start minus 60 seconds).
  Periodic refresh is limited to active/upcoming/locked work; an enabled module with no pending
  session, program, lock or freeze has no timer. This is the necessary interpretation of
  “nothing while idle” to make automatic starts work. Module-off remains completely inert.
- No destructive live-app/keyboard tests are run against the member's current applications.
  Injected-backend tests establish controller dispatch and rules; physical multi-display kiosk,
  browser-specific AX menu behavior and actual lock/unlock timing remain device acceptance checks.

### Known Standard bypasses

1. Force quit / SIGKILL / process suspension or crash removes all panels and enforcement; deleting
   the app by hand and an unapproved/disabled login item prevent recovery. `uninstall.sh` refuses
   while a lock is active (override `GOALONG_UNINSTALL_DURING_LOCK=1`). Permission/updater relaunches and
   system-directed termination also leave a recovery gap. Another user, recovery/safe mode or
   another OS is outside the process boundary.
2. The member owns the preferences and store. Disabling the module in defaults while Goalong is
   stopped, deleting the store directory or both generations, replacing them with valid JSON,
   restoring an older copy, changing app bundle IDs or moving/replacing the app defeats this level.
   A damaged or deleted `blocking.json` alone gives way to the previous generation; this is not
   cryptographic tamper resistance.
3. Only foreground targets are observed. Background downloads/audio/network use, another browser
   window, offscreen tabs, very quick app/window switches and page execution before tab closure
   can escape. Quota gaps after missed/stale samples are not invented; eligible accounting is
   capped at 15 seconds per interval and can undercount when the process is stalled.
4. Browser identity/private-mode detection and AX URL/menu exposure are best effort. Undetected
   wrappers, spoofed AX metadata, unreadable private markers, disabled Accessibility, a rejected
   AX/Command-W operation, remapped shortcuts, full-screen Spaces/window ordering and an unknown
   browser without a usable window frame can defeat site enforcement. Missing Accessibility is
   shown and known browsers are covered; it does not grant the app power to stop network traffic.
5. A same-boot forward clock jump is corrected. A forward clock change across reboot, edited clock
   metadata, or a killed process before the minute checkpoint cannot be detected reliably.
6. A regular app may refuse termination during the one-second grace; another user/protected
   process and the reviewed system/non-regular exceptions are intentionally never terminated.
7. Kiosk limitations, allowed-app windows, Mission Control/Spaces/system UI and changed OS lock
   shortcuts remain escape surfaces. Screen locking cannot be guaranteed without a stronger
   component. Shutdown/restart stay possible and resume depends on Goalong launching at login.
8. The design-owned typing field rejects multi-character growth, but cannot distinguish an
   individual pasted character or automated keystrokes from typing; the controller receives text,
   not trusted input provenance. Standard provides a friction challenge, not input attestation.

### Engine verification and local delivery (2026-10-04)

- `swift build`: passed (exit 0).
- Full `swift test` with an isolated `HOME`: 1,561 tests, 48 skipped, 0 failures, 283.6 seconds.
  `BlockingEngineTests`: 30 tests, 0 failures. The two previously known isolated-HOME
  `ChatGPTRecapTests` keychain failures did not reproduce in this run.
- `scripts/verify_source_security.sh`: passed (exit 0).
- `python3 scripts/generate_support_source_allowlist.py --check`: passed (exit 0).
- `./scripts/audit_privacy_boundaries.sh`: passed (exit 0).
- Workflow script validation/regressions: 58 commands, all exit 0. Full packaging, install,
  opt-in rendering and physical browser/multi-display/lock-screen tests were not run for this
  engine handoff. No live app was terminated and no lock shortcut was sent during verification.
- Logs: `/tmp/goalong-blocking-build.log`, `/tmp/goalong-blocking-tests.log`,
  `/tmp/goalong-blocking-security.log`, `/tmp/goalong-blocking-privacy.log`,
  `/tmp/goalong-blocking-workflow.log`. The isolated HOME path is recorded in
  `/tmp/goalong-blocking-test-home.txt`.
- Local commits: `c8457e1` (rules/store/calendar), `5d6012d` (Standard backend), `75af45c`
  (lifecycle/observation/accounting and regression tests), followed by the documentation/inventory
  commit. Branch: `feat/cold-turkey-engine-20261004`; no push or PR. All design-owner files preserved.
