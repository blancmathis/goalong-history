# Screen Time provenance and Activity presentation

## Boundaries

The Apple Screen Time page now accepts only the selected Apple summary. It no
longer distributes Apple browser duration among websites observed by Goalong,
substitutes Goalong usage when Apple is unavailable, or labels a local refresh
as a new Apple event. Applications and Apple-reported websites have separate
filters: website duration may already be included in its browser, so the two
lists must not be added to manufacture a total.

Reconstructed data is explicitly labelled “Durée reconstituée”, not an official
Settings total. Optional protected Apple stores can remain unavailable. This
change does not bypass macOS permissions, alter Apple settings, or promise
Settings parity. A user-invoked Settings button opens the normal comparison UI.
One concise source notice replaces the duplicate warnings; raw diagnostics are
still available in the source disclosure. Missing, archived, loading and stale
fallback states remain distinct.

Selecting a different day or device scope synchronously invalidates the old
summary, so it cannot be displayed or exported under the new selection. An
in-flight request is discarded by the existing day/scope guards, which then
request the latest selection. Completed days still use the compact local
archive, not fresh Apple history reads.

## Activity

The primary metrics now show measured foreground duration, application count
and the longest continuous sequence. Work classification and the configurable
focus threshold remain in the rhythm detail disclosure, with their limitations.
The default hourly chart centers on observed hours; the whole calendar day is
one toggle away. Cropping changes only the viewport, never duration calculations.
Calendar-based boundaries preserve daylight-saving days and sparse observations.

The full-width usage ranking has native locally resolved app icons, local-only
website marks, query/clear, duration/name sorting, expandable long lists,
consistent whole-period percentages and bars, keyboard buttons and VoiceOver
labels. The detail sheet uses the same identity and icon. Website and browser
views still partition exactly the same foreground intervals. No favicon service
receives browsing history; no agent is launched by browsing the page.

## Regression coverage

`GoalongAppleUsagePresentationTests` covers source-only rows, missing source,
browser/site overlap, scoped searches, partial-total labels and immediate day /
device invalidation using an injected synthetic provider.
`GoalongActivityPresentationTests` covers native identity preservation, Unicode
names, search, sorting, unchanged durations, sparse and late-night viewports and
23/25-hour DST days. Existing activity grouping, preview, history, privacy and
update tests remain required. Native snapshot rendering is opt-in through
`GOALONG_ANALYTICS_SNAPSHOTS` and uses synthetic data only.
