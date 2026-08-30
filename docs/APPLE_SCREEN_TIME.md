# Apple Screen Time in Goalong History

## What the page now represents

The **History → Screen Time** filter reads Apple's own local and iCloud-synchronized usage data. It does not calculate a replacement Screen Time number from Goalong History events.

The runtime combines two Apple sources:

1. **knowledgeC `/app/usage`** for Apple-created application usage intervals;
2. **Biome `App.InFocus`** for local and remote device focus transitions synchronized through iCloud.

The source code is isolated under `Sources/LocalHistoryApp/AppleScreenTime/` and the SEGB/protobuf decoder lives in the independent `AppleScreenTime` module.

## One-time setup

1. Turn on **System Settings → Screen Time**.
2. Turn on **Share Across Devices** on the Mac, iPhone and iPad using the same Apple Account.
3. Grant the signed **Goalong History.app** Full Disk Access under **Privacy & Security → Full Disk Access**.
4. Reopen Goalong History if macOS does not apply the TCC grant immediately.

No daily export, manual file selection, companion snapshot or Goalong server is required for the data already synchronized to the Mac.

## Automatic updates

The dashboard checks the Apple stores every five seconds while viewing today. Unchanged Biome files are served from an in-memory fingerprint cache; only newly created or modified SEGB files are decoded again.

The Mac-side refresh cadence is deterministic. Cross-device latency is not: Apple controls when iCloud/Biome delivers iPhone and iPad transitions. The page displays the latest Apple file/event update so a user can distinguish a live Mac refresh from a stale remote sync.

## Device names and types

Goalong resolves each synchronized peer conservatively, in this order:

1. an exact Apple hardware model carried by knowledgeC or Biome;
2. the typed `BMDevicePlatform` value already carried by Biome (`iPad`, `iPhone`, Mac, Apple TV, Apple Watch, HomePod or Apple Vision Pro);
3. the matching trusted, recently updated friendly name from Apple's local account-device catalogue;
4. a strong watchOS application signature for older Apple Watch rows that lack platform metadata;
5. an explicit generic type plus a stable, shortened peer tag when Apple does not expose enough metadata.

The normalizer preserves exact names such as `iPhone Mathis`, `iPad de Mathis` and `Apple Watch de Mathis`. It never assigns order-dependent labels such as “Apple device 1” or “Apple device 2”. Unknown future platform values remain explicit generic devices instead of being guessed.

## Per-device selection

The page supports:

- **This Mac** — only the current physical Mac;
- **All devices** — every Apple device synchronized to the Mac;
- **Selected devices** — exact device IDs chosen individually.

Each shared JSON file carries the selected scope, included device count, aggregation method, provenance and optional per-application rows.

The **Selected devices** list also keeps trusted, recently updated Apple devices available when they have no usage on the displayed day. Historical or ambiguous Biome peers are not added unless they contributed usage for that day, so an idle iPad remains selectable without reviving old device ghosts.

## How application time is reconstructed

knowledgeC rows already contain start/end application intervals. Biome stores protobuf transition events:

- field 3: gained/lost foreground state;
- field 4: CFAbsoluteTime timestamp;
- field 6: bundle identifier.

The native decoder supports Apple SEGB v1 and v2 containers. A foreground gain opens an interval; a matching loss or a different app gaining focus closes it. A currently open interval is extended to “now” only when Apple's latest event is recent, preventing a stale iCloud stream from inventing hours of usage.

knowledgeC has precedence. Biome contributes only uncovered fragments, so data present in both stores is not double-counted.

Goalong preserves Apple's complete merged report in memory, including explicit operating-system inactivity surfaces. Default summaries then hide those rows and subtract their durations. On Mac this means `com.apple.loginwindow` and Apple's `com.apple.ScreenSaver.*` bundle family; on iPhone, iPad and iPod it means `com.apple.SleepLockScreen`. Keeping those markers through the merge prevents a stale Biome foreground app from refilling a period Apple already identified as locked. The filter uses exact Apple bundle namespaces, not display names or broad “system app” guesses.

The Overview page shows every active-use application by default. Its **Include login and lock-screen time** switch adds Apple-reported login-window, lock-screen, and screen-saver rows and updates the Screen Time total from the same already-read report. The switch does not hide or reveal ordinary apps. This is a presentation choice: it does not re-scan Apple stores and does not create a second stored copy. CLI reports retain the complete per-device rows while their aggregate summary uses the filtered default; daily AI recaps and share summaries also use the filtered default so known lock-screen time does not consume tokens or appear as active use.

This boundary removes known locked and screen-saver periods. It does not claim proof of attention: an unlocked application left visible while someone walks away cannot be distinguished safely from legitimate passive use such as reading, video or a call, especially across remote Apple devices. Goalong therefore does not impose an arbitrary idle timeout.

## Privacy and security

- Apple databases are opened read-only with SQLite.
- Device-name enrichment reads only the account catalogue fields `name`, `model`, `os`, `trusted` and `last_updated_date`; serial numbers, account identifiers and service metadata are never selected.
- Apple files are never modified, vacuumed, migrated or copied into Goalong storage.
- Goalong History stores only its scope/share configuration and explicit share exports.
- The small device-name catalogue is cached only in memory and re-read only when its SQLite file or write-ahead log fingerprint changes.
- Full Disk Access is required because Apple protects knowledgeC and Biome with TCC.
- The private formats can change after an OS update; failures remain isolated to this optional feature.

The defensible source claim is:

> Goalong History read these usage intervals from Apple-owned Screen Time/usage stores present on this Mac, including Apple-synchronized remote-device streams where available.

It is not a cryptographic attestation from Apple and it is not proof of attention or productive work.

## Public Apple API path

`NativeCollector.swift` still contains the official `DeviceActivityData.activityData(filteredBy:using:)` adapter for an eligible Apple-platform companion. Apple's public data-export route requires enhanced authorization, a managed entitlement and current regional/platform eligibility. It can later provide a supported alternative to the private macOS stores, but it is no longer required for the normal automatic Mac experience.
