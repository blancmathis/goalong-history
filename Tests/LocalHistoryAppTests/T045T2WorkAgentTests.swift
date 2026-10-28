#if os(macOS)
    import XCTest
    @testable import LocalHistoryApp
    @testable import LocalHistoryCore

    /// T-045 T2: the guard branches of `GoalongWorkAgent.classify`. The full run needs a ChatGPT session, so it is not
    /// unit-tested; these tests prove that nothing starts and the right reason is shown.
    @MainActor
    final class T045T2WorkAgentTests: XCTestCase {
        private var directory: URL!

        override func setUpWithError() throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("t045t2-workagent-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        override func tearDown() {
            try? FileManager.default.removeItem(at: directory)
        }

        private func agent(definition: GoalongWorkDefinition) -> GoalongWorkAgent {
            let store = GoalongWorkStore(
                fileURL: directory.appendingPathComponent("work-classification.json"),
                definition: { definition }, committedTasks: { [] }, renamedTask: { _, _ in [] })
            return GoalongWorkAgent(store: store, root: directory)
        }

        private let day = T045T2Fixtures.date(2026, 3, 10)

        func testReadinessMessages() {
            XCTAssertEqual(GoalongWorkAgent.Readiness.ready.message, "")
            XCTAssertEqual(GoalongWorkAgent.Readiness.noDefinition.message, "Décrivez d’abord ce qui compte comme travail pour vous.")
            XCTAssertEqual(GoalongWorkAgent.Readiness.historyOff.message, "L’historique de ce Mac est désactivé : il n’y a rien à classer.")
            XCTAssertEqual(GoalongWorkAgent.Readiness.noConsent.message, "Autorisez ChatGPT à classer votre temps.")
            XCTAssertEqual(GoalongWorkAgent.Readiness.notConnected.message, "Connectez votre compte ChatGPT pour lancer le classement.")
            XCTAssertEqual(GoalongWorkAgent.Readiness.paused.message, "Goalong est en pause : le classement reprendra ensuite.")
        }

        func testClassifyWithoutDefinitionShowsThatReasonAndStartsNothing() {
            let agent = agent(definition: GoalongWorkDefinition())
            XCTAssertEqual(agent.readiness, .noDefinition)
            agent.classify(day: day)
            XCTAssertEqual(agent.lastError, "Décrivez d’abord ce qui compte comme travail pour vous.")
            XCTAssertNil(agent.runningDay)
            XCTAssertFalse(agent.isRunning)
        }

        func testAutomaticClassifyStaysSilentWhenNotReady() {
            let agent = agent(definition: GoalongWorkDefinition())
            agent.classify(day: day, userInitiated: false)
            XCTAssertNil(agent.lastError, "an automatic run never shows an error")
            XCTAssertNil(agent.runningDay)
        }

        func testClassifyWithDefinitionButHistoryConsentOffSaysHistoryIsOff() throws {
            try T045T2Fixtures.disableConsent(.localComputerHistory, in: self)
            let agent = agent(definition: GoalongWorkDefinition(goals: "Écrire"))
            XCTAssertEqual(agent.readiness, .historyOff)
            agent.classify(day: day)
            XCTAssertEqual(agent.lastError, "L’historique de ce Mac est désactivé : il n’y a rien à classer.")
            XCTAssertNil(agent.runningDay)
        }

        func testClassifyIfNeededDoesNothingWhenNotReady() {
            let agent = agent(definition: GoalongWorkDefinition())
            agent.classifyIfNeeded([], now: day)
            XCTAssertNil(agent.lastError)
            XCTAssertNil(agent.runningDay)
        }
    }
#endif
