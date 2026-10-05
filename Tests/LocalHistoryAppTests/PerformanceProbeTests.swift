#if os(macOS)
import Foundation
import XCTest
import LocalHistoryCore
@testable import LocalHistoryApp

/// Opt-in timings on a private COPY of a real data root (the probe writes derived files).
/// GOALONG_PERF_ROOT=<copy> GOALONG_PERF_DAY=yyyy-MM-dd swift test --filter PerformanceProbeTests
final class PerformanceProbeTests: XCTestCase {
    private func setting() throws -> (URL, Date) {
        let environment = ProcessInfo.processInfo.environment
        guard let root = environment["GOALONG_PERF_ROOT"], let dayText = environment["GOALONG_PERF_DAY"] else {
            throw XCTSkip("Set GOALONG_PERF_ROOT (a copy) and GOALONG_PERF_DAY.")
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        return (URL(fileURLWithPath: root, isDirectory: true), try XCTUnwrap(formatter.date(from: dayText)))
    }

    /// CPU seconds used by the whole process: steadier than wall time on a busy machine.
    private func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }

    private func time<T>(_ label: String, _ body: () throws -> T) rethrows -> T {
        let start = ProcessInfo.processInfo.systemUptime, cpu = cpuSeconds()
        let value = try body()
        print(String(format: "PERF %@: %.3f s (cpu %.3f s)", label, ProcessInfo.processInfo.systemUptime - start, cpuSeconds() - cpu))
        return value
    }

