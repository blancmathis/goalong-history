---
version: 1
slug: "sources-localhistoryapp-overviewpage-swift"
primary_target: "Sources/LocalHistoryApp/OverviewPage.swift"
related_targets: ["Sources/LocalHistoryApp/UnifiedHistoryPage.swift", "Sources/LocalHistoryApp/DayNavigationHeader.swift", "Sources/LocalHistoryApp/ComputerHistoryPage.swift"]
---

<!--
THESIS: Read the day quickly, then inspect its evidence without losing date or source context.
OWN-WORLD: Extend the approved native dark Settings language: SF, neutral surfaces, restrained borders, native controls. Settings remain unchanged.
STORY: See coverage and usage, open History, search recorded context, inspect a time window, return to the day.
FIRST VIEWPORT: Stable day header, bounded controls, day summary and activity strip; History has source selection followed by a searchable timeline.
FORM: Operate; refinement of the approved macOS world.
-->

Today keeps source totals separate, distinguishes absent observations from zero, places local coverage before usage, and keeps grouping options in a disclosure. The optional AI report remains below usage with its existing actions and disclosures.

History preserves all three sources and their date synchronization. Computer History filters already-built windows by app or context and supports both chronological orders. Search resets on date change. Whole-day duration is explicitly labelled so a filter cannot be mistaken for a recalculated day total. Details remain expandable, with reduced-motion support. Source errors stay visible; absent-source detail and source-management controls are disclosed without being removed.

Validation: app build and 30 existing public-control and usage-projection tests pass. Native synthetic-data preview exercised Today grouping, Explore History, timeline search (4 of 12 matching windows), order reversal, expansion, and no-results handling. Both Today and Computer History were inspected at 1080 × 680, Today also at 1240 × 860; Today light appearance and scrolled/pinned header were inspected. Independent visual review found no material issue in populated Today and compact History exports. Date navigation, three-source switching and no-results recovery were exercised. The preview also displayed an existing source-runtime error and verified its readable presentation. Connected Apple/AI populated states and physical hover/full keyboard traversal remain unverified. No production capture, permission or installed-app change.

History row refinement: each app icon, name and duration form one compact group (6-point internal gap), with horizontal flow and a wrapping grid fallback. Rows use 14-point vertical padding. Input/event/switch counters remain in expanded details. One status panel replaces duplicate source warnings and includes Retry, explicit retry-failure feedback and selectable technical details. Missing activity never claims retained content. Native QA exercised Retry, repeated-failure feedback, technical disclosure and activity expansion at 1240 × 860 and inspected 1080 × 680. The 25 public-control and UI-refresh tests pass. The preview-only unsafe-path warning was traced to the /tmp alias; its home now uses an isolated real directory in /Users/Shared. Native verification then showed Stored on this Mac with source-data access enabled and the warning gone. No security check was weakened.
