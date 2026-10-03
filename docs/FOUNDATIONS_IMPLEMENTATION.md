# Foundations F1–F5 — handoff

Branch: `feat/data-foundations-20261003`. No push, PR, merge, installation or real-data writes.

## UI and integration API

- `Sources/LocalHistoryCore/GoalongDayCoverage.swift`: `GoalongCoverageReason` (all F2 reasons and day reasons), `GoalongDayOrigin` (`journal`, `summary`), `GoalongDayCoverage` with observed/active/idle/concealed/unobserved seconds, `secondsByReason`, `concealedSecondsByReason`, `unobservedSecondsByReason`, first/last observation, mixed-period origin and `summaryDays`. Available on `Day.coverage` and `Period.coverage`; `Segment.coverageReason` participates in merging.
- `Day.origin`, `Day.hasDetailedSource`, `Day.dayReason`, `Day.firstObservation`, `Day.lastObservation` in `GoalongLocalAnalytics.swift`. A summary fast path can still have detailed events. Use `hasDetailedSource == false`, not merely `.origin == .summary`, to say that detailed data is gone.
- `Sources/LocalHistoryCore/GoalongActivityBreakdown.swift`: `GoalongActivityBreakdown.Mode` (`call`, `media`, `display`, `keyboard`, `pointer`, `reading`), `hours`, `secondsByMode`, `seconds(_:)`, `totalSeconds`. Hour has start/end, modes and totals. Available on `Day.breakdown`, `Period.breakdown`; preserved by `.applying(verdicts)` and archives.
- `Sources/LocalHistoryCore/GoalongActivityDayStore.swift`: root initializer, `read`, `write`, `load`, `sourceRevision`, `dayKey`, `journalDays`, `backfill`, `preserveBeforePurge`; schema/caps public. `load` accepts detailed and summary retention days and cancellation. Raw sources remain authoritative while present. Only closed `.ready` days are written; no titles, full URLs, text, tasks or conversations in the summary.
- `Sources/LocalHistoryApp/GoalongActivityDayReader.swift`: app adapter `load` and `sourceRevision` (includes summary stamp for cache invalidation); `GoalongActivitySummaryBackfill.shared.start/cancel`. The hook in `GoalongAnalyticsModel` is deliberately tiny: replace past-day load with adapter; delegate revision to adapter. **Perf integration:** retain the perf thread's current-day incremental path; route closed days through this adapter and include its summary revision stamp.
- `HistoryDataClass.activitySummaries` and `HistoryRetentionPolicy.activitySummaries`, indefinite by default, backward-compatible v1 decode. The existing settings switch has only the exhaustive-case additions; no SwiftUI layout change.
- `Sources/LocalHistoryCore/GoalongWorkReassessment.swift`: `GoalongWorkRetryState`, `permitsReassessment`, bounded `GoalongWorkReassessment.excerpts`. `GoalongWorkVerdicts.retries`, `GoalongWorkClassification.pending(... calendar:)`, `.request(... contextExcerpts:, dayNote:)`. Request exposes `visible_context_excerpt` and `day_note`.
- `GoalongWorkStore.Entry.attempts/lastAskedDay`, `markAsked`; `GoalongWorkAgent.classify(day:userInitiated:dayNote:)`. **S5 integration:** supply the note to that parameter (including the automatic path where desired), after the user's sharing choice/masking. No note store or recap file was edited in F.

## Guarantees and limits

Summary read/write uses owner-checked no-follow directory/file descriptors, 0700/0600, bounded decode, geometry/method/timezone validation, atomic rename and fsync. Raw day retention validates/re-reads a summary before unlink; on failure raw events stay. The app maintenance is utility-priority and every normal writer enters the existing derived-history barrier. Deletion includes affected summary files and removes their directory on full clearing. A finite summary policy is explicit expiry; normal readers/backfill do not recreate expired summaries, and retention may remove the new preserved summary when that class was explicitly expired too.

Breakdown minute precedence is coarse by design: all active parts of a minute get its strongest valid observed mode. No extra-source seconds are added. Tests cover idle, gaps, passive modes, input, fractional timestamps, hour boundaries, classification and archive round-trip.

