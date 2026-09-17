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

## Actual wiring

`GoalongMotionView.swift` draws native paths using SwiftUI's display timeline.
The dashboard installs `GoalongProgressViewStyle` for indeterminate progress,
including its onboarding branch and website-sharing sheet. Measured progress
continues to use a native linear ProgressView with its actual label and value.
The persistent sidebar mark follows `DashboardViewModel.isRefreshing`; ordinary
recording does not cause an endless branded animation.

Operation state remains authoritative. A result, error or cancellation never
waits for the 300ms visual release. Removing a loading view removes its motion;
the persistent header can relax from the current phase without a jump. Repeated
busy values do not restart a cycle and a new operation can interrupt relaxation.

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

For an isolated real SwiftUI window:

```sh
mkdir -p qa/brand-motion
GOALONG_MOTION_SNAPSHOTS="$PWD/qa/brand-motion" \
  swift test --filter GoalongMotionRenderingTests
```

This opt-in test renders 24/32/48-point marks, compares live activity frames,
checks identical settled and reduced frames, and renders both macOS appearances
and measured versus indefinite progress. It toggles the additive local motion
preference, not the user's system setting. It uses synthetic view state, not a
user's activity history. A screenshot is not a full application usability or
accessibility audit, nor proof that an installed app has been updated.
