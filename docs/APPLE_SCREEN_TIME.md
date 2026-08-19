# Screen Time in LocalHistory

LocalHistory now measures the current Mac automatically and continuously. It does not require the user to export Apple Screen Time every day, and it does not read Apple's private Screen Time databases.

## User flow

1. Install and run LocalHistory normally on the Mac.
2. Open **Screen Time** in the dashboard.
3. Choose **This Mac**, **All devices**, or **Selected devices**.
4. View continuously updated device totals and application durations.
5. Optionally export a share file with totals only, per-device totals, or device-plus-application rows.

For the current Mac, there is no import step. Today's calculation refreshes every five seconds from the foreground activity stream that LocalHistory already records.

## How the Mac total is produced

The Mac source reconstructs non-overlapping foreground intervals from:

- application activation and context changes;
- recorder heartbeats;
- pause and resume transitions;
- session lock and unlock transitions;
- display/system sleep and wake transitions;
- recorder start and stop events;
- privacy-suppression boundaries.

The total advances while the recorder is running, the session is active, the display is awake and a foreground application is known. A normal foreground interval must keep receiving heartbeats; its unconfirmed trailing edge is capped. This prevents a crash or terminated recorder from silently adding hours of usage.

Private browsing, excluded applications/domains and secure-input periods can remain represented in the overall device duration without exposing an application identity. Manual pause, unavailable session and unavailable Accessibility stop measurement.

## Application details

For the Mac, LocalHistory attributes each measured interval to the foreground app's name and bundle identifier. Durations are aggregated per app and update along with the total.

For companion devices, the official collector walks Apple's DeviceActivity categories and application activity rows, aggregating `totalActivityDuration` by bundle identifier. Apple may not expose a localized app name in every process context, so the bundle identifier remains the stable fallback.

## Device scopes

- **This Mac**: only the physical Mac currently running LocalHistory.
- **All devices**: this Mac plus every connected companion-device report.
- **Selected devices**: only the exact physical-device identifiers chosen by the user.

An all-device total is the **sum of per-device screen-on durations**. It is deliberately not described as unique human time: simultaneous iPhone and Mac use remains counted on both device rows.

## Automatic iPhone and iPad path

The reusable iOS collector and Mac-side multi-device fusion are implemented. An end-to-end automatic companion still needs:

- an iOS application target signed by Goalong;
- Apple's managed `Family Controls App and Website Usage` entitlement;
- `approvedWithDataAccess` user authorization;
- a secure sync transport that delivers the newest signed companion snapshot to the Mac;
- pinned-key verification on the Mac.

A manual snapshot import remains available only for development and compatibility testing. It is not required for the current Mac and is not intended as the final daily workflow for other devices.

## Local storage

Device-scope configuration and optional companion snapshots are stored separately under:

```text
~/Library/Application Support/LocalHistory/apple-screen-time/
├── configuration.json
└── imports/
    └── <timestamp>-<uuid>.json
```

The live Mac calculation reads the existing daily event JSONL incrementally; it does not create a second raw activity database.

Directories use `0700` and files use `0600` where supported.

## Share format

A Screen Time share JSON includes:

- interval and creation date;
- requested device scope;
- included-device count;
- summed screen-on duration;
- the explicit no-cross-device-deduplication rule;
- optional per-device and application rows according to the disclosure level;
- collector provenance;
- current verification status and a trust notice.

A standalone Screen Time summary is not automatically equivalent to LocalHistory's complete minute-seal proof package. Share the corresponding LocalHistory evidence as well when cryptographic verification of the underlying event history matters.

## Security and anti-cheat status

LocalHistory validates imported companion structure, bounded durations, device uniqueness and schema version. Structural validation does not prove that an unsigned JSON file was not edited.

Companion snapshots therefore retain explicit states:

- `unsigned`;
- `signaturePresentUnverified`;
- `verifiedOfficialCollector`.

Only a snapshot whose canonical signature has been checked against a pinned official key should receive `verifiedOfficialCollector`. Even then, the claim remains limited to what an official client observed; it does not prove attention, identity or productive work.

## Why no private macOS Screen Time database access

The feature intentionally avoids private SQLite stores, undocumented daemons and reverse-engineered paths. The live Mac source uses LocalHistory's own documented capture boundary, works continuously, remains independently maintainable and does not require Full Disk Access merely to imitate Apple's Settings UI.
