import Darwin
import Foundation
import OndeCore
import OndeDSP

public struct AmbianceRenderMeasure {
    public let seconds: Double
    public let wallSeconds: Double
    public let cpuSeconds: Double
    public let peak: Float
    public let rms: Double
    public let peakResidentBytes: UInt64
    public var percentOfOneCore: Double { cpuSeconds / seconds * 100 }
}

/// One DSP/bank owner, no global cache. Device output exists only after start.
@MainActor public final class AmbianceRuntime {
    private var core: OpaquePointer?
    private var bank: OrchestraBank.Loaded?
    private var output: AmbianceAudioOutput?
    public private(set) var copiedSampleBytes = 0
    /// Set before startOutput; called when the audio device changed and playback stopped.
    var onInterrupted: (() -> Void)?
    /// A verified bank and its DSP, built off the main actor. One owner: either `init(prepared:)` or `discard()`.
    struct PreparedOrchestra: @unchecked Sendable {
        fileprivate let core: OpaquePointer
        fileprivate let bank: OrchestraBank.Loaded
        /// Destroys the DSP first, then the mappings, when the result is no longer wanted.
        func discard() { onde_dsp_destroy(core) }
    }
    /// Hashes and maps the samples: pure I/O, safe to run on any thread, cancellable.
    nonisolated static func prepareOrchestra(source: AmbianceSource, orchestraDirectory: URL) throws -> PreparedOrchestra {
        guard let profile = source.profile else { throw AmbianceError.unavailable }
        let configuration = try profile.configuration.validated()
        guard let candidate = onde_dsp_create(44_100, profile.mode.dspMode, configuration.seed) else { throw AmbianceError.unavailable }
        do {
            let loaded = try OrchestraBank.load(into: candidate, required: true, directory: orchestraDirectory, configuration: configuration)
            for (index, value) in configuration.values.enumerated() {
                onde_dsp_set(candidate, GenerativeSettings.dspIndex(index), Float(value))
            }
            onde_dsp_set(candidate, Int32(ONDE_GAIN), 1)
            return PreparedOrchestra(core: candidate, bank: loaded)
        } catch { onde_dsp_destroy(candidate); throw error }
    }
    init(prepared: PreparedOrchestra) {
        core = prepared.core; bank = prepared.bank; copiedSampleBytes = prepared.bank.copiedBytes
    }
    public convenience init(source: AmbianceSource, orchestraDirectory: URL) throws {
        self.init(prepared: try Self.prepareOrchestra(source: source, orchestraDirectory: orchestraDirectory))
    }
    init(fileURL: URL, looping: Bool, finish: @escaping () -> Void) throws {
        output = try AmbianceAudioOutput(fileURL: fileURL, looping: looping, finish: finish)
    }
    deinit { output?.stop(); if let core { onde_dsp_destroy(core) } }
    public var volume: Double = 1 {
        didSet {
            if let output { output.volume = volume }
            else if let core { onde_dsp_set(core, Int32(ONDE_GAIN), Float(AmbianceSettings.clamp(volume))) }
        }
    }
    func startOutput() throws {
        if output == nil, let core {
            onde_dsp_set(core, Int32(ONDE_GAIN), 1)
            output = AmbianceAudioOutput(core: core)
        }
        guard let output else { throw AmbianceError.unavailable }
        output.interrupted = onInterrupted
        do { try output.start(volume: volume) }
        catch { stop(); throw error }
    }
    public var diagnostics: AmbianceDiagnostics {
        var result = AmbianceDiagnostics()
        result.residentBytes = Self.residentBytes()
        result.runtimeCreated = core != nil || output != nil
        result.engineRunning = output?.running == true
        result.mappedBytes = bank?.mappedBytes ?? 0
        result.copiedSampleBytes = copiedSampleBytes
        return result
    }
    public func stop() {
        onInterrupted = nil
        output?.stop(); output = nil
        if let core { onde_dsp_destroy(core) }
        core = nil; bank = nil; copiedSampleBytes = 0
    }
    public func render(seconds: Double) throws -> AmbianceRenderMeasure {
        guard output == nil, seconds.isFinite, (0.1...10_800).contains(seconds), let core else { throw AmbianceError.unavailable }
        // Allocate scratch once before rendering; the C callback never allocates or locks.
        var left = [Float](repeating: 0, count: 2048), right = left
        let frames = Int(seconds * 44_100), started = ProcessInfo.processInfo.systemUptime, cpu = Self.cpuSeconds()
        var remaining = frames, energy = 0.0, peak: Float = 0
        var peakResident = Self.residentBytes(), sampledSecond = 0
        while remaining > 0 {
            if Task<Never, Never>.isCancelled { throw AmbianceError.cancelled }
            let count = min(2048, remaining)
            onde_dsp_render(core, &left, &right, UInt32(count))
            for i in 0..<count {
                peak = max(peak, abs(left[i]), abs(right[i]))
                energy += Double(left[i]) * Double(left[i]) + Double(right[i]) * Double(right[i])
            }
            remaining -= count
            let second = (frames - remaining) / 44_100
            if second != sampledSecond {
                peakResident = max(peakResident, Self.residentBytes()); sampledSecond = second
            }
        }
        return AmbianceRenderMeasure(seconds: seconds, wallSeconds: ProcessInfo.processInfo.systemUptime - started,
                                     cpuSeconds: Self.cpuSeconds() - cpu, peak: peak, rms: sqrt(energy / Double(frames * 2)),
                                     peakResidentBytes: peakResident)
    }
    nonisolated public static func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? info.resident_size : 0
    }
    private static func cpuSeconds() -> Double {
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }
}
