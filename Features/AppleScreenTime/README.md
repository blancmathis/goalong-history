# Apple Screen Time feature

This feature is intentionally isolated from Goalong History's foreground recorder. The **Apple Screen Time** page must never silently substitute Goalong-recorded activity for Apple data.

## Runtime architecture

```text
Features/AppleScreenTime/
├── Sources/
│   ├── Models.swift              # versioned device/scope/share schema
│   ├── Analyzer.swift            # aggregation and selective sharing
│   ├── Store.swift               # private Goalong configuration/export storage
│   ├── NativeCollector.swift     # public DeviceActivity API adapter for an eligible companion
│   └── AppleBiomeFormat.swift    # dependency-free SEGB + AppUsage/App.InFocus decoder
└── Tests/
    ├── AppleScreenTimeTests.swift
    └── AppleBiomeFormatTests.swift

Features/AppleSystemScreenTime/Sources/
├── AppleSystemScreenTimeSource.swift    # shared read-only Apple aggregate + knowledgeC + Biome collector
├── AppleScreenTimeDeviceNormalizer.swift

Sources/LocalHistoryApp/AppleScreenTime/
├── AppleScreenTimeDashboardModel.swift
└── ScreenTimePage.swift
```

## Automatic macOS source

The Mac app reads Apple-generated data that already exists on the user's Mac without opening, activating or controlling System Settings:

- `ScreenTimeAgent`'s `RMAdminStore-Local.sqlite` and `RMAdminStore-Cloud.sqlite`
  - Apple's private per-device usage blocks, screen-on totals, applications and websites;
  - queried in place and read-only when macOS makes its protected Data Vault available.

- `~/Library/Biome/streams/restricted/ScreenTime.AppUsage/local/`
  - Apple's local application-usage transitions for this Mac;
  - bundle and parent-bundle identifiers, which preserve attribution for helper processes.
- `~/Library/Application Support/Knowledge/knowledgeC.db`
  - `/app/usage` intervals;
  - bundle identifier, start/end time and Apple device metadata where available.
- `~/Library/Biome/streams/restricted/App.InFocus/local/`
  - Apple's local App.InFocus transition stream.
- `~/Library/Biome/streams/restricted/App.InFocus/remote/<device-id>/`
  - iPhone/iPad/other-device transitions synchronized by Apple through iCloud when **Screen Time → Share Across Devices** is enabled.
- `~/Library/Biome/sync/sync.db`
  - Apple device identifiers and hardware model metadata.

All SQLite connections are `SQLITE_OPEN_READONLY`. The feature never writes to, migrates or repairs Apple stores. Biome files are parsed from read-only `Data` mappings and cached by file size/mtime so the dashboard can refresh frequently without rescanning unchanged files.

## Permissions and freshness

Apple protects these locations with TCC, so the signed Goalong History app needs **Full Disk Access** for the Screen Time feature. Accessibility is not used by Screen Time; it remains a separate, optional permission for Computer History.

The visible page refreshes every 30 seconds, and the refresh button still re-reads immediately. This avoids repeatedly enumerating Apple stores while keeping the UI current; iPhone/iPad freshness is controlled by Apple's iCloud/Biome synchronization. “Real time” therefore means automatic and continuously re-read as Apple syncs—not a guaranteed zero-latency push channel.

## Device-scope semantics

- `macOnly`: this physical Mac only (the UI labels it **This Mac**);
- `allDevices`: every Apple device whose system rows/streams are present on this Mac;
- `selectedDevices`: exact stable device identifiers selected by the user.

`.allDevices` includes every readable Apple device report. Partial selections sum only the selected per-device reports; concurrent use across selected devices is intentionally not deduplicated. Because Apple does not publish the private grouping and suppression contract used by System Settings, these background-only values are never labelled as certified UI parity.

## Source precedence and deduplication

For this Mac, a healthy `ScreenTime.AppUsage` stream is used alone because it carries Apple's application attribution, including the parent application of helper processes. `knowledgeC` and local `App.InFocus` are fallbacks only when that stream is missing or partial; they do not refill its gaps, which would otherwise reintroduce omitted applications and inflate totals. For synchronized iPhone, iPad and other-device data, `knowledgeC` remains preferred and `App.InFocus` fills uncovered periods. Interval subtraction prevents the same physical period from being counted twice across fallback sources, while different applications reported concurrently by the preferred source remain visible and the screen-on total is still counted once.

These readable stores are Apple-generated, but they are not always the same private DeviceActivity rollup rendered by Settings. On macOS versions that vault that summary beyond Full Disk Access, Goalong reports the best available reconstruction and says so explicitly instead of claiming exact Settings parity.

The current Mac is identified from the local Biome stream and from knowledgeC Mac rows that do not correspond to an iCloud remote device. Remote devices are keyed by Apple's Biome device identifier. Hardware IDs such as `iPhone14,5` and `iPad13,18` are used when present; otherwise the UI keeps a generic device label rather than guessing.

## Private-format boundary

knowledgeC and Biome are Apple system data, but they are **not a public macOS Screen Time SDK**. Apple may change or vault these stores in a future release. Parse failures are isolated per file/device, surfaced as partial availability and covered by fixtures for SEGB v1/v2 plus both AppUsage and App.InFocus transition stitching.

This is separate from Apple's public `DeviceActivityData.activityData(filteredBy:using:)` route for an eligible iOS/iPadOS 26.4+ companion. `NativeCollector.swift` keeps the cross-platform collector contract, while the API-specific implementation is compile-gated until Goalong can validate it against a version-matched SDK and an approved managed entitlement. The current Mac app does not claim that private-store reads are the public API or certified Settings parity.

## Trust statement

A share produced from this source says that Goalong History read these values from Apple-owned local system stores. Apple does not provide a third-party cryptographic signature over the private files, so the claim is not equivalent to App Attest or Goalong's live minute seals. It is nevertheless distinct from—and must never be confused with—an estimate produced from Goalong History's recorder.
