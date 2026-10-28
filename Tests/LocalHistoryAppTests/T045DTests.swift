#if os(macOS)
    import Foundation
    import XCTest
    @testable import LocalHistoryApp

    /// T-045 D: small defects left open by the H1 and H2 reviews.
    final class T045DTests: XCTestCase {
        // D-149a: after a zone change the Bilan day moves to its midnight in the new zone, but the
        // day overview kept the bounds read in the old zone. It must be read again for the new instant.
        func testDayOverviewIsReadAgainForTheNewZoneAfterATimeZoneChange() throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let originalZone = NSTimeZone.default
            defer { NSTimeZone.default = originalZone }
            NSTimeZone.default = try XCTUnwrap(TimeZone(identifier: "Europe/Paris"))
            let lock = NSLock()
            var requested: [Date] = []
            let runtime = ChatGPTRecapRuntime(
                chatHistoryStore: ChatGPTHistoryStore(rootDirectory: root.appendingPathComponent("history")),
                recapsDirectory: root.appendingPathComponent("recaps"),
                executableLocator: { nil },
                sessionFactory: { _ in throw NSError(domain: "T045D", code: 1) },
                delayedAutomaticScheduler: { _ in },
                analysisConsentProvider: { true },
                dayOverviewReader: { day in
                    lock.lock(); requested.append(day); lock.unlock()
                    throw NSError(domain: "T045D", code: 2)
                }
            )
            runtime.configure(deviceID: "t045d-device")
            let oct25 = try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 12)))
            runtime.selectDay(oct25)
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            NSTimeZone.default = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
            NotificationCenter.default.post(name: .NSSystemTimeZoneDidChange, object: nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            lock.lock(); let last = requested.last; lock.unlock()
            XCTAssertEqual(last, runtime.selectedDay, "The overview still holds the old zone's day bounds")
        }
    }
#endif
