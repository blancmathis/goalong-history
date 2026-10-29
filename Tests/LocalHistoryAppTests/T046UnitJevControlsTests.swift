#if os(macOS)
import Foundation
import XCTest
@testable import LocalHistoryApp

/// T-046 L9 lot 2 : ce que font les commandes de Jev (pause, reprise, extraits), sans vue.
@MainActor final class T046UnitJevControlsTests: XCTestCase {
    private func monitor(enabled: Bool, root: URL) throws -> (JevMonitor, GoalongCapabilityConsentStore) {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let consents = GoalongCapabilityConsentStore(fileURL: root.appendingPathComponent("consents.json"))
        if enabled { XCTAssertTrue(consents.set(.jevMonitoring, enabled: true, surface: .settings)) }
        let defaults = UserDefaults(suiteName: "t046-jev-" + UUID().uuidString)!
        let m = JevMonitor(scopePreferences: JevMonitoringPreferences(defaults: defaults), consents: consents,
                           sessionProvider: { nil }, inbox: JevIngress(notificationCenter: NotificationCenter()),
                           localRoot: root)
        return (m, consents)
    }
    private func tempRoot() -> URL { URL(fileURLWithPath: "/private/tmp/t046-jev-" + UUID().uuidString) }

    func testPresetBreakButtonsStartATimedBreakAndResumeEndsIt() throws {
        let root = tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let (m, _) = try monitor(enabled: true, root: root)
        for minutes in JevQuickPauseControl.menuItems(enabled: true, breakRunning: false).durations {
            m.startBreak(minutes: minutes)
            XCTAssertNotNil(m.timedBreak, "\(minutes) min")
            XCTAssertGreaterThan(m.remainingSeconds, (minutes - 1) * 60)
            XCTAssertLessThanOrEqual(m.remainingSeconds, minutes * 60)
            m.endBreak()
            XCTAssertNil(m.timedBreak); XCTAssertEqual(m.remainingSeconds, 0)
            XCTAssertTrue(m.enabled, "reprendre ne coupe jamais la surveillance")
        }
    }
    func testStepperRangeIsAcceptedAndOutOfRangeBreakIsRefused() throws {
        let root = tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let (m, _) = try monitor(enabled: true, root: root)
        m.startBreak(minutes: 0); XCTAssertNil(m.timedBreak)
        m.startBreak(minutes: 1); XCTAssertNotNil(m.timedBreak); m.endBreak()
        m.startBreak(minutes: 120); XCTAssertNotNil(m.timedBreak); m.endBreak()
        m.startBreak(minutes: 100_000); XCTAssertNil(m.timedBreak)
    }
    func testBreakIsNotOfferedWhileMonitoringIsOff() throws {
        let root = tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let (m, _) = try monitor(enabled: false, root: root)
        m.startBreak(minutes: 10)
        XCTAssertNil(m.timedBreak)
        XCTAssertEqual(JevQuickPauseControl.menuItems(enabled: false, breakRunning: false).durations, [])
    }
    func testBreakIsWrittenToDiskAndReloadedByANewMonitor() throws {
        let root = tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let (m, consents) = try monitor(enabled: true, root: root)
        m.startBreak(minutes: 15)
        let defaults = UserDefaults(suiteName: "t046-jev-" + UUID().uuidString)!
        let reloaded = JevMonitor(scopePreferences: JevMonitoringPreferences(defaults: defaults), consents: consents,
                                  sessionProvider: { nil }, inbox: JevIngress(notificationCenter: NotificationCenter()),
                                  localRoot: root)
        XCTAssertEqual(reloaded.timedBreak, m.timedBreak)
        XCTAssertGreaterThan(reloaded.remainingSeconds, 14 * 60)
    }
    func testResetUnreadableBreakClearsTheFlagAndTheNotice() throws {
        let root = tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JevLocalFiles.write(Data("not json".utf8), name: "break.json", root: root)
        let (m, _) = try monitor(enabled: true, root: root)
        XCTAssertTrue(m.breakStorageInvalid)
        XCTAssertEqual(m.error, JevMonitor.unreadableBreakNotice)
        m.endBreak()
        XCTAssertFalse(m.breakStorageInvalid); XCTAssertNil(m.error); XCTAssertNil(m.timedBreak)
    }
    func testMenuLabelsMatchTheMonitorState() {
        XCTAssertEqual(String(format: "Surveillance en pause : %02d:%02d restantes", 605 / 60, 605 % 60),
                       "Surveillance en pause : 10:05 restantes")
        XCTAssertEqual(String(format: "Surveillance en pause : %02d:%02d restantes", 59 / 60, 59 % 60),
                       "Surveillance en pause : 00:59 restantes")
        let items = JevQuickPauseControl.menuItems(enabled: true, breakRunning: true)
        XCTAssertTrue(items.resume)
    }
    func testDisablingFromTheMenuTurnsConsentOffAndCancelsTheBreak() throws {
        let root = tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let (m, consents) = try monitor(enabled: true, root: root)
        m.setEnabled(false)
        XCTAssertFalse(consents.isEnabled(.jevMonitoring)); XCTAssertFalse(m.enabled)
        XCTAssertEqual(m.status, "Surveillance désactivée")
    }
    func testExcerptSwitchOffStoresFalseAndOnStoresTrueOnlyAfterConfirmation() {
        let key = JevMonitor.excerptKey
        let before = UserDefaults.standard.object(forKey: key)
        defer { if let before { UserDefaults.standard.set(before, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } }
        let m = JevMonitor(loadLocalSettings: false)
        m.setIncludeText(true); XCTAssertTrue(UserDefaults.standard.bool(forKey: key))
        m.setIncludeText(false); XCTAssertFalse(UserDefaults.standard.bool(forKey: key))
        XCTAssertFalse(m.includeText, "sans « Texte affiché », aucun extrait n’est joint")
    }
}
#endif
