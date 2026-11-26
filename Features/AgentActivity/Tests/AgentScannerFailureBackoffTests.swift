import XCTest
@testable import AgentActivity

/// T-057 D1 §3: a source that keeps failing must not be re-read on every 30 s analysis scan, and
/// must not write an error log line for every scan and every status text built from the failure.
final class AgentScannerFailureBackoffTests: XCTestCase {
    func testPermanentlyFailingSourceLogsOnceAndBacksOffDuringAnalysisScans() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-scanner-backoff-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("source", isDirectory: true)
        let file = source.appendingPathComponent("session.jsonl")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("{\"type\":\"message\",\"text\":\"a\"}\n".utf8).write(to: file)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            try? FileManager.default.removeItem(at: root)
        }
        let store = try AgentActivityStore(rootDirectory: root.appendingPathComponent("store", isDirectory: true))
        let folder = AgentWatchedFolder(id: "backoff", displayName: "Backoff", path: source.path, provider: .custom)
        let configuration = AgentActivityConfiguration(watchedFolders: [folder])
        let scanner = AgentActivityScanner(store: store)
        let start = Date()

        _ = scanner.scan(configuration: configuration, forceFullDiscovery: true, at: start)
        XCTAssertEqual(store.entries().first?.availability, .available)
        XCTAssertEqual(scanner.loggedScanFailureCountForTesting(), 0)

        // The source changes, then becomes unreadable for good.
        try Data("{\"type\":\"message\",\"text\":\"a\"}\n{\"type\":\"message\",\"text\":\"bb\"}\n".utf8)
            .write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)

        var reads = 0
        var failingScans = 0
        for step in 1...10 {
            let result = scanner.scan(
                configuration: configuration,
                analyzeContent: true,
                at: start.addingTimeInterval(Double(step) * 5)
            )
            if !result.failures.isEmpty { failingScans += 1 }
            let metrics = scanner.cycleMetricsForTesting()
            reads += metrics.metadataResolutionCount + metrics.sourceBodyReadCount
        }

        XCTAssertNotEqual(store.entries().first?.availability, .available)
        XCTAssertGreaterThanOrEqual(failingScans, 1)
        XCTAssertLessThanOrEqual(failingScans, 2, "failing source retried on \(failingScans) of 10 scans")
        // First failing read (metadata + body) + at most one retry within `unavailableSourceRetrySeconds` (60 s).
        XCTAssertLessThanOrEqual(reads, 3, "failing source re-read \(reads) times in 50 s")
        XCTAssertEqual(scanner.loggedScanFailureCountForTesting(), 1, "one error line per failing source")
    }
}
