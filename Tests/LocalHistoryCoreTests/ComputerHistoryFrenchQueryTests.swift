import Foundation
import XCTest
@testable import LocalHistoryCore

final class ComputerHistoryFrenchQueryTests: XCTestCase {
    func testFrenchResumeQuestionFindsWorkBeforeTheBreak() {
        let textEdit = fixtureApp("TextEdit")
        let safari = fixtureApp("Safari")
        let events = [
            fixtureEvent(
                id: "proposal-work",
                sequence: 1,
                offset: 0,
                kind: .typingBurst,
                app: textEdit,
                windowTitle: "Proposition commerciale.md",
                host: nil,
                keyboard: KeyboardSnapshot(
                    category: "text_activity",
                    key: nil,
                    modifiers: [],
                    isRepeat: false
                )
            ),
            fixtureEvent(
                id: "after-break",
                sequence: 2,
                offset: 25 * 60,
                kind: .urlChanged,
                app: safari,
                windowTitle: "Actualités sans rapport",
                host: "news.example.com"
            ),
        ]
        let memory = ComputerHistoryEngine.analyze(
            events: events,
            day: fixtureStart,
            calendar: utcCalendar
        )

        let answer = ComputerHistorySearchService(memories: [memory]).ask(
            "Ou j en etais avant ma pause ?",
            now: fixtureStart.addingTimeInterval(30 * 60)
        )

        XCTAssertTrue(answer.answer.contains("Proposition commerciale"))
        XCTAssertEqual(answer.hits.first?.kind, .episode)
    }

    func testFrenchResourceQuestionFindsTheProposalDocument() {
        let safari = fixtureApp("Safari")
        let event = fixtureEvent(
            id: "proposal-document",
            sequence: 1,
            offset: 0,
            kind: .urlChanged,
            app: safari,
            windowTitle: "Proposition commerciale — Google Docs",
            host: "docs.google.com"
        )
        let memory = ComputerHistoryEngine.analyze(
            events: [event],
            day: fixtureStart,
            calendar: utcCalendar
        )

        let answer = ComputerHistorySearchService(memories: [memory]).ask(
            "Retrouve le document de proposition commerciale",
            now: fixtureStart.addingTimeInterval(60)
        )

        XCTAssertFalse(answer.hits.isEmpty)
        XCTAssertEqual(answer.hits.first?.kind, .resource)
        XCTAssertEqual(answer.hits.first?.resource?.kind, .document)
    }

    func testFrenchStatusQuestionKeepsBlockedEvidenceExplicit() {
        let safari = fixtureApp("Safari")
        let event = fixtureEvent(
            id: "blocked-ci",
            sequence: 1,
            offset: 0,
            kind: .mouseClick,
            app: safari,
            windowTitle: "Tests CI failed with error database unavailable",
            host: "github.com",
            pointer: PointerSnapshot(
                button: "left",
                x: 100,
                y: 80,
                clickCount: 1
            )
        )
        let memory = ComputerHistoryEngine.analyze(
            events: [event],
            day: fixtureStart,
            calendar: utcCalendar
        )

        let answer = ComputerHistorySearchService(memories: [memory]).ask(
            "Quel travail est bloque ?",
            now: fixtureStart.addingTimeInterval(60)
        )

        XCTAssertTrue(answer.answer.contains("blocked"))
        XCTAssertEqual(answer.hits.first?.status, .blocked)
    }

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
}
