import Foundation
import XCTest

@testable import LocalHistoryCore

final class ComputerHistorySupportMatchingTests: XCTestCase {
    /// The byte prefilter must never change an answer of the plain `contains` scan.
    func testContainsAnyMatchesPlainScanOnTrickyText() {
        let markers = [
            " done ", " error ", " termine ", " terminé ", "e\u{301}", "\r", "\n", "a\r\nb",
            "café", " sent ", "x",
        ]
        let texts = [
            "", " done ", "it is done now", " done\u{301} ", " Done ", " done \u{301}",
            "c'est terminé ", " termine\u{301} ", "cafe\u{301} ", "café", "a\r\nb", "a\rb",
            "line\r\n done \r\n", "emoji 🧑‍💻 sent ", " sent ", "σ error ς", "x\u{301}",
            "no marker here", "\u{FEFF} error ",
        ]
        for text in texts {
            for marker in markers {
                XCTAssertEqual(
                    ComputerHistorySupport.containsAny(text, markers: [marker]),
                    text.contains(marker),
                    "\(text.debugDescription) / \(marker.debugDescription)"
                )
            }
            XCTAssertEqual(
                ComputerHistorySupport.containsAny(text, markers: markers),
                markers.contains { text.contains($0) },
                text.debugDescription
            )
        }
    }
}
