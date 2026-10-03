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
            for count in [1, 7, 28, 0, -1, -2, -7, -31, -37] {
                let payload = fixture(count: count)
                let selection = GoalongActivityNavigation(day: payload.current.days.last?.date ?? payload.updatedAt,
                    period: payload.current.days.count)
                // The summary for every fixture; the named views for a day and a week.
                let views: [GoalongActivityDetail?] = [1, 7].contains(count) ? [nil, .rhythm, .usage, .sessions, .texture, .reports, .coverage] : [nil]
                for shown in views {
                for width in [640.0, 1000.0] {
                    let root = VStack(alignment: .leading, spacing: 0) {
                        GoalongActivityHeader(selection: selection, isPreview: payload.isPreview, isRefreshing: false,
                            onDay: { _ in }, onPeriod: { _ in }, onStep: { _ in }, onToday: {},
                            onReturn: {}, onRefresh: {}, onShare: {})
                        Divider()
                        VStack(alignment: .leading, spacing: 20) {
                            if payload.isPreview { GoalongAnalyticsPreviewBanner() }
                            GoalongAnalyticsContent(payload: payload, focusMinutes: .constant(25), detail: .constant(shown))
                        }.padding(LHTheme.pageInset)
                    }
                        .frame(width: width).fixedSize(horizontal: false, vertical: true)
                        .background(LHTheme.pageBackground).foregroundStyle(LHTheme.text).tint(LHTheme.accent)
                        // Still renders: the thread is shown complete instead of mid-trace.
                        .environment(\.goalongReduceMotion, true).goalongControls()
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
                    let name = "analytics-\(count)d\(shown.map { "-" + $0.rawValue } ?? "")-\(Int(width))-\(dark ? "dark" : "light").png"
                    try data.write(to: directory.appendingPathComponent(name))
                    print("ANALYTICS_NATIVE_RENDER \(name) \(bitmap.pixelsWide)x\(bitmap.pixelsHigh)")
                }
                }
            }
        }
    }
    /// Opt-in renders of the drill-downs: the usage timeline and one usage's detail sheet.
    @MainActor func testRenderActivityDrillDownsWithSyntheticData() throws {
        guard let path = ProcessInfo.processInfo.environment["GOALONG_ANALYTICS_SNAPSHOTS"] else {
            throw XCTSkip("Opt-in native rendering with synthetic data only")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        // Tests run alphabetically: this one may be first, before any directory exists.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory); app.finishLaunching()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 800),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil); window.contentViewController = nil }
        let day = fixture(count: -31).current.days[0]
        let week = fixture(count: -37)
        let range = GoalongActivityPresentation.chartRange(day, fullDay: false)
        let item = try XCTUnwrap(GoalongActivityProjection.usage(week.current, grouping: .sites, previous: week.previous).first)
        let views: [(String, AnyView, CGFloat)] = [
            ("timeline", AnyView(GoalongUsageTimelineChart(day: day, grouping: .sites, dateRange: range, hourStride: 2)
                .padding(24).frame(width: 952)), 952),
            ("usage-detail", AnyView(GoalongActivityUsageDetail(item: item, period: week.current, grouping: .sites,
                isPreview: false, onHistoryDay: { _ in })), 600),
        ]
        for dark in [true, false] {
            app.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.appearance = app.appearance
            for (name, view, width) in views {
                let controller = NSHostingController(rootView: view.background(LHTheme.pageBackground)
                    .foregroundStyle(LHTheme.text).tint(LHTheme.accent))
                window.contentViewController = controller
                window.setContentSize(NSSize(width: width, height: 800)); window.makeKeyAndOrderFront(nil)
                RunLoop.current.run(until: Date().addingTimeInterval(0.3))
                let host = controller.view
                let height = max(300, host.fittingSize.height)
                window.setContentSize(NSSize(width: width, height: height))
                RunLoop.current.run(until: Date().addingTimeInterval(0.3))
                host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                XCTAssertGreaterThan(data.count, 5000)
                let file = "activity-\(name)-\(dark ? "dark" : "light").png"
                try data.write(to: directory.appendingPathComponent(file))
                print("ANALYTICS_NATIVE_RENDER \(file) \(bitmap.pixelsWide)x\(bitmap.pixelsHigh)")
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
        if requestedCount == -31 || requestedCount == -37 {
            return realisticFixture(days: requestedCount == -31 ? 1 : 7, calendar: calendar)
        }
        let count = requestedCount == -7 ? 7 : 0
        let base = calendar.date(from: .init(year: 2026, month: 9, day: 1))!
        var days: [GoalongLocalAnalytics.Day] = []
        for index in 0..<(max(1, count) * 2) {
            let day = calendar.date(byAdding: .day, value: index, to: base)!
            var events: [HistoryEvent] = []
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

    /// Shaped like real days observed on a working Mac: a browser with many sites,
    /// a switch every ~30 seconds, long evenings, and almost nothing classified.
    private func realisticFixture(days count: Int, calendar: Calendar) -> GoalongAnalyticsPayload {
        let base = calendar.date(from: .init(year: 2026, month: 9, day: 14))!
        let rotation: [(String, String, String?, Bool?)] = [
            ("Safari", "com.apple.Safari", "chatgpt.com", nil), ("Codex", "com.openai.codex", nil, nil),
            ("Safari", "com.apple.Safari", "github.com", true), ("Messages", "com.apple.MobileSMS", nil, nil),
            ("Safari", "com.apple.Safari", "youtube.com", nil), ("Xcode", "com.apple.dt.Xcode", nil, true),
            ("Safari", "com.apple.Safari", "mail.google.com", nil), ("WhatsApp", "net.whatsapp.WhatsApp", nil, nil),
            ("Safari", "com.apple.Safari", "docs.google.com", nil), ("Terminal", "com.apple.Terminal", nil, true),
        ]
        var days: [GoalongLocalAnalytics.Day] = []
        for index in 0..<(count * 2) {
            let day = calendar.date(byAdding: .day, value: index, to: base)!
            var events: [HistoryEvent] = []
            let start = 8.5 + Double(index % 3) * 0.5, end = 22.0 + Double(index % 2)
            var time = day.addingTimeInterval(start * 3600), step = 0
            while time < day.addingTimeInterval(end * 3600) {
                // Lunch and dinner breaks leave unobserved gaps instead of invented activity.
                let hour = time.timeIntervalSince(day) / 3600
                if (12.5..<13.5).contains(hour) || (19.5..<20.25).contains(hour) { time += 600; continue }
                let focusStretch = (10.0..<11.0).contains(hour) || (15.0..<15.6).contains(hour)
                let pick = focusStretch ? rotation[5 + (step % 2) * 4] : rotation[(step * 7 + index) % rotation.count]
                let dwell = focusStretch ? 150.0 : Double(12 + (step * 37) % 70)
                events.append(HistoryEvent(id: "real-\(index)-\(step)", sessionID: "fixture", timestamp: time, kind: .heartbeat,
                    app: AppSnapshot(name: pick.0, bundleIdentifier: pick.1, processIdentifier: 1),
                    url: pick.2.map { URLSnapshot(value: "https://" + $0, host: $0, redactionApplied: true) },
                    classification: .init(category: pick.3 == true ? "software_development" : "web", isWork: pick.3,
                        confidence: pick.3 == true ? 0.96 : 0.95, classifierVersion: "rules-2026.08-v1")))
                time += min(dwell, 110); step += 1
            }
            days.append(GoalongLocalAnalytics.build(events: events, day: day,
                now: calendar.date(byAdding: .day, value: 1, to: day)!, calendar: calendar))
        }
        return GoalongAnalyticsPayload(current: .init(days: Array(days.suffix(count))),
            previous: .init(days: Array(days.prefix(count))), cards: [], archiveNotice: nil,
            updatedAt: calendar.date(byAdding: .day, value: count * 2, to: base)!)
    }
}
#endif
