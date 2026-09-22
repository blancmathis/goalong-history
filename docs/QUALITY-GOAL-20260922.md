# Goal — Goalong History quality, 22 September 2026

## Objective

Continue the interrupted « Évaluer l’avancement de Goalong » task: make the app
reliable from end to end, fix reproducible failures, and record what has actually
been verified. A passing unit suite is not a claim that every live interaction,
private-data transmission or installation has been exercised.

## Starting point and preservation

The audited installed app is 0.6.34, sourced from `1350040fc842`.
The interrupted agent left an uncommitted conversation-warning correction in the
`goalong-analytics-final-20260920` worktree. That worktree is preserved unchanged.
This continuation uses a separate worktree and branch,
`fix/end-to-end-quality-20260922`, based on `d68166f05557` (the unified Activité
merge), and carries forward the intent and tool-error wording of that correction.

## Corrections

### A. Preview lifecycle

The installed preview could display only its banner. The page's load task required
`dashboardIsVisible`, which in this app means *keyboard focus*, not merely a
visible window. That boundary is deliberate for private archive reads but
inappropriate for explicitly requested synthetic data.

`GoalongAnalyticsLoadRequest` retains the focus requirement for real reads and
allows the in-memory preview without it. Its identity does not change when focus
moves while a preview is open. Real unfocused first loads now explain why reading
is waiting, instead of presenting a blank page or an indefinite loading state.
The preview remains opt-in, never persisted, separately navigated and ineligible
for real sharing or AI generation.

### B. Conversation source health

Transcript error-event telemetry is no longer treated as a read failure.
`AgentConversationSourceHealth` distinguishes an unreadable index, actual scan
failures, bounded analysis still in progress and an inventory capacity limit.
Read failures retain Retry and source review. Pending work offers Resume analysis.
Capacity limits explain the bounded projection instead of suggesting that an
identical retry can remove the limit. Raw source paths are not put in the notice.

This is not a claim to repair every malformed third-party transcript. Genuine
source-read failures remain visible.

### C. Apple Screen Time provenance

Both Activité and the detailed Apple page display a source-assurance notice.
The notice distinguishes the Apple Settings presentation, an authorized public
export, a private aggregate and a partial reconstruction. It explicitly says
when reconstruction may differ from Apple Settings and missing data is unknown,
not zero. No permission, collector, source total or device aggregation is changed.
Apple measurements remain separate from Goalong foreground observations.

## Acceptance and evidence

- [x] Resume on the current unified Activité source; preserve the original worktree.
- [x] Add 17 app regression tests for preview focus, preview/real separation,
  canceled requests, source-failure semantics and the four Apple assurance levels.
- [x] Add a separate scanner regression that deliberately expires the production
  traversal deadline, then verifies recovery of all 300 changed source files.
- [x] Final local targeted suite: 39 tests passed, including the 18 new regressions.
- [x] Scanner recheck: the three initially failing load fixtures and three existing
  deadline/fairness tests passed, six tests total with no weakened assertions.
- [x] Policy suites: 71 Python tests passed across background continuity, updates,
  reviewed site submission, release publication and presigned-release preparation.
- [x] Source/privacy audit and six installer/signing/CLI safety scripts passed.
- [x] Native synthetic rendering passed: 28 analytics PNGs, light/dark, 640/1000
  points, covering 1/7/28 days, empty history and sparse observations.
- [x] Representative CI renders inspected visually: 1-day wide/light, 7-day
  narrow/dark, 28-day wide/dark, empty narrow/light and sparse narrow/dark.
  These are native fixture renders, not live user-interaction results.
- [x] CI at app-fix commit `ccab86a`: complete macOS quality gate succeeded,
  including the full native suite, permission relaunch isolation, 57 isolated
  native journey renders, timezone checks, bundle validation and package smoke
  tests. History sharing acceptance and native brand motion also succeeded.