Automatic unclear verdicts need 5 minutes, another analysed day, and fewer than 3 attempts. Failed dispatched requests count. Owner corrections never enter the retry path. Legacy entries count as one attempt with `seen` as lastAskedDay. Visible excerpts require reviewed visible-text permission and app/domain/privacy masking, are hash checked/redacted/clipped, and remain transient. Excerpt reads fail closed at 64 MiB, 32,768 rows or 20 seconds.

A root/day outside the summary caps, unsafe paths or unreadable input retains raw events instead of expiring them. Existing purged days cannot be reconstructed if they have no valid summary. Method/timezone changes with no journal cannot reinterpret old summaries. This is deliberate fail-closed behavior, not backfill from memory narratives.

## Verification

Code commit: `0e7e493`. Method/privacy documentation commit: `5aa79a4`. Complete private logs: `/tmp/goalong-foundations-verification/`.

Full isolated-HOME run (`HOME` and `CFFIXED_USER_HOME` pointing to the same `mktemp -d /tmp/goalong-XXXX` directory, `swift test --jobs 3`) completed with exit 1, exactly the two failures expressly allowed by this brief:

```text
Executed 1455 tests, with 29 tests skipped and 2 failures (2 unexpected) in 218.999 (219.142) seconds
ChatGPTRecapTests.testAnalysisProofStoreCreatesBoundedVerifiableArtifactsWithoutCopyingPromptOrTranscript: keychainFailure(-60006)
ChatGPTRecapTests.testGeneratedResponseCapsuleIsEncryptedBoundedAuthenticatedAndCryptographicallyDeleted: keychainFailure(-60006)
```

All 20 new regression tests passed (11 Core foundations, 7 App persistence, 2 Core reassessment). Full log: `full-suite-approved.log`; the two errors originate at `AnalysisProofStore.swift:329` and `AnalysisEvidenceCapsuleStore.swift:182`.

Native CI: disclosures 1/1, analytics renders 2/2, reminder controls 1/1, brand journeys 3/3, timezone export checks 27/27 in each of UTC, America/Chicago and Europe/Paris, permission relaunch, source allowlist, security and privacy/dependency audits passed. Native evidence is in `native/`; `ci-native-status.log` tracks the bundle checks. ARM64 app build passed with `--jobs 3`, ad-hoc signature, version `0.6.0-ci`; bundle plist/signature/identity, `verify_local_bundle.sh`, security-capability manifest and `test_goalong_cli.sh` all passed (exit 0). No app was installed. The final native evidence has 149 PNGs.

`package_release.sh` passed (exit 0), followed by both archive existence/size checks (exit 0). The first native wrapper checked those two paths before running the packaging step, which gave exit 1 for each; the missing step was then run and the checks were repeated successfully. Both initial failures and corrected results remain visible in `ci-native-status.log` and `ci-packaging-status.log`.

Artifacts in this worktree's ignored `dist/`:

- `Goalong History.app` (ARM64 only, ad-hoc signed).
- `Goalong-History-macOS-universal.zip`: 101,775,150 bytes, SHA-256 `d86125e4e6de308c9300e0372015e6181e3982074c2d9d9dfb8af617293f12e0`.
- `Goalong-History-macOS-universal.dmg`: 113,061,357 bytes, SHA-256 `7daa247566ff7c33ade24e17e61ea30cc8e6bdfb12d04dbf11324163839d7d47`.

The filenames are the existing workflow's names; this local build contains only ARM64. Manifest `sourceCommit` is `5aa79a42755cfb346f6cf13011fcb4bafa912c56`, `sourceDirty: true` because the external test edit was present during packaging. GitHub artifact-upload steps were not run; there was no push or remote CI run. All executable local workflow stages were exercised, subject to the explicitly allowed Keychain failures and the standalone-checkout validator limitation below.
Focused run already passed: `Executed 96 tests, with 1 test skipped and 0 failures (0 unexpected)`.
First full pass was interrupted after the existing scavenger ownership test exceeded its 100 ms wall-clock budget on a Mac with load >300. Its existing injectable monotonic clock is now fixed only in the ownership fixture; production limits and deadline-specific tests remain unchanged. The two known isolated-HOME keychain failures were observed as `keychainFailure(-60006)`.
21 static CI checks passed (exit 0). Static CI checks pass except the original upgrade safety invocation rejected this worktree (`Not a Goalong History git checkout`, exit 66). The unchanged validator/test scripts pass from a temporary standalone checkout containing a normal `.git` directory (exit 0); no script was patched or guard bypassed.

