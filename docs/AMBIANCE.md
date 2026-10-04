# Ambiance — Onde inside Goalong (spec, 2026-10-04)

Ambiance is an optional module. It plays Onde's generative focus and relax music, sound packs
that each member downloads one by one, and the member's own audio files. It costs nothing to a
member who does not turn it on.

## Non-negotiable rules

1. **Off by default.** Off means: no Onde object, no `AVAudioEngine`, no bank file opened, no
   `URLSession`, no timer, no observer, no permission prompt. A unit test proves it.
2. **No audio in the app bundle.** The universal binary grows by at most 1 MB. Measure it.
3. **Stop releases everything.** On `stop()`, the audio engine stops and is released, and the
   bank is unmapped or freed. Resident memory returns to the pre-play level (± 5 MB).
4. **Memory while playing:** at most +90 MB over the idle level. Prefer memory-mapped sample data
   (`Data(contentsOf:options: .alwaysMapped)`) and load only the instruments the current
   composition uses. If the DSP copies samples, say so in the report with the measured cost.
5. **CPU while playing:** measure the average over 5 minutes of Focus on this Mac. Target below
   5 % of one core. Report the number even if the target is missed.

## Engine (vendored, not a dependency)

- Source: `https://github.com/blancmathis/onde` at `dfa5ab747373d1eed324115db07971c4096ffc49`.
  Copy `Sources/OndeDSP` and only the `Sources/OndeCore` files that rendering needs (settings,
  compositions, renderer, orchestra bank, transition, playback selection). Do not copy the
  updater, IPC, Espace, daily activity, artwork or agent files.
- Location: `Features/Ambiance/Engine/` with `SOURCE_COMMIT`, Onde's MIT `LICENSE` and
  `THIRD_PARTY_NOTICES.md`. Same pattern as the Onde web port (`~/Sites/Onde-web/engine/`).
- Why vendored: `scripts/audit_update_dependency.py` and `scripts/verify_source_security.sh`
  reject any remote package other than Sparkle. Do not weaken those audits.
- SwiftPM: a C target `OndeDSP` (use `cLanguageStandard: .c11`, never `unsafeFlags`) and a Swift
  library target `Ambiance` (`Features/Ambiance/Sources`). `LocalHistoryApp` depends on `Ambiance`.
- Audio output: port `Sources/OndeApp/GenerativeEngine.swift` (`AVAudioSourceNode` calling
  `onde_dsp_render`). No allocation or lock on the render thread.

## Content: packs downloaded on demand

| Pack id | Content | License |
|---|---|---|
| `orchestra` | VSCO 2 CE notes, built with Onde `Tools/prepare_orchestra.sh` | CC0 |
| `textures` | Pluie douce, Marée, Velours brun, Air rose, Aube (Onde `Tools/Synthesize.swift`) | CC0 |

- Focus and Relax compositions need `orchestra`. Without it, the UI offers the download.
- Kevin MacLeod tracks (CC BY 4.0) are out of scope for v1.
- Hosting: a dedicated GitHub release on `blancmathis/goalong-history`, tag `ambiance-packs-v1`,
  one archive per pack. The catalog is compiled into the app (`AmbiancePackCatalog.swift`: id,
  French title, byte size, HTTPS URL, SHA-256).
- **Do not create or upload the release.** Build the archives into `/tmp/goalong-ambiance-packs/`
  and stop there; the owner approves the upload. Dev override: env `GOALONG_AMBIANCE_PACK_DIR`
  installs packs from a local folder.
- Download only after an explicit user action. Ephemeral session, no cookies, no cache. Check
  byte size and SHA-256 before install. Install atomically into the app support directory
  (reuse `AppPaths`), folder `Ambiance/<packId>/`. `remove(id)` deletes that folder.
- Document this new external path in `docs/NETWORK.md` ("Intentional external paths") and in
  every inventory or audit that lists network paths (`scripts/generate_security_artifacts.py`).

## The member's own music

- The member picks files or a folder. Store paths only (no copy) in the module's settings.
- Play with `AVAudioFile`/`AVAudioPlayerNode` (streamed from disk). A missing file shows as
  missing; it never crashes or blocks the list.

## API for the UI (no SwiftUI in this task)

Two layers, so reading settings never starts the runtime:

- `AmbianceSettings` (cheap, `UserDefaults`): `isEnabled` (key `goalong.module.ambiance.enabled`,
  default `false`), `volume` (0…1), `ownFiles`, `lastSource`.
- `@MainActor final class AmbianceController: ObservableObject`, created only when the module is
  enabled. It owns an `AmbianceRuntime` (engine + bank) created on `play` and destroyed on `stop`.
  - `state`: `.idle`, `.loading`, `.playing(AmbianceSource)`, `.error(String)` (French message).
  - `sources`: Focus compositions, Relax compositions, installed textures, own files, each with a
    French title and an `isAvailable` flag (pack missing = unavailable).
  - `play(_:)`, `stop()`, `volume`.
  - `packs: [AmbiancePackState]` (id, title, bytes, status `notInstalled | downloading(Double) |
    installed | failed(String)`), `download(_:)`, `cancelDownload(_:)`, `remove(_:)`.
  - `addOwnFiles(_ urls: [URL])`, `removeOwnFile(_:)`.
  - `diagnostics`: mapped bytes, resident bytes, engine running (for tests and support).

## Tests

- Module off: building the app model never creates `AmbianceController`, `AmbianceRuntime`, an
  audio engine or a `URLSession`, and opens no file under `Ambiance/`.
- Pack install rejects a wrong SHA-256 or size, installs atomically, `remove` deletes the folder.
- Offline render (no audio device) of Focus and Relax with a dev pack is not silent; after
  `stop()`, `diagnostics` shows no mapped bank and no running engine.
- All existing checks stay green: the commands in `.github/workflows/macos.yml` and
  `scripts/verify_source_security.sh`.

## Out of scope for v1

Automatic start with work sessions or Jev, Spotify/Music control, attribution tracks, all UI
(page, Settings › Modules toggle, sidebar entry: the owner's design session does these).
