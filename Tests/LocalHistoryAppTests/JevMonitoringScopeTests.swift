#if os(macOS)
import XCTest
@testable import LocalHistoryApp

final class JevMonitoringScopeTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "jev-scope-" + UUID().uuidString, value = UserDefaults(suiteName: name)!
        addTeardownBlock { value.removePersistentDomain(forName: name) }; return value
    }
    @MainActor func testMissingScopePreservesAlwaysWithoutWritingAndExplicitChoicePersists() {
        let d = defaults(), p = JevMonitoringPreferences(defaults: d)
        XCTAssertEqual(p.scope, .always); XCTAssertNil(d.object(forKey: JevMonitoringPreferences.storageKey))
        p.setScope(.sessionsOnly)
        XCTAssertEqual(JevMonitoringPreferences(defaults: d).scope, .sessionsOnly)
        p.setScope(.always); XCTAssertEqual(JevMonitoringPreferences(defaults: d).scope, .always)
        XCTAssertTrue(JevMonitoringScope.always.permits(sessionActive: false))
        XCTAssertFalse(JevMonitoringScope.sessionsOnly.permits(sessionActive: false))
        XCTAssertTrue(JevMonitoringScope.sessionsOnly.permits(sessionActive: true))
    }
    @MainActor func testCorruptOrFutureScopeFailsClosedUntilExplicitSave() {
        for data in [Data("bad".utf8), Data(#"{"schema":2,"scope":"always"}"#.utf8), Data(#"{"schema":1,"scope":"future"}"#.utf8)] {
            let d = defaults(); d.set(data, forKey: JevMonitoringPreferences.storageKey)
            let p = JevMonitoringPreferences(defaults: d)
            XCTAssertNotNil(p.error); XCTAssertEqual(p.scope, .sessionsOnly)
            XCTAssertEqual(d.data(forKey: JevMonitoringPreferences.storageKey), data)
            p.setScope(.always); XCTAssertNil(p.error)
        }
    }
    @MainActor func testWaitingDisablesIngressImmediatelyAndScopeChangesGrantNoConsent() throws {
        let root = URL(fileURLWithPath: "/private/tmp/jev-scope-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let consents = GoalongCapabilityConsentStore(fileURL: root.appendingPathComponent("consents.json"))
        let p = JevMonitoringPreferences(defaults: defaults()), inbox = JevIngress(notificationCenter: NotificationCenter())
        var session: UUID?
        let monitor = JevMonitor(scopePreferences: p, consents: consents, sessionProvider: { session },
                                 inbox: inbox, loadLocalSettings: false)
        monitor.setScope(.sessionsOnly)
        XCTAssertFalse(consents.isEnabled(.jevMonitoring)); XCTAssertFalse(consents.isEnabled(.localComputerHistory))
        XCTAssertEqual(monitor.status, "Surveillance désactivée")
        XCTAssertTrue(consents.set(.jevMonitoring, enabled: true, surface: .settings))
        monitor.start()
        XCTAssertEqual(monitor.status, "En attente d’une séance"); XCTAssertFalse(inbox.isEnabled)
        session = UUID(); NotificationCenter.default.post(name: .goalongFocusSessionDidChange, object: nil)
        XCTAssertTrue(monitor.status.contains("connexion API"), "Session scope still respects the missing key")
        inbox.configure(enabled: true); let generation = inbox.generation
        session = nil; NotificationCenter.default.post(name: .goalongFocusSessionDidChange, object: nil)
        XCTAssertEqual(monitor.status, "En attente d’une séance"); XCTAssertFalse(inbox.isEnabled)
        XCTAssertNotEqual(inbox.generation, generation); XCTAssertEqual(monitor.procrastinationSeconds, 0)
        monitor.setScope(.always)
        XCTAssertTrue(consents.isEnabled(.jevMonitoring)); XCTAssertFalse(consents.isEnabled(.localComputerHistory))
        XCTAssertFalse(inbox.isEnabled)
    }
}
#endif
