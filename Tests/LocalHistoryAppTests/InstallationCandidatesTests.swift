#if os(macOS)
import Foundation
import XCTest
@testable import LocalHistoryApp

/// Where a Goalong copy may already live: every place is checked once, in a stable order.
final class InstallationCandidatesTests: XCTestCase {
    private struct Running: RunningInstance {
        var isTerminated = false
        var bundleURL: URL?
        func terminate() -> Bool { true }
    }

    func testCandidatesListDestinationBothApplicationsFoldersAndRunningCopiesWithoutDuplicates() {
        let destination = URL(fileURLWithPath: "/Applications/Goalong History.app", isDirectory: true)
        let volume = URL(fileURLWithPath: "/Volumes/Goalong/Goalong History.app", isDirectory: true)
        let found = InstallationLocationManager.existingCandidates(
            destination: destination,
            running: [Running(bundleURL: volume), Running(bundleURL: destination), Running(bundleURL: nil)])
        XCTAssertEqual(found.first, destination.standardizedFileURL, "The chosen destination comes first")
        XCTAssertEqual(found.count, Set(found.map(\.path)).count, "No path is listed twice")
        XCTAssertTrue(found.contains(volume.standardizedFileURL), "A running copy is a candidate")
        XCTAssertTrue(found.contains { $0.path.hasSuffix("/Applications/Goalong History.app") && $0.path.hasPrefix(NSHomeDirectory()) },
                      "The user's Applications folder is checked")
        XCTAssertEqual(found.count, 3)
    }

    func testStandardizedPathsMergeEquivalentSpellings() {
        let destination = URL(fileURLWithPath: "/Applications/./Goalong History.app", isDirectory: true)
        let found = InstallationLocationManager.existingCandidates(destination: destination, running: [])
        XCTAssertEqual(found.filter { $0.path == "/Applications/Goalong History.app" }.count, 1)
    }

    func testNoCopyAnywhereMeansReplace() {
        let source = URL(fileURLWithPath: "/nonexistent/source.app")
        let candidates = [URL(fileURLWithPath: "/nonexistent/a.app"), URL(fileURLWithPath: "/nonexistent/b.app")]
        let (decision, shown) = InstallationLocationManager.aggregateDecision(source: source, candidates: candidates)
        XCTAssertEqual(decision, .replace)
        XCTAssertNil(shown)
    }
}
#endif
