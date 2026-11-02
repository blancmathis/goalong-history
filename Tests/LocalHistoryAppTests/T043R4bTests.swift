import BraiseCore
import Foundation
import XCTest
@testable import LocalHistoryApp

/// T-043 lot R4b: each screen says one thing, and an action stays off while its prerequisite is missing.
@MainActor
final class T043R4bTests: XCTestCase {
    // R-87: a site share without recording shows no « Enregistré sur ce Mac » pill, and no rule controls with nothing tracked.
    func testSharePageShowsRecordedPillOnlyWhileRecording() {
        XCTAssertFalse(SharePage.showsRecordedPill(recordingEnabled: false))
        XCTAssertTrue(SharePage.showsRecordedPill(recordingEnabled: true))
        XCTAssertFalse(UsageRulesList.showsControls(trackedCount: 0))
        XCTAssertTrue(UsageRulesList.showsControls(trackedCount: 3))
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

    // R-81: a finding names its way out; without Mail the bar offers a copy instead of a dead email button.
    func testSupportFindingsAndBarOfferAWayOut() {
        XCTAssertEqual(SupportFindingRow.action(for: .permissionMissing)?.title, "Ouvrir Réglages Système…")
        XCTAssertEqual(SupportFindingRow.action(for: .lowDiskSpace)?.title, "Gérer le stockage…")
        XCTAssertNil(SupportFindingRow.action(for: .recordingInterrupted))
        XCTAssertTrue(SupportRequestView.showsSaveCopyInBar(emailUnavailable: true))
        XCTAssertFalse(SupportRequestView.showsSaveCopyInBar(emailUnavailable: false))
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

    // R-89: a failed protection service offers « Réessayer » and says why; a waiting one does not.
    func testFailedGuardOffersRetryWithCause() {
        var state = BlockingProtectionState()
        state.guardian = .failed(GuardFailure.registrationRefused)
        XCTAssertTrue(BlockingProtectionDetails.showsRetry(state))
        XCTAssertTrue(BlockingProtectionDetails.levelHelp(state)?.contains(" : ") == true, "the cause follows the state")
        state.guardian = .awaitingApproval
        XCTAssertFalse(BlockingProtectionDetails.showsRetry(state))
        state.guardian = .running
        XCTAssertFalse(BlockingProtectionDetails.showsRetry(state))
    }

    // R-93: two Braise rules at the same hours have distinct switch labels.
    func testBraiseRuleSwitchLabelsAreDistinct() {
        let weekdays = ScheduleRule(weekdays: Set(2...6), startMinute: 22 * 60, endMinute: 7 * 60)
        let weekend = ScheduleRule(weekdays: [1, 7], startMinute: 22 * 60, endMinute: 7 * 60)
        XCTAssertNotEqual(BraisePage.ruleSwitchLabel(weekdays), BraisePage.ruleSwitchLabel(weekend))
    }
}
