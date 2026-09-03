# Apple Screen Time in Goalong History

## What the page now represents

The **History → Screen Time** filter reads Apple-owned local and iCloud-synchronized usage data. It never calculates a replacement Screen Time number from Goalong History events and never adds Computer History observations to Apple totals.

The preferred source is the presentation already rendered by **System Settings → Screen Time → App & Website Activity**. On demand, Goalong uses the macOS Accessibility API to read Apple's visible All Devices total, every listed physical device, and the visible application or website rows for the requested day. It navigates the existing Apple controls, reads values in memory, restores the previous foreground app, and stores neither screenshots nor an Apple-usage snapshot. This is exact parity with the values Apple visibly presents at that instant and rounding level; it is not an undocumented database claim or an Apple attestation.

The bounded visible reader supports today and the previous 35 days. Today's result is cached in process memory for two minutes and a past day for ten minutes, with at most eight cached days. The cache disappears when Goalong exits. Reading a fresh value can briefly bring System Settings to the foreground because Apple exposes the transient device menu only while that window is active.

If the visible presentation cannot be read, the preferred private-store fallback is `ScreenTimeAgent`’s read-only `RMAdminStore-Local.sqlite` and `RMAdminStore-Cloud.sqlite`. Their `UsageBlock`, `UsageTimedItem`, `CoreDevice` and `InstalledApp` rows contain Apple-owned per-device totals, applications and sites. Goalong queries only the selected day and uses the smallest available Apple block duration so daily, weekly or other aggregate resolutions cannot be counted together. These are private formats: Apple does not document them as the public presentation contract used by System Settings, so their values must not be described as certified exact parity.

When that aggregate store is absent, protected or has changed schema, the runtime exposes an explicit fallback/partial state and can use three bounded Apple sources:

1. **Biome `ScreenTime.AppUsage`** for Apple's local application-usage transitions on this Mac, including parent-app attribution for helpers;
2. **knowledgeC `/app/usage`** for Apple-created application usage intervals and fallback coverage;
3. **Biome `App.InFocus`** for local and remote device focus transitions synchronized through iCloud.

The source code is isolated under `Sources/LocalHistoryApp/AppleScreenTime/` and the SEGB/protobuf decoder lives in the independent `AppleScreenTime` module.

## One-time setup

1. Turn on **System Settings → Screen Time**.
2. Turn on **Share Across Devices** on the Mac, iPhone and iPad using the same Apple Account.
3. Grant the signed **Goalong History.app** Accessibility access. Goalong uses it only for the explicitly enabled local activity capture and the bounded on-demand read of Apple's visible Screen Time controls.
4. Grant Full Disk Access if you also want the private-store fallback when the visible Apple page is unavailable.
5. Reopen Goalong History if macOS does not apply a TCC grant immediately.

No daily export, manual file selection, companion snapshot or Goalong server is required for the data already synchronized to the Mac.

## Automatic updates

The dashboard refreshes at most every 30 seconds while the page is visible. The visible Apple presentation itself is cached for two minutes today and ten minutes for past days, so a foreground page does not repeatedly drive System Settings. Aggregate-store queries are bounded to the selected day. On the fallback path, unchanged Biome files are served from an in-memory fingerprint cache; only newly created or modified SEGB files are decoded again.

The Mac-side refresh cadence is deterministic. Cross-device latency is not: Apple controls when iCloud/Biome delivers iPhone and iPad transitions. The page displays the latest Apple file/event update so a user can distinguish a live Mac refresh from a stale remote sync.

## Device names and types

Goalong resolves each synchronized peer conservatively, in this order:

1. an exact Apple hardware model carried by knowledgeC or Biome;
2. the typed `BMDevicePlatform` value already carried by Biome (`iPad`, `iPhone`, Mac, Apple TV, Apple Watch, HomePod or Apple Vision Pro);
3. the matching trusted, recently updated friendly name from Apple's local account-device catalogue;
4. a strong watchOS application signature for older Apple Watch rows that lack platform metadata;
5. an explicit generic type plus a stable, shortened peer tag when Apple does not expose enough metadata.

The normalizer preserves exact names such as `Alex’s iPhone`, `Alex’s iPad` and `Alex’s Apple Watch`. It never assigns order-dependent labels such as “Apple device 1” or “Apple device 2”. Unknown future platform values remain explicit generic devices instead of being guessed.

## Per-device selection

The page supports:

- **This Mac** — only the current physical Mac;
- **All devices** — every Apple device synchronized to the Mac;
- **Selected devices** — exact device IDs chosen individually.

For **All devices**, Goalong uses Apple's own visible All Devices presentation rather than recreating it from rounded device rows. For one device or a partial selection, it uses the exact visible per-device presentations; combinations are sums of those device-specific Apple values because macOS Settings offers no multi-select subset control. Selecting every physical device switches back to Apple's explicit All Devices presentation. Each shared JSON file carries the selected scope, included device count, aggregation method, provenance and optional per-application rows.

The **Selected devices** list also keeps trusted, recently updated Apple devices available when they have no usage on the displayed day. Historical or ambiguous Biome peers are not added unless they contributed usage for that day, so an idle iPad remains selectable without reviving old device ghosts.

## How application time is read