- [x] Application changes committed and pushed in draft PR #36. The subsequent
  commit adds only validated test fixtures and this evidence record; application
  code is unchanged from the successful CI commit. Its own CI status is tracked
  on the PR rather than presumed from the previous run.
- [ ] Review the updated application interactively on the Mac. The UI-control
  connector reports a Codex signature-verification failure; CI image retrieval
  enabled static visual review, not access to the running application's controls.
- [ ] Validate the stable-signing-identity distribution and approved installation
  path on the actual Mac. A successful CI test package is not this live install.
- [ ] Exercise the installed build's restart and live interactions. Do not report
  fixtures as live private-data transmission or successful Apple Settings parity.

The installed application remains 0.6.34 and has not been replaced. Original source
folders, recorded history, consent and background recording were not changed.

## Initial full-suite finding and resolution

The first local full run completed 1,140 tests, with 21 skips and eight failed
assertions in three pre-existing load fixtures. The result remains in the record:

- `testMultiFolderCycleSharesOneBodyBudgetAndOneAtomicIndexWrite`: 200 reads
  rather than exactly 256 when the independent deadline expired on the busy host.
- `testTenThousandSourcesUseOneCommitAndBoundedWarmPollingWithoutLostChanges`:
  extra traversal visits and 99/100 changes found within the exact one-pass quota.
- `testFiveHundredTwelveRootsAdvanceInBoundedThirtyTwoRootCycles`: one cycle
  reached the time boundary before its exact 32-root quota.

All three fixtures assert cardinality/cursor contracts but originally used real
monotonic time. They now use existing injected clocks with production limits and
all strict assertions unchanged. The selected-day body budget is also preserved
in the 10,000-source fixture. None of the production scanner implementation or its
security, memory, byte, cancellation and wall-time limits was changed.

The corrected three cases passed locally alongside three independent deadline
and fairness tests (six tests, 595.608 seconds). The 10,000-source replay recovered
all 100 modified sources. The additional forced warm-deadline regression passed
and verified that all 300 changed sources were eventually recovered without a
new full discovery, missing IDs or unavailable-source states. Together with the
38 app tests, the final targeted run passed 39 tests in 20.499 seconds.

This is a successful full CI run plus targeted local revalidation, not a claim
that the first failing local log was retroactively green. The real-private-Codex
benchmark remains opt-in and was not enabled.

## Evidence locations

The goal is tracked in PR #36, `fix/end-to-end-quality-20260922`.
Successful CI for `ccab86a`: macOS quality run `35749432668`, sharing run
`35749432620`, native brand run `35749432642`. Analytics artifact `10704965620`
and native journey artifact `10704796341` contain synthetic data only.

Local analytics snapshots are below `dist/quality-evidence-20260922/analytics/`
and excluded from Git. Native command logs remain under `/tmp/`:
`goalong-quality-full-20260922.log`, `goalong-quality-focused-20260922.log`,
`goalong-quality-scanner-regression-20260922.log`,
`goalong-quality-final-targeted-20260922.log` and
`goalong-quality-render-20260922.log`.

Do not publish personal histories, conversation screenshots, credential material
or application-support data as evidence.

## Reproduction commands

```sh
xcrun swift test --jobs 4 --filter \
  'GoalongAnalyticsLoadRequestTests|AgentConversationSourceHealthTests|GoalongScreenTimeSourcePresentationTests|GoalongActivityTests|GoalongAnalyticsPreviewTests'
xcrun swift test --jobs 4
bash scripts/verify_source_security.sh
GOALONG_ANALYTICS_SNAPSHOTS="$PWD/dist/quality-evidence-20260922/analytics" \
  xcrun swift test --skip-build --filter GoalongAnalyticsRenderingTests
```

## Live-test boundaries

Do not disable macOS protections, grant new optional access, reset consent,
rewrite recorded history or upload private observations merely to complete the
checklist. Existing fixture-based sharing tests may validate protocol handling
without sending personal data. Preserve ongoing recording until a deliberate,
validated installation/restart step is reached.
