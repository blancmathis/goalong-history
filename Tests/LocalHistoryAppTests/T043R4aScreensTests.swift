#if os(macOS)
import Foundation
import XCTest
@testable import LocalHistoryApp
@testable import LocalHistoryCore

/// T-043 lot R4a: activité, IA, barre des menus, accueil, racine, historique (déc. 1 et 11).
final class T043R4aScreensTests: XCTestCase {
    // R-72: one reading indicator, and the token card waits for the first conversation.
    func testConversationsShowOneReadingIndicator() {
        XCTAssertEqual(AgentActivityPage.scanIndicator(scanning: true, capturesEmpty: true), .emptyState)
        XCTAssertEqual(AgentActivityPage.scanIndicator(scanning: true, capturesEmpty: false), .header)
        XCTAssertEqual(AgentActivityPage.scanIndicator(scanning: false, capturesEmpty: true), .none)
        XCTAssertFalse(AgentActivityPage.showsTokenCard(sourcesUnreadable: false, scanning: true, capturesEmpty: true))
        XCTAssertTrue(AgentActivityPage.showsTokenCard(sourcesUnreadable: false, scanning: true, capturesEmpty: false))
        XCTAssertFalse(AgentActivityPage.showsTokenCard(sourcesUnreadable: true, scanning: false, capturesEmpty: false))
    }

    // R-83: « Afficher le classement » greyed without the Mac's history; a corrected row reads « Modifier ».
    func testWorkReviewNeedsHistoryAndNamesACorrectedRow() {
        XCTAssertFalse(GoalongWorkReviewCard.canLoadReview(historyConsent: false, historyOff: false, loading: false))
        XCTAssertFalse(GoalongWorkReviewCard.canLoadReview(historyConsent: true, historyOff: true, loading: false))
        XCTAssertFalse(GoalongWorkReviewCard.canLoadReview(historyConsent: true, historyOff: false, loading: true))
        XCTAssertTrue(GoalongWorkReviewCard.canLoadReview(historyConsent: true, historyOff: false, loading: false))
        XCTAssertEqual(GoalongWorkReviewCard.correctionMenuTitle(byOwner: true), "Modifier")
        XCTAssertEqual(GoalongWorkReviewCard.correctionMenuTitle(byOwner: false), "Corriger")
    }

    // R-74: the recording banner holds a stopped day; the page adds no empty state repeating it.
    func testStoppedRecordingTodayIsSaidOnceByTheBanner() {
        for kind in [GoalongRecordingStateNotice.Kind.off, .paused, .permissions] {
            XCTAssertTrue(GoalongActivityEmptyCopy.bannerHoldsEmptyDay(isDay: true, isToday: true, eventCount: 0,
                                                                       incompleteDays: 0, purged: false, recording: kind))
        }
        XCTAssertFalse(GoalongActivityEmptyCopy.bannerHoldsEmptyDay(isDay: true, isToday: true, eventCount: 0,
                                                                    incompleteDays: 0, purged: false, recording: .input))
        XCTAssertFalse(GoalongActivityEmptyCopy.bannerHoldsEmptyDay(isDay: true, isToday: true, eventCount: 3,
                                                                    incompleteDays: 0, purged: false, recording: .off))
        XCTAssertFalse(GoalongActivityEmptyCopy.bannerHoldsEmptyDay(isDay: true, isToday: true, eventCount: 0,
                                                                    incompleteDays: 1, purged: false, recording: .off))
        XCTAssertFalse(GoalongActivityEmptyCopy.bannerHoldsEmptyDay(isDay: true, isToday: false, eventCount: 0,
                                                                    incompleteDays: 0, purged: false, recording: .off))
        let storage = GoalongActivityEmptyCopy.copy(isDay: true, isToday: true, eventCount: 0, incompleteDays: 0, purged: false,
                                                    recording: nil, storage: .init(kind: .diskFull, since: nil))
        XCTAssertFalse(storage.message.contains("reprendra seul"), "the banner already says it resumes on its own")
        XCTAssertFalse(storage.message.contains("coupure"))
    }

    // R-80: the bottom bar names what is pending.
    func testPendingSettingsBarNamesTheChanges() {
        let saved = DashboardSettingsDraft(config: .default)
        var draft = saved
        draft.captureClicks.toggle()
        XCTAssertEqual(DashboardSection.pendingChangeSummary(saved: saved, draft: draft), "1 modification en attente : clics")
        draft.captureScroll.toggle()
        XCTAssertEqual(DashboardSection.pendingChangeSummary(saved: saved, draft: draft),
                       "2 modifications en attente : clics, défilement")
    }

    // R-73: an open page of a disabled module keeps its sidebar entry.
    func testOpenDisabledModuleKeepsItsSidebarEntry() {
        XCTAssertTrue(DashboardSection.sidebarSections(modules: [], showing: .ambiance).contains(.ambiance))
        XCTAssertFalse(DashboardSection.sidebarSections(modules: [], showing: .overview).contains(.ambiance))
        XCTAssertEqual(DashboardSection.sidebarSections(modules: [], showing: .braise).suffix(2), [.braise, .settings])
    }

    // R-79: the last onboarding step says the real state.
    func testOnboardingReadyTitleFollowsTheRealState() {
        XCTAssertEqual(LocalHistoryOnboardingView.readyTitle(recordingOn: true, paused: false), "Vous pouvez commencer")
        XCTAssertEqual(LocalHistoryOnboardingView.readyTitle(recordingOn: false, paused: false), "Presque prêt")
        XCTAssertEqual(LocalHistoryOnboardingView.readyTitle(recordingOn: true, paused: true), "Presque prêt")
        // R282-5: a missing macOS permission keeps « Presque prêt ».
        XCTAssertEqual(LocalHistoryOnboardingView.readyTitle(recordingOn: true, paused: false, permissionMissing: true), "Presque prêt")
    }
}
#endif
