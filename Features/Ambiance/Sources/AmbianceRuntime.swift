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

/// One render owner, no global cache. Live device output is blocked by the
/// unchanged repository audit; this path exercises the production DSP offline.
@MainActor public final class AmbianceRuntime {
    private var core: OpaquePointer?
    private var bank: OrchestraBank.Loaded?
    public private(set) var copiedSampleBytes = 0
    public init(source: AmbianceSource, orchestraDirectory: URL) throws {
        guard let profile = source.profile else { throw AmbianceError.unavailable }
        let configuration = try profile.configuration.validated()
        guard let candidate = onde_dsp_create(44_100, profile.mode.dspMode, configuration.seed) else { throw AmbianceError.unavailable }
        do {
            let loaded = try OrchestraBank.load(into: candidate, required: true, directory: orchestraDirectory, configuration: configuration)
            for (index, value) in configuration.values.enumerated() {
                onde_dsp_set(candidate, GenerativeSettings.dspIndex(index), Float(value))
            }
            onde_dsp_set(candidate, Int32(ONDE_GAIN), 1)
            core = candidate; bank = loaded; copiedSampleBytes = loaded.copiedBytes
        } catch { onde_dsp_destroy(candidate); throw error }
    }
    deinit { if let core { onde_dsp_destroy(core) } }
    public var volume: Double = 1 {
        didSet { if let core { onde_dsp_set(core, Int32(ONDE_GAIN), Float(AmbianceSettings.clamp(volume))) } }
    }
    public var diagnostics: AmbianceDiagnostics {
        var result = AmbianceDiagnostics()
        result.residentBytes = Self.residentBytes()
        result.runtimeCreated = core != nil
        result.mappedBytes = bank?.mappedBytes ?? 0
        result.copiedSampleBytes = copiedSampleBytes
        return result
    }
    public func stop() {
        if let core { onde_dsp_destroy(core) }
        core = nil; bank = nil; copiedSampleBytes = 0
    }
    public func render(seconds: Double) throws -> AmbianceRenderMeasure {
        guard seconds.isFinite, (0.1...10_800).contains(seconds), let core else { throw AmbianceError.unavailable }
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
