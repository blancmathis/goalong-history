#if os(macOS)
import XCTest
@testable import LocalHistoryApp

/// ux-reglages-01: the preview lists every section of the document sent, not only four.
final class GoalongAnalysisHumanPreviewKeysTests: XCTestCase {
    func testExtraKeysCoverSectionsBeyondTheFourTables() {
        let object: [String: Any] = [
            "date": "2026-11-26", "lecture": "x", "limite": "y",
            "applications_sur_ce_Mac": [], "note_du_jour": ["texte": "a"], "contexte_sante_importe": ["pas": 3],
            "developpement": [:], "usages_micro_camera": [:], "agenda_rappels": [:], "autres_appareils": [:], "inconnue": 1,
        ]
        XCTAssertEqual(GoalongAnalysisHumanPreview.extraKeys(object),
                       ["agenda_rappels", "autres_appareils", "contexte_sante_importe", "developpement", "inconnue", "note_du_jour", "usages_micro_camera"])
        XCTAssertTrue(GoalongAnalysisHumanPreview.extraKeys(["date": "d", "lecture": "l", "applications_sur_ce_Mac": []]).isEmpty)
    }
}
#endif
