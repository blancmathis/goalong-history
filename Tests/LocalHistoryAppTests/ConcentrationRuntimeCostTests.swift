#if os(macOS)
import XCTest
@testable import LocalHistoryApp

/// Same getrusage method/cadence as BlockingRuntimeCostTests; no AX read or permission.
final class ConcentrationRuntimeCostTests: XCTestCase {
    func testDetectionCPUCost() throws {
        guard ProcessInfo.processInfo.environment["GOALONG_FOCUS_COST"] != nil else { throw XCTSkip("Opt-in local CPU measurement") }
        var detection = FocusDetection(), now = Date()
        let count = 12000, cadence = 0.75
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        let before = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
        for n in 0..<count {
            now = now.addingTimeInterval(cadence)
            _ = detection.observe(.init(at: now, input: n % 20 != 0, context: "\(n / 500)", verdict: n % 3000 > 2900 ? .other : nil))
        }
        getrusage(RUSAGE_SELF, &usage)
        let after = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
        let ms = (after - before) / Double(count) * 1000
        print(String(format: "FOCUS_COST detection cpu=%.6f ms/sample cadence=%.2f s core=%.6f%% samples=%d", ms, cadence, ms / (cadence * 1000) * 100, count))
        XCTAssertLessThan(ms / (cadence * 1000) * 100, 0.1)
    }
}
#endif
