<div align="center">
  <img src="Distribution/AppIcon.svg" width="112" alt="LocalHistory app icon">

# LocalHistory

**Private, verifiable activity for macOS.**

A native menu-bar app that turns foreground activity into a clear local timeline, seals it against later rewriting, and lets the user disclose only what they choose.

[Download the latest Mac release](https://github.com/blancmathis/goalong-history/releases/latest) · [Guide français](GUIDE_FR.md) · [Security model](SECURITY.md)
</div>

> LocalHistory is for a Mac you own and use yourself. Never use it to monitor another person without their prior, explicit consent.

## A Mac installation that feels like a product

The normal installation does **not** require Terminal, Xcode, Homebrew, Python, or administrator commands.

1. Download `LocalHistory-macOS-universal.dmg` from Releases.
2. Drag **LocalHistory** to **Applications**.
3. Open the app.
4. Follow the native setup assistant.

The release is universal (`arm64 + x86_64`), Developer ID signed, notarized by Apple, and compatible with macOS 13 Ventura or later.

The first launch guides the user through five focused screens:

1. what LocalHistory does;
2. the exact privacy boundary;
3. Accessibility, explained and requested in context;
4. Input Monitoring, explained and requested separately;
5. a final health check and an explicit “start at login” choice.

Permission state updates live. Every step includes a direct System Settings route and a safe “set up later” path, so the user is never stranded.

## What the app records

When the relevant macOS permissions are granted, LocalHistory can store:

- the active app and bundle identifier;
- active window title and accessible control metadata;
- a cleaned browser URL where available and allowed;
- clicks and grouped scroll activity;
- shortcuts and navigation keys;
- typing count and duration, **never the characters**;
- app, window, focus, lock, sleep, pause, and suppression transitions;
- limited Core Graphics input-origin signals.

It does **not** record screenshots, screen video, camera, microphone, system audio, clipboard contents, passwords, or reconstructed typed text.

Private-browser windows are fail-closed. The record keeps a generic private/suppressed coverage state without storing the private URL, window title, click details, or keyboard activity. Password managers and secure text-entry contexts are excluded or suppressed as well.

## Local-first by default

Detailed activity is written to the current user’s private Application Support directory:

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

Verification networking is disabled by default. When the user enables it, the only live upload is an opaque minute commitment. App names, URLs, window titles, clicks, categories, event roots, event counts, and local event timestamps are not included in that upload.

## Verifiable without forcing disclosure

Each event is separated into independently committed groups:

```text
time · application · context · activity · classification · coverage · trust · raw_digest
```

Each group receives a random 256-bit salt and SHA-256 commitment. Those commitments form an event Merkle root. Event roots are chained with a monotonic sequence and the previous event hash.

Once per minute, event roots are committed into a minute Merkle root. The minute anchor is chained to the previous anchor and signed with a P-256 device key. LocalHistory first tries Secure Enclave and falls back to a non-exportable Keychain key while reporting the lower trust tier.

The **Share** screen offers four disclosure levels for every grouped period:

- full details;
- application only;
- category only;
- completely private.

The original JSONL is never rewritten. Export creates a separate `*.verified-share.json` package containing only the selected openings and the hashes required to reconstruct the already-sealed roots. Every sealed minute remains represented, so anonymization cannot silently turn into omission.

## Native dashboard

The SwiftUI dashboard is split into five areas:

- **Overview** — runtime state, daily metrics, coverage, top apps, and recent sessions;
- **Activity** — searchable sessions, event breakdown, privacy states, and automation signals;
- **Share** — visual selective disclosure, exact outgoing-data preview, and verified export;
- **Privacy & Security** — permission state, data flow, storage, identity, and safe deletion;
- **Settings** — capture signals, retention, URL redaction, verification, and exclusions.

A menu-bar control keeps pause/resume, status, dashboard access, and sharing immediately available.

## Updates and start at login

Start-at-login is an explicit onboarding choice implemented with Apple’s `SMAppService`. LocalHistory no longer installs a hand-written LaunchAgent. Upgrading preserves the local history and settings directory.

A legacy LaunchAgent from versions before 0.4 is removed automatically by the installer.

## Build from source

Source installation is intentionally a developer path, not the public onboarding path.

Requirements:

- macOS 13 or later;
- Xcode Command Line Tools.

```bash
git clone https://github.com/blancmathis/goalong-history.git
cd goalong-history
./install.sh --source
```

Or run the individual quality gates:

```bash
swift test
./scripts/audit_privacy_boundaries.sh
LOCALHISTORY_ARCHS="$(uname -m)" ./scripts/build_app.sh
```

Useful Make targets:

```bash
make test
make audit
make app
make dmg
make install-source
```

The build script creates a real `.app` bundle, generates the `.icns` asset, writes the production Info.plist, signs the bundle, and verifies it. Local builds use ad-hoc signing; public releases use Developer ID signing and notarization.

## Release pipeline

The tag workflow builds both architectures, creates the universal binary, signs with Hardened Runtime, notarizes and staples the app, creates the branded DMG and ZIP, notarizes the DMG, verifies both artifacts, and publishes SHA-256 checksum files.

Release credentials and the exact process are documented in [`docs/RELEASING.md`](docs/RELEASING.md). Installation design principles are documented in [`docs/INSTALLATION_UX.md`](docs/INSTALLATION_UX.md).

## Reference verification server

The included backend is deliberately a reference implementation:

```bash
cd server_reference
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
uvicorn app:app --host 127.0.0.1 --port 8787
```

Then enable opaque minute commitments under **Settings → Anti-tamper verification** and use:

```text
http://127.0.0.1:8787
```

HTTP is accepted only for localhost development. Use authenticated accounts, HTTPS, rate limits, challenge expiry, append-only or audited anchor storage, and a production App Attest verifier before presenting activity as platform-verified.

## Honest trust boundary

The defensible claim is:

> The official client observed and committed these data at those times; the disclosed fields match the live anchors and were not rewritten later.

It is not proof of a person’s identity, internal attention, or intellectual effort. Hardware HID emulation, another person at the keyboard, remote hardware, and a compromised operating system remain fundamental limits.

## License

MIT. See [`LICENSE`](LICENSE).
