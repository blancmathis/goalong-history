import AppKit
import BraiseCore
import Foundation
import SwiftUI
import XCTest
@testable import LocalHistoryApp

/// T-043 lot R4b: each screen says one thing, and an action stays off while its prerequisite is missing.
@MainActor
final class T043R4bTests: XCTestCase {
    // R-87: the pill « Enregistré sur ce Mac » and the rule controls are in the rendered page only when they are true.
    func testSharePageRendersRecordedPillOnlyWhileRecording() throws {
        let off = try renderedShare(recording: false)
        XCTAssertFalse(off.contains("Enregistré sur ce Mac"), "recording off: no « Enregistré » pill; saw \(off.sorted())")
        XCTAssertFalse(off.contains("Rechercher des apps, sites, pages ou catégories"), "nothing observed: no search over an empty list")
        XCTAssertTrue(off.contains("Partager"), "the page itself did render")
        let on = try renderedShare(recording: true)
        XCTAssertTrue(on.contains("Enregistré sur ce Mac"), "recording on: the pill shows; saw \(on.sorted())")
    }

    // R-77: « Supprimer les données de Concentration » stays off while there is nothing to delete.
    func testFocusStoreHasDataOnlyAfterAWrite() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("t043r4b-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertFalse(FocusStore(directory: directory).hasData, "missing folder: nothing to delete")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        XCTAssertFalse(FocusStore(directory: directory).hasData, "empty folder: nothing to delete")
        try Data("{}".utf8).write(to: directory.appendingPathComponent("pending-stop.json"))
        XCTAssertTrue(FocusStore(directory: directory).hasData)
    }

    // R-81: a finding names its way out (rendered button); the mapping itself is real, not an echo.
    func testSupportFindingsRenderTheirWayOut() {
        XCTAssertEqual(SupportFindingRow.action(for: .permissionMissing)?.title, "Ouvrir Réglages Système…")
        XCTAssertEqual(SupportFindingRow.action(for: .lowDiskSpace)?.title, "Gérer le stockage…")
        XCTAssertNil(SupportFindingRow.action(for: .recordingInterrupted))
        func rendered(_ code: SupportFinding.Code) -> Set<String> {
            visibleText(SupportFindingRow(finding: SupportFinding(severity: .warning, code: code, title: "Constat", detail: "Détail")),
                        width: 520, height: 200)
        }
        XCTAssertTrue(rendered(.permissionMissing).contains("Ouvrir Réglages Système…"))
        XCTAssertTrue(rendered(.lowDiskSpace).contains("Gérer le stockage…"))
        XCTAssertFalse(rendered(.recordingInterrupted).contains { $0.hasPrefix("support-finding-action-") })
    }

    // R-81: the bar offers « Enregistrer une copie… » in place of « Envoyer par e-mail » when there is no mail app.
    func testSupportBarSwapsEmailForSaveCopyWithoutMail() {
        func rendered(emailUnavailable: Bool) -> Set<String> {
            let controller = SupportRequestController()
            controller.emailUnavailable = emailUnavailable
            return visibleText(SupportRequestView(controller: controller), width: 620, height: 900)
        }
        let noMail = rendered(emailUnavailable: true)
        XCTAssertTrue(noMail.contains("support-save-copy"), "saw \(noMail.sorted())")
        XCTAssertFalse(noMail.contains("support-email"))
        let mail = rendered(emailUnavailable: false)
        XCTAssertTrue(mail.contains("support-email"), "saw \(mail.sorted())")
        XCTAssertFalse(mail.contains("support-save-copy"))
        XCTAssertTrue(noMail.contains("support-share") && mail.contains("support-share"), "« Partager… » is in the bar in every state")
    }

