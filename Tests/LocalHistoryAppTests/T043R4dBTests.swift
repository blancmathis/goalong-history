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
        // Tour 2: an empty block list names nothing it blocks.
        XCTAssertEqual(BlockingListsSection.behaviour(list(sites: [], apps: [])), "Ne bloque encore rien")
    }

    // R4d-20 (tour 2): what is drawn, not the source. 1 284 reads « 1 284 » (French grouping), never « 1284 ».
    func testRuleCountIsDrawnWithFrenchGrouping() {
        // An English environment: a bare interpolation would draw « 1,284 ».
        let shown = visibleText(GoalongRuleCount(1284).environment(\.locale, Locale(identifier: "en_US")))
        XCTAssertTrue(shown.contains(GoalongUIFormat.number(1284)), "\(shown)")
        XCTAssertFalse(shown.contains("1284"), "\(shown)")
        XCTAssertNotEqual(GoalongUIFormat.number(1284), "1284")
    }

    private func visibleText(_ root: some View) -> Set<String> {
        let view = NSHostingView(rootView: root.frame(width: 200, height: 40).environment(\.goalongReduceMotion, true).goalongControls())
        view.frame = NSRect(x: 0, y: 0, width: 200, height: 40)
        view.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        view.layoutSubtreeIfNeeded()
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApplication.shared.accessibilityAttributeValue(enhanced)
        NSApplication.shared.accessibilitySetValue(true, forAttribute: enhanced)
        defer { NSApplication.shared.accessibilitySetValue(previous ?? false, forAttribute: enhanced) }
        var found = Set<String>(), pending: [Any] = [view], seen = Set<ObjectIdentifier>()
        while let value = pending.popLast(), seen.count < 5_000 {
            guard let object = value as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else { continue }
            for name in ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"] {
                if let text = read(object, name) as? String, !text.isEmpty { found.insert(text) }
            }
            pending.append(contentsOf: read(object, "accessibilityChildren") as? [Any] ?? [])
            if let child = object as? NSView { pending.append(contentsOf: child.subviews) }
        }
        return found
    }

    private func read(_ object: NSObject, _ name: String) -> AnyObject? {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector), let method = object.method(for: selector) else { return nil }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
        return unsafeBitCast(method, to: Getter.self)(object, selector)?.takeUnretainedValue()
    }

    // R4d-6 (tour 2): the limit is honoured at other heights too — drawn, the sheet is never taller than it.
    func testListSheetHonoursItsHeightLimit() {
        func height(_ limit: CGFloat?) -> CGFloat {
            var sheet = BlockListSheet(controller: GalleryFixtures.blockingEmpty(), listID: UUID(), now: Date(), onDone: {})
            if let limit { sheet.maxHeight = limit }
            let host = NSHostingView(rootView: sheet.environment(\.goalongReduceMotion, true).goalongControls())
            host.frame = NSRect(x: 0, y: 0, width: 600, height: 2000)
            host.layoutSubtreeIfNeeded()
            return host.fittingSize.height
        }
        XCTAssertEqual(BlockListSheet(controller: GalleryFixtures.blockingEmpty(), listID: UUID(), now: Date(), onDone: {}).maxHeight, 760)
        XCTAssertLessThanOrEqual(height(500), 500)
        XCTAssertLessThanOrEqual(height(450), 450)
        XCTAssertLessThan(height(450), height(nil), "a smaller limit gives a shorter sheet")
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