    private func peakFootprintMB() -> Double {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
        }
        return result == 0 ? Double(info.ri_lifetime_max_phys_footprint) / 1_048_576 : -1
    }

    /// Bytes in use in malloc (live objects), not the page high-water mark.
    private func footprintMB() -> Double {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return Double(stats.size_in_use) / 1_048_576
    }

    func testActivityMemory() throws {
        let (root, day) = try setting()
        let start = Calendar.current.startOfDay(for: day)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start)!
        let before = footprintMB()
        var loaded: ComputerHistoryEvidenceLoad? = autoreleasepool {
            HistoryLocalStoreReader(rootDirectory: root).loadLocalAnalyticsEvidence(start: start, endExclusive: end)
        }
        let withEvents = footprintMB()
        let built = autoreleasepool { GoalongLocalAnalytics.build(events: loaded!.events, day: day) }
        print("PERF memory: stride=\(MemoryLayout<HistoryEvent>.stride) events=\(loaded!.events.count) held=\(String(format: "%.1f", withEvents - before)) MB")
        loaded = nil
        let afterRelease = footprintMB()
        var days: [GoalongLocalAnalytics.Day] = []
        for offset in 1...6 {
            autoreleasepool { days.append(GoalongLocalAnalytics.load(root: root, day: Calendar.current.date(byAdding: .day, value: -offset, to: day)!)) }
        }
        print("PERF memory: released to \(String(format: "%.1f", afterRelease - before)) MB; 6 cached days=\(String(format: "%.1f", footprintMB() - afterRelease)) MB segments=\(built.segments.count)")
        _ = days.count
    }

    func testActivityDayRead() throws {
        let (root, day) = try setting()
        let today = time("activity day load (selected day)") { GoalongLocalAnalytics.load(root: root, day: day) }
        print("PERF   segments=\(today.segments.count) events=\(today.eventCount) state=\(today.state)")
        let previous = Calendar.current.date(byAdding: .day, value: -1, to: day)!
        _ = time("activity day load (previous day)") { GoalongLocalAnalytics.load(root: root, day: previous) }
        let start = Calendar.current.startOfDay(for: day)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start)!
        let loaded = time("activity evidence read only") {
            HistoryLocalStoreReader(rootDirectory: root).loadLocalAnalyticsEvidence(start: start, endExclusive: end)
        }
        print("PERF   raw=\(loaded.metrics.rawEventCount) retained=\(loaded.events.count) bytes=\(loaded.metrics.eventBytesRead)")
        _ = time("activity build only") { GoalongLocalAnalytics.build(events: loaded.events, day: day) }
    }

    @MainActor func testActivityPage() async throws {
        let (root, day) = try setting()
        for count in [1, 7] {
            let model = GoalongAnalyticsModel(root: root)
            let start = ProcessInfo.processInfo.systemUptime, cpu = cpuSeconds()
            await model.load(day: day, count: count)
            print(String(format: "PERF activity page %d j (cold): %.3f s (cpu %.3f s), peak footprint %.0f MB", count,
                ProcessInfo.processInfo.systemUptime - start, cpuSeconds() - cpu, peakFootprintMB()))
            let again = ProcessInfo.processInfo.systemUptime, againCPU = cpuSeconds()
            await model.load(day: day, count: count)
            print(String(format: "PERF activity page %d j (refresh): %.3f s (cpu %.3f s)", count,
                ProcessInfo.processInfo.systemUptime - again, cpuSeconds() - againCPU))
            let relaunched = GoalongAnalyticsModel(root: root)
            let restart = ProcessInfo.processInfo.systemUptime, restartCPU = cpuSeconds()
            await relaunched.load(day: day, count: count)
            print(String(format: "PERF activity page %d j (relaunch): %.3f s (cpu %.3f s)", count,
                ProcessInfo.processInfo.systemUptime - restart, cpuSeconds() - restartCPU))
            XCTAssertNil(model.error)
            XCTAssertNil(relaunched.error)
            XCTAssertEqual(model.payload?.current, relaunched.payload?.current)
            XCTAssertEqual(model.payload?.previous, relaunched.payload?.previous)
        }
    }

    func testHistoryPage() throws {
        let (root, day) = try setting()
        let store = ComputerHistoryStore(rootDirectory: root,
            codexMemoryDirectory: root.appendingPathComponent("codex-mirror", isDirectory: true))
        _ = time("history stored memory (markdown)") { store.loadStored(for: day) }
        _ = time("history stored memory (page, no markdown)") { store.loadStored(for: day, renderMarkdown: false) }
        let reader = DashboardDataReader(rootDirectory: root)
        let snapshot = time("history dashboard snapshot (cold)") { reader.snapshot(for: day) }
        print("PERF   sessions=\(snapshot.sessions.count)")
        _ = time("history dashboard snapshot (again)") { reader.snapshot(for: day) }
    }

    func testAnalysisFullDay() throws {
        let (root, day) = try setting()
        let start = Calendar.current.startOfDay(for: day)
        let unbounded = ActivityAnalysisDayLoadLimits(maximumRetainedRows: 4_000_000, maximumEstimatedRetainedBytes: 8 << 30)
        let loader = ActivityAnalysisDayLoader(rootDirectory: root, limits: unbounded)
        let before = footprintMB()
        let snapshot = try time("full-day load") { try autoreleasepool { try loader.load(day: start) } }
        print(String(format: "PERF   events=%d semantic=%d bytesRead=%lld live=%.1f MB", snapshot.events.count,
            snapshot.semanticSnapshots.count, snapshot.bytesRead, footprintMB() - before))
        let generatedAt = Date()
        _ = time("engine: activity analysis") { autoreleasepool { ActivityAnalysisEngine.analyze(events: snapshot.events, day: start,
            options: ActivityAnalysisOptions(agentTokenBudget: ActivityAnalysisPreferences.agentTokenBudget), generatedAt: generatedAt) } }
        _ = try time("engine: activity memory") { try autoreleasepool { try DeterministicActivitySummarizer().summarize(ActivitySummaryInput(
            events: snapshot.events, intervalStart: start, intervalEnd: start.addingTimeInterval(86_399.999),
            generatedAt: generatedAt, semanticSnapshots: snapshot.semanticSnapshots)) } }
        _ = time("engine: computer history") { autoreleasepool { ComputerHistoryEngine.analyze(events: snapshot.events,
            semanticSnapshots: snapshot.semanticSnapshots, day: start, priorMemories: [],
            sourceJournalSummary: snapshot.sourceJournalSummary, generatedAt: generatedAt) } }
        print(String(format: "PERF   live after engines=%.1f MB peak=%.0f MB", footprintMB() - before, peakFootprintMB()))
        let store = ComputerHistoryStore(rootDirectory: root, codexMemoryDirectory: root.appendingPathComponent("codex-mirror", isDirectory: true))
        let coordinator = ActivityAnalysisCycleCoordinator(rootDirectory: root, computerHistoryStore: store, dayLoadLimits: unbounded)
        time("full cycle, no ceiling") {
            do {
                let result = try autoreleasepool { try coordinator.process(day: start, tokenBudget: ActivityAnalysisPreferences.agentTokenBudget,
                    forceVerification: true, includeActivityMemory: true) }
                print("PERF   bytesRead=\(result.sourceBytesRead) writes=\(result.derivedViewsWritten)")
            } catch { print("PERF   failed: \(error)") }
        }
        print(String(format: "PERF   peak=%.0f MB", peakFootprintMB()))
    }

    func testAnalysisFullCycleOnly() throws {
        let (root, day) = try setting()
        let start = Calendar.current.startOfDay(for: day)
        let unbounded = ActivityAnalysisDayLoadLimits(maximumRetainedRows: 4_000_000, maximumEstimatedRetainedBytes: 8 << 30)
        let store = ComputerHistoryStore(rootDirectory: root, codexMemoryDirectory: root.appendingPathComponent("codex-mirror", isDirectory: true))
        let coordinator = ActivityAnalysisCycleCoordinator(rootDirectory: root, computerHistoryStore: store, dayLoadLimits: unbounded)
        time("full cycle only, no ceiling") {
            do {
                let result = try autoreleasepool { try coordinator.process(day: start, tokenBudget: ActivityAnalysisPreferences.agentTokenBudget,
                    forceVerification: true, includeActivityMemory: true) }
                print("PERF   bytesRead=\(result.sourceBytesRead) writes=\(result.derivedViewsWritten)")
            } catch { print("PERF   failed: \(error)") }
        }
        print(String(format: "PERF   peak=%.0f MB", peakFootprintMB()))
    }

    /// Highest physical footprint seen by a 5 ms sampler since the last `take()`.
    private final class PeakSampler: @unchecked Sendable {
        private let lock = NSLock()
        private var peak: UInt64 = 0
        private var running = true

        init() {
            Thread { [weak self] in
                while let self, self.isRunning {
                    self.note(); usleep(5_000)
                }
            }.start()
        }

        private var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }
        func stop() { lock.lock(); running = false; lock.unlock() }

        static func footprint() -> UInt64 {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                }
            }
            return result == KERN_SUCCESS ? info.phys_footprint : 0
        }

        private func note() {
            let now = Self.footprint()
            lock.lock(); peak = max(peak, now); lock.unlock()
        }

        func take(_ label: String) {
            note()
            lock.lock(); let value = peak; peak = 0; lock.unlock()
            print(String(format: "PERF   %@: peak %.0f MB, now %.0f MB", label,
                Double(value) / 1_048_576, Double(Self.footprint()) / 1_048_576))
        }
    }

    func testAnalysisPhaseMemory() throws {
        let (root, day) = try setting()
        let start = Calendar.current.startOfDay(for: day)
        let sampler = PeakSampler()
        defer { sampler.stop() }
        sampler.take("baseline")
        let priorStore = ComputerHistoryStore(rootDirectory: root, codexMemoryDirectory: root.appendingPathComponent("codex-mirror", isDirectory: true))
        let prior = autoreleasepool { priorStore.loadRecent(maximumDays: 32, renderMarkdown: false).memories.filter { $0.dayStart < start } }
        sampler.take("prior memories (\(prior.count) days)")
        let unbounded = ActivityAnalysisDayLoadLimits(maximumRetainedRows: 4_000_000, maximumEstimatedRetainedBytes: 8 << 30)
        let snapshot = try autoreleasepool { try ActivityAnalysisDayLoader(rootDirectory: root, limits: unbounded).load(day: start) }
        sampler.take("load")
        let generatedAt = Date()
        ActivitySemanticTextSanitizer.withMemo {
            _ = autoreleasepool { ActivityAnalysisEngine.analyze(
                events: snapshot.events.map {
                    ActivityAnalysisCycleCoordinator.eventByResolvingSemanticContext($0, semanticSnapshots: snapshot.semanticSnapshots)
                },
                day: start, options: ActivityAnalysisOptions(agentTokenBudget: ActivityAnalysisPreferences.agentTokenBudget),
                generatedAt: generatedAt) }
            sampler.take("activity analysis")
            let memory = autoreleasepool { ComputerHistoryEngine.analyze(events: snapshot.events,
                semanticSnapshots: snapshot.semanticSnapshots, day: start, priorMemories: prior,
                sourceJournalSummary: snapshot.sourceJournalSummary, generatedAt: generatedAt) }
            sampler.take("computer history")
            let store = ComputerHistoryStore(rootDirectory: root, codexMemoryDirectory: root.appendingPathComponent("codex-mirror", isDirectory: true))
            _ = try? autoreleasepool { try store.write(memory, for: start) }
            sampler.take("computer history write")
        }
    }

    func testAnalysisCycle() throws {
        let (root, day) = try setting()
        let mirror = root.appendingPathComponent("codex-mirror", isDirectory: true)
        let store = ComputerHistoryStore(rootDirectory: root, codexMemoryDirectory: mirror)
        _ = time("computer history loadRecent 32 j (markdown)") { store.loadRecent(maximumDays: 32) }
        _ = time("computer history loadRecent 32 j (no markdown)") {
            store.loadRecent(maximumDays: 32, renderMarkdown: false)
        }
        let coordinator = ActivityAnalysisCycleCoordinator(rootDirectory: root, computerHistoryStore: store)
        for pass in 1...2 {
            time("analysis cycle pass \(pass)") {
                do {
                    let result = try coordinator.process(day: day, tokenBudget: ActivityAnalysisPreferences.agentTokenBudget,
                        forceVerification: false, includeActivityMemory: true)
                    print("PERF   bytesRead=\(result.sourceBytesRead) writes=\(result.derivedViewsWritten)")
                } catch {
                    print("PERF   failed: \(error)")
                }
            }
        }
    }
}
#endif
