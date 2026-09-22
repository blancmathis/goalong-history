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
- [x] Add regression coverage for preview focus, preview/real separation, canceled
  requests, source-failure semantics and all four Apple assurance levels.
- [x] Focused native suite: 38 tests, including 17 new regression cases, passed.
- [x] Policy suites: 71 Python tests passed across background continuity, updates,
  reviewed site submission, release publication and presigned-release preparation.
- [x] Source/privacy audit and six installer/signing/CLI safety scripts passed.
- [x] Native synthetic rendering passed: 28 PNGs, light/dark, 640/1000 points,
  covering 1/7/28 days, empty history, isolated events and sparse observations.
- [ ] Finish the full native suite and recheck the deterministic quota fixture.
- [ ] Inspect the native renders and updated live UI visually. The UI-control
  connector currently reports a Codex signature-verification failure; generating
  PNGs is not being reported as a completed visual review.
- [ ] Review and commit the exact verified source.
- [ ] Validate a signed packaged build and installation through the existing
  stable-identity, explicitly approved update path.
- [ ] Exercise the installed build's restart and live interactions. Do not report
  synthetic tests as live private-data transmission or successful Apple parity.

Logs, synthetic snapshots and per-command exit statuses belong to the local QA
record, not the source repository. Do not publish personal histories, screenshots
of conversations, credential material or application-support data.

## Additional finding during full-suite validation

The initial full native run reported 200 rather than 256 reads in
`testMultiFolderCycleSharesOneBodyBudgetAndOneAtomicIndexWrite`. That fixture
used real monotonic time while asserting an exact cardinality: the independent
production deadline could stop a busy test host after the first folder.
The fixture now uses the scanner's existing injected clocks, with production
limits and every strict assertion unchanged. Deadline/fairness tests remain
separate. No production scanner limit was relaxed. The corrected fixture must
be rerun before this item is considered verified.

The long 10,000-source regression was sampled read-only while running; it was
performing its bounded warm-polling checks, not waiting on a live personal source.
The opt-in real-Codex-source benchmark remains disabled.

Local-only evidence is retained below `dist/quality-evidence-20260922/`; it is
excluded from Git. The initial full-suite failure remains part of the record.

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
