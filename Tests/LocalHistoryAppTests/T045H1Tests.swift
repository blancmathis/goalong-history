#if os(macOS)
    import Foundation
    import XCTest
    @testable import LocalHistoryApp

    /// T-045 H1: bugs in zones never audited before (selectedDay pages, dashboard numbers, bet bounds).
    final class T045H1Tests: XCTestCase {
        // H1-01: « Bilan quotidien » keeps its chosen day as an instant. After Paris → New York,
        // « 25 oct. 00:00 Paris » reads as Oct 24 and the page loads the Oct 24 recap.
        func testRecapChosenPastDayKeepsItsDateAfterATimeZoneChange() throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let originalZone = NSTimeZone.default
            defer { NSTimeZone.default = originalZone }
            NSTimeZone.default = try XCTUnwrap(TimeZone(identifier: "Europe/Paris"))
            let runtime = ChatGPTRecapRuntime(
                chatHistoryStore: ChatGPTHistoryStore(rootDirectory: root.appendingPathComponent("history")),
                recapsDirectory: root.appendingPathComponent("recaps"),
                executableLocator: { nil },
                sessionFactory: { _ in throw NSError(domain: "T045H1", code: 1) },
                delayedAutomaticScheduler: { _ in }
            )
            let oct25 = try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 12)))
            runtime.selectDay(oct25)
            NSTimeZone.default = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
            NotificationCenter.default.post(name: .NSSystemTimeZoneDidChange, object: nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            XCTAssertEqual(Calendar.current.component(.day, from: runtime.selectedDay), 25, "Bilan page shows Oct 24")
        }
    }
#endif
