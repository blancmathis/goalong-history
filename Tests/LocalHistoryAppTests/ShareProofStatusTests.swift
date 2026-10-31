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
            XCTAssertTrue(status.detail.hasPrefix("20 minutes confirmées sur 32."))
        }

        func testObservedButUnsealedMinutesExplainWhyAndOfferSupport() {
            let status = ShareProofStatus.make(observedMinutes: 16, sealedMinutes: 0, recordingEnabled: true)
            XCTAssertFalse(status.canExport)
            // UI-17A (32/55, R7): plain words, what the file holds, and what unblocks it.
            XCTAssertEqual(status.title, "16 minutes, pas encore confirmées par ce Mac")
            XCTAssertTrue(status.detail.hasPrefix("Le fichier contiendra seulement les minutes confirmées."))
            XCTAssertTrue(status.detail.contains("dès la première"))
            XCTAssertTrue(status.detail.contains("signalez un problème"))
            XCTAssertFalse(status.detail.contains("signé"))
            XCTAssertEqual(status.action, .reportProblem)
        }

        func testRecordingOffPointsToSettings() {
            let observed = ShareProofStatus.make(observedMinutes: 1, sealedMinutes: 0, recordingEnabled: false)
            XCTAssertEqual(observed.title, "1 minute, pas encore confirmée par ce Mac")
            XCTAssertTrue(observed.detail.contains("Activez l’enregistrement"))
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
