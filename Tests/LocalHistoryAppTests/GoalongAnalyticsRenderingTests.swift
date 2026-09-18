#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import LocalHistoryApp
@testable import LocalHistoryCore

final class GoalongAnalyticsRenderingTests: XCTestCase {
    @MainActor func testRenderAnalyticsWithSyntheticData() throws {
        guard let path = ProcessInfo.processInfo.environment["GOALONG_ANALYTICS_SNAPSHOTS"] else {
            throw XCTSkip("Opt-in native rendering with synthetic data only")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory); app.finishLaunching()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 800),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil); window.contentViewController = nil }
        for dark in [true, false] {
            app.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.appearance = app.appearance
            for count in [1, 7, 28, 0, -1, -2, -7] {
                let payload = fixture(count: count)
                for width in [640.0, 1000.0] {
                    let root = VStack(alignment: .leading, spacing: 22) {
                        if payload.isPreview { GoalongAnalyticsPreviewBanner() }
                        GoalongAnalyticsContent(payload: payload, focusMinutes: .constant(25))
                    }
                        .padding(24).frame(width: width).fixedSize(horizontal: false, vertical: true)
                        .background(LHTheme.pageBackground).foregroundStyle(LHTheme.text).tint(LHTheme.accent)
                    let controller = NSHostingController(rootView: root)
                    window.contentViewController = controller
                    window.setContentSize(NSSize(width: width, height: 900))
                    window.makeKeyAndOrderFront(nil)
                    RunLoop.current.run(until: Date().addingTimeInterval(0.3))
                    let host = controller.view
                    let height = max(500, host.fittingSize.height)
                    host.frame = NSRect(x: 0, y: 0, width: width, height: height)
                    window.setContentSize(NSSize(width: width, height: height))
                    RunLoop.current.run(until: Date().addingTimeInterval(0.3))
                    host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
                    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    XCTAssertGreaterThan(data.count, 5000)
                    let name = "analytics-\(count)d-\(Int(width))-\(dark ? "dark" : "light").png"
                    try data.write(to: directory.appendingPathComponent(name))
                    print("ANALYTICS_NATIVE_RENDER \(name) \(bitmap.pixelsWide)x\(bitmap.pixelsHigh)")
                }
            }
        }
    }
    private func fixture(count requestedCount: Int) -> GoalongAnalyticsPayload {
        let calendar = Calendar.current
        let selectedDay = calendar.date(from: .init(year: 2026, month: 9, day: 18))!
        if requestedCount > 0 {
            return GoalongAnalyticsPreview.make(ending: selectedDay, count: requestedCount, calendar: calendar, now: selectedDay)
        }
        if requestedCount == -1 || requestedCount == -2 {
            let offsets = requestedCount == -1 ? [0] : [0, 9, 7]
            let events = offsets.map { seconds in
                HistoryEvent(id: "sparse-\(seconds)", sessionID: "fixture",
                    timestamp: selectedDay.addingTimeInterval(Double(9 * 3600 + seconds)), kind: .heartbeat,
                    app: .init(name: "Éditeur", bundleIdentifier: "fixture.editor", processIdentifier: 1))
            }
            let day = GoalongLocalAnalytics.build(events: events, day: selectedDay,
                now: selectedDay.addingTimeInterval(12 * 3600), calendar: calendar)
            return GoalongAnalyticsPayload(current: .init(days: [day]), previous: .init(days: []),
                cards: [], archiveNotice: nil, updatedAt: selectedDay)
        }
        let count = requestedCount == -7 ? 7 : 0
        let base = calendar.date(from: .init(year: 2026, month: 9, day: 1))!
        var days: [GoalongLocalAnalytics.Day] = []
        for index in 0..<(max(1, count) * 2) {
            let day = calendar.date(byAdding: .day, value: index, to: base)!
            var events: [HistoryEvent] = []
            // Missing middle day proves the curve does not bridge a collection gap.
            if count > 0 && index != max(1, count) + 2 {
                for minute in 0...(170 + (index % 4) * 35) {
                    let app = minute % 90 < 60 ? "Éditeur" : "Navigateur"
                    events.append(HistoryEvent(id: "\(index)-\(minute)", sessionID: "fixture",
                        timestamp: day.addingTimeInterval(Double(9 * 3600 + minute * 60)), kind: .heartbeat,
                        app: AppSnapshot(name: app, bundleIdentifier: "fixture." + app, processIdentifier: 1),
                        classification: .init(category: "Création", isWork: minute % 90 < 75, confidence: 0.9, classifierVersion: "fixture")))
                }
            }
            days.append(GoalongLocalAnalytics.build(events: events, day: day,
                now: calendar.date(byAdding: .day, value: 1, to: day)!, calendar: calendar))
        }
        let size = max(1, count)
        let cards = [GoalongAnalyticsCard(id: "fixture-project", day: "2026-09-10", module: "projects",
            title: "Projet d’exemple — préparation du parcours mobile", summary: "Données fictives pour vérifier la présentation. Aucun historique personnel n’a été lu.",
            status: "inferred", caveat: "Une activité observée ne prouve pas l’achèvement du projet.")]
        return GoalongAnalyticsPayload(current: .init(days: Array(days.suffix(size))),
            previous: .init(days: Array(days.prefix(size))), cards: cards, archiveNotice: nil,
            updatedAt: base.addingTimeInterval(12 * 3600))
    }
}
#endif
