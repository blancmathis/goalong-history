---
name: Goalong History
description: Native Goalong workspace: forest surfaces, lime actions and readable activity data.
colors:
  accent: "#d3f35f"
  sidebar-dark: "#0b100d"
  page-dark: "#101712"
  card-dark: "#131b16"
  sidebar-light: "#eae7dc"
  page-light: "#f4f2ea"
  card-light: "#faf9f4"
typography:
  headline:
    fontFamily: "system-ui"
    fontSize: "26px"
    fontWeight: 600
  title:
    fontFamily: "system-ui"
    fontSize: "15px"
    fontWeight: 600
  body:
    fontFamily: "system-ui"
    fontSize: "12px"
    fontWeight: 400
  label:
    fontFamily: "system-ui"
    fontSize: "13px"
    fontWeight: 500
rounded:
  navigation: "8px"
  group: "14px"
spacing:
  section: "24px"
  page-inset: "28px"
components:
  navigation:
    rounded: "{rounded.navigation}"
    typography: "{typography.label}"
    height: "38px"
  group:
    rounded: "{rounded.group}"
    padding: "20px"
    backgroundColor: "{colors.card-dark}"
---

<!-- IMPLEMENTED AND INSPECTED in an isolated native preview: user approved the revised organization while rejecting generated visual styling. The installed app has not been replaced. AppKit lengths are points; portable tokens above use px to express the same logical numeric values. -->

# Goalong History design system

## Overview

A working dark macOS workspace, with the native interaction detail of Apple and Codex. The generated appearances were rejected; native source is the visual authority. The user endorsed the organization and clear interaction affordances. Keep the existing Today, History and Settings navigation and all current capabilities. Improve legibility, alignment and hierarchy without hiding useful information. Familiar macOS controls and precise state feedback take priority over decoration.

## Colors

Use the actual Goalong website as the visual authority: `goalong-website` commit `428fd13`, `styles/landing/shared.css`. Dark surfaces move from forest ink (#0b100d) to green-black content (#101712), cards (#131b16) and raised controls (#1b251e). Lime (#d3f35f) identifies primary actions and selection; it is not a success indicator. Primary button text is dark ink (#18210d), never white on lime. The light appearance translates the site's paper palette, with a darker olive tint for readable links and controls. Preserve separate green, amber, coral and violet semantic colors and visible labels/symbols.

`LHTheme` in `GoalongTheme.swift` owns all shared adaptive tokens, including increased-contrast appearances. Body controls remain native SwiftUI/AppKit. `LHPrimaryButtonStyle` changes presentation without replacing Button actions, roles or keyboard shortcuts. Token contrast is covered by `GoalongBrandThemeTests`; this is not a claim that every native control or text pixel has been measured.

## Typography

Use the macOS system family (San Francisco), standard rather than rounded for general UI. Establish a compact hierarchy: page title, section heading, row label, body and metadata. Raise the current 9–10 point explanatory copy to a comfortable reading size. Reserve monospaced typography for commands and identifiers, and tabular digits for metrics. The headline, title, body and label roles use the frontmatter scale. Dense metadata is 11 points; compact chart-specific labels may remain smaller. The preceding UI pass inspected 1080 × 680 and 1240 × 860. The September brand audit renders 1080 × 680, 1240 × 790 and 1600 × 1000; see its report for the narrower visual-validation limits.

## Layout

Retain the sidebar and current routes. The sidebar is 208 points; prose-heavy Settings and Privacy content is bounded at 920 points. The root minimum size remains 1080 × 680. PageHeader moves actions below its heading when a horizontal arrangement cannot fit. Bound prose-heavy settings content so controls do not span the whole display. Align labels and descriptions on the left and switches on a consistent trailing edge. Group related settings in continuous lists with subtle separators. Keep history and tables spacious enough for actual data. Preserve visible back navigation on every Settings subpage, including while scrolling.

## Elevation & Depth

Use tonal separation and subtle borders. Avoid decorative shadows, gradients, and nested card stacks. Overlays retain native macOS presentation and focus behavior.

## Shapes

Use restrained continuous corners on grouped surfaces and system control shapes. Preserve the Goalong mark. Neutral icons identify destinations without repeated colored tiles.

## Components

Keep native buttons, switches, date pickers and segmented controls. Primary actions remain clear; secondary actions stay quiet but visible. Navigation rows have whole-row targets, visibly distinct hover and pressed feedback, keyboard focus and accessible names. Back navigation, selection, switches and copy feedback must be exercised in the actual built app; a screenshot cannot validate interaction. Preserve the account Refresh and Disconnect controls; do not replace them with a new Manage route. Preserve save behavior, permissions, confirmations, data access and background processing. Hover uses a 120 ms ease-out transition and press feedback 100 ms; both are disabled with Reduce Motion. Shared navigation uses adaptive hover, pressed and selected forest/olive surfaces, a visible 3-point selected marker, and a focus outline. Explicit accessible names identify navigation destinations. Native accessibility activation could not be validated in the September brand audit because the XCTest host did not expose SwiftUI descendants. Rendered views and model transaction checks are separate evidence; neither proves pointer or keyboard behavior.

## Do's and Don'ts

- Keep all three primary destinations and all Settings subpages.
- Make explanatory text readable and keep essential information visible.
- Verify light/dark appearance and minimum/large window sizes.
- Distinguish missing data, disabled permissions and actual zero values.
- Do not add decorative imagery, promotional copy or new configuration.
- Do not imply that mockups or source builds update the installed app.

## Historical verification evidence — preceding UI pass

The app builds and all 18 ComputerHistoryPublicControlParityTests pass. Native preview QA covered the three main routes, all five Settings destinations, Back while scrolling, Command-[ from an editor, CLI copy feedback, edit/discard, and save with isolated JSON persistence (retention changed from 30 to 31 and restored to 30). Dark rendering was inspected across these pages at minimum and comfortable sizes; light Settings was inspected at minimum size. An independent source review found no routing/binding/save/account regression, and a separate visual review inspected the exported native Settings render.

The preview uses isolated test storage and does not run capture or source discovery. Connected-account states, populated live history, physical pointer targeting and full keyboard focus traversal are outside this verification. Installed Goalong History has not been restarted or replaced.

## Today and History refinement

The accepted Settings design remains unchanged. Today and History share a stable day-navigation header. Today presents distinct source totals and local timeline before app usage; absent local observations are labelled rather than rendered as zero. History keeps its native three-source selector, local timeline search, chronological order and expandable details. The timeline total explicitly describes the whole day when results are filtered. Source-management controls use disclosures while unavailable-source errors stay visible. See the Overview surface brief for scoped runtime evidence and remaining verification limits.

## Website brand alignment — September 2026

The new pass preserves the route hierarchy and underlying capture, storage, consent and sharing behavior. It aligns the main window, onboarding, shared cards/actions, day controls and standalone Profile Studio window. Settings prose remains capped at 920 points; the native sidebar remains 208 points. See `docs/BRAND_ALIGNMENT_AUDIT.md` for current verification evidence and its limitations. Historical verification above refers to the previous UI pass, not this build.