## Files and context

Detailed source diff is on this branch. Four required docs updated: LOCAL-ANALYTICS, PRIVACY, DATA-FLOW, WORK_DEFINITION; source allowlist regenerated. Added three regression test files and updated two existing fixtures for the new semantics, plus the deterministic scavenger fixture above.
An external change appeared in `Tests/LocalHistoryAppTests/ChatGPTRecapTests.swift` during the package build, adding Keychain availability skips. It was not made, staged, committed or reverted by F. The full-suite numbers above precede that external change and report the original two failures honestly.

Main checkout's shared CONTEXT.md is parent-owned and was read; F does not edit another worktree. Parent should replace the old 'audit only / not approved' state with the actual implemented/integration state after merging these commits, and record the perf/S5 integration hooks above.

## Deviations and integration decisions

- A summary cache hit reports `origin == .summary` even while raw detail remains. `hasDetailedSource` separately answers whether event-level drill-down remains possible. Raw revision mismatch always rebuilds.
- Journal revisions include nanoseconds, inode/device and size, and the app's cache key includes the summary-file stamp. This also invalidates summary-only results after deletion.
- Explicit finite retention for the new class overrides the normal indefinite summary guarantee; expired summaries are not recreated. If writing a safe summary is impossible, detailed retention keeps the source.
- The only view-file edit is the existing retention settings' exhaustive title/set-duration case for the new class. No visual layout or new chart was implemented.
- The legacy scavenger ownership fixture uses its already-supported injected clock to avoid measuring overloaded host scheduling; production and deadline tests are unchanged.
- The baseline upgrade validator requires a real `.git` directory, so its worktree invocation fails with exit 66. Testing the unchanged scripts in a temporary standalone checkout passed, without changing the validator or relaxing its guard.
- The large busy-day reader/incremental today path belongs to stream P and is not reimplemented here. Note persistence and consent/recap wiring belong to stream S.

## Changed files (26 source/test/method-documentation files + this report)

- `Sources/LocalHistoryApp/AppDelegate.swift`
- `Sources/LocalHistoryApp/DerivedHistoryCleaner.swift`
- `Sources/LocalHistoryApp/GoalongActivityDayReader.swift`
- `Sources/LocalHistoryApp/GoalongAnalyticsModel.swift`
- `Sources/LocalHistoryApp/GoalongWorkAgent.swift`
- `Sources/LocalHistoryApp/GoalongWorkStore.swift`
- `Sources/LocalHistoryApp/HistoryRetentionSettings.swift`
- `Sources/LocalHistoryApp/HistoryRetentionStore.swift`
- `Sources/LocalHistoryApp/SupportSourceAllowlist.swift`
- `Sources/LocalHistoryCore/GoalongActivityBreakdown.swift`
- `Sources/LocalHistoryCore/GoalongActivityDayStore.swift`
- `Sources/LocalHistoryCore/GoalongDayCoverage.swift`
- `Sources/LocalHistoryCore/GoalongLocalAnalytics.swift`
- `Sources/LocalHistoryCore/GoalongWork.swift`
- `Sources/LocalHistoryCore/GoalongWorkReassessment.swift`
- `Sources/LocalHistoryCore/RetentionPolicy.swift`
- `Tests/LocalHistoryAppTests/AbandonedTemporaryScavengerTests.swift`
- `Tests/LocalHistoryAppTests/GoalongActivityPersistenceTests.swift`
- `Tests/LocalHistoryAppTests/RetentionStoreTests.swift`
- `Tests/LocalHistoryCoreTests/GoalongActivityFoundationTests.swift`
- `Tests/LocalHistoryCoreTests/GoalongWorkClassificationTests.swift`
- `Tests/LocalHistoryCoreTests/GoalongWorkReassessmentTests.swift`
- `docs/DATA-FLOW.md`
- `docs/LOCAL-ANALYTICS.md`
- `docs/PRIVACY.md`
- `docs/WORK_DEFINITION.md`
- `docs/FOUNDATIONS_IMPLEMENTATION.md` (this handoff and validation record).
