#if os(macOS)
import AppKit
import Foundation
import SwiftUI
import XCTest
import LocalHistoryCore
@testable import LocalHistoryApp

/// T-043 lot R4d-B: Blocage, Concentration, composants.
@MainActor
final class T043R4dBTests: XCTestCase {
    // R4d-3: the journal is switched on while a report is being prepared. That report was built with the journal off;
    // a second one must follow, and the « Journal technique activé » answer must stay.
    func testEnablingTheJournalWhilePreparingQueuesAFreshReport() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("r4d3-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = UserDefaults(suiteName: "r4d3-\(UUID().uuidString)")!
        let journal = SupportDiagnostics(root: root, defaults: suite)
        let controller = SupportRequestController()
        controller.reportDirectory = root.appendingPathComponent("reports")
        controller.prepare()
        XCTAssertEqual(controller.phase, .preparing)
        controller.enableJournal(journal)
        XCTAssertTrue(controller.rebuildPending, "the switch came while the first report was being built")
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if case .ready = controller.phase, controller.buildCount == 2, !controller.rebuildPending { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(controller.buildCount, 2, "a second report was built after the journal went on")
        if case .ready = controller.phase {} else { XCTFail("phase \(controller.phase)") }
        XCTAssertEqual(controller.feedback, "Journal technique activé. Les prochains événements seront inclus.")
    }

    // R4d-26: « Bloque l’accès » names what it blocks.
    func testBlockedSubjectNamesWhatIsBlocked() {
        func list(sites: [String], apps: [String], mode: BlockList.Mode = .block) -> BlockList {
            BlockList(name: "L", mode: mode, sites: sites.map { BlockSiteRule(pattern: $0) },
                      apps: apps.map { BlockAppRule(bundleIdentifier: $0, name: $0) })
        }
        XCTAssertEqual(BlockingListsSection.behaviour(list(sites: ["x.com"], apps: [])), "Bloque l’accès à ces sites")
        XCTAssertEqual(BlockingListsSection.behaviour(list(sites: [], apps: ["a.b"])), "Bloque l’accès à ces apps")
        XCTAssertEqual(BlockingListsSection.behaviour(list(sites: ["x.com"], apps: ["a.b"])), "Bloque l’accès à ces sites et apps")
        XCTAssertEqual(BlockingListsSection.behaviour(list(sites: ["x.com"], apps: [], mode: .allowOnly)), "Bloque l’accès à tout le reste")
    }

    // R4d-20: counts go through the locale formatter, never a bare interpolation.
    func testCountsUseTheFormatter() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for file in ["ActivityEventInspector", "MonitoringRulesList", "UsageRulesList"] {
            let source = try String(contentsOf: root.appendingPathComponent("Sources/LocalHistoryApp/\(file).swift"), encoding: .utf8)
            XCTAssertFalse(source.contains("Text(\"\\(items.count)\")") || source.contains("Text(\"\\(filteredEvents.count)\")"), file)
            XCTAssertTrue(source.contains("GoalongUIFormat.number("), file)
        }
    }

    // R4d-6: the app keeps its 760 pt limit; the gallery lifts it on the real sheet.
    func testListSheetKeepsItsHeightLimitByDefault() {
        let sheet = BlockListSheet(controller: GalleryFixtures.blockingEmpty(), listID: UUID(), now: Date(), onDone: {})
        XCTAssertEqual(sheet.maxHeight, 760)
    }

    // R4d-16: a folded group with a summary draws something a bare folded header does not.
    func testFoldedDisclosureShowsItsSummary() throws {
        func ink(_ view: some View) throws -> [UInt8] {
            let host = NSHostingView(rootView: view.frame(width: 400, height: 60).environment(\.goalongReduceMotion, true).goalongControls())
            host.frame = NSRect(x: 0, y: 0, width: 400, height: 60)
            host.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            return Array(try XCTUnwrap(rep.representation(using: .png, properties: [:])))
        }
        let bare = try ink(GoalongDisclosureGroup("Réglages") { Text("x") })
        let summed = try ink(GoalongDisclosureGroup("Réglages") { Text("x") }.collapsedSummary("Secours : ⌃ ⌥ ⌘ R"))
        XCTAssertNotEqual(bare, summed)
    }
}
#endif
