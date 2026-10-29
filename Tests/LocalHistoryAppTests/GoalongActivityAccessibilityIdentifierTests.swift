#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import LocalHistoryApp

/// The page-level `activity-content` identifier must not replace the identifiers of the controls inside it:
/// automation (the e2e pilot) reaches « Applications et sites » by `activity-explore-usage`.
final class GoalongActivityAccessibilityIdentifierTests: XCTestCase {
    @MainActor func testChildIdentifiersSurviveThePageIdentifier() throws {
        let day = Calendar.current.date(from: .init(year: 2026, month: 9, day: 18))!
        let payload = GoalongAnalyticsPreview.make(ending: day, count: 1, calendar: .current, now: day)
        let root = GoalongAnalyticsContent(payload: payload, focusMinutes: .constant(25),
            lanes: GoalongAnalyticsPreview.lanes(day: day), detail: .constant(nil))
            .frame(width: 900).environment(\.goalongReduceMotion, true).goalongControls()
        let view = NSHostingView(rootView: root)
        view.frame = NSRect(x: 0, y: 0, width: 900, height: 2400)
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
        XCTAssertTrue(identifiers.contains("activity-explore-usage"),
                      "Child identifiers are overridden by the page identifier; saw \(identifiers.sorted())")
    }

    private func read(_ object: NSObject, _ name: String) -> AnyObject? {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector), let method = object.method(for: selector) else { return nil }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
        return unsafeBitCast(method, to: Getter.self)(object, selector)?.takeUnretainedValue()
    }
}
#endif
