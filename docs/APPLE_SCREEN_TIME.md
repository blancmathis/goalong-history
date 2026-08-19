# Apple Screen Time in LocalHistory

## What the page now represents

The **Apple Screen Time** page reads Apple's own local and iCloud-synchronized usage data. It does not calculate a replacement Screen Time number from LocalHistory events.

The runtime combines two Apple sources:

1. **knowledgeC `/app/usage`** for Apple-created application usage intervals;
2. **Biome `App.InFocus`** for local and remote device focus transitions synchronized through iCloud.

The source code is isolated under `Sources/LocalHistoryApp/AppleScreenTime/` and the SEGB/protobuf decoder lives in the independent `AppleScreenTime` module.

## One-time setup

1. Turn on **System Settings → Screen Time**.
2. Turn on **Share Across Devices** on the Mac, iPhone and iPad using the same Apple Account.
3. Grant the signed **LocalHistory.app** Full Disk Access under **Privacy & Security → Full Disk Access**.
4. Reopen LocalHistory if macOS does not apply the TCC grant immediately.

No daily export, manual file selection, companion snapshot or Goalong server is required for the data already synchronized to the Mac.

## Automatic updates

The dashboard checks the Apple stores every five seconds while viewing today. Unchanged Biome files are served from an in-memory fingerprint cache; only newly created or modified SEGB files are decoded again.

The Mac-side refresh cadence is deterministic. Cross-device latency is not: Apple controls when iCloud/Biome delivers iPhone and iPad transitions. The page displays the latest Apple file/event update so a user can distinguish a live Mac refresh from a stale remote sync.

## Per-device selection

The page supports:

- **This Mac** — only the current physical Mac;
- **All devices** — every Apple device synchronized to the Mac;
- **Selected devices** — exact device IDs chosen individually.

Each shared JSON file carries the selected scope, included device count, aggregation method, provenance and optional per-application rows.

## How application time is reconstructed

knowledgeC rows already contain start/end application intervals. Biome stores protobuf transition events:

- field 3: gained/lost foreground state;
- field 4: CFAbsoluteTime timestamp;
- field 6: bundle identifier.

The native decoder supports Apple SEGB v1 and v2 containers. A foreground gain opens an interval; a matching loss or a different app gaining focus closes it. A currently open interval is extended to “now” only when Apple's latest event is recent, preventing a stale iCloud stream from inventing hours of usage.

knowledgeC has precedence. Biome contributes only uncovered fragments, so data present in both stores is not double-counted.

## Privacy and security

- Apple databases are opened read-only with SQLite.
- Apple files are never modified, vacuumed, migrated or copied into Goalong storage.
- LocalHistory stores only its scope/share configuration and explicit share exports.
- Full Disk Access is required because Apple protects knowledgeC and Biome with TCC.
- The private formats can change after an OS update; failures remain isolated to this optional feature.

The defensible source claim is:

> LocalHistory read these usage intervals from Apple-owned Screen Time/usage stores present on this Mac, including Apple-synchronized remote-device streams where available.

It is not a cryptographic attestation from Apple and it is not proof of attention or productive work.

## Public Apple API path

`NativeCollector.swift` still contains the official `DeviceActivityData.activityData(filteredBy:using:)` adapter for an eligible Apple-platform companion. Apple's public data-export route requires enhanced authorization, a managed entitlement and current regional/platform eligibility. It can later provide a supported alternative to the private macOS stores, but it is no longer required for the normal automatic Mac experience.
