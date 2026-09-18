# Goalong / Passage — native integration

## Reference and scope

The source is the approved `Goalong_Demonstrateur.html` first script,
SHA-256 `701f2deb041757f60f3ab336f0c2ab316034d7a56a6bcba0b56882a9f9f31866`.
`GoalongMotionModel.swift` is its Foundation-only mathematical port. The native
Bezier anchors, handles, deformation field, 2.4-second cycle and 300ms entry/release
are preserved. The G arm follows the same field as the contour. It is not a pair
of independent spinning rings or a video embedded in a web view.

This integrates entry, indefinite activity, phase-dependent release and exact
rest. The separate approved hero video and presentation-only placement masters
are not available in this repository, are not approximated, and are not replaced
by a new splash screen. The existing onboarding and menu bar identity remain.

## Actual wiring — selective placements, 18 September 2026

There is no dashboard-wide or sheet-wide branded ProgressViewStyle. The sidebar
uses its original static GoalongMark. Today, toolbar refresh controls, account
flows, settings, sheets and secondary progress indicators use their native UI.

Full-page waiting states use GoalongPageLoadingView. Its logo and label are
centered like Analytics. SourceAccessGate uses it while resolving access before
any History page is mounted (Ce Mac, Apple Screen Time and Conversations). The
same component is used for the Analytics and compact day-analysis page waits.
An immediately available page has no forced transition or loading duration.
A ready page stays visible during passive access revalidation; disabled sources
remain disabled and missing access still presents its normal recovery UI.

The page component opts in at its leaf only. The existing day-data status remains
explicit and separate:

- History: one mark in the day-status card, continuously through preparation and
  source verification. ComputerHistoryDayLoadingPhase combines timeline/snapshot
  preparation, model loading and sourceStatus == .checking. A retained-memory
  cache hit can still be verifying after isLoading becomes false. The same mark
  stays mounted across these phases; the timeline does not add another spinner.
- Analytics: the existing central waiting state while the first payload is being
  read. Its position, size, copy and real loading lifetime are retained. The
  upper-right refresh button remains native, not a second animated logo. An
  already available payload is not hidden just to show an animation.

Operation state remains authoritative. There is no extra minimum waiting time,
repeated splash, click-to-replay behaviour or decorative delay. Errors and absent
sources end the logo's activity and retain their own native symbol and message.
The equations, cycle and interrupted-release behaviour are unchanged.

## Accessibility and resource use

The read-only system `accessibilityReduceMotion` preference is always respected.
An additive `goalongReduceMotion` environment value can reduce motion further,
but never disables the system preference. Status text and measured progress stay
available. Brand shapes are decorative; an otherwise unlabelled ProgressView
retains an accessible loading label.

The timeline is paused when the view is unmounted, at rest, when movement is
reduced, or when its owning window is hidden, minimized or occluded. A small
view-bound AppKit probe observes that window only and removes its observers when
detached. No agent, service, dependency, media decoder or continuous recording
indicator is added. Collection, permissions, updater, release signing, network
access and storage are unchanged.

## Verification

`swift test` covers independent numeric reference samples, a 21.6-second sequence,
cycle continuity, the G attachment and interruption/reentry across thirteen phases.

For an isolated real SwiftUI window under a running AppKit event loop:

```sh
./scripts/test_brand_motion.sh "$PWD/qa/brand-motion"
```

The probe compiles the production theme, model and view directly; it does not
load the main application, read user history or create app services. It renders 24/32/48-point marks, compares live activity frames,
checks identical settled and reduced frames, and renders both macOS appearances
and measured versus indefinite progress. It toggles the additive local motion
preference, not the user's system setting. It uses synthetic view state, not a
user's activity history. A screenshot is not a full application usability or
accessibility audit, nor proof that an installed app has been updated.

The rendering probe uses `NSApplication.run()` rather than substituting the
XCTest event loop for AppKit. Pixel comparisons use booleans and SHA-256 reports,
so a failure never expands a full raw bitmap into CI logs.

CI runs the probe with both OS reduced-motion settings on a disposable hosted
Mac, verifies the observed system preference in each report and restores the
runner's original preference. The local script and application never modify
the user's preference. A locally reduced system is tested as stationary, not
incorrectly expected to animate.

Placement tests cover the actual access-gate branch, immediate and deferred
completion, usable-page revalidation, disabled sources and errors. The native
AppKit probe renders the shared page placeholder in light/dark and reduced
motion, counts one real motion view while loading and zero when ready. It uses
synthetic page state and never runs a real permission check or reads history.
The sidebar/toolbar and data-verification placement regressions are retained.
