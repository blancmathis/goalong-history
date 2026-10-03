import Darwin
import Foundation
import XCTest
@testable import LocalHistoryCore

/// Opt-in, cloning the supplied private copy again before appending synthetic rows.
final class GoalongLocalAnalyticsFoldPerformanceTests: XCTestCase {
    func testPerformanceFoldStateAndRefresh() throws {
        let env = ProcessInfo.processInfo.environment
        guard let sourcePath = env["GOALONG_PERF_ROOT"], let dayText = env["GOALONG_PERF_DAY"] else {
            throw XCTSkip("Set GOALONG_PERF_ROOT (a private copy) and GOALONG_PERF_DAY.")
        }
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        let day = try XCTUnwrap(formatter.date(from: dayText))
        let horizon = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: day))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("goalong-fold-perf-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("events"), withIntermediateDirectories: true)
        let file = root.appendingPathComponent("events/\(dayText).jsonl")
        let source = URL(fileURLWithPath: sourcePath).appendingPathComponent("events/\(dayText).jsonl")
        guard copyfile(source.path, file.path, nil, copyfile_flags_t(COPYFILE_DATA | COPYFILE_CLONE)) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        func cpu() -> Double {
            var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
            return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
                + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        }
        func liveMB() -> Double {
            var stats = malloc_statistics_t(); malloc_zone_statistics(nil, &stats)
            return Double(stats.size_in_use) / 1_048_576
        }
        func timed<T>(_ label: String, _ body: () throws -> T) rethrows -> T {
            let wall = ProcessInfo.processInfo.systemUptime, before = cpu()
            let result = try body()
            print(String(format: "PERF %@ %@: %.3f s (cpu %.3f s)", env["GOALONG_PERF_LABEL"] ?? "fold", label,
                ProcessInfo.processInfo.systemUptime - wall, cpu() - before))
            return result
        }
        let before = liveMB()
        let state = try timed("initial state") {
            try autoreleasepool {
                let load = GoalongLocalAnalytics.load(root: root, day: day, resuming: nil, now: horizon)
                XCTAssertEqual(load.day.state, .ready)
                return try XCTUnwrap(load.state)
            }
        }
        print(String(format: "PERF %@ state: %.2f MB live; retained rows=%d; total rows=%d",
            env["GOALONG_PERF_LABEL"] ?? "fold", liveMB() - before, state.events.count,
            state.cursor?.files.reduce(0, { $0 + $1.retainedEventCount }) ?? -1))
        _ = timed("unchanged refresh") {
            autoreleasepool { GoalongLocalAnalytics.load(root: root, day: day, resuming: state, now: horizon) }
        }
        let latest = try XCTUnwrap(state.events.map(\.timestamp).max())
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        var extra = Data(), index = 0
        while extra.count < 1_048_576 {
            let event = HistoryEvent(id: "fold-perf-\(index)", sessionID: "perf",
                timestamp: min(latest.addingTimeInterval(Double(index % 300)), horizon.addingTimeInterval(-1)),
                kind: .heartbeat, app: .init(name: "Perf", bundleIdentifier: "fixture.perf", processIdentifier: 1),
                window: .init(title: "Synthetic appended activity", role: nil, subrole: nil), metadata: ["idle_seconds": "0"])
            extra.append(try encoder.encode(event)); extra.append(0x0A); index += 1
        }
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd(); try handle.write(contentsOf: extra); try handle.close()
        let resumed = timed("refresh after 1 MiB append") {
            autoreleasepool { GoalongLocalAnalytics.load(root: root, day: day, resuming: state, now: horizon) }
        }
        let full = timed("full after 1 MiB append") {
            autoreleasepool { GoalongLocalAnalytics.load(root: root, day: day, resuming: nil, now: horizon) }
        }
        XCTAssertTrue(resumed.didResume)
        XCTAssertEqual(resumed.day, full.day)
        XCTAssertEqual(resumed.eventBytesRead, Int64(extra.count))
        print("PERF append bytes=\(resumed.eventBytesRead) full bytes=\(full.eventBytesRead) added rows=\(index)")
    }
}
