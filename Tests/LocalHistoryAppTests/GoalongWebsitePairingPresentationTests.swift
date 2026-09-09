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
}
#endif
