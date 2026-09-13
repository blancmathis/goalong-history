---
version: 1
slug: "sources-localhistoryapp-settingspage-swift"
primary_target: "Sources/LocalHistoryApp/SettingsPage.swift"
related_targets: ["Sources/LocalHistoryApp/DashboardRootView.swift","Sources/LocalHistoryApp/DashboardComponents.swift","Sources/LocalHistoryApp/OverviewPage.swift","Sources/LocalHistoryApp/UnifiedHistoryPage.swift"]
---

<!--
THESIS: Make existing settings readable and quickly scannable, preserving all capabilities.
OWN-WORLD: Dark Apple / Codex native macOS surfaces, San Francisco, restrained blue, subtle neutral separators and visible interaction states.
STORY: Find a setting, understand its consequence, change it deliberately, return reliably.
FIRST VIEWPORT: Existing three-item sidebar; Settings heading; bounded main column with capability switches aligned right, account connection, and five destination rows. Comfortable type and whitespace.
FORM: User-pinned native macOS direction; no randomized seed. Operate mode.
-->

Scope: Goalong macOS dashboard shell and shared visual components, with Settings as the first design probe. Extend the same hierarchy to Today, History and all five settings destinations.

Preserve all content, privacy disclosures, routes, save behavior and runtime logic. Current app screenshots and SwiftUI sources establish factual content. The native preview uses isolated test storage without capture or source discovery. Rejected generated images are not visual authority.

The user rejected the initial generated light and dark probes. The implementation uses actual SwiftUI controls and preserves existing account actions.

User endorsed the organization/UX and rejected the generated visual styling. Source implementation now carries the same organization with restrained native proportions, whole-row feedback, aligned toggles and shared adaptive surfaces.

Validation: LocalHistory builds; the existing 18 public-control parity tests pass after updating the previous inline-back-button assertion for the shared bar. Independent source review found no routing/binding/save/account-action regression; typography and refresh accessibility-label findings have been corrected.

Native QA: inspected dark rendering at 1080 × 680 and 1240 × 860 and light Settings at 1080 × 680. Exercised all three main routes, all five Settings destinations, scrolling with fixed Back, Command-[ from the Advanced editor, copy success, edit/discard and persisted save/restore in isolated JSON. Independent visual review inspected the exported native Settings render.

Unverified: physical pointer hit testing and hover/pressed rendering, Tab focus traversal, populated live history and connected-account states. Installed Goalong has not been restarted or replaced.
