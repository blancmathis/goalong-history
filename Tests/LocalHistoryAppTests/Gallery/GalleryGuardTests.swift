#if os(macOS)
import Foundation
import GoalongHeadlessTestSupport
import SwiftUI
import XCTest
@testable import LocalHistoryApp

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

    /// Views decide « aujourd’hui » through `GoalongToday`, which the gallery freezes; `Calendar.isDateInToday` reads
    /// the real clock and changes images on another day (C2-couverture-02). Background code may keep it.
    func testViewsDoNotReadTheRealTodayDirectly() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/LocalHistoryApp")
        let allowed: Set<String> = ["GoalongCallPresenceMonitor.swift", "GoalongToday.swift"]
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var offenders: [String] = []
        var scanned = 0
        for case let url as URL in files where url.pathExtension == "swift" && !allowed.contains(url.lastPathComponent) {
            scanned += 1
            if try String(contentsOf: url, encoding: .utf8).contains("isDateInToday(") { offenders.append(url.lastPathComponent) }
        }
        XCTAssertGreaterThan(scanned, 50, "sources not found at \(sources.path)")
        XCTAssertEqual(offenders, [], "use GoalongToday.isToday in views")
    }

    /// The frozen clock reads « vendredi 23 octobre 2026 » and « 09:41 » whatever the Mac's language and time zone.
    func testFrozenClockReadsInFrench() {
        XCTAssertEqual(GalleryWitness.dateText(GalleryClock.base), "vendredi 23 octobre 2026")
        XCTAssertEqual(GalleryWitness.timeText(GalleryClock.base), "09:41")
    }
}
#endif
