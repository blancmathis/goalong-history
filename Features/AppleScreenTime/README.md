# Screen Time feature

This feature is kept separate from the recorder implementation so its analysis, device aggregation, Apple companion code and UI can evolve independently. The Mac source nevertheless consumes the recorder's existing append-only event stream; it does not duplicate foreground capture or read an undocumented Apple database.

## Layout

```text
Features/AppleScreenTime/
├── Sources/
│   ├── Models.swift          # device scope, reports and share schemas
│   ├── Analyzer.swift        # interval aggregation and selective disclosure
│   ├── Store.swift           # private configuration and companion snapshots
│   └── NativeCollector.swift # conditional official iOS DeviceActivity collector
└── Tests/
    └── AppleScreenTimeTests.swift

Sources/LocalHistoryApp/AppleScreenTime/
├── LiveMacScreenTimeSource.swift       # automatic current-Mac source
├── AppleScreenTimeDashboardModel.swift # live + connected-device fusion
└── ScreenTimePage.swift                # device-aware SwiftUI dashboard
```

## Automatic Mac measurement

`LiveMacScreenTimeSource` tails the current day's JSONL file incrementally. It reconstructs foreground intervals from application transitions and the recorder heartbeat rather than rescanning the complete history on every refresh.

An interval is measurable only while:

- the recorder is running;
- recording is not manually paused;
- the user session is active;
- the display/system is awake;
- a foreground application is known.

Lock, sleep, stop, pause and unavailable-session events close the interval. A normal foreground state must continue receiving heartbeats; an unconfirmed trailing gap is capped. Privacy-suppressed contexts can contribute to the overall device duration while their application identity remains unattributed.

The dashboard refreshes today's calculation every five seconds. This is a presentation refresh rate, not extra activity capture: the underlying recorder remains the single source of Mac events.

## Device scopes

The UI presents the existing schema scopes with product semantics:

- `macOnly` → **This Mac**: only the physical Mac running LocalHistory;
- `allDevices` → **All devices**: this Mac plus every connected companion-device row;
- `selectedDevices` → **Selected devices**: an explicit set of physical device IDs.

The all-device total is the sum of per-device screen-on durations. Concurrent use on two devices is intentionally not deduplicated or described as unique human time.

## Applications

The current Mac receives an exact foreground-application breakdown from LocalHistory events. The conditional iOS collector also walks each DeviceActivity segment's categories and application activities, aggregating `totalActivityDuration` by bundle identifier.

Apple may withhold a localized application name outside specific extensions. With approved data access, the bundle identifier remains the stable identity and is preserved in the report.

## Other Apple devices

Automatic iPhone/iPad and additional-Mac data requires a signed Goalong iOS companion and a transport that delivers its newest snapshot to the Mac. The reusable collector and multi-device fusion are in place; provisioning the companion still requires Apple's managed entitlement and the final sync implementation.

Manual JSON import remains only as a development and compatibility fallback. It is not the intended daily workflow and is never needed for the current Mac.

## Official Apple collection requirements

The companion adapter uses Apple's public `DeviceActivityData.activityData(filteredBy:using:)` API. Customer use requires:

- an eligible device in the European Union signed into an Apple Account with an EU country or region;
- `AuthorizationStatus.approvedWithDataAccess`;
- the managed `Family Controls App and Website Usage` entitlement (`com.apple.developer.family-controls.app-and-website-usage`);
- an Apple platform and SDK that expose the data-export API.

Official references:

- [DeviceActivityData.activityData](https://developer.apple.com/documentation/deviceactivity/deviceactivitydata/activitydata%28filteredby%3Ausing%3A%29)
- [DeviceActivityData.ApplicationActivity](https://developer.apple.com/documentation/deviceactivity/deviceactivitydata/applicationactivity)
- [Family Controls App and Website Usage entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.family-controls.app-and-website-usage)
- [Requesting the Family Controls entitlement](https://developer.apple.com/documentation/familycontrols/requesting-the-family-controls-entitlement)

## Trust boundary

The live Mac calculation is derived from LocalHistory's own event history, but its standalone Screen Time share file is not automatically equivalent to a complete minute-seal proof package. When cryptographic verification matters, share the corresponding LocalHistory evidence as well.

A plain companion JSON is marked `unsigned`. A payload containing a signature is marked `signaturePresentUnverified` until LocalHistory verifies it against a pinned official collector key. Only successfully verified envelopes may be imported with `.verifiedOfficialCollector`.

The defensible claims remain limited: the product can report what the official client observed on each connected device, not prove a person's identity, attention or intellectual effort.

## Updating and testing

The reusable module remains independently versioned through `AppleScreenTimeExportEnvelope.schemaVersion`.

```bash
swift test --filter AppleScreenTimeTests
```

Changes to Mac interval reconstruction should stay in `LiveMacScreenTimeSource.swift`. Changes to Apple's export surface should stay in `NativeCollector.swift`. Device fusion and product behavior belong in the dashboard model rather than in either collector.
