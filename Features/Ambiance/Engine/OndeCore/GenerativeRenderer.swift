import Foundation
import AVFoundation
import OndeDSP

/// The offline exporter uses the exact same oscillator, sequencer and reverb as
/// the app, not a separate approximation. Identical seed/config/sample rate ->
/// identical newly-started render. Uses verified bundled CC0 notes for orchestral profiles; never reads personal imports.
public enum GenerativeRenderer {
    public static func render(mode: SessionMode, configuration: GenerativeSettings,
                              seconds: Double, path: String, orchestraDirectory: URL? = nil) throws -> [String: Any] {
        let config = try configuration.validated()
        guard seconds.isFinite, seconds >= 1, seconds <= 10_800 else {
            throw OndeError("invalid_duration", "Duration must be 1...10800 seconds (up to 3 hours per WAV).")
        }
        let url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
        guard path.hasPrefix("/") || path.hasPrefix("~/"), url.pathExtension.lowercased() == "wav" else {
            throw OndeError("invalid_path", "Provide an absolute destination ending in .wav.")
        }
        guard !FileManager.default.fileExists(atPath: url.path) else { throw OndeError("file_exists", "Destination already exists; choose another name.") }
        let parent = url.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: parent.path) else { throw OndeError("missing_directory", "Destination directory must already exist.") }
        let temp = parent.appendingPathComponent(".onde-render-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: temp) }
        let sr: Double = 44_100
        guard let dsp = onde_dsp_create(sr, mode.dspMode, config.seed) else { throw OndeError("generator_init_failed", "Could not allocate the synthesis core.") }
        defer { onde_dsp_destroy(dsp) }
        let bank = try OrchestraBank.load(into: dsp, required: true, directory: orchestraDirectory, configuration: config)
        defer { withExtendedLifetime(bank) {} }
        if config.piano>0 && (onde_dsp_orchestra_families(dsp)&2048)==0 {throw OndeError("piano_missing", "Install the complete acoustic bank for piano compositions.")}
        for (index, value) in config.values.enumerated() { onde_dsp_set(dsp, GenerativeSettings.dspIndex(index), Float(value)) }
        onde_dsp_set(dsp, Int32(ONDE_GAIN), 1)
        let format = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sr,
                                       AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 16,
                                       AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        let total = Int64((seconds * sr).rounded())
        let start = ProcessInfo.processInfo.systemUptime
        var peak: Float = 0; var energy: Double = 0
        do {
            let file = try AVAudioFile(forWriting: temp, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2048)!
            let channels = buffer.floatChannelData!
            var written: Int64 = 0
            while written < total {
                let count = UInt32(min(2048, total - written))
                buffer.frameLength = count
                onde_dsp_render(dsp, channels[0], channels[1], count)
                for i in 0..<Int(count) {
                    let remaining = Double(total - written - Int64(i)) / sr
                    let endFade = Float(min(1, max(0, remaining / min(4, seconds * 0.2))))
                    let gain = endFade * endFade * (3 - 2 * endFade)
                    for channel in 0..<2 {
                        channels[channel][i] *= gain
                        let v = channels[channel][i]; peak = max(peak, abs(v)); energy += Double(v * v)
                    }
                }
                try file.write(from: buffer); written += Int64(count)
            }
        }
        // moveItem refuses replacement if another process created the path meanwhile.
        try FileManager.default.moveItem(at: temp, to: url)
        let result: [String: Any] = ["path": url.path, "seconds": seconds, "sample_rate": sr,
                                     "mode": mode.rawValue, "seed": config.seed, "configuration": jsonObject(config),
                                     "engine": "onde-living-7", "channels": 2, "bit_depth": 16,
                                     "render_wall_seconds": ProcessInfo.processInfo.systemUptime - start,
                                     "peak": peak, "rms": sqrt(energy / Double(total * 2)),
                                     "scheduled_events": onde_dsp_events(dsp), "license": "CC0-1.0",
                                     "audio_origin": "local_generation", "phrase_index": onde_dsp_phrase(dsp), "chapter_index": onde_dsp_chapter(dsp), "phrase_fingerprint": String(onde_dsp_plan_hash(dsp)), "composition_id": config.composition, "vocal_source": config.vocals > 0 ? "original_synthesized_vowels" : "none", "sample_based": config.orchestra>0, "orchestra_samples": onde_dsp_orchestra_samples(dsp), "orchestra_events": onde_dsp_orchestra_events(dsp), "sample_license":"CC0-1.0"]
        // Sidecar only when free; never overwrite an existing user's manifest.
        let manifest = url.appendingPathExtension("json")
        if !FileManager.default.fileExists(atPath: manifest.path) { try? jsonData(result, pretty: true).write(to: manifest, options: .withoutOverwriting) }
        return result
    }
}
