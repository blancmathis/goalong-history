#if os(macOS)
    import Foundation
    import LocalHistoryCore
    import XCTest
    @testable import LocalHistoryApp

    /// H27: the signed export survives a lost focus, the 10-minute history keeps to recorded times,
    /// and the earned break agrees in number.
    final class T045H27Tests: XCTestCase {
        /// A writer that waits for the test before it writes, and records what the model asked.
        private final class SlowWriter {
            let started = DispatchSemaphore(value: 0)
            let release = DispatchSemaphore(value: 0)
            private let lock = NSLock()
            private var cancelledAtWrite: Bool?
            var sawCancellation: Bool? { lock.lock(); defer { lock.unlock() }; return cancelledAtWrite }

            func write(_ job: ShareExportJob, _ cancellation: @escaping () -> Bool) throws {
                started.signal()
                _ = release.wait(timeout: .now() + 10)
                lock.lock(); cancelledAtWrite = cancellation(); lock.unlock()
                guard !cancellation() else { throw ShareBuildError.cancelled }
                try Data("{}".utf8).write(to: job.destination)
            }
        }

        @MainActor private func model(writer: SlowWriter, revealed: @escaping (URL) -> Void) throws -> DashboardViewModel {
            guard FileManager.default.homeDirectoryForCurrentUser.path.hasPrefix("/tmp/goalong-") else {
                throw XCTSkip("Dashboard tests require an isolated test HOME")
            }
            let config = ConfigManager(), permissions = PermissionManager(), health = CaptureHealthStore(permissions: PermissionManager())
            let agents = try AgentActivityRuntime(rootDirectory: AppPaths.agentActivityDirectory,
                executableURL: URL(fileURLWithPath: "/nonexistent/h27-test"), performInitialDiscovery: false,
                sourceDiscovery: { [] }, onCaptured: { _ in })
            return DashboardViewModel(state: CaptureState(), permissions: permissions, configManager: config,
                sharingRulesStore: SharingRulesStore(), agentActivityRuntime: agents,
                deviceInfo: DeviceIdentityInfo(deviceID: "h27-fixture", publicKeyBase64: "", trustTier: "test", algorithm: "test"),
                eventTapStatus: { false }, currentSuppression: { nil }, captureHealthSnapshot: { health.snapshot },
                onBeginCaptureValidation: {}, onTogglePause: {}, onRequestPermissions: {},
                onSaveConfiguration: { try config.save($0) }, onDeleteDetails: { _, done in done(.success(0)) },
                onDeleteTargetedDetails: { _, done in done(.success(0)) },
                shareExportWriter: writer.write, revealExportedFile: revealed)
        }

        private func destination() throws -> URL {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("h27-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
            return folder.appendingPathComponent("jour.signed-share.json")
        }

        @MainActor private func waitUntilExportEnds(_ model: DashboardViewModel) {
            let deadline = Date().addingTimeInterval(10)
            while model.isExportingShare, Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }

        // D1: Finder click, ⌘H or ⌘M hide the dashboard; the export the user asked for still finishes.
        @MainActor func testShareExportSurvivesLosingKeyAndHiding() throws {
            let writer = SlowWriter()
            var revealed: [URL] = []
            let model = try model(writer: writer, revealed: { revealed.append($0) })
            let file = try destination()
            model.dashboardDidBecomeVisible()
            model.startShareExport(to: file)
            XCTAssertTrue(model.isExportingShare)
            XCTAssertEqual(writer.started.wait(timeout: .now() + 5), .success)

            model.dashboardDidBecomeHidden(discardContents: false)  // window resigns key
            model.dashboardDidBecomeHidden()  // ⌘H or ⌘M
            writer.release.signal()
            waitUntilExportEnds(model)

            XCTAssertEqual(writer.sawCancellation, false)
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
            XCTAssertFalse(model.isExportingShare)
            XCTAssertEqual(model.alert?.title, "Fichier signé exporté")
            XCTAssertEqual(revealed, [file])
        }

        // D1: closing the window cancels the export, and says so in French.
        @MainActor func testShareExportCancelledByWindowCloseSaysSo() throws {
            let writer = SlowWriter()
            var revealed: [URL] = []
            let model = try model(writer: writer, revealed: { revealed.append($0) })
            let file = try destination()
            model.dashboardDidBecomeVisible()
            model.startShareExport(to: file)
            XCTAssertEqual(writer.started.wait(timeout: .now() + 5), .success)

            model.dashboardDidBecomeHidden(discardContents: false)
            model.dashboardWillClose()
            XCTAssertFalse(model.isExportingShare)
            writer.release.signal()
            waitUntilExportEnds(model)

            XCTAssertEqual(writer.sawCancellation, true)
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
            XCTAssertEqual(model.alert?.kind, .error)
            XCTAssertEqual(model.alert?.title, "Export interrompu")
            XCTAssertEqual(model.alert?.message, "La fenêtre a été fermée avant la fin de l’export. Relancez-le.")
            XCTAssertEqual(revealed, [])
        }

        // N1: the 30 s tolerance never creates a row nor an end time after the recorded end.
        func testTenMinuteGroupsKeepToRecordedEnd() throws {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
            let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 27)))
            let start = try XCTUnwrap(calendar.date(bySettingHour: 10, minute: 0, second: 0, of: day))
            let end = try XCTUnwrap(calendar.date(bySettingHour: 10, minute: 9, second: 45, of: day))
            let groups = ComputerHistoryTenMinuteGroup.build(
                sessions: [session(start: start, end: end)],
                day: day, calendar: calendar, now: end.addingTimeInterval(86_400))
            XCTAssertEqual(groups.map(\.start), [start])
            XCTAssertEqual(groups.first?.sessions.map(\.end), [end])

            // A session that ends exactly on a boundary does not open the next slot either.
            let boundary = try XCTUnwrap(calendar.date(bySettingHour: 10, minute: 10, second: 0, of: day))
            let exact = ComputerHistoryTenMinuteGroup.build(
                sessions: [session(start: start, end: boundary)],
                day: day, calendar: calendar, now: boundary.addingTimeInterval(86_400))
            XCTAssertEqual(exact.map(\.start), [start])

            // A single-event session (start == end) keeps its row.
            let single = ComputerHistoryTenMinuteGroup.build(
                sessions: [session(start: end, end: end)],
                day: day, calendar: calendar, now: end.addingTimeInterval(86_400))
            XCTAssertEqual(single.count, 1)
            XCTAssertEqual(single.first?.sessions.map(\.end), [end])
        }

        // N2: « gagnée » agrees with the number of minutes.
        func testEarnedBreakAgreesInNumber() {
            XCTAssertEqual(BlockingFormat.earnedBreak(minutes: 1), "+1 min de pause gagnée pendant vos séances de concentration")
            XCTAssertEqual(BlockingFormat.earnedBreak(minutes: 2), "+2 min de pause gagnées pendant vos séances de concentration")
        }

        private func session(start: Date, end: Date) -> ActivitySession {
            ActivitySession(
                id: "h27", start: start, end: end, appName: "Xcode", bundleIdentifier: "com.apple.dt.Xcode",
                windowTitle: "Document", host: nil, category: "productivity", isWork: true, confidence: 1,
                suppressionReason: nil, eventCount: 3, inputEventCount: 1, softwareAttributedEventCount: 0,
                kindCounts: [:], latestMessage: nil)
        }
    }
#endif
