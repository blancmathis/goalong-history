#if os(macOS)
import Foundation
import GoalongHeadlessTestSupport
import SwiftUI
import XCTest
@testable import LocalHistoryApp
import LocalHistoryCore

/// In `make test`: the gallery's own protections work (spec C §11.7, §11.9). Renders nothing.
final class GalleryGuardTests: XCTestCase {
    /// A witness that tries an ephemeral request and a process launch is counted, and both are refused.
    func testGuardsCountAnEphemeralRequestAndAProcessLaunch() throws {
        guard GoalongGalleryGuardsInstalled() else { throw XCTSkip("GOALONG_TESTS_VISIBLE=1: gallery guards off") }
        GalleryGuardReport.begin()
        let session = URLSession(configuration: .ephemeral)
        let done = expectation(description: "request ends")
        var failure: Error?
        session.dataTask(with: URL(string: "https://exemple.invalid/galerie")!) { _, _, error in
            failure = error
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 5)
        session.invalidateAndCancel()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        XCTAssertThrowsError(try process.run(), "the guard lets a process start")
        let report = GalleryGuardReport.take()
        XCTAssertNotNil(failure, "the request was not refused")
        XCTAssertGreaterThanOrEqual(report.network, 1, report.summary)
        XCTAssertGreaterThanOrEqual(report.tasks, 1, report.summary)
        XCTAssertEqual(report.status, .failed)
        // Outside a session nothing is counted.
        GalleryGuardReport.begin()
        XCTAssertTrue(GalleryGuardReport.take().isClean)
    }

    /// The data reset refuses the account's real HOME and any folder outside a gallery or test HOME.
    @MainActor func testResetRefusesARealHome() {
        let realHome = URL(fileURLWithPath: String(cString: getpwuid(getuid())!.pointee.pw_dir), isDirectory: true)
        XCTAssertThrowsError(try GalleryStateReset.resetHome(realHome))
        XCTAssertThrowsError(try GalleryStateReset.resetHome(URL(fileURLWithPath: "/tmp", isDirectory: true)))
    }

    /// R10: with recording off the gallery read today as « Lecture incomplète » because its reset had deleted the
    /// journal folder the app creates at every launch. The empty fixture must read like the app: no source, not a
    /// read error.
    @MainActor func testTheEmptyFixtureReadsTodayAsNoSource() throws {
        let events = AppPaths.eventsDirectory, manager = FileManager.default
        guard events.path.hasPrefix("/tmp/goalong-") || events.path.hasPrefix("/private/tmp/goalong-") else {
            throw XCTSkip("data root \(events.path) is not a throwaway HOME")
        }
        let aside = events.deletingLastPathComponent().appendingPathComponent("events-r10-aside-" + UUID().uuidString)
        let existed = manager.fileExists(atPath: events.path)
        if existed { try manager.moveItem(at: events, to: aside) }
        defer {
            try? manager.removeItem(at: events)
            if existed { try? manager.moveItem(at: aside, to: events) }
        }
        try GalleryFixtureHome.install(.empty)
        let day = GoalongLocalAnalytics.load(root: AppPaths.applicationSupportDirectory, day: GalleryClock.today,
                                             now: GalleryClock.now, calendar: GalleryClock.calendar)
        XCTAssertEqual(day.state, .noSource, "recording off reads as no source, never as an unreadable day")
    }

