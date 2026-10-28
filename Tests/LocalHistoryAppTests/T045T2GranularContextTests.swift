#if os(macOS)
    import XCTest
    @testable import LocalHistoryApp
    @testable import LocalHistoryCore

    /// T-045 T2: `buildGranular` refuses unreviewed selections and builds an empty-source context. It only reads the
    /// data root; the run script gives it a throwaway HOME.
    final class T045T2GranularContextTests: XCTestCase {
        private let day = T045T2Fixtures.date(2026, 3, 10)
        override func setUpWithError() throws { try T045T2Fixtures.requireThrowawayDataRoot() }

        private let refusal = "Vérifiez les données autorisées pour ChatGPT."

        private func selection(reviewed: Bool = true, scope: GoalongAnalysisScope? = GoalongAnalysisScope(conversationFolderIDs: [])) -> GoalongAnalysisSelection {
            var value = GoalongAnalysisSelection()
            value.reviewed = reviewed
            value.conversations = true
            value.scope = scope
            value.privacyRevision = GoalongPrivacyPolicy.load(in: AppPaths.applicationSupportDirectory).revision
            return value
        }

        private func build(_ selection: GoalongAnalysisSelection) throws -> ChatGPTRecapContext {
            try ChatGPTRecapContextBuilder.buildGranular(
                day: day, deviceID: "", includeScreenTime: true, includeAgentActivity: true, selection: selection)
        }

        private func assertRefused(_ selection: GoalongAnalysisSelection, _ message: String? = nil, line: UInt = #line) {
            XCTAssertThrowsError(try build(selection), line: line) { error in
                guard case CodexAppServerError.generationFailed(let text) = error else {
                    return XCTFail("unexpected error \(error)", line: line)
                }
                XCTAssertEqual(text, message ?? refusal, line: line)
            }
        }

        func testRefusesASelectionWithoutScope() { assertRefused(selection(scope: nil)) }
        func testRefusesAnUnreviewedSelection() { assertRefused(selection(reviewed: false)) }
        func testRefusesASelectionWithNoSource() {
            var value = selection()
            value.conversations = false
            assertRefused(value)
        }

        func testRefusesASelectionMadeForAnotherPrivacyRevision() {
            var value = selection()
            value.privacyRevision = "an-older-revision"
            assertRefused(value)
        }

        func testRefusesAnUnconfirmedFolderList() {
            var value = selection()
            value.scope?.conversationFolderIDs = nil
            assertRefused(value)
        }

        func testBuildsAnEmptyConversationContextWithoutConsent() throws {
            try T045T2Fixtures.disableConsent(.aiConversations, in: self)
            let context = try build(selection())
            let dayKey = ActivityAnalysisPaths.dayString(day)
            XCTAssertEqual(dayKey, "2026-03-10")
            XCTAssertTrue(context.renderedData.contains("\"date\" : \"\(dayKey)\""))
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(context.renderedData.utf8)) as? [String: Any])
            let chosen = try XCTUnwrap(payload["conversations_choisies"] as? [Any], "the key must hold a list")
            XCTAssertTrue(chosen.isEmpty, "no conversation was chosen: \(chosen)")
            XCTAssertFalse(context.renderedData.contains("applications_sur_ce_Mac"), "computer data was not selected")
            XCTAssertFalse(context.renderedData.contains("temps_ecran_Apple"), "Screen Time was not selected")
            XCTAssertEqual(context.digest, SHA256Digest.hashHex(context.renderedData))
            XCTAssertEqual(context.sourceCounts.localEvents, 0)
            XCTAssertEqual(context.sourceCounts.agentCaptures, 0)
            XCTAssertEqual(context.sourceCounts.agentMessages, 0)
            XCTAssertEqual(context.sourceCounts.screenTimeDevices, 0)
            XCTAssertNil(context.sourceCounts.developerProjects)
            XCTAssertNil(context.computerHistory)
            XCTAssertTrue(context.localJournalSourceAbsent)
            XCTAssertEqual(context.systemSourceItemCount, 0)
            XCTAssertEqual(context.activity.headline, "Données choisies pour ChatGPT")
            XCTAssertTrue(context.activity.applications.isEmpty)
            XCTAssertFalse(context.hasMeaningfulData)
            XCTAssertEqual(context.day, day)
        }
    }
#endif
