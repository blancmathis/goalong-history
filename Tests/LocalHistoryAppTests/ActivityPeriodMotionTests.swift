#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import LocalHistoryApp

/// T-054: Jour / 7 jours / 28 jours animate at every switch, not only the first time a period is shown; « Animations »
/// off in Réglages animates nothing. The real dashboard, gallery data, a window never on screen.
@MainActor
final class ActivityPeriodMotionTests: XCTestCase {
    func testEveryPeriodSwitchAnimatesAgainWhenThePeriodWasShownBefore() throws {
        let traces = try switchPeriods(animationsOff: false)
        XCTAssertEqual(traces.count, 4)
        for (index, trace) in traces.enumerated() {
            XCTAssertGreaterThan(trace.animated, 0, "switch \(index + 1) (\(trace.label)) drew its thread without motion")
            XCTAssertEqual(trace.still, 0, "switch \(index + 1) (\(trace.label)) showed a still thread")
        }
    }

    func testAnimationsOffInSettingsAnimateNoSwitch() throws {
        let traces = try switchPeriods(animationsOff: true)
        XCTAssertEqual(traces.count, 4)
        for (index, trace) in traces.enumerated() {
            XCTAssertEqual(trace.animated, 0, "switch \(index + 1) (\(trace.label)) animated with animations off")
            XCTAssertGreaterThan(trace.still, 0, "switch \(index + 1) (\(trace.label)) showed no thread at all")
        }
    }

    func testSettingsSearchFindsTheAnimationsSwitch() {
        XCTAssertTrue(GoalongMotionSettings.matches("anim"))
        XCTAssertTrue(GoalongMotionSettings.matches("Animations"))
        XCTAssertFalse(GoalongMotionSettings.matches(""))
        XCTAssertFalse(GoalongMotionSettings.matches("stockage"))
    }

    /// 1 j shown first, then 7 j, 1 j, 7 j, 1 j: the last three show a period already shown once.
    private func switchPeriods(animationsOff: Bool) throws -> [(label: String, animated: Int, still: Int)] {
        var traces: [(label: String, animated: Int, still: Int)] = []
        try GalleryRenderer.withPreparedApplication {
            let ctx = GalleryContext()
            try GalleryStateReset.all(home: ctx.home)
            defer { ctx.finish() }
            ctx.defaults.set(animationsOff, forKey: GoalongMotionPreference.offKey)
            let (model, window, host, _, _) = try ViewSwitchTimingTests.memberDashboard(ctx, days: 35)
            defer { window.contentView = nil; window.close() }
            settle(host, model)
            for label in ["7 jours", "Jour", "7 jours", "Jour"] {
                let animated = GoalongThreadTraceProbe.animated, still = GoalongThreadTraceProbe.still
                let button = try XCTUnwrap(ViewSwitchAX.first(in: host) {
                    $0.replacingOccurrences(of: "\u{00A0}", with: " ") == label }, "no « \(label) » button")
                XCTAssertEqual(ViewSwitchAX.flag(button, "accessibilityPerformPress"), true)
                settle(host, model)
                traces.append((label, GoalongThreadTraceProbe.animated - animated, GoalongThreadTraceProbe.still - still))
            }
        }
        return traces
    }

    /// Until every read is over and no loading view is left, then a few more turns for the appear of the new content.
    private func settle(_ host: NSView, _ model: DashboardViewModel) {
        XCTAssertNotNil(ViewSwitchTimingTests.settle(host, model: model, timeout: 10), "the dashboard never settled")
        spin(host, 0.3)
    }

    private func spin(_ host: NSView, _ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
            host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        }
    }
}
#endif
