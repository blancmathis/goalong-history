# Goalong History — website brand alignment

## Scope and reference

Based on Goalong History `2d8eac2` and Goalong website `428fd13`.
The authoritative dark palette is `goalong-website/styles/landing/shared.css`;
the paper-based light translation uses `styles/01-site.css`. The existing Goalong
vector mark is retained, not regenerated. San Francisco remains the native
counterpart of the website's Inter/system sans-serif stack.

The accepted Today / History / Settings organization, all History source tabs,
Settings destinations, native date picker, account controls and disclosure
behavior are preserved. This pass does not change recording, permissions,
consent, analysis, transfers, storage, CLI contracts or security boundaries.

## UI changes

- Shared forest/ink surfaces, lime primary actions with dark text, paper/olive
  light mode, and explicit increased-contrast variants in `GoalongTheme.swift`.
- One primary ButtonStyle across the existing actions; Button roles, callbacks,
  disabled states and shortcuts remain at their original call sites.
- The existing mark and a clearer Goalong wordmark in the sidebar and onboarding.
  Full-row navigation has hover/pressed feedback, explicit accessible names,
  selection marker and focus outline. Reduce Motion suppresses transitions.
- Cards use 14-point continuous corners and 20-point default insets. Day arrows
  have 24-point targets; day headers can place actions below the heading.
- Settings prose is capped at 920 points, with existing 28-point page insets.
  Small onboarding explanations and sidebar metadata have been enlarged.
- The main titlebar and standalone Profile Studio receive matching surfaces.
- The distribution icon reuses the exact Goalong mark on a forest tile; installer
  artwork shares the palette. Old unconditional signing/notarization badges are
  replaced with neutral product descriptions, consistent with the ad-hoc build.

Primary lime/ink token contrast is approximately 13.27:1. The light-mode semantic
text colors are chosen to meet 4.5:1 even on the darker paper sidebar. Tests resolve
the actual adaptive NSColors in all four macOS appearances, rather than testing
only a duplicate list of hexadecimal values. These measurements concern theme
tokens, not every rendered native label, chart or system control.

## Reproducible verification

Run `swift test --filter GoalongBrandThemeTests` for palette and contrast tests.
Run `swift test --filter ComputerHistoryPublicControlParityTests` for the existing
public-control contract. `scripts/verify_brand_ui.sh` builds the tests and renders
actual SwiftUI pages into `qa/brand-alignment`.

The native renderer refuses to construct a DashboardViewModel unless Foundation's
home and application-support paths resolve inside a freshly created
`/tmp/goalong-brand-*` home. It does not execute AppDelegate, capture, startup
migration, login-item registration, source discovery or actual transfers. It uses
empty, isolated stores. Save/discard and section selection are tested through the
existing DashboardViewModel methods. Native button activation was attempted but
the XCTest host exposed no SwiftUI accessibility descendants; these checks do
NOT validate physical clicks, focus traversal or button activation.

## Verification results

- Native application and test targets compile successfully on the authorized Mac.
- 58 focused tests passed with zero failures: public-control parity, brand token
  contrast, source activation/consent, private-browsing preferences, overview
  projections, profile and application-menu coverage.
- The opt-in native render test passed: 20 actual SwiftUI renders, model
  save/discard and route assertions, and minimum-size onboarding assertions.
  Native-view rendering uses the real SwiftUI views at minimum, normal and large
  window sizes, in dark and light appearances. See `qa/brand-alignment/README.md`
  for the generated matrix. Stores are empty fixtures, not live user history.
- One bounded fallback text/pixel check on the minimum-size Settings capture
  confirmed forest surfaces and readable untruncated principal descriptions.
  The exported gallery has not received a complete manual visual review.
- Increased-contrast border tokens pass 3:1 checks and actual components read
  SwiftUI's contrast environment. An accessibility appearance render is not proof
  that the system-wide Increase Contrast setting was toggled or fully audited.
- The distribution asset generator passed locally: the app icon is exactly
  1024 × 1024 pixels and the DMG background 1440 × 880, independent of display
  scale. Both vector previews parse successfully. No app was installed.
- Source comparison confirmed 16 additional UI files contain only the primary
  button-style substitution. Core, CLI and source engines have no diff.
- The full-suite attempt is NOT green and was stopped after a scanner-load
  failure in untouched `AgentActivityScannerLoadTests`:
  `testMultiFolderCycleSharesOneBodyBudgetAndOneAtomicIndexWrite` expected 256
  body reads/index entries and observed 200. Baseline reproduction was not done.
  This is not resolved or attributed to a cause by this UI pass.

The installed application is not replaced by either build or rendering. This is
an isolated source change, not an application installation.

## Limits

Native rendering is not a substitute for physical pointer testing, a complete
VoiceOver audit, full keyboard traversal, connected-account state testing or a
real-data performance benchmark. The Mac visual-control connector returned a
client signature error during this pass; it was not repaired or bypassed.
No OS permission, installed application, login item or user history is changed.
