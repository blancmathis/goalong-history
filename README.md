<div align="center">
  <img src="Distribution/AppIcon.svg" width="112" alt="Goalong History app icon">

# Goalong History

**Private, verifiable activity for macOS.**

A native menu-bar app that turns foreground activity into a clear local timeline, seals it against later rewriting, and lets the user disclose only what they choose.

[Install the audited source build](#build-from-source) · [Guide français](GUIDE_FR.md) · [Security and privacy](docs/INDEX.md)
</div>

> **Agent Activity privacy notice:** the currently published `latest-main` bundle predates
> direct-source indexing. Do not install that bundle. From this checkout, use
> `./install.sh --source`; the installer builds, audits, stages, and validates the
> direct-source app before replacing an existing installation.

> Goalong History is for a Mac you own and use yourself. Never use it to monitor another person without their prior, explicit consent.

## A Mac installation that feels like a product

The current public `latest-main` artifact is intentionally rejected by the installer because it
predates the direct-source Agent Activity privacy boundary. Until a replacement release is
published, build and install this checkout with `./install.sh --source`. That workflow runs the
tests and privacy audit, builds the app for the current Mac architecture, validates its identity and direct-source marker,
then replaces an existing installation atomically with rollback on failure.

After installation, open **Goalong History** and follow the native setup assistant. The app is
compatible with macOS 13 Ventura or later. A source build automatically uses an available Apple
Development identity for stable local permissions; without one it warns and falls back to ad-hoc signing.

The first launch guides the user through focused, skippable screens. Every sensitive capability is off until the user enables it:

1. what Goalong History does;
2. the exact privacy boundary;
3. an explicit Computer History choice, off by default;
4. Accessibility and Input Monitoring, requested only when Computer History was enabled;
5. separate Apple Screen Time and AI-conversation choices, both off by default;
6. a final health check and an explicit “start at login” choice, also off by default.

macOS permission state never counts as Goalong consent. A previously granted Full Disk Access,
Accessibility or Input Monitoring switch cannot silently reactivate a Goalong source.

The installed app also provides a read-only `goalong` terminal command for users and local agents. It exposes Computer History, detailed Apple Screen Time, direct-source AI conversations, available dates, daily recaps, and bounded agent context as JSON without creating a second history store or background process. See [`docs/CLI.md`](docs/CLI.md).

Permission state updates live. Every step includes a direct System Settings route and a safe “set up later” path, so the user is never stranded.

## What the app records

When both the relevant Goalong capability and macOS permission are enabled, Goalong History can store:

- the active app and bundle identifier;
- active window title and accessible control metadata;
- a cleaned browser URL where available and allowed;
- clicks and grouped scroll activity;
- generic shortcut and navigation activity, without exact keys or modifiers;
- typing count and duration, **never the characters**;
- app, window, focus, lock, sleep, pause, and suppression transitions;
- limited Core Graphics input-origin signals.

It does **not** record screenshots, screen video, camera, microphone, system audio, clipboard contents, passwords, or reconstructed typed text.

Recognized and capability-detected private-browser windows are fail-closed. The record keeps a generic private/suppressed coverage state without storing the private URL, window title, click details, or keyboard activity. Browser URL availability still depends on the Accessibility information exposed by that browser; an extension may be needed for browsers that do not expose it. Password managers and secure text-entry contexts are excluded or suppressed as well.

## Local-first by default

Detailed activity is written to the current user’s private Application Support directory.
This abridged tree includes the principal preserved data stores:

```text
~/Library/Application Support/LocalHistory/
├── config.json
├── capability-consent.json   # created after a choice; absence fails closed to all-off
├── sharing-rules.json
├── integrity-state.json
├── diagnostics.log
├── events/
│   └── YYYY-MM-DD.jsonl
├── seals/
│   └── YYYY-MM-DD.seals.jsonl
├── receipts/
│   └── YYYY-MM-DD.receipts.jsonl
├── semantic/
├── analysis/
├── memories/
├── computer-history/
├── apple-screen-time/
├── agent-activity-v2/
├── chatgpt/
│   ├── recaps/
│   └── proofs/          # small signed metadata, never transcript bodies
└── shares/
```

Directories use mode `0700`; detailed files use mode `0600`.

There is exactly one public application: **Goalong History**, bundle identifier
`ai.goalong.localhistory`. Its compiled target contains no Goalong first-party HTTP uploader,
App Attest transport or in-app updater. Optional ChatGPT analysis starts the fixed local Codex
`app-server` process only after its own consent; this is the sole intentional external-analysis
path. Full Disk Access readers still share the main app process, which is documented as a
remaining limitation rather than hidden behind an “offline” label. See
[`docs/GUARANTEES.md`](docs/GUARANTEES.md).

## Verifiable without forcing disclosure

Each event is separated into independently committed groups:

```text
time · application · website · context · activity · classification · coverage · trust · raw_digest
```

Each group receives a random 256-bit salt and SHA-256 commitment. Those commitments form an event Merkle root. Event roots are chained with a monotonic sequence and the previous event hash.

Once per minute, event roots are committed into a minute Merkle root. The minute anchor is chained to the previous anchor and signed with a P-256 device key. Goalong History first tries Secure Enclave through the modern Data Protection Keychain and falls back to a non-exportable Keychain key for a stable certificate-backed build. Ad-hoc development builds use a user-only local key file and report that lower trust tier instead of creating a Keychain item that would trigger password prompts after recompilation. Public releases are accepted only when Developer ID signed and notarized by Apple.

Signing identities are scoped to the app's designated code-signing requirement. If that requirement changes, Goalong History records a visible identity rotation and keeps the existing chain data instead of repeatedly requesting access to an incompatible old key. A refused authentication attempt also suspends background signing for that launch, so it can never create a password dialog every minute.

The contextual **Share day** action stores one rule for every observed application and website:

- show the app or website name;
- show only its category;
- hide its identifying details.

Website rules take priority over the containing browser rule. The original JSONL is never rewritten. Export creates a separate `*.signed-share.json` package containing only the selected event-level openings and the hashes required to reconstruct the already-sealed roots. Before writing it, Goalong recomputes the disclosed commitments, day and boundary links, device identities, and every included P-256 signature. `goalong verify-share PATH` repeats those checks offline. Every sealed minute remains represented, so anonymization cannot silently turn into omission. Receipt IDs, trust-tier labels, export time and classifier version remain explicitly unverified metadata in the current package rather than being presented as App Attest proof.

New daily AI analyses use the same honest separation of claims. Goalong signs a
metadata-only context manifest, exact prompt/response hashes, the five-line
result and the run chain into a bounded ES256 proof. The complete prompt and
source conversations are never copied; only the bounded generated response is
temporarily encrypted with a per-run Keychain key. `goalong export-proof` creates
a path-redacted `.goalong-proof`, and `goalong verify-proof` independently checks
its strict ZIP inventory, hashes, source commitments, artifact links and local
signatures offline. Provider authorship, App Attest and an external timestamp
remain separate and are reported as absent unless their own signed evidence is
actually included.

## Native dashboard

The SwiftUI dashboard exposes only three primary destinations:

- **Today** — runtime state, daily metrics, top applications, coverage and the optional
  five-line GPT-5.6 Luna High assessment;
- **History** — one selected-day view with an all-sources timeline and filters for causal
  [Computer History](docs/COMPUTER_HISTORY_PARITY.md), Apple Screen Time and
  [AI conversations](Features/AgentActivity/README.md);
- **Settings** — ChatGPT connection and a short progressive-disclosure list for recording,
  sources, privacy, permissions and expert controls.

Sharing is a contextual **Share day** action on Today and History. Privacy, source management,
verification and detailed capture options remain available without occupying permanent sidebar
destinations.

A menu-bar control keeps pause/resume, status, dashboard access, and sharing immediately available.

## Updates and start at login

Start-at-login is an explicit onboarding choice implemented with Apple’s `SMAppService`. Goalong History no longer installs a hand-written LaunchAgent. Upgrading preserves the local history and settings directory.

A legacy LaunchAgent from versions before 0.4 is removed automatically by the installer. The
single app has no in-app updater. Releases are downloaded and replaced manually so the exact
signed artifact, SHA-256 inventory and capability manifest can be inspected before installation.

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
./scripts/verify_source_security.sh --with-tests
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

The build script creates the single `.app` bundle, generates the `.icns` asset, writes the release
Info.plist, code signs the bundle, and verifies it. It also generates
`security-capabilities.json`, an SPDX SBOM and `release-manifest.json` from the final signed
artifact. Local builds automatically use a stable Apple Development identity when available.
Public releases require Developer ID, Hardened Runtime and notarization.

## Release pipeline

Every successful merge to `main` can build both architectures, create the universal binary,
verify the single-app security manifest, create the branded DMG and ZIP, and replace the
`latest-main` prerelease. Publication is skipped unless Developer ID signing and notarization
credentials are complete; no ad-hoc public artifact is published. Updates remain manual and
auditable. The separate stable-tag workflow remains reserved for explicit stable releases.

Release credentials and the exact process are documented in [`docs/RELEASING.md`](docs/RELEASING.md). Installation design principles are documented in [`docs/INSTALLATION_UX.md`](docs/INSTALLATION_UX.md).

## Archived reference verification server

The included backend is deliberately a reference implementation:

```bash
cd server_reference
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
uvicorn app:app --host 127.0.0.1 --port 8787
```

The repository retains a reference server for protocol research, but the single public app does
not contain its uploader and cannot send data to it. Reintroducing any remote verification path
requires a new explicit design review, consent surface, manifest entry and release gate.

## Honest trust boundary

The defensible local-only claim is:

> The disclosed fields match the included commitments, and the included local device key signed the linked minute anchors.

That local proof does not authenticate the official Goalong build, Apple App Attest,
an external timestamp, or an AI provider. Those stronger claims require their own
independently verifiable evidence and are never inferred from a receipt ID or a
locally saved model name.

It is not proof of a person’s identity, internal attention, or intellectual effort. Hardware HID emulation, another person at the keyboard, remote hardware, and a compromised operating system remain fundamental limits.

## License

MIT. See [`LICENSE`](LICENSE).