    /// SYS-16: the fixture runs the app's own storage preparation, so every standard folder exists again after the
    /// reset, not only `events/`.
    @MainActor func testTheFixtureRecreatesEveryStandardStorageFolder() throws {
        let support = AppPaths.applicationSupportDirectory
        guard support.path.hasPrefix("/tmp/goalong-") || support.path.hasPrefix("/private/tmp/goalong-") else {
            throw XCTSkip("data root \(support.path) is not a throwaway HOME")
        }
        // Remove only empty standard folders (deepest first): `make test` shares this HOME with other tests.
        for folder in AppPaths.standardStorageDirectories(in: support).reversed() {
            let contents = try? FileManager.default.contentsOfDirectory(atPath: folder.path)
            if contents?.isEmpty == true { try? FileManager.default.removeItem(at: folder) }
        }
        try GalleryFixtureHome.install(.empty)
        for folder in AppPaths.standardStorageDirectories(in: support) {
            var isDirectory: ObjCBool = false
            XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory) && isDirectory.boolValue,
                          "\(folder.path) is missing after the fixture install")
        }
    }

    /// Views decide « aujourd’hui » through `GoalongToday`, which the gallery freezes. `Calendar.isDateInToday`, a
    /// day default such as `startOfDay(for: Date())`, `date(byAdding:…, to: Date())`, `in: ...Date()` or an
    /// `@State var x = Date()` read the real clock and change images on another day (C2-couverture-02, C3-outil-03,
    /// C3-couverture-02). Background code, never drawn by the gallery, may keep them.
    func testViewsDoNotReadTheRealTodayDirectly() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/LocalHistoryApp")
        let allowed: Set<String> = ["GoalongToday.swift", "GoalongCallPresenceMonitor.swift",
                                    "ActivityAnalysisRuntime.swift", "GoalongWorkAgent.swift",
                                    "AgentActivityRuntime.swift", "ChatGPTRecapRuntime.swift"]
        let patterns = try [#"isDateInToday\("#, #"startOfDay\(for: Date\(\)\)"#, #"to: Date\(\)\)"#,
                            #"\.\.\.Date\(\)"#, #"@State (private )?var \w+ = Date\(\)"#]
            .map { try NSRegularExpression(pattern: $0) }
        // R12 audit: a live `TimelineView` tick (`?? context.date`, `at: context.date`), a `?? Date()` or `now: Date()`
        // argument, a `day:` / `relativeTo:` / `of:` real clock, `Date().timeIntervalSinceReferenceDate`, a
        // `.date = Date()` reset or a `{ Date() }` clock. Wrap ticks in `GoalongToday.timeline(_:)`. Background files
        // below stamp real events, deadlines or durations and never draw « aujourd’hui ».
        let background: Set<String> = ["EventRecorder.swift", "EventTapMonitor.swift", "SupportDiagnostics.swift",
                                       "JevMonitor.swift", "AppDelegate.swift", "MinuteSealer.swift",
                                       "SoftwareUpdateManager.swift", "GoalongGuardClient.swift"]
        let livePatterns = try [#"(\?\? |at: )context\.date"#, #"\?\? Date\(\)"#, #"now: Date\(\)"#, #"day: Date\(\)"#,
                                #"relativeTo: Date\(\)"#, #"of: Date\(\)"#, #"Date\(\)\.timeIntervalSinceReferenceDate"#,
                                #"\.date = Date\(\)"#, #"\{ Date\(\) \}"#]
            .map { try NSRegularExpression(pattern: $0) }
        // A view, sheet, formatter or view model must default its clock to the views' today, not `Date()`.
        let viewFile = try NSRegularExpression(pattern: #"(Page|Views?|Sheet|Format|Preview|Summary|Models?)\.swift$"#)
        let viewDefault = try NSRegularExpression(pattern: #"(now|day): Date = Date\(\)"#)
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var offenders: [String] = []
        var scanned = 0
        for case let url as URL in files where url.pathExtension == "swift" && !allowed.contains(url.lastPathComponent) {
            scanned += 1
            let text = try String(contentsOf: url, encoding: .utf8)
            let name = url.lastPathComponent
            var checks = patterns
            if !background.contains(name) { checks += livePatterns }
            if viewFile.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil { checks.append(viewDefault) }
            for pattern in checks
            where pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil {
                offenders.append("\(name): \(pattern.pattern)")
            }
            // The Activité preview opens `GoalongActivityNavigation()` with no day: its defaults must be the views' today.
            if url.lastPathComponent == "GoalongActivityNavigation.swift", text.contains("Date()") {
                offenders.append("GoalongActivityNavigation.swift: Date()")
            }
        }
        XCTAssertGreaterThan(scanned, 50, "sources not found at \(sources.path)")
        XCTAssertEqual(offenders, [], "use GoalongToday.now / GoalongToday.isToday in views")
    }

    /// The frozen clock reads « vendredi 23 octobre 2026 » and « 09:41 » whatever the Mac's language and time zone.
    func testFrozenClockReadsInFrench() {
        XCTAssertEqual(GalleryWitness.dateText(GalleryClock.base), "vendredi 23 octobre 2026")
        XCTAssertEqual(GalleryWitness.timeText(GalleryClock.base), "09:41")
    }
}
#endif
