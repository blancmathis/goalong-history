# Goalong integration of Onde

Upstream revision is in `SOURCE_COMMIT`. The C engine, settings, compositions,
offline renderer, transition renderer and playback-selection policy are vendored;
there is no remote Swift package. Only the rendering types were extracted from
`Models.swift`. The upstream notices are retained verbatim; their references to
Kevin MacLeod recordings and Onde application assets describe upstream Onde.
Those recordings, assets, updater, IPC, Espace and activity files are absent here.

Goalong adaptations:

- `OrchestraBank` has no global decoded cache or bundle lookup. Callers provide an
  installed pack directory. The score determines the instrument families to map.
- Each sample is size-bounded and checksum-verified through 64 KiB reads, then
  mapped read-only with POSIX `mmap`. The manifest uses `Data(..., .alwaysMapped)`.
  WAV parsing accepts only bounded stereo PCM16 with the declared rate and frames.
- `onde_dsp_add_pcm16_sample` adds a borrowed sample descriptor before the first
  render. Cubic interpolation performs the same PCM16-to-float normalization as
  the upstream AVFoundation decoder. The copy-based API remains available.
- The Swift runtime retains every mapping until after it destroys its DSP.
  There is no sample-data copy, render-thread allocation or render-thread lock.
  The upstream sampler remains responsible for scheduling, envelopes and mixing.
- Offline exporters explicitly retain bank mappings through their final render.
  They accept a pack directory and never search the application bundle.
- The two upstream WAV exporters and unused playback-selection helper remain
  vendored for provenance but are excluded from the private OndeCore target:
  no Goalong caller uses them, and Ambiance's
  public offline diagnostic renders directly through its runtime. This avoids
  linking unused export/transition code while preserving the documented UI API.
- Goalong does not serialize engine configurations or expose Onde's legacy profile
  catalog/CLI controls. Their unused Codable conformances, JSON helpers and legacy
  presets are removed from the compiled engine. All fifteen Focus/Relax profiles,
  their rendering values, seeds and validation remain unchanged. Module settings
  still persist through `AmbianceSettings`; pack receipts retain their JSON format.
- The 2026-10-04 owner decision permits device output and explicit pack downloads
  in two isolated files, with stricter microphone guards; see
  [`AMBIANCE-IMPLEMENTATION.md`](../../../docs/AMBIANCE-IMPLEMENTATION.md).

The focused tests compare PCM16 mapping against the original decoded sampler,
including audible acoustic events, and cover all Focus/Relax composition renders.
