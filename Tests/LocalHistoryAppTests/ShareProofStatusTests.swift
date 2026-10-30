#if os(macOS)
    import XCTest

    @testable import LocalHistoryApp

    /// UI-65: « 0 minute avec preuve » must say why and what to do, without changing what is exported.
    final class ShareProofStatusTests: XCTestCase {
        func testSealedMinutesAllowExportWithoutAction() {
            let status = ShareProofStatus.make(observedMinutes: 32, sealedMinutes: 20, recordingEnabled: true)
            XCTAssertTrue(status.canExport)
            XCTAssertNil(status.action)
            XCTAssertEqual(status.title, "Prêt à créer un fichier selon vos règles")
        }

        func testObservedButUnsealedMinutesExplainWhyAndOfferSupport() {
            let status = ShareProofStatus.make(observedMinutes: 16, sealedMinutes: 0, recordingEnabled: true)
            XCTAssertFalse(status.canExport)
            XCTAssertEqual(status.title, "16 minutes observées, aucune avec preuve")
            XCTAssertTrue(status.detail.contains("signées par ce Mac"))
            XCTAssertEqual(status.action, .reportProblem)
        }

        func testRecordingOffPointsToSettings() {
            let observed = ShareProofStatus.make(observedMinutes: 1, sealedMinutes: 0, recordingEnabled: false)
            XCTAssertEqual(observed.title, "1 minute observée, aucune avec preuve")
            XCTAssertEqual(observed.action, .openRecordingSettings)
            XCTAssertFalse(observed.canExport)

            let empty = ShareProofStatus.make(observedMinutes: 0, sealedMinutes: 0, recordingEnabled: false)
            XCTAssertEqual(empty.action, .openRecordingSettings)
            XCTAssertTrue(empty.detail.contains("désactivé"))
        }

        func testEmptyDayWithRecordingOnSuggestsAnotherDay() {
            let status = ShareProofStatus.make(observedMinutes: 0, sealedMinutes: 0, recordingEnabled: true)
            XCTAssertFalse(status.canExport)
            XCTAssertNil(status.action)
            XCTAssertTrue(status.detail.contains("autre jour"))
        }

        func testProofSummaryShowsObservedMinutes() {
            XCTAssertEqual(ShareProofStatus.proofSummary(observedMinutes: 16, sealedMinutes: 0),
                           "0 minute avec preuve sur 16 observées")
            XCTAssertEqual(ShareProofStatus.proofSummary(observedMinutes: 1, sealedMinutes: 1),
                           "1 minute avec preuve sur 1 observée")
            XCTAssertEqual(ShareProofStatus.proofSummary(observedMinutes: 0, sealedMinutes: 0),
                           "0 minute avec preuve")
        }
    }
#endif
