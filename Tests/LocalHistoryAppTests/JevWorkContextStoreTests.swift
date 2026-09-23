#if os(macOS)
import Foundation
import XCTest
@testable import LocalHistoryApp
@testable import LocalHistoryCore

final class JevWorkContextStoreTests: XCTestCase {
    @MainActor func testOnlyExplicitSaveChangesReferenceAndInvalidStorageFailsClosed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("work-context-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JevWorkContextStore(root: root)
        XCTAssertEqual(store.context, .empty)
        let before = store.revision
        try store.save("Goalong: SwiftUI updater")
        XCTAssertNotEqual(store.revision, before)
        XCTAssertEqual(JevWorkContextStore(root: root).context.summary, "Goalong: SwiftUI updater")
        let file = root.appendingPathComponent("jev/work-context.json")
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertThrowsError(try store.save(String(repeating: "x", count: 101)))
        XCTAssertEqual(store.context.summary, "Goalong: SwiftUI updater")
        try JevLocalFiles.write(Data("bad json".utf8), name: "work-context.json", root: root)
        let corrupt = JevWorkContextStore(root: root)
        XCTAssertNotNil(corrupt.error); XCTAssertEqual(corrupt.context, .empty)
        try corrupt.save("New explicit task")
        XCTAssertNil(corrupt.error)
        try corrupt.save("")
        XCTAssertEqual(corrupt.context, .empty)
    }
    @MainActor func testWorkCannotBeProvedWithoutReferenceAndTopic() throws {
        let now = Date()
        let sample = JevSample(date: now, resource: "Xcode", title: "", action: "typing", surface: "other", isActivity: true)
        let window = JevWindow(start: now, end: now.addingTimeInterval(15), samples: [sample])
        let work = try JevWorkContext(summary: "Goalong Swift app")
        XCTAssertEqual(JevWorkContextStore.reviewedVerdict(.productive, work: .empty, window: window), .unknown)
        XCTAssertEqual(JevWorkContextStore.reviewedVerdict(.productive, work: work, window: window), .unknown)
        XCTAssertEqual(JevWorkContextStore.reviewedVerdict(.procrastination, work: .empty, window: window), .unknown)
    }
    @MainActor func testWorkReferenceSymlinkCannotExposeAnotherFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("work-context-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = JevWorkContextStore(root: root)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("jev/work-context.json"), withDestinationURL: root.appendingPathComponent("elsewhere"))
        XCTAssertNotNil(JevWorkContextStore(root: root).error)
    }
}
#endif
