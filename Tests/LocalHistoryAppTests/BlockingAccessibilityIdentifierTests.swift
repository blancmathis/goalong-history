#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import LocalHistoryApp

/// The `blocking-state-active` group id must not replace the ids of the buttons inside it: the e2e pilot
/// stops a block, takes a break or unlocks by `blocking-stop`, `blocking-take-break`, `blocking-extra-break`
/// and `blocking-unlock` (L3n J-0011, J-0012).
final class BlockingAccessibilityIdentifierTests: XCTestCase {
    private typealias F = GalleryFixtures

    @MainActor func testFreeBlockKeepsStopAndBreakIdentifiers() throws {
        let controller = controller()
        controller.start(listIDs: [F.socialID], until: F.blockingNow.addingTimeInterval(84 * 60), lock: .free)
        try assertIdentifiers(["blocking-state-active", "blocking-stop", "blocking-take-break"], controller: controller)
    }

    @MainActor func testPasswordBlockKeepsUnlockIdentifier() throws {
        try assertIdentifiers(["blocking-state-active", "blocking-unlock", "blocking-take-break"], controller: F.blockingGuarded())
    }

    @MainActor func testPasswordBlockKeepsExtraBreakIdentifier() throws {
        var usage = BlockDayUsage(day: BlockingController.dayKey(F.blockingNow))
        usage.breaksTaken[F.socialID] = 3
        let controller = controller(usage: usage)
        controller.setPassword("rendu-fixe")
        controller.start(listIDs: [F.socialID], until: F.blockingNow.addingTimeInterval(84 * 60), lock: .password)
        try assertIdentifiers(["blocking-state-active", "blocking-extra-break", "blocking-unlock"], controller: controller)
    }

    @MainActor private func controller(usage: BlockDayUsage? = nil) -> BlockingController {
        let now = F.blockingNow
        var document = BlockingDocument()
        document.lists = [F.socialList, F.videoList, F.focusList]
        if let usage { document.usage = usage }
        return BlockingController(document: document, clock: { now }, continuous: { now.timeIntervalSince1970 },
                                  runningApps: F.noApps)
    }

    /// Renders off screen (no window, no focus taken) and reads every identifier of the AX tree.
    @MainActor private func assertIdentifiers(_ expected: [String], controller: BlockingController,
                                              file: StaticString = #filePath, line: UInt = #line) throws {
        let root = BlockingPageContent(controller: controller, now: F.blockingNow)
            .frame(width: 900).environment(\.goalongReduceMotion, true).goalongControls()
        let view = NSHostingView(rootView: root)
        view.frame = NSRect(x: 0, y: 0, width: 900, height: 1500)
        view.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.35))
        NSApplication.shared.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))

        var identifiers = Set<String>(), pending: [Any] = [view], seen = Set<ObjectIdentifier>()
        while let value = pending.popLast(), seen.count < 20_000 {
            guard let object = value as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else { continue }
            if let id = read(object, "accessibilityIdentifier") as? String { identifiers.insert(id) }
            pending.append(contentsOf: read(object, "accessibilityChildren") as? [Any] ?? [])
            if let child = object as? NSView { pending.append(contentsOf: child.subviews) }
        }
        for id in expected {
            XCTAssertTrue(identifiers.contains(id), "\(id) is overridden by a container identifier; saw \(identifiers.sorted())",
                          file: file, line: line)
        }
    }

    private func read(_ object: NSObject, _ name: String) -> AnyObject? {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector), let method = object.method(for: selector) else { return nil }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
        return unsafeBitCast(method, to: Getter.self)(object, selector)?.takeUnretainedValue()
    }
}
#endif
