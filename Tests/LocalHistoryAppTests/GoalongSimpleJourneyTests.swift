#if os(macOS)
import XCTest
import Foundation
import AgentActivity
@testable import LocalHistoryApp
@testable import LocalHistoryCore

final class GoalongSimpleJourneyTests: XCTestCase {
    private let valid = Data(#"{"version":2,"source":"goalong-history","days":[{"date":"2026-09-14","title":"Goalong","summary":"","outcomes":[],"activities":[],"telemetry":{"devices":[{"id":"device-test","name":"Ordinateur","screenSeconds":null,"hourly":null,"apps":[{"id":"app","name":"Éditeur","seconds":1800}]}],"websites":null,"agent":null}}]}"#.utf8)
    func testReadablePreviewUsesActualBytesAndRejectsUnknownContent() throws {
        let parsed = try GoalongReadableShareData(payload: valid)
        XCTAssertEqual(parsed.devices.first?.applications.first?.label, "Éditeur")
        XCTAssertEqual(parsed.devices.first?.applications.first?.seconds, 1800)
        XCTAssertNil(parsed.devices.first?.total); XCTAssertNil(parsed.devices.first?.hourly)
        for replacement in ["\"summary\":\"SECRET\"", "\"summary\":{\"hidden\":\"SECRET\"}"] {
            let text = String(decoding: valid, as: UTF8.self).replacingOccurrences(of: "\"summary\":\"\"", with: replacement)
            XCTAssertThrowsError(try GoalongReadableShareData(payload: Data(text.utf8)))
        }
        let unknown = String(decoding: valid, as: UTF8.self).replacingOccurrences(of: "\"seconds\":1800", with: "\"seconds\":1800,\"unreviewed\":\"SECRET\"")
        XCTAssertThrowsError(try GoalongReadableShareData(payload: Data(unknown.utf8)))
        XCTAssertThrowsError(try GoalongReadableShareData(payload: Data("{}".utf8)))
    }
    func testLocalSourcesAreNotChatGPTConsentAndExclusionChangesInvalidateScope() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("goalong-analysis-choice-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        var policy = GoalongPrivacyPolicy.load(in: root)
        XCTAssertFalse(GoalongAnalysisSelection.load(root: root).isValid(for: policy))
        var scope = GoalongAnalysisSelection(); scope.reviewed = true; scope.computer = true; scope.privacyRevision = policy.revision
        try scope.save(root: root)
        XCTAssertTrue(GoalongAnalysisSelection.load(root: root).isValid(for: policy))
        policy.revision = "changed"
        XCTAssertFalse(GoalongAnalysisSelection.load(root: root).isValid(for: policy))
    }
    func testBasicChatGPTContextDoesNotContainWindowTextOrExcludedApplications() throws {
        let day = Calendar.current.startOfDay(for: Date())
        let events = [
            HistoryEvent(sessionID: "test", timestamp: day.addingTimeInterval(36000), kind: .applicationActivated,
                app: .init(name: "Editor", bundleIdentifier: "test.editor", processIdentifier: 0),
                window: .init(title: "SECRET DOCUMENT", role: nil, subrole: nil)),
            HistoryEvent(sessionID: "test", timestamp: day.addingTimeInterval(36060), kind: .applicationActivated,
                app: .init(name: "PRIVATE APP", bundleIdentifier: "test.private", processIdentifier: 1),
                window: .init(title: "SECRET MESSAGE", role: nil, subrole: nil)),
            HistoryEvent(sessionID: "test", timestamp: day.addingTimeInterval(36120), kind: .heartbeat,
                app: .init(name: "PRIVATE APP", bundleIdentifier: "test.private", processIdentifier: 1))
        ]
        let activity = ActivityAnalysisEngine.analyze(events: events, day: day)
        var scope = GoalongAnalysisSelection(); scope.computer = true
        var policy = GoalongPrivacyPolicy(); policy.applications = ["test.private": "PRIVATE APP"]
        let context = try ChatGPTRecapContextBuilder.selectedContext(day: day, activity: activity, memory: nil,
            screenTime: nil, agents: AgentActivityOverview(day: day), sourceAbsent: false, selection: scope, privacy: policy)
        XCTAssertFalse(context.renderedData.contains("SECRET"))
        XCTAssertFalse(context.renderedData.contains("PRIVATE APP"))
        XCTAssertFalse(context.renderedData.contains("test.private"))
        XCTAssertTrue(context.renderedData.contains("Editor"))
        XCTAssertNil(context.computerHistory)
        XCTAssertEqual(context.sourceCounts.semanticSnapshots, 0)
    }
    func testOnboardingHasThreeStepsWithLegacyWelcomeForwardingSafely() {
        XCTAssertEqual(SetupStep.allCases, [.privacy, .sources, .ready])
        XCTAssertEqual(SetupStep.welcome.next, .privacy)
        XCTAssertEqual(SetupStep.privacy.next, .sources)
        XCTAssertEqual(SetupStep.sources.next, .ready)
        XCTAssertNil(SetupStep.ready.next)
    }
    @MainActor func testOpeningOneOffShareDoesNotRewriteApprovedSchedule() {
        let suite = "goalong-one-off-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let sender = GoalongWebsiteAutoSender(defaults: defaults, root: FileManager.default.temporaryDirectory.appendingPathComponent(suite), sourceConsent: { _ in true })
        let model = GoalongWebsiteSharingModel(autoSender: sender)
        let before = sender.savedConfiguration?.identifier
        model.presentSingleDay(Date())
        XCTAssertEqual(model.draft.delivery, .once)
        XCTAssertEqual(sender.savedConfiguration?.identifier, before)
        XCTAssertFalse(sender.enabled)
    }
}
#endif
