# Ambiance — audio output and pack download (owner decision, 2026-10-04)

The owner approved two narrow exceptions to `scripts/audit_privacy_boundaries.sh`, so that
Ambiance can play sound and download its packs. Every other rule of the audits stays as it
is, or becomes stricter. Read `docs/AMBIANCE.md` (spec) and `docs/AMBIANCE-IMPLEMENTATION.md`
(what exists, API, blocked rules) first.

## 1. Audio output, never input

- `AVAudioEngine` and its output-side types (`AVAudioSourceNode`, `AVAudioPlayerNode`,
  `AVAudioMixerNode`, `AVAudioFile`, `AVAudioPCMBuffer`) are allowed in exactly one file under
  `Features/Ambiance/Sources/`, for example `AmbianceAudioOutput.swift`. The audit allowlists
  this one path for `AVAudioEngine`. `AudioUnitRender`, `AudioDeviceStart`,
  `AudioDeviceCreateIOProcID` and `AudioHardwareCreateProcessTap` stay forbidden everywhere.
- New rules, enforced everywhere, the allowed file included: reject `inputNode`,
  `AVAudioInputNode`, `installTap`, `AVAudioRecorder`, `AVCaptureDevice`, `AudioQueueNewInput`,
  `kAudioOutputUnitProperty_EnableIO`, `requestRecordPermission`, `recordPermission`.
  Reject `NSMicrophoneUsageDescription` in the Info.plist builders, and
  `com.apple.security.device.audio-input` or `com.apple.security.device.microphone` in any
  entitlements file. Prove each new rule with a negative fixture: the audit fails on it.
- The engine exists only while something plays. Play creates it. Stop stops it, detaches the
  nodes and releases it. Module off: no engine, ever.
- The member's own music plays through the same file and streams from disk with `AVAudioFile`
  (no full decode in memory, no copy of the file).
- Measure real playback on the default output device (production code, not offline render):
  RAM before play, peak, after stop, and CPU of one core during 300 s, for Ambre and
  Confluence and for one personal file. Budget: +90 MB at most while playing, back within
  5 MB of the start value after stop.

## 2. Pack download

- `URLSession` is allowed in exactly one more file, for example
  `Features/Ambiance/Sources/AmbiancePackDownloader.swift`. Add it to the allowlist next to
  the site and Jev files, and to every inventory of network emitters
  (`scripts/audit_site_submission.py` if it lists them, `scripts/generate_security_artifacts.py`,
  regenerated artifacts).
- HTTPS `GET` only, to `https://github.com/blancmathis/goalong-history/releases/download/ambiance-packs-v1/<asset>`
  and to the host GitHub currently uses for release-asset redirects (check which one today).
  Refuse any other host, also on redirect.
- `URLSessionConfiguration.ephemeral`: no cookies, no cache, no credentials, no custom header,
  no identifier of the member or of the Mac. Goalong never builds or changes a query string.
- GitHub's signed redirect (clarified 2026-10-04): GitHub answers the release URL with a 302
  to `release-assets.githubusercontent.com` whose query is GitHub's own short-lived signature
  (`jwt`, `sig`, …). The downloader follows exactly this one redirect, with the query exactly
  as GitHub sent it, and only when: the first request is the catalog URL on `github.com` with
  no query; the target is `https://release-assets.githubusercontent.com` on port 443; it is the
  only redirect; the request stays a plain `GET` from the ephemeral session. Refuse a query on
  `github.com`, any other host, a second redirect. Never log, store or show the signed URL
  (errors name the pack, not the URL).
- A download starts only from an explicit member action (one call from the UI). Never at
  launch, at module activation, on a timer or in the background. No silent retry loop.
- Before unpacking, check the size and SHA-256 against the catalog compiled into the app.
  On mismatch, delete the file and report an error.
- The reserved URLs become the active path: update `docs/NETWORK.md` ("Intentional external
  paths") and `docs/GUARANTEES.md`.

## 3. Permissions

- Ambiance asks for no permission: not at onboarding, not when the module is turned on, not
  on Play. Sound output needs none. The microphone is never used.
- The member's own music is chosen with the system file picker (`NSOpenPanel`), only when the
  member asks. If macOS later shows its own folder prompt (Documents, Downloads, Desktop) when
  that music plays, this is acceptable; Goalong never triggers a prompt by itself.
- No Full Disk Access, no Apple Music library (no MediaPlayer, no MusicKit,
  no `NSAppleMusicUsageDescription`).
- `docs/PERMISSIONS.md` and `docs/GUARANTEES.md` state it in the member's words: Goalong can
  play music; it never listens.
