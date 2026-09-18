# Local Analyses: sparse observations and developer preview

## Ordering, not missing data

The recorder can append a buffered typing/scrolling event after a newer foreground
observation. The bounded reader deliberately preserves journal order. Analyses used
to treat any timestamp reversal as a failed source read and replace the entire day
with unobserved time.

`GoalongLocalAnalytics.build` now stably orders its bounded, read-only projection by
observation timestamp. Original journal offsets break ties because older journals
can use second-precision timestamps. It never rewrites the source journal. Actual
source mutation, corrupt JSON, inaccessible files, cancellation, and evidence-budget
failures still cannot publish plausible totals.

There is no minimum observed duration for the charts. A seven-second interval is
measurable; one isolated sample is not an invented minute. Axes adapt to seconds,
minutes, or hours. First traces, true absence, and unreadable sources have separate
presentation states. Idle/private observations remain separate from active time.
Existing gaps, stop/resume boundaries, privacy suppression, and no leading/trailing
extrapolation are unchanged.

## Explicit developer setting

Settings → Advanced → Development → Developer mode uses the local preference
`goalong.developerMode.enabled`, with an absent key meaning **false** in every build.
It grants no capture, network, or system permissions.

When enabled, Analyses exposes “Aperçu avec données fictives”. The preview selection
is view-local, never persisted, and clears when leaving the page or disabling the
setting. Demo date navigation does not modify the selected date of real history.
Returning to real data triggers a real load; an old preview payload is never shown
under the real-data heading while that load is pending.

## Fixture boundary

`GoalongAnalyticsPreview` is a deterministic, calendar-based in-memory factory. It
covers the current and previous 1/7/28-day periods, focus thresholds, applications,
example.org websites, idle/private/unobserved intervals, context changes, and every
project-analysis module. The same calendar date has the same measurements across
period selectors. Full simulated days, including today, are labeled as simulations.

The reader returns fixtures before consulting the source cache, event files, or
saved analysis archives. No source events or analyses are created. A persistent
banner, date note, card labels, and footer distinguish mock data. Send-to-Goalong,
real-history drilldown, and AI-analysis controls are disabled for preview payloads.
The recorder and unrelated authorized background tasks are not stopped or changed.

## Reproducible checks

```sh
xcrun swift test -j 4 --filter 'GoalongLocalAnalyticsTests|GoalongAnalyticsPreviewTests|GoalongAnalyticsFormattingTests'
xcrun swift test -j 4
GOALONG_ANALYTICS_SNAPSHOTS=/absolute/private/path xcrun swift test -j 4 --filter GoalongAnalyticsRenderingTests
```

The native renderer covers full mock days/weeks/months, a missing middle day, an
empty period, a single sample, and nine seconds of out-of-order sparse observations,
in dark/light appearances at 640 and 1000 points. Tests use temporary fixture stores
and isolated preference suites; they do not enable the installed user's developer mode.

An explicitly authorized read-only diagnosis can set `GOALONG_ANALYTICS_PROBE_ROOT`
and run `GoalongLocalAnalyticsTests/testOptInReadOnlyLocalAnalyticsProbe`. It logs
aggregate counts only. Its output and native screenshots are local QA evidence, not
source journals to commit or publish.
