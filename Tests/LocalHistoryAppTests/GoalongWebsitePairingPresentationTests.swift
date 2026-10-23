#if os(macOS)
import AppKit
import XCTest
@testable import LocalHistoryApp

final class GoalongWebsitePairingPresentationTests: XCTestCase {
    @MainActor
    func testConfirmationBelongsToAppWindowAndRepeatedCancellationIsSafe() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let coordinator = GoalongWebsitePairingCoordinator()
        let url = try XCTUnwrap(URL(string: "goalong-history://connect?site=https://example.invalid#" + String(repeating: "a", count: 43)))
        let task = Task { @MainActor in await coordinator.connect(url: url, window: window) }
        for _ in 0..<100 {
            if window.attachedSheet != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNotNil(window.attachedSheet, "Consent must be a sheet of the app window, not a separate menu-bar alert")
        XCTAssertTrue(window.attachedSheet?.sheetParent === window)
        coordinator.cancelPendingPrompt()
        coordinator.cancelPendingPrompt()
        let connected = await task.value
        XCTAssertFalse(connected, "Cancelling must return before exchanging a code or saving access")
        XCTAssertNil(window.attachedSheet)
    }
    @MainActor
    func testOnlyTheSameAccountOnTheSameSiteKeepsTheDailyPlan() {
        XCTAssertTrue(GoalongWebsitePairingCoordinator.keepsSchedule(savedOrigin: "https://a.example", savedAccountID: "acc", newOrigin: "https://a.example", newAccountID: "acc"))
        XCTAssertFalse(GoalongWebsitePairingCoordinator.keepsSchedule(savedOrigin: "https://a.example", savedAccountID: "acc", newOrigin: "https://a.example", newAccountID: "other"))
        XCTAssertFalse(GoalongWebsitePairingCoordinator.keepsSchedule(savedOrigin: "https://a.example", savedAccountID: "acc", newOrigin: "https://b.example", newAccountID: "acc"))
        XCTAssertFalse(GoalongWebsitePairingCoordinator.keepsSchedule(savedOrigin: "https://a.example", savedAccountID: "", newOrigin: "https://a.example", newAccountID: ""))
    }

    @MainActor
    func testConfirmationPromisesToKeepThePlanOnlyWhenItCanBeKept() {
        typealias C = GoalongWebsitePairingCoordinator
        let site = "https://a.example"
        XCTAssertEqual(C.scheduleNotice(planOrigin: nil, savedOrigin: site, savedAccountID: "acc", newOrigin: site), "")
        XCTAssertTrue(C.scheduleNotice(planOrigin: site, savedOrigin: site, savedAccountID: "acc", newOrigin: site).contains("reste programmé"))
        // A plan made with a hand-picked token file has no recorded account: it will be deleted.
        let noAccount = C.scheduleNotice(planOrigin: site, savedOrigin: site, savedAccountID: "", newOrigin: site)
        XCTAssertFalse(noAccount.contains("reste programmé")); XCTAssertTrue(noAccount.contains("sera supprimé"))
        XCTAssertFalse(C.scheduleNotice(planOrigin: "https://b.example", savedOrigin: site, savedAccountID: "acc", newOrigin: site).contains("reste programmé"))
        XCTAssertFalse(C.scheduleNotice(planOrigin: site, savedOrigin: "", savedAccountID: "acc", newOrigin: site).contains("reste programmé"))
    }

    @MainActor
    func testDisconnectPromisesDeletionOnlyForAFileCreatedByPairing() {
        let directory = URL(fileURLWithPath: "/tmp/goalong-connections-\(UUID().uuidString)")
        let managed = directory.appendingPathComponent(UUID().uuidString + ".token").path
        XCTAssertTrue(GoalongWebsitePairingCoordinator.isManagedTokenPath(managed, directory: directory))
        XCTAssertFalse(GoalongWebsitePairingCoordinator.isManagedTokenPath(NSHomeDirectory() + "/Downloads/goalong-token.txt", directory: directory))
        XCTAssertFalse(GoalongWebsitePairingCoordinator.isManagedTokenPath("", directory: directory))
        let picked = GoalongWebsiteConnectionCard.disconnectMessage(tokenPath: NSHomeDirectory() + "/Downloads/goalong-token.txt")
        XCTAssertFalse(picked.contains("supprimé de ce Mac"))
        XCTAssertTrue(picked.contains("restera à sa place"))
    }
}
#endif
