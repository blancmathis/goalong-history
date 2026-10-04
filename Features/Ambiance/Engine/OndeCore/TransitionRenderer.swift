import Foundation
import AVFoundation
import OndeDSP

/// An audition of the production crossfader, not a post-edited audio concatenation.
public enum TransitionRenderer {
    public static func render(from: SoundProfile, to: SoundProfile, seconds: Double, at: Double, fade: Double, path: String, orchestraDirectory: URL? = nil) throws -> [String: Any] {
        guard seconds.isFinite, (15...300).contains(seconds), at.isFinite, at >= 3,
              fade.isFinite, (2...30).contains(fade), at + fade + 5 <= seconds else {
            throw OndeError("invalid_transition", "Use 15...300 seconds; start >= 3; fade 2...30; allow 5 seconds after the transition.")
        }
        guard path.hasPrefix("/"), URL(fileURLWithPath: path).pathExtension.lowercased() == "wav" else { throw OndeError("invalid_path", "Use a new absolute WAV path.") }
        let url = URL(fileURLWithPath: path), fm = FileManager.default
        guard !fm.fileExists(atPath: path) else { throw OndeError("file_exists", "The destination already exists.") }
        let temp = url.deletingLastPathComponent().appendingPathComponent(".onde-transition-\(UUID().uuidString).wav")
        defer { try? fm.removeItem(at: temp) }
        let sr = 44100.0
        var banks: [OrchestraBank.Loaded] = []
        defer { withExtendedLifetime(banks) {} }
        func scene(_ profile: SoundProfile) throws -> OpaquePointer {
            let c = try profile.configuration.validated()
            guard let core = onde_dsp_create(sr, profile.mode.dspMode, c.seed) else { throw OndeError("generator_init_failed", "Scene allocation failed.") }
            do {
                let bank = try OrchestraBank.load(into: core, required: true, directory: orchestraDirectory, configuration: c)
                banks.append(bank)
                for (i, v) in c.values.enumerated() { onde_dsp_set(core, GenerativeSettings.dspIndex(i), Float(v)) }
                onde_dsp_set(core, Int32(ONDE_GAIN), 1)
                var l = [Float](repeating: 0, count: 1024), r = l
                var remaining = Int((240 / c.tempo * sr).rounded(.up))
                while remaining > 0 { let n = min(1024, remaining); onde_dsp_render(core, &l, &r, UInt32(n)); remaining -= n }
                return core
            } catch { onde_dsp_destroy(core); throw error }
        }
        guard let mixer = onde_scene_mixer_create(sr) else { throw OndeError("generator_init_failed", "Mixer allocation failed.") }
        defer { onde_scene_mixer_destroy(mixer) }
        let first = try scene(from)
        guard onde_scene_mixer_submit(mixer, first, fade) == 1 else { onde_dsp_destroy(first); throw OndeError("generator_init_failed", "Scene submission failed.") }
        var next: OpaquePointer? = try scene(to)
        defer { if let next { onde_dsp_destroy(next) } }
        onde_scene_mixer_gain(mixer, 1)
        let total = Int64(seconds * sr), switchAt = Int64(at * sr)
        var peak: Float = 0, energy = 0.0, begun: Double?
        do {
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sr, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
            let file = try AVAudioFile(forWriting: temp, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let format = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2048)!, channels = buffer.floatChannelData!
            var written: Int64 = 0
            while written < total {
                if written >= switchAt, let candidate = next {
                    guard onde_scene_mixer_submit(mixer, candidate, fade) == 1 else { throw OndeError("generator_init_failed", "Transition submission failed.") }; next = nil
                }
                var n = min(Int64(2048), total - written)
                if written < switchAt { n = min(n, switchAt - written) }
                buffer.frameLength = UInt32(n)
                onde_scene_mixer_render(mixer, channels[0], channels[1], UInt32(n))
                if begun == nil && onde_scene_mixer_state(mixer) == 2 { begun = Double(written) / sr }
                for i in 0..<Int(n) {
                    let x = Float(min(1, Double(total - written - Int64(i)) / (sr * 2)))
                    let g = x*x*(3-2*x)
                    for c in 0..<2 { channels[c][i] *= g; let v = channels[c][i]; peak = max(peak, abs(v)); energy += Double(v*v) }
                }
                try file.write(from: buffer); written += n; onde_scene_mixer_collect(mixer)
            }
        }
        try fm.moveItem(at: temp, to: url)
        let result: [String: Any] = ["path": path, "seconds": seconds, "from": from.id, "to": to.id, "fade_seconds": fade,
            "requested_at": at, "transition_began_at": begun as Any? ?? NSNull(), "peak": peak,
            "rms": sqrt(energy/Double(total*2)), "engine": "onde-living-7", "mixer": "production_scene_mixer", "license": "CC0-1.0"]
        try? jsonData(result, pretty: true).write(to: url.appendingPathExtension("json"), options: .withoutOverwriting)
        return result
    }
}
