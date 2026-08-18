# Apple Screen Time in LocalHistory

LocalHistory can analyze an official Apple Screen Time export while keeping the source and device scope unambiguous.

## User flow

1. An eligible companion client requests Apple's enhanced Screen Time data authorization.
2. The companion fetches `DeviceActivityData` for a chosen interval and exports the versioned JSON envelope.
3. On the Mac, open **Apple Screen Time → Import export**.
4. Choose **All Apple devices**, **Mac only**, or **Selected devices**.
5. Export a share file as totals only, per-device totals, or devices plus application rows.

Imported files are stored separately under:

```text
~/Library/Application Support/LocalHistory/apple-screen-time/
├── configuration.json
└── imports/
    └── <timestamp>-<uuid>.json
```

Directories use `0700` and files use `0600` where supported.

## What “all devices” means

Apple returns one report per person/device pair. LocalHistory preserves those rows and aggregates only after applying the selected scope. An all-device total is the **sum of per-device screen-on durations**. It is not a deduplicated estimate of human attention: if an iPhone and Mac are active simultaneously, both durations remain represented.

## Share format

`*.apple-screen-time-share.json` includes:

- interval and creation date;
- requested device scope;
- number of included devices;
- summed screen-on duration;
- the explicit aggregation method;
- optional per-device and application rows according to the selected disclosure level;
- Apple API provenance and authorization evidence;
- import-verification status and a human-readable trust notice.

## Security and anti-cheat status

LocalHistory validates structure, bounded durations, device uniqueness and schema version before accepting an import. This prevents malformed or abusive files from entering the dashboard, but structural validation is not proof that a user did not edit an unsigned JSON file.

The current implementation therefore uses three explicit states:

- `unsigned`: no signature in the imported export;
- `signaturePresentUnverified`: a signature exists but is not linked to a trusted official collector key;
- `verifiedOfficialCollector`: the caller has verified the signature against a trusted official collector key.

Only the third state should be presented as collector-authenticated. Even then, the claim remains limited to what the official client received from Apple's public API; it does not prove attention, identity, or productive work.

## Why no private macOS database access

The feature intentionally does not read private Screen Time SQLite stores, invoke undocumented daemons, or depend on reverse-engineered file paths. Those approaches are brittle, difficult to permission cleanly, and incompatible with the project's honest trust boundary.
