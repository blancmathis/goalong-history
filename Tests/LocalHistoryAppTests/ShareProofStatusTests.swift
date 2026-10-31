#if os(macOS)
    import XCTest

    @testable import LocalHistoryApp

    /// UI-65, UI-9 C: « aucune vérifiée » must say why and what to do, in plain words, without changing what is exported.
    final class ShareProofStatusTests: XCTestCase {
        func testSealedMinutesAllowExportWithoutAction() {
            let status = ShareProofStatus.make(observedMinutes: 32, sealedMinutes: 20, recordingEnabled: true)
            XCTAssertTrue(status.canExport)
            XCTAssertNil(status.action)
            XCTAssertEqual(status.title, "Prêt à créer un fichier selon vos règles")
            XCTAssertTrue(status.detail.hasPrefix("20 minutes vérifiées sur 32."))
        }

        func testObservedButUnsealedMinutesExplainWhyAndOfferSupport() {
            let status = ShareProofStatus.make(observedMinutes: 16, sealedMinutes: 0, recordingEnabled: true)
            XCTAssertFalse(status.canExport)
            XCTAssertEqual(status.title, "16 minutes observées, aucune vérifiée")
            XCTAssertTrue(status.detail.contains("vérifiées par ce Mac"))
            // UI-15B (32/55): says why, and that sharing stays possible.
            XCTAssertTrue(status.detail.hasPrefix("Ce Mac n’a pas signé ces minutes"))
            XCTAssertTrue(status.detail.contains("Le partage reste possible"))
            XCTAssertEqual(status.action, .reportProblem)
        }

        func testRecordingOffPointsToSettings() {
            let observed = ShareProofStatus.make(observedMinutes: 1, sealedMinutes: 0, recordingEnabled: false)
            XCTAssertEqual(observed.title, "1 minute observée, aucune vérifiée")
            XCTAssertEqual(observed.action, .openRecordingSettings)
            XCTAssertFalse(observed.canExport)

            let empty = ShareProofStatus.make(observedMinutes: 0, sealedMinutes: 0, recordingEnabled: false)
            XCTAssertEqual(empty.action, .openRecordingSettings)
            XCTAssertEqual(empty.title, "Enregistrement désactivé")
            XCTAssertTrue(empty.detail.contains("Activez l’enregistrement"))
        }

        func testEmptyDayWithRecordingOnSuggestsAnotherDay() {
            let status = ShareProofStatus.make(observedMinutes: 0, sealedMinutes: 0, recordingEnabled: true)
            XCTAssertFalse(status.canExport)
            XCTAssertNil(status.action)
            XCTAssertTrue(status.detail.contains("autre jour"))
        }
    }
#endif
