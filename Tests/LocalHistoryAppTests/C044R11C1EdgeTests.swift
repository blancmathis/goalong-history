#if os(macOS)
import Foundation
import XCTest
@testable import LocalHistoryApp

/// T-044 r11 volet C1: permission recovery with two permissions in progress.
/// Each test loops over a witness (must pass) and the faulty case.
final class C044R11C1EdgeTests: XCTestCase {
    /// Local history needs Accessibility AND Input Monitoring. The user opens Settings for both,
    /// then Goalong restarts without a named permission (System Settings quit → AppDelegate.swift:681,
    /// or the sheet's « Redémarrer » → SourceActivation.swift:613). `prepareRelaunch` records the
    /// relaunch only for `activePermission()` (PermissionRecovery.swift:110), i.e. the last one opened.
    /// Expected: after that relaunch, Accessibility still missing → `.repair`, not « relaunch » again.
    /// Witness: only Accessibility in progress → `.repair`.
    func testRelaunchWithTwoPermissionsInProgressCountsForBoth() {
        for both in [false, true] {
            let suite = "C044R11C1-\(UUID().uuidString)"
            let d = UserDefaults(suiteName: suite)!
            defer { d.removePersistentDomain(forName: suite) }
            PermissionRecoveryLedger.record(.settingsOpened, for: .accessibility, defaults: d)
            if both { PermissionRecoveryLedger.record(.settingsOpened, for: .inputMonitoring, defaults: d) }
            // Same code path as PermissionRecovery.prepareRelaunch(permission: nil) on success.
            PermissionRecoveryLedger.recordRelaunchForOpenedPermissions(defaults: d)
            let progress = PermissionRecoveryLedger.load(.accessibility, defaults: d)
            let advice = PermissionRecoveryAdvice.resolve(accessAvailable: false, stableInstallation: true, signatureValid: true,
                                                          runningCopies: 1, identityChanged: false, progress: progress)
            XCTAssertEqual(progress.relaunches, 1, "both=\(both): the relaunch is not counted for Accessibility")
            XCTAssertEqual(advice, .repair, "both=\(both): Accessibility still asks for another relaunch")
        }
    }
}
#endif
