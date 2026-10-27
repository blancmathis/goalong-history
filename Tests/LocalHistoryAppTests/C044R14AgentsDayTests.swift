#if os(macOS)
    import AgentActivity
    import Foundation
    import XCTest
    @testable import LocalHistoryApp

    /// T-044 r14 volet C: time zone change regressions (C14-02, C14-03).
    final class C044R14AgentsDayTests: XCTestCase {
        // C14-03: the Agents secondary page (DashboardRootView .agentActivity) is bound to nothing; its chosen
        // past day is a frozen Paris midnight that reads as the day before after a westward zone change.
        func testAgentsChosenPastDayKeepsItsDateAfterATimeZoneChange() throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let originalZone = NSTimeZone.default
            defer { NSTimeZone.default = originalZone }
            NSTimeZone.default = try XCTUnwrap(TimeZone(identifier: "Europe/Paris"))
            let runtime = try AgentActivityRuntime(
                rootDirectory: root, executableURL: URL(fileURLWithPath: "/usr/bin/true"),
                sourceDiscovery: { [] }, onCaptured: { _ in })
            let oct25 = try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 12)))
            runtime.selectDay(oct25)
            NSTimeZone.default = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
            NotificationCenter.default.post(name: .NSSystemTimeZoneDidChange, object: nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            XCTAssertEqual(Calendar.current.component(.day, from: runtime.selectedDay), 25, "Agents page shows Oct 24")
        }
    }
#endif
