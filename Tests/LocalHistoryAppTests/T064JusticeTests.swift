#if os(macOS)
    import Foundation
    import LocalHistoryCore
    import XCTest

    @testable import LocalHistoryApp

    final class T064JusticeTests: XCTestCase {
        func testBrowserDetectionMatchesWholeWordsOnly() {
            for name in ["Archive Utility", "Adobe Media Encoder", "Knowledge Base", "File Browser", "Diagrams", "Parcel"] {
                XCTAssertFalse(UsageBreakdownProjection.isBrowserName(name), name)
            }
            for name in ["Arc", "Dia", "Microsoft Edge", "Google Chrome", "Zen Browser", "Safari", "Brave Browser"] {
                XCTAssertTrue(UsageBreakdownProjection.isBrowserName(name), name)
            }
        }

        func testLegacyMergeKeepsLinesAppendedWhileTheFolderIsLocked() throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("t064-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let max = 1_000_000
            try GoalongSystemSourceFiles.write(Data("a\n".utf8), root: root, folder: "calls", name: "2026-11-15.jsonl", maximumBytes: max)
            let appended = expectation(description: "appended")
            try GoalongSystemSourceFiles.withFolderLock(root: root, folder: "calls") {
                DispatchQueue.global().async {
                    try? GoalongSystemSourceFiles.write(
                        Data("late\n".utf8), root: root, folder: "calls", name: "2026-11-15.jsonl", append: true, maximumBytes: max)
                    appended.fulfill()
                }
                Thread.sleep(forTimeInterval: 0.3)
                // The concurrent append is still waiting: the locked cycle sees the file unchanged.
                let seen = try XCTUnwrap(try GoalongSystemSourceFiles.read(root: root, folder: "calls", name: "2026-11-15.jsonl", maximumBytes: max))
                XCTAssertEqual(String(decoding: seen, as: UTF8.self), "a\n")
            }
            wait(for: [appended], timeout: 5)
            let final = try XCTUnwrap(try GoalongSystemSourceFiles.read(root: root, folder: "calls", name: "2026-11-15.jsonl", maximumBytes: max))
            XCTAssertEqual(String(decoding: final, as: UTF8.self), "a\nlate\n")
        }
    }
#endif
