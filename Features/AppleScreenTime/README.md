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
│   └── AppleBiomeFormat.swift    # dependency-free SEGB + App.InFocus decoder
└── Tests/
    ├── AppleScreenTimeTests.swift
    └── AppleBiomeFormatTests.swift

Sources/LocalHistoryApp/AppleScreenTime/
├── AppleSystemScreenTimeSource.swift    # read-only Apple knowledgeC + Biome collector
├── AppleScreenTimeDashboardModel.swift
└── ScreenTimePage.swift
```

## Automatic macOS source

The Mac app reads Apple-generated data that already exists on the user's Mac:

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

Apple protects these locations with TCC. The signed Goalong History app needs **Full Disk Access** once. The UI detects a permission failure and links directly to the relevant System Settings pane.

The page refreshes every five seconds, but iPhone/iPad freshness is controlled by Apple's iCloud/Biome synchronization. “Real time” therefore means automatic and continuously re-read as Apple syncs—not a guaranteed zero-latency push channel.

## Device-scope semantics

- `macOnly`: this physical Mac only (the UI labels it **This Mac**);
- `allDevices`: every Apple device whose system rows/streams are present on this Mac;
- `selectedDevices`: exact stable device identifiers selected by the user.

Totals are sums of per-device usage. Concurrent use of two devices is intentionally not deduplicated.

## Source precedence and deduplication

`knowledgeC` intervals are preferred because they are already materialized Apple usage rows. Biome intervals fill devices or time fragments not covered by knowledgeC. Interval subtraction prevents the same Apple activity from being counted twice when both stores contain it.

The current Mac is identified from the local Biome stream and from knowledgeC Mac rows that do not correspond to an iCloud remote device. Remote devices are keyed by Apple's Biome device identifier. Hardware IDs such as `iPhone14,5` and `iPad13,18` are used when present; otherwise the UI keeps a generic device label rather than guessing.

## Private-format boundary

knowledgeC and Biome are Apple system data, but they are **not a public macOS Screen Time SDK**. Apple may change or vault these stores in a future release. Parse failures are isolated per file/device, surfaced as partial availability and covered by fixtures for SEGB v1/v2 and protobuf transition stitching.

This is separate from Apple's public `DeviceActivityData.activityData(filteredBy:using:)` route. That API remains in `NativeCollector.swift` for an eligible iPhone/iPad companion and requires Apple's managed entitlement and enhanced data authorization. It is not required for the Mac to read the Apple data already synchronized locally.

## Trust statement

A share produced from this source says that Goalong History read these values from Apple-owned local system stores. Apple does not provide a third-party cryptographic signature over the private files, so the claim is not equivalent to App Attest or Goalong's live minute seals. It is nevertheless distinct from—and must never be confused with—an estimate produced from Goalong History's recorder.
