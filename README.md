# LocalHistory v0.3.2 — private, verifiable activity for macOS

LocalHistory is a local-first macOS activity recorder with a native dashboard. It records permitted foreground activity on the Mac, seals the record cryptographically every minute, and lets the user later create a selectively anonymized proof without rewriting the original history.

It is intended for a Mac you own and use yourself. Do not use it to monitor another person without their prior explicit consent.

## What is new in v0.3.2

v0.3.2 is a compatibility patch for the installer. It preserves the complete native SwiftUI interface and the v0.2 anti-tamper/selective-disclosure protocol, while fixing release installation on the macOS system Bash when no optional Swift compatibility flag is required.

The dashboard contains five clearly separated areas:

- **Overview** — current recorder status, active/work/private time, live-anchor coverage, 24-hour timeline, top applications and recent sessions.
- **Activity** — searchable, filterable sessions with local context, category, event breakdown, privacy states and software-attributed input warnings.
- **Share** — a visual day timeline with four disclosure levels, bulk presets, an exact preview of what leaves the Mac, and verified-package export.
- **Privacy & security** — permission state, local/remote data flow, storage, signing identity, protections and safe deletion controls.
- **Settings** — capture signals, retention, URL redaction, verification server, App Attest preference and exclusions, with save/discard state.

A first-run onboarding sheet explains the privacy and verification model. The menu-bar icon remains available for quick status, pause/resume, sharing and diagnostics.

## Capture and privacy model

Detailed local data can contain:

- active app and bundle identifier;
- active window title and accessible control metadata;
- cleaned browser URL where available;
- clicks and grouped scroll activity;
- shortcuts and navigation keys;
- typing counts and duration, never raw typed characters;
- app/window/focus changes;
- lock, sleep, pause and suppression states;
- limited Core Graphics input-origin signals.

LocalHistory does **not** record screenshots, video, microphone/system audio, clipboard contents or reconstructed typed characters.

Private-browser windows are fail-closed: LocalHistory stores a generic suppression/coverage state and not the private URL, window title, click details or keyboard activity. Password managers and secure text-entry contexts are also excluded or suppressed.

## Anti-tamper model

Every event is split into independently committed groups:

- `time`
- `application`
- `context`
- `activity`
- `classification`
- `coverage`
- `trust`
- `raw_digest`

Each group receives a random 256-bit salt and SHA-256 commitment. The commitments form an event Merkle root. Event roots are chained with a monotonic sequence and the previous event hash.

Once per minute, all event roots are committed into a minute Merkle root. That root is chained to the previous minute anchor and signed with a P-256 device key. The client first attempts to keep the private key in Secure Enclave; if unavailable, it falls back to a non-exportable Keychain key and reports a lower trust tier.

When verification is enabled, only the opaque minute anchor is sent live to the server. The live payload does not contain app names, URLs, window titles, clicks, categories, event roots, event counts or local event timestamps.

The reference payload contains only:

```text
device pseudonym
anchor sequence
opaque minute root
previous opaque anchor hash
current anchor hash
P-256 signature
app version
one-time challenge ID
optional App Attest material
```

The server's own receipt time externally anchors when it saw the proof.

## Selective anonymization

The **Share** screen lets the user choose one disclosure level for each grouped period:

1. **Full details**
2. **Application only**
3. **Category only**
4. **Completely private**

The original JSONL is never modified for anonymization. LocalHistory creates a separate `*.verified-share.json` package.

For application/category disclosures, the package contains only the chosen field openings plus the commitment hashes needed to reconstruct the previously anchored Merkle root. Hidden fields remain hidden because their random salts are not disclosed.

For a completely private minute, the package proves that the sealed period existed and reveals its time/coverage state, but does not reveal the detailed events or event count. A private period must not be counted by the server as verified work.

Every sealed minute remains represented in the package. A user can anonymize a period, but cannot silently remove it. The package also attempts to include adjacent private boundary anchors so a verifier can detect omission of leading or trailing minutes around a local calendar day.

## Input-automation signals

For keyboard and mouse events, LocalHistory records Core Graphics source PID, UID and source state when macOS exposes them. A userspace-attributed synthetic event can therefore be marked and shown in the Activity interface.

This is a risk signal, not absolute proof of cheating. Hardware HID emulation, remote hardware, another person using the Mac and a compromised operating system remain fundamental limits.

## App Attest

The client contains an optional App Attest bridge when the installed SDK/runtime supports it. The installer automatically retries with the bridge disabled if the local SDK cannot compile it.

The included reference server intentionally fails closed for App Attest (`appAttestAccepted=false`) until a production verifier is connected in `server_reference/app_attest.py`. Do not display an App-Attest-verified badge until the verifier checks your Apple Team ID, bundle ID, certificate chain, challenge binding, counters and chosen macOS integrity policy.

Even without App Attest, the reference server validates P-256 device signatures, one-time challenges, anchor continuity, commitments and selective-disclosure structure.

## Installation

Requirements: macOS 13 or later and Xcode Command Line Tools.

1. Unzip the package.
2. Open the `LocalHistory` folder.
3. Double-click `Install.command`.
4. If Gatekeeper blocks it, Control-click `Install.command`, choose **Open**, then confirm.
5. Grant **Accessibility** and **Input Monitoring** when prompted.

The installer runs the privacy audit, Swift tests and a native release build on the target Mac before installing:

```text
~/Applications/LocalHistory.app
```

No `sudo` is used. The dashboard opens on first v0.3 launch; afterward it can be reopened from the menu-bar icon.

## Data layout

```text
~/Library/Application Support/LocalHistory/
├── config.json
├── integrity-state.json
├── diagnostics.log
├── events/
│   └── YYYY-MM-DD.jsonl
├── seals/
│   └── YYYY-MM-DD.seals.jsonl
├── receipts/
│   └── YYYY-MM-DD.receipts.jsonl
└── shares/
```

Directories use mode `0700`; detailed files use mode `0600`.

Deleting detailed history does not delete cryptographic seals or server receipts. The deleted interval cannot later be selectively revealed and is forced to private-only.

## Enable the reference verification server

Verification is disabled by default, so the app can remain entirely local.

Run the reference backend:

```bash
cd server_reference
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
uvicorn app:app --host 127.0.0.1 --port 8787
```

Then open **Settings → Anti-tamper verification**, enable opaque minute commitments and enter:

```text
http://127.0.0.1:8787
```

HTTP is accepted only for localhost. Use HTTPS for any remote deployment.

In a real social network, replace the reference unauthenticated device registration with the platform's authenticated account/session flow.

## Development and validation

```bash
swift test
swift build -c release --product LocalHistory
./scripts/audit_privacy_boundaries.sh
python3 -m py_compile server_reference/app.py server_reference/app_attest.py
```

The GitHub Actions workflow also builds and tests on a macOS runner.

## Production requirements before calling activity “verified”

This package is still a developer build. A production anti-cheat deployment additionally needs:

- one official Developer ID-signed and notarized build;
- Hardened Runtime and a controlled release pipeline;
- device registration bound to the authenticated social-network account;
- real App Attest verification where supported;
- HTTPS, rate limiting and one-time challenge expiry;
- append-only or audited anchor storage;
- versioned, server-authorized classification rules;
- clock/server-time anomaly detection;
- ongoing private-mode and automation-regression testing.

The defensible claim is:

> The official client observed and committed these data at those times; the disclosed fields match the live anchors and were not rewritten later.

It is not proof of a person's internal attention, identity or intellectual effort.