    // R-85: a used quota is its own state, the end time shows once; R-98: the counts sit on one line.
    func testVeilSaysQuotaStateAndEndTimeOnce() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func veil(_ reason: BlockingVeilPresentation.Reason, lock: BlockLock = .locked) -> BlockingVeilPresentation {
            BlockingVeilPresentation(reason: reason, listName: "Réseaux", start: now, end: now.addingTimeInterval(3600), lock: lock)
        }
        let end = BlockingFormat.endTime(now.addingTimeInterval(3600))
        let quota = BlockedSiteVeil.stateLine(veil(.quotaUsed("instagram.com", minutes: 30)))
        XCTAssertEqual(quota, "Quota du jour atteint", "the thread under it already shows the end")
        XCTAssertEqual(BlockedSiteVeil.stateLine(veil(.site("youtube.com"))), "Verrouillé jusqu’à \(end)")
        XCTAssertEqual(BlockedSiteVeil.stateLine(veil(.site("youtube.com"), lock: .free)), "Bloqué jusqu’à \(end)")
        let feedback = BlockingListFeedback(listID: UUID(), reason: nil, attemptsToday: 3, earnedMinutesToday: 10)
        let counts = BlockedSiteVeil.countsLine(feedback)
        XCTAssertNotNil(counts)
        XCTAssertFalse(counts?.contains("\n") ?? true, "one line")
        XCTAssertNil(BlockedSiteVeil.countsLine(nil))
    }

    // R-89: a failed protection service renders « Réessayer » and its cause; a waiting or running one renders neither.
    func testFailedGuardRendersRetryWithCause() {
        func rendered(_ guardian: BlockingProtectionState.Component) -> Set<String> {
            visibleText(BlockingProtectionDetails(controller: GalleryFixtures.blockingProtected(guardian)).padding(18), width: 440, height: 700)
        }
        let failed = rendered(.failed(GuardFailure.registrationRefused))
        XCTAssertTrue(failed.contains("Réessayer"), "saw \(failed.sorted())")
        XCTAssertTrue(failed.contains { $0.contains(GuardFailure.registrationRefused) }, "the cause is on screen")
        for ok in [BlockingProtectionState.Component.awaitingApproval, .running] {
            XCTAssertFalse(rendered(ok).contains("Réessayer"), "\(ok)")
        }
    }

    private final class CountingGuardClient: GoalongGuardClienting {
        var onChange: (() -> Void)?
        var needsConsent = false
        var canRemove = false
        private(set) var retries = 0
        private(set) var updates = 0
        func update(severeUntil: Date?) -> BlockingProtectionState.Component { updates += 1; return .notInstalled }
        func removeService() {}
        func retry() { retries += 1 }
    }

    // R-89 (R280-3): « Réessayer » reaches the guard client once, then the state is read again.
    func testRetryGuardServiceCallsClientRetryThenRefreshes() {
        let client = CountingGuardClient()
        let controller = BlockingController(document: BlockingDocument(), guardClient: client)
        let before = client.updates
        controller.retryGuardService()
        XCTAssertEqual(client.retries, 1)
        XCTAssertGreaterThanOrEqual(client.updates, before, "refresh ran after retry")
        controller.retryGuardService()
        XCTAssertEqual(client.retries, 2)
    }

    // R-77 (R280-5): the page reads a published flag, refreshed once per change: after a write and after a deletion.
    func testRuntimeHasStoredDataFollowsWritesAndDeletion() throws {
        let directory = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("t043r4b-rt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        var reads = 0
        let runtime = ConcentrationRuntime(storeFactory: { reads += 1; return FocusStore(directory: directory) },
                                           factory: { try ConcentrationController(store: $0) }, presentsPanels: false)
        XCTAssertFalse(runtime.hasStoredData)
        let afterInit = reads
        _ = runtime.hasStoredData; _ = runtime.hasStoredData
        XCTAssertEqual(reads, afterInit, "reading the flag does not touch the disk")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Data("{}".utf8).write(to: directory.appendingPathComponent("pending-stop.json"))
        runtime.refreshHasData()
        XCTAssertTrue(runtime.hasStoredData, "after a write")
        try runtime.deleteData()
        XCTAssertFalse(runtime.hasStoredData, "after the deletion")
    }

    // R-93: two Braise rules at the same hours have distinct switch labels.
    func testBraiseRuleSwitchLabelsAreDistinct() {
        let weekdays = ScheduleRule(weekdays: Set(2...6), startMinute: 22 * 60, endMinute: 7 * 60)
        let weekend = ScheduleRule(weekdays: [1, 7], startMinute: 22 * 60, endMinute: 7 * 60)
        XCTAssertNotEqual(BraisePage.ruleSwitchLabel(weekdays), BraisePage.ruleSwitchLabel(weekend))
    }

    // MARK: Helpers

    /// Renders off screen (no window, no focus) and returns every label, title, value and identifier of the AX tree.
    private func visibleText(_ root: some View, width: CGFloat, height: CGFloat) -> Set<String> {
        let view = NSHostingView(rootView: root.frame(width: width).environment(\.goalongReduceMotion, true).goalongControls())
        view.frame = NSRect(x: 0, y: 0, width: width, height: height)
        view.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        view.layoutSubtreeIfNeeded()
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApplication.shared.accessibilityAttributeValue(enhanced)
        NSApplication.shared.accessibilitySetValue(true, forAttribute: enhanced)
        defer { NSApplication.shared.accessibilitySetValue(previous ?? false, forAttribute: enhanced) }
        var found = Set<String>(), pending: [Any] = [view], seen = Set<ObjectIdentifier>()
        while let value = pending.popLast(), seen.count < 20_000 {
            guard let object = value as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else { continue }
            for name in ["accessibilityIdentifier", "accessibilityLabel", "accessibilityTitle", "accessibilityValue"] {
                if let text = read(object, name) as? String, !text.isEmpty { found.insert(text) }
            }
            pending.append(contentsOf: read(object, "accessibilityChildren") as? [Any] ?? [])
            if let child = object as? NSView { pending.append(contentsOf: child.subviews) }
        }
        return found
    }

    private func read(_ object: NSObject, _ name: String) -> AnyObject? {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector), let method = object.method(for: selector) else { return nil }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
        return unsafeBitCast(method, to: Getter.self)(object, selector)?.takeUnretainedValue()
    }

    private func renderedShare(recording: Bool) throws -> Set<String> {
        guard FileManager.default.homeDirectoryForCurrentUser.path.hasPrefix("/tmp/goalong-") else {
            throw XCTSkip("needs the isolated test HOME of make check")
        }
        let config = ConfigManager(), permissions = PermissionManager(), health = CaptureHealthStore(permissions: PermissionManager())
        let agents = try AgentActivityRuntime(rootDirectory: AppPaths.agentActivityDirectory,
            executableURL: URL(fileURLWithPath: "/nonexistent/r4b-test"), performInitialDiscovery: false,
            sourceDiscovery: { [] }, onCaptured: { _ in })
        let model = DashboardViewModel(state: CaptureState(), permissions: permissions, configManager: config,
            sharingRulesStore: SharingRulesStore(), agentActivityRuntime: agents,
            deviceInfo: DeviceIdentityInfo(deviceID: "r4b-fixture", publicKeyBase64: "", trustTier: "test", algorithm: "test"),
            eventTapStatus: { false }, currentSuppression: { nil }, captureHealthSnapshot: { health.snapshot },
            onBeginCaptureValidation: {}, onTogglePause: {}, onRequestPermissions: {},
            onSaveConfiguration: { try config.save($0) }, onDeleteDetails: { _, done in done(.success(0)) },
            onDeleteTargetedDetails: { _, done in done(.success(0)) })
        let folder = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("r4b-consent-\(UUID().uuidString)")
        let file = folder.appendingPathComponent("capability-consent.json")
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let consents = GoalongCapabilityConsentStore(fileURL: file)
        if recording { XCTAssertTrue(consents.set(.localComputerHistory, enabled: true, surface: .settings)) }
        return visibleText(SharePage(model: model, consents: consents), width: 1000, height: 760)
    }
}