On the preferred private-store path, Goalong does not reconstruct a total from focus events. It reads each Apple `UsageBlock` screen-on total and its trusted `UsageTimedItem` rows, resolves friendly names from Apple’s `InstalledApp` records, and keeps website domains inside the same physical block. Application and website durations can overlap, but the block’s screen-on total is counted once. Local and cloud rows with the same device and block identity are deduplicated by Apple update time and source priority. This stronger provenance still does not prove equality with every grouping, suppression or rounding rule in Settings.

The following reconstruction rules apply only to the fallback path:

knowledgeC rows already contain start/end application intervals. Biome `App.InFocus` stores protobuf transition events:

- field 3: gained/lost foreground state;
- field 4: CFAbsoluteTime timestamp;
- field 6: bundle identifier.

Biome `ScreenTime.AppUsage` contains an independent start/stop stream per application, a Unix timestamp, a bundle identifier, an optional parent bundle identifier and an optional Apple trust bit. Goalong attributes a helper to its non-empty parent bundle, keeps concurrent applications distinct, ignores explicitly untrusted events and deduplicates repeated transitions of the same app.

The native decoder supports Apple SEGB v1 and v2 containers. For `App.InFocus`, a foreground gain opens an interval; a matching loss or a different app gaining focus closes it. For `ScreenTime.AppUsage`, each application owns its own interval. A currently open interval is extended to “now” only when Apple's latest event is recent, preventing a stale stream from inventing hours of usage.

On this Mac, a healthy `ScreenTime.AppUsage` stream is used by itself for application attribution and physical coverage. Goalong does not refill its intentional gaps with knowledgeC/App.InFocus rows, because doing so can resurrect an application Apple omitted and inflate both ranking and total. knowledgeC/App.InFocus are used for the Mac only when `ScreenTime.AppUsage` is missing or partial. On synchronized remote devices, knowledgeC has precedence and App.InFocus fills uncovered fragments. Different apps may legitimately overlap, so Goalong retains every app duration but counts each physical screen-on slice once.

Goalong preserves Apple's complete merged report in memory, including explicit operating-system inactivity surfaces. Default summaries then hide those rows and subtract their durations. On Mac this means `com.apple.loginwindow` and Apple's `com.apple.ScreenSaver.*` bundle family; on iPhone, iPad and iPod it means `com.apple.SleepLockScreen`. Keeping those markers through the merge prevents a stale Biome foreground app from refilling a period Apple already identified as locked. The filter uses exact Apple bundle namespaces, not display names or broad “system app” guesses.

The Overview page shows every active-use application by default. Its **Include login and lock-screen time** switch adds Apple-reported login-window, lock-screen, and screen-saver rows and updates the Screen Time total from the same already-read report. The switch does not hide or reveal ordinary apps. This is a presentation choice: it does not re-scan Apple stores and does not create a second stored copy. CLI reports retain the complete per-device rows while their aggregate summary uses the filtered default; daily AI recaps and share summaries also use the filtered default so known lock-screen time does not consume tokens or appear as active use.

This boundary removes known locked and screen-saver periods. It does not claim proof of attention: an unlocked application left visible while someone walks away cannot be distinguished safely from legitimate passive use such as reading, video or a call, especially across remote Apple devices. Goalong therefore does not impose an arbitrary idle timeout.

## Privacy and security

- The exact visible reader uses Accessibility only, retains no screenshot, writes no Apple data, and keeps only a small bounded in-memory cache.
- Apple fallback databases are opened with SQLite `READONLY`, `NOFOLLOW`, `query_only`, an allow-list authorizer, no mmap and an inode check after canonical path resolution.
- Device-name enrichment reads only the account catalogue fields `name`, `model`, `os`, `trusted` and `last_updated_date`; serial numbers, account identifiers and service metadata are never selected.
- Apple files are never modified, vacuumed, migrated or copied into Goalong storage.
- Goalong History stores only its scope/share configuration and explicit share exports.
- The small device-name catalogue is cached only in memory and re-read only when its SQLite file or write-ahead log fingerprint changes.
- ScreenTimeAgent’s aggregate store is inside an Apple Data Vault and can remain inaccessible to third-party apps even with Full Disk Access. Full Disk Access is still required for the fallback knowledgeC and Biome stores.
- The private formats can change after an OS update; failures remain isolated to this optional feature.

For the visible presentation, the defensible source claim is:

> Goalong History read the values Apple System Settings visibly presented for this day and device selection at the recorded read time.

For a private-store fallback, the defensible source claim is:

> Goalong History read these per-device totals and timed items directly from Apple-owned private stores present on this Mac, including Apple-synchronized remote devices where available.

It is not a cryptographic attestation from Apple and it is not proof of attention or productive work.
Neither the private aggregate nor the reconstructed fallbacks are described as certified exact Settings parity.

## Public Apple API path

Apple documents `DeviceActivityData.activityData(filteredBy:using:)` for an eligible iOS/iPadOS 26.4+ companion. That public data-export route requires enhanced authorization, a managed entitlement and current regional/platform eligibility. Goalong keeps the collector contract and an explicitly gated adapter source, but the current Mac product does not ship a verified companion implementation. The installed SDK is too old to validate the final 26.4 signature, and a distributable companion additionally requires Apple approval. Until both exist, the supported UI must report private aggregate provenance or reconstruction rather than public-API parity.
