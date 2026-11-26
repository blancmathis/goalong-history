#if os(macOS)
import Foundation
import XCTest
@testable import LocalHistoryApp

/// ux-reglages-04: a ready check must reach the alert memory, so the loss after a recovery alerts again.
final class SourceAlertRearmTests: XCTestCase {
    func testLossAfterRecoveryAlertsAgain() {
        let memory = SourceAccessAlertMemory()
        XCTAssertTrue(memory.shouldAlert(.localComputerHistory, .accessibility))
        XCTAssertFalse(memory.shouldAlert(.localComputerHistory, .accessibility))
        XCTAssertFalse(memory.shouldAlert(.localComputerHistory, .ready))
        XCTAssertTrue(memory.shouldAlert(.localComputerHistory, .accessibility))
    }

    /// The call site must not filter ready out before the memory sees it (the first fix stopped there).
    func testExistingConsentCheckPassesReadyToTheMemory() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/LocalHistoryApp/SourceActivation.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "private func validateExistingConsent()"))
        let body = String(source[start.lowerBound...].prefix(900))
        XCTAssertFalse(body.contains("status != .ready else { return }"))
        XCTAssertTrue(body.contains("SourceAccessAlertMemory.shared.shouldAlert(capability, status)"))
    }
}
#endif
