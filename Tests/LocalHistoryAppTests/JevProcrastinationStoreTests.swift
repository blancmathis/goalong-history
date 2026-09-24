#if os(macOS)
import Foundation
import XCTest
@testable import LocalHistoryApp
@testable import LocalHistoryCore

final class JevProcrastinationStoreTests: XCTestCase {
    @MainActor func testSaveReloadFailureAndExplicitClearPreserveOtherCriteria() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("procrastination-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JevWorkContextStore(root: root)
        try store.save("Atlas", applications: "Figma", content: "Launch design", procrastination: "Scroller X")
        let original = store.context, revision = store.revision
        XCTAssertEqual(JevWorkContextStore(root: root).context, original)
        let file = root.appendingPathComponent("jev/work-context.json")
        let data = try Data(contentsOf: file)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertThrowsError(try store.save("Atlas", procrastination: String(repeating: "é", count: 401)))
        XCTAssertEqual(store.context, original)
        XCTAssertEqual(store.revision, revision)
        XCTAssertEqual(try Data(contentsOf: file), data)
        try store.save(original.summary, applications: original.applications, content: original.content, procrastination: "")
        XCTAssertNotEqual(store.revision, revision)
        XCTAssertEqual(store.context.summary, "Atlas")
        XCTAssertEqual(store.context.applications, "Figma")
        XCTAssertEqual(store.context.content, "Launch design")
        XCTAssertTrue(store.context.procrastination.isEmpty)
        XCTAssertEqual(JevWorkContextStore(root: root).context, store.context)
    }
    @MainActor func testReadingVersionTwoNeverRewritesChoicesOrAddsNegativeExamples() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("procrastination-migration-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = Data(#"{"schemaVersion":2,"summary":"Atlas","applications":"Figma","content":"Launch design"}"#.utf8)
        try JevLocalFiles.write(legacy, name: "work-context.json", root: root)
        let store = JevWorkContextStore(root: root)
        XCTAssertNil(store.error)
        XCTAssertTrue(store.context.procrastination.isEmpty)
        XCTAssertEqual(store.context.applications, "Figma")
        XCTAssertEqual(try JevLocalFiles.read("work-context.json", root: root), legacy)
        try store.save(store.context.summary, applications: store.context.applications,
                       content: store.context.content, procrastination: "Achats personnels")
        XCTAssertEqual(JevWorkContextStore(root: root).context.procrastination, "Achats personnels")
    }
    @MainActor func testChangingOnlyNegativeExamplesPublishesTheSameCancellationBoundary() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("procrastination-revision-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JevWorkContextStore(root: root)
        try store.save("Atlas")
        let revision = store.revision
        let changed = expectation(forNotification: .jevWorkContextDidChange, object: store)
        try store.save("Atlas", procrastination: "Shopping personnel")
        wait(for: [changed], timeout: 1)
        XCTAssertNotEqual(store.revision, revision)
        let source = try appSource("JevMonitor.swift")
        XCTAssertTrue(source.contains(".jevWorkContextDidChange"))
        XCTAssertEqual(source.components(separatedBy: "workStore.revision == workRevision").count - 1, 2)
    }
    func testUIExposesAddEditSaveAndNonExhaustiveSemanticsWithoutEnablingMonitoring() throws {
        let source = try appSource("JevWorkContextControls.swift")
        for required in ["monitoring-procrastination", "monitoring-add-procrastination", "monitoring-saved-procrastination",
                         "pas une liste exhaustive", "procrastination: procrastination", "procrastination = store.context.procrastination",
                         "monitoring-cancel-goals", "exemples de procrastination à TypeSafe"] {
            XCTAssertTrue(source.contains(required), required)
        }
        XCTAssertFalse(source.contains("setEnabled("))
        XCTAssertFalse(source.contains("JevMonitor.shared"))
        XCTAssertTrue(try appSource("JevMonitoringPage.swift").contains("JevWorkContextControls()"))
    }
    private func appSource(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/LocalHistoryApp/" + name), encoding: .utf8)
    }
}
#endif
