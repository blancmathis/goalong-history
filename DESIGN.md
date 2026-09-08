---
name: Goalong History
description: Native macOS workspace with restrained dark surfaces and readable activity data.
colors:
  accent: "rgb(20% 48% 96%)"
  sidebar-dark: "rgb(10% 10% 10%)"
  page-dark: "rgb(12.5% 12.5% 12.5%)"
  card-dark: "rgb(14.5% 14.5% 14.5%)"
  sidebar-light: "rgb(96% 96% 96%)"
  page-light: "rgb(98.5% 98.5% 98.5%)"
  card-light: "#ffffff"
typography:
  headline:
    fontFamily: "system-ui"
    fontSize: "24px"
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
  navigation: "7px"
  group: "12px"
spacing:
  section: "24px"
  page-inset: "28px"
components:
  navigation:
    rounded: "{rounded.navigation}"
    typography: "{typography.label}"
    height: "34px"
  group:
    rounded: "{rounded.group}"
    padding: "18px"
    backgroundColor: "{colors.card-dark}"
---

<!-- IMPLEMENTED AND INSPECTED in an isolated native preview: user approved the revised organization while rejecting generated visual styling. The installed app has not been replaced. AppKit lengths are points; portable tokens above use px to express the same logical numeric values. -->

# Goalong History design system

## Overview

A working dark macOS workspace, with the native interaction detail of Apple and Codex. The generated appearances were rejected; native source is the visual authority. The user endorsed the organization and clear interaction affordances. Keep the existing Today, History and Settings navigation and all current capabilities. Improve legibility, alignment and hierarchy without hiding useful information. Familiar macOS controls and precise state feedback take priority over decoration.

## Colors

Design and validate the primary composition in dark mode: matte charcoal sidebar, slightly lighter content and controls, subtle neutral separators, high-contrast primary text and readable secondary labels. Retain adaptive native surfaces for light appearance during implementation. Keep the existing recognizable blue accent for actions and selection. Green, amber and red communicate actual states alongside a label or symbol. Do not use color as the only state cue. LHTheme in DashboardComponents.swift owns these adaptive surfaces; labels retain macOS semantic text colors. Dark and light Settings rendering was visually inspected; formal contrast measurements remain unperformed.

## Typography

Use the macOS system family (San Francisco), standard rather than rounded for general UI. Establish a compact hierarchy: page title, section heading, row label, body and metadata. Raise the current 9–10 point explanatory copy to a comfortable reading size. Reserve monospaced typography for commands and identifiers, and tabular digits for metrics. The headline, title, body and label roles use the frontmatter scale. Dense metadata is 11 points; compact chart-specific labels may remain smaller. Native rendering was inspected at 1080 × 680 and 1240 × 860.

## Layout

Retain the sidebar and current routes. The sidebar is 208 points; prose-heavy Settings and Privacy content is bounded at 920 points. The root minimum size remains 1080 × 680. PageHeader moves actions below its heading when a horizontal arrangement cannot fit. Bound prose-heavy settings content so controls do not span the whole display. Align labels and descriptions on the left and switches on a consistent trailing edge. Group related settings in continuous lists with subtle separators. Keep history and tables spacious enough for actual data. Preserve visible back navigation on every Settings subpage, including while scrolling.

## Elevation & Depth

Use tonal separation and subtle borders. Avoid decorative shadows, gradients, and nested card stacks. Overlays retain native macOS presentation and focus behavior.

## Shapes

Use restrained continuous corners on grouped surfaces and system control shapes. Preserve the Goalong mark. Neutral icons identify destinations without repeated colored tiles.

## Components

Keep native buttons, switches, date pickers and segmented controls. Primary actions remain clear; secondary actions stay quiet but visible. Navigation rows have whole-row targets, visibly distinct hover and pressed feedback, keyboard focus and accessible names. Back navigation, selection, switches and copy feedback must be exercised in the actual built app; a screenshot cannot validate interaction. Preserve the account Refresh and Disconnect controls; do not replace them with a new Manage route. Preserve save behavior, permissions, confirmations, data access and background processing. Hover uses a 120 ms ease-out transition, disabled with Reduce Motion. The shared navigation style uses primary-color opacity 4.5% on hover, 8.5% when selected, and 12% while pressed; the focus stroke uses the accent. Accessibility-target activation, selection and return navigation were exercised. Pointer hover/pressed states and Tab focus remain unverified under the current automation and macOS keyboard-navigation settings.

## Do's and Don'ts

- Keep all three primary destinations and all Settings subpages.
- Make explanatory text readable and keep essential information visible.
- Verify light/dark appearance and minimum/large window sizes.
- Distinguish missing data, disabled permissions and actual zero values.
- Do not add decorative imagery, promotional copy or new configuration.
- Do not imply that mockups or source builds update the installed app.

## Verification evidence

The app builds and all 18 ComputerHistoryPublicControlParityTests pass. Native preview QA covered the three main routes, all five Settings destinations, Back while scrolling, Command-[ from an editor, CLI copy feedback, edit/discard, and save with isolated JSON persistence (retention changed from 30 to 31 and restored to 30). Dark rendering was inspected across these pages at minimum and comfortable sizes; light Settings was inspected at minimum size. An independent source review found no routing/binding/save/account regression, and a separate visual review inspected the exported native Settings render.

The preview uses isolated test storage and does not run capture or source discovery. Connected-account states, populated live history, physical pointer targeting and full keyboard focus traversal are outside this verification. Installed Goalong History has not been restarted or replaced.

## Today and History refinement

The accepted Settings design remains unchanged. Today and History share a stable day-navigation header. Today presents distinct source totals and local timeline before app usage; absent local observations are labelled rather than rendered as zero. History keeps its native three-source selector, local timeline search, chronological order and expandable details. The timeline total explicitly describes the whole day when results are filtered. Source-management controls use disclosures while unavailable-source errors stay visible. See the Overview surface brief for scoped runtime evidence and remaining verification limits.
