#if os(macOS)
import Foundation
import XCTest

/// T-044 r5: blocking and stake decisions read the trusted clock (`BlockingController.now`, `stakeNow()`).
/// A raw wall-clock read in Blocking/ or Concentration/ must say why with `// wall: <reason>`.
final class TrustedClockSourceGuardTests: XCTestCase {
    private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/LocalHistoryApp")

    private func hits(in folders: [String], patterns: [String], unless marker: String? = nil) throws -> [String] {
        let regexes = try patterns.map { try NSRegularExpression(pattern: $0) }
        var hits: [String] = [], count = 0
        for folder in folders {
            let files = FileManager.default.enumerator(at: root.appendingPathComponent(folder), includingPropertiesForKeys: nil)!
                .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
            count += files.count
            for file in files {
                for (i, line) in try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n").enumerated()
                where !line.trimmingCharacters(in: .whitespaces).hasPrefix("//")
                    && regexes.contains(where: { $0.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil })
                    && !(marker.map(line.contains) ?? false) {
                    hits.append("\(folder)/\(file.lastPathComponent):\(i + 1)")
                }
            }
        }
        XCTAssertGreaterThan(count, 10)
        return hits
    }

    func testRawWallClockReadsSayWhy() throws {
        let raw = ["\\bDate\\(\\)", "\\bDate\\.now\\b", "\\bDate\\.init\\b", "timeIntervalSinceNow", "\\bwallClock\\(\\)"]
        XCTAssertEqual(try hits(in: ["Blocking", "Concentration"], patterns: raw, unless: "// wall:"), [])
    }

    func testStakeDecisionsDoNotReadTheRawClock() throws {
        let raw = ["FocusCommitRule\\.check\\([^)]*now: clock\\(\\)", "FocusCommitmentRules\\.exitOpen\\([^)]*now: clock\\(\\)",
                   "\\bend\\s*[<>]=?\\s*clock\\(\\)", "clock\\(\\)\\s*[<>]=?\\s*[\\w.]*\\bend\\b", "activeBlocks.*\\bclock\\(\\)"]
        XCTAssertEqual(try hits(in: ["Concentration"], patterns: raw), [])
    }

    func testBlockingClockIsTheTrustedClock() throws {
        let source = try String(contentsOf: root.appendingPathComponent("Blocking/BlockingController.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("BlockingClock.trusted(wall: wallClock()"), "BlockingController.clock() no longer reads the trusted clock")
        XCTAssertFalse(source.contains("let clock: () -> Date"), "BlockingController stores a raw clock again")
    }
}
#endif
