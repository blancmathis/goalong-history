#if os(macOS)
import Foundation
import XCTest
@testable import LocalHistoryApp

final class GoalongPageLoadingTests: XCTestCase {
    private func store() throws -> GoalongCapabilityConsentStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return GoalongCapabilityConsentStore(fileURL: root.appendingPathComponent("consents.json"))
    }
    private func state(_ v: SourceAccessValidation, _ s: GoalongCapabilityConsentStore) -> SourceAccessPresentation {
        .resolve(enabled: s.isEnabled(.localComputerHistory), checking: v.checking, result: v.result)
    }
    func testUnresolvedAccessUsesThePrimaryPageWait() {
        XCTAssertEqual(SourceAccessPresentation.resolve(enabled: true, checking: false, result: nil), .loading)
        XCTAssertEqual(SourceAccessPresentation.resolve(enabled: true, checking: true, result: nil), .loading)
    }
    func testAnImmediateResultDoesNotHoldAnAnimationOpen() throws {
        let s = try store()
        XCTAssertTrue(s.set(.localComputerHistory, enabled: true, surface: .settings))
        let v = SourceAccessValidation(store: s)
        v.validate(.localComputerHistory) { _, done in done(.ready) }
        XCTAssertFalse(v.checking)
        XCTAssertEqual(state(v, s), .content)
    }
    func testADeferredResultEndsTheWaitOnCompletionWithoutATimer() throws {
        let s = try store()
        XCTAssertTrue(s.set(.localComputerHistory, enabled: true, surface: .settings))
        let v = SourceAccessValidation(store: s)
        var finish: ((SourceAccessStatus) -> Void)?
        v.validate(.localComputerHistory) { _, done in finish = done }
        XCTAssertEqual(state(v, s), .loading)
        finish?(.ready)
        XCTAssertEqual(state(v, s), .content)
    }
    func testRevalidatingAnAvailablePageDoesNotCoverItWithALogo() throws {
        let s = try store()
        XCTAssertTrue(s.set(.localComputerHistory, enabled: true, surface: .settings))
        let v = SourceAccessValidation(store: s)
        v.validate(.localComputerHistory) { _, done in done(.ready) }
        var finish: ((SourceAccessStatus) -> Void)?
        v.validate(.localComputerHistory) { _, done in finish = done }
        XCTAssertTrue(v.checking)
        XCTAssertEqual(state(v, s), .content)
        finish?(.accessibility)
        XCTAssertEqual(state(v, s), .issue(.accessibility))
    }
    func testDisabledSourcesHaveNoPageWaitAndAreNeverProbed() throws {
        let s = try store()
        let v = SourceAccessValidation(store: s)
        v.validate(.localComputerHistory) { _, _ in XCTFail("Disabled sources must not be read") }
        XCTAssertEqual(state(v, s), .content)
    }
    func testDeniedAndMissingSourcesEndThePageWait() {
        let issues: [SourceAccessStatus] = [.accessibility, .inputMonitoring, .fullDiskAccess,
            .screenTimeSetup, .unavailable("Source unavailable")]
        for issue in issues {
            XCTAssertEqual(SourceAccessPresentation.resolve(enabled: true, checking: false, result: issue), .issue(issue))
            XCTAssertEqual(SourceAccessPresentation.resolve(enabled: true, checking: true, result: issue), .loading)
            XCTAssertEqual(SourceAccessPresentation.resolve(enabled: false, checking: false, result: issue), .content)
        }
    }
}
#endif
