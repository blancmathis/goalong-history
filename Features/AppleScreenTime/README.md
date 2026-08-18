# Apple Screen Time feature

This folder is intentionally isolated from the foreground-activity recorder. It can evolve with Apple's Screen Time APIs without changing event capture, sealing, or the existing macOS permission boundary.

## What is included

```text
Features/AppleScreenTime/
├── Sources/
│   ├── Models.swift          # stable JSON schema and explicit device scope
│   ├── Analyzer.swift        # per-device/day aggregation and selective sharing
│   ├── Store.swift           # private local imports and configuration
│   └── NativeCollector.swift # conditional official DeviceActivity collector
└── Tests/
    └── AppleScreenTimeTests.swift
```

The macOS dashboard integration lives in `Sources/LocalHistoryApp/AppleScreenTime/` and only depends on this module.

## Device-scope semantics

Every analysis and share payload contains one of these scopes:

- `allDevices`: every physical device returned by Apple;
- `macOnly`: only reports whose Apple device model is `Mac`;
- `selectedDevices`: only explicit physical-device identifiers derived from Apple's device name and model.

The displayed total is deliberately named **summed screen-on time**. It is the sum of each included device's `totalActivityDuration`; simultaneous use on two devices is not deduplicated.

## Official Apple collection requirements

The native adapter uses Apple's public `DeviceActivityData.activityData(filteredBy:using:)` API. Customer use requires:

- an eligible device in the European Union signed into an Apple Account with an EU country or region;
- `AuthorizationStatus.approvedWithDataAccess`;
- the managed `Family Controls App and Website Usage` entitlement (`com.apple.developer.family-controls.app-and-website-usage`);
- an Apple platform/SDK that exposes the 2026 data-export API.

The adapter is conditionally compiled for iOS 26 or later. The Mac app imports the resulting JSON envelope and never reads Apple's private Screen Time databases.

Official references:

- [DeviceActivityData.activityData](https://developer.apple.com/documentation/deviceactivity/deviceactivitydata/activitydata%28filteredby%3Ausing%3A%29)
- [Family Controls App and Website Usage entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.family-controls.app-and-website-usage)
- [Requesting the Family Controls entitlement](https://developer.apple.com/documentation/familycontrols/requesting-the-family-controls-entitlement)

## Trust boundary

A plain JSON import is marked `unsigned`. A payload containing a companion signature is marked `signaturePresentUnverified` until LocalHistory verifies it against a pinned official collector key. The UI and share export never silently promote imported data to the same trust tier as LocalHistory's live minute seals.

To reach `verifiedOfficialCollector`, add a canonical signing format to the companion, pin the official public-key chain in the Mac app, and pass only successfully verified envelopes to `AppleScreenTimeStore.importEnvelope(_:verification:)` with `.verifiedOfficialCollector`.

## Updating the feature

The reusable module has no dependency on `LocalHistoryCore` or the macOS UI. Run its tests with:

```bash
swift test --filter AppleScreenTimeTests
```

When Apple changes the API, most updates should remain confined to `NativeCollector.swift` and this README. The schema is versioned independently through `AppleScreenTimeExportEnvelope.schemaVersion`.
