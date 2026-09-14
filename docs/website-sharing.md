# GoLong website sharing

## User journey

On the website: Settings → **Partager depuis GoLong History**. Pair the Mac once,
confirm the displayed site in History, then use **Choisir les données**. Website
navigation includes the current authenticated account UUID, not a credential.
History compares the origin, account UUID and paired credential fingerprint;
a different account or a manually replaced credential requires re-pairing.
Opening the picker alone never exports or sends activity.

In History Settings → **Partager avec GoLong**:

- **Partager une fois**: select a recorded day and explicitly check devices.
  Application rows, hourly measurements, domains and personal device names are
  opt-in. Search, select visible results, clear selections and review retained IDs
  not present on this example day. Prepare a local preview, inspect its exact JSON,
  then check the consent box and confirm the single send.
- **Synchroniser chaque jour**: select the same bounded fields, a time (hour and
  minute) and an example day. Review and authorize the fixed selection. Activating
  the plan does **not** upload the example day. The schedule sends the previous
  calendar day after the chosen time in the saved timezone, while History is open.

Nothing is selected on first use. Newly discovered devices, apps and domains do
not enlarge an existing daily authorization. Previously selected IDs absent from
the example are explicitly listed and removable. Device totals include all usage
on selected devices, including time in apps whose identities remain undisclosed.
Web domains are a separate source on this Mac, not other selected Apple devices.

## Consent and transport invariants

The primary one-off send uses the exact previewed bytes, destination and credential
fingerprint. Changing any choice invalidates the preview/checkbox. A preview older
than 15 minutes requires preparation again. Source permissions are checked before
preparation and again before transmission. Credential identity is rechecked inside
the actual URLSession submission path. Selection is applied in the local exporter,
not merely hidden visually. Optional allowlists are backwards compatible with CLI
callers: `nil` is the original CLI behavior; `[]` discloses no rows.

Daily plans use version 2 of the privacy policy. Legacy plans are suspended, visibly
explained and require fresh review. Free-form recaps, positional recap indices,
contextual analyses and project labels cannot authorize future unreviewed text;
they are never automatically sent. Existing advanced, reviewed one-off recap,
analysis and health flows remain available separately.

Upload tokens retain the existing private-file storage checks (regular file,
current owner, restrictive permissions, no symlink). Normal HTTPS validation,
ephemeral URLSession and redirect rejection remain intact. Tokens never appear in
navigation URLs. The submission idempotency key is derived from exact payload
bytes; identical-byte retries reuse the server receipt rather than replaying the
operation. Neither client nor server claims independent verification of these data.

## Scheduling, recovery and audience

The scheduler is a timer in the running app, **not** a new privileged daemon.
It does not wake a sleeping/offline Mac, does not promise wall-clock execution and
does not backfill older missed days. On the next eligible check it considers only
the previous calendar day. `lastAttempt` is persisted before networking. An error
or uncertain receipt pauses the plan instead of silently retrying. The user checks
the website history, reviews a fresh preview and explicitly resumes.

A source revocation, changed settings or successful re-pairing pauses/removes the
old authorization. A send already in progress may still arrive. Pausing or removing
an authorization does not delete data already received or copies already shared.
Sending to one's account and sharing with other people are distinct: existing
website audience rules may apply immediately to received data. No audience setting
is changed by pairing, previewing or enabling a daily schedule.

## Reproducible validation

```sh
swift build -j 4 --target LocalHistoryApp
GOALONG_TEST_SELECTED_EXPORT=/tmp/goalong-selected-export.json \
  swift test -j 4 --filter 'GoalongSiteExportTests|GoalongWebsiteAutoSenderTests|GoalongWebsiteSharingModelTests|GoalongWebsitePairingPresentationTests'
```

Native render (requires compiled tests, uses synthetic catalog and mocked sender):

```sh
SAFE_HOME=$(mktemp -d /tmp/goalong-sharing-home-XXXXXX)
mkdir -p qa/history-sharing
HOME="$SAFE_HOME" CFFIXED_USER_HOME="$SAFE_HOME" \
GOALONG_SHARING_TEST_HOME="$SAFE_HOME" \
GOALONG_SHARING_SNAPSHOTS="$PWD/qa/history-sharing" \
  swift test --skip-build --filter GoalongWebsiteSharingRenderingTests
```

Tests must not start the production AppDelegate, capture data, change permissions,
replace the installed application, activate a real daily plan or upload real data.
The website counterpart documents component-browser and import-contract checks.
A production round-trip with an explicitly selected real account remains a separate
release acceptance step, not something inferred from mocks or a successful build.
