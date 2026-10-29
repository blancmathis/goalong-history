#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import LocalHistoryApp

/// The page-level `activity-content` identifier must not replace the identifiers of the controls inside it:
/// automation (the e2e pilot) reaches « Applications et sites » by `activity-explore-usage`.
/// Each section identifier below must keep the ids of its own controls the same way (one test per container).
final class GoalongActivityAccessibilityIdentifierTests: XCTestCase {
    private let day = Calendar.current.date(from: .init(year: 2026, month: 9, day: 18))!

    @MainActor func testChildIdentifiersSurviveThePageIdentifier() throws {
        // One id per container: a page child (page .contain) and a control inside the Explorer section (section .contain).
        try assertIdentifiers(["activity-primary-metrics", "activity-explore-usage"], in: content())
    }

    @MainActor func testClassificationCardKeepsItsButtonIdentifier() throws {
        try assertIdentifiers(["activity-classification", "activity-define-work"],
                              in: content(workStatus: GoalongWorkStatus(hasDefinition: false)))
    }

    @MainActor func testTasksSectionKeepsItsActionIdentifiers() throws {
        try assertIdentifiers(["activity-tasks", "activity-tasks-definition", "activity-tasks-review"], in: content())
    }

    @MainActor func testRecapSectionKeepsItsOpenIdentifier() throws {
        try assertIdentifiers(["activity-recap", "activity-recap-open"], in: content())
    }

    @MainActor func testPrimaryChartKeepsItsControlIdentifiers() throws {
        try assertIdentifiers(["activity-primary-chart", "activity-full-day", "activity-rhythm-mode"], in: content(detail: .rhythm))
    }

    @MainActor func testReportsSectionKeepsItsProjectsIdentifier() throws {
        try assertIdentifiers(["activity-reports", "analytics-projects"], in: content(detail: .reports))
    }

    @MainActor func testSessionsSectionKeepsItsFocusIdentifiers() throws {
        try assertIdentifiers(["activity-sessions", "analytics-focus-threshold", "activity-focus-definition"],
                              in: content(detail: .sessions))
    }

    /// A real (non-preview) day, so the task actions show, with a saved daily recap of that day.
    @MainActor private func content(detail: GoalongActivityDetail? = nil,
                                    workStatus: GoalongWorkStatus = .preview) -> some View {
        let preview = GoalongAnalyticsPreview.make(ending: day, count: 1, calendar: .current, now: day)
        let recap = GoalongAnalyticsCard(id: "recap", day: "2026-09-18", module: "dailyRecap", title: "Bilan",
                                         summary: "Une journée.", status: "observed", caveat: "")
        let payload = GoalongAnalyticsPayload(current: preview.current, previous: preview.previous,
            cards: preview.cards + [recap], archiveNotice: nil, updatedAt: day)
        return GoalongAnalyticsContent(payload: payload, focusMinutes: .constant(25),
            lanes: GoalongAnalyticsPreview.lanes(day: day), workStatus: workStatus, detail: .constant(detail))
            .frame(width: 900).environment(\.goalongReduceMotion, true).goalongControls()
    }

    /// Renders off screen (no window, no focus taken) and reads every identifier of the AX tree.
    @MainActor private func assertIdentifiers(_ expected: [String], in root: some View,
                                              file: StaticString = #filePath, line: UInt = #line) throws {
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
