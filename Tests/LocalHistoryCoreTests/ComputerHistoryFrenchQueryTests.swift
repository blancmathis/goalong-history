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

        for query in [
            "Ou j en etais avant ma pause ?",
            "Où en étais-je avant ma dernière pause ?",
            "Où j'en étais ?",
            "Où j’en étais avant ma pause ?",
        ] {
            let answer = ComputerHistorySearchService(memories: [memory]).ask(
                query,
                now: fixtureStart.addingTimeInterval(30 * 60)
            )

            XCTAssertTrue(answer.answer.contains("Proposition commerciale"))
            XCTAssertEqual(answer.hits.first?.kind, .episode)
            XCTAssertFalse(
                ComputerHistorySearchService.shouldSearchRawSources(for: query),
                "Resume questions should not trigger the expensive raw lexical pass"
            )
        }
    }

    func testResumeQuestionAfterALongIdlePeriodNamesTheLatestWork() {
        let textEdit = fixtureApp("TextEdit")
        let typing = KeyboardSnapshot(
            category: "text_activity",
            key: nil,
            modifiers: [],
            isRepeat: false
        )
        let events = [
            fixtureEvent(
                id: "morning-work",
                sequence: 1,
                offset: 0,
                kind: .typingBurst,
                app: textEdit,
                windowTitle: "Proposition commerciale.md",
                host: nil,
                keyboard: typing
            ),
            fixtureEvent(
                id: "afternoon-work",
                sequence: 2,
                offset: 60 * 60,
                kind: .typingBurst,
                app: textEdit,
                windowTitle: "Rapport Q3.md",
                host: nil,
                keyboard: typing
            ),
        ]
        let memory = ComputerHistoryEngine.analyze(
            events: events,
            day: fixtureStart,
            calendar: utcCalendar
        )

        let answer = ComputerHistorySearchService(memories: [memory]).ask(
            "Où en étais-je avant ma pause ?",
            now: fixtureStart.addingTimeInterval(4 * 60 * 60)
        )

        XCTAssertTrue(answer.answer.contains("Rapport Q3"), answer.answer)
        XCTAssertFalse(answer.answer.contains("Proposition commerciale"))
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

    func testFrenchTodaySummaryAvoidsTheRawJournalPass() {
        for query in [
            "Sur quoi ai-je travaillé aujourd'hui ?",
            "Sur quoi j'ai travaillé aujourd’hui ?",
        ] {
            assertTodaySummaryAvoidsTheRawJournalPass(query)
        }
        XCTAssertFalse(
            ComputerHistorySearchService.shouldSearchRawSources(
                for: "Sur quoi j'ai travaillé hier ?"
            )
        )
    }

    private func assertTodaySummaryAvoidsTheRawJournalPass(_ query: String) {
        let textEdit = fixtureApp("TextEdit")
        let event = fixtureEvent(
            id: "today-summary",
            sequence: 1,
            offset: 0,
            kind: .typingBurst,
            app: textEdit,
            windowTitle: "Plan de lancement.md",
            host: nil,
            keyboard: KeyboardSnapshot(
                category: "text_activity",
                key: nil,
                modifiers: [],
                isRepeat: false
            )
        )
        let memory = ComputerHistoryEngine.analyze(
            events: [event],
            day: fixtureStart,
            calendar: utcCalendar
        )

        let answer = ComputerHistorySearchService(memories: [memory]).ask(
            query,
            now: fixtureStart.addingTimeInterval(60)
        )

        XCTAssertFalse(
            ComputerHistorySearchService.shouldSearchRawSources(for: query)
        )
        XCTAssertTrue(answer.answer.contains(memory.executiveSummary))
        XCTAssertFalse(answer.answer.contains("Most relevant observed history"))
    }

    func testDayWordsMatchWholeWordsOnly() throws {
        let calendar = utcCalendar
        let now = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 8, day: 30, hour: 18))
        )
        let today = calendar.startOfDay(for: now)
        let yesterday = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: today))
        func interval(_ query: String) -> DateInterval? {
            ComputerHistorySearchService.explicitTemporalInterval(
                for: query,
                now: now,
                calendar: calendar
            )
        }

        for query in [
            "Où est le fichier de la proposition ?",
            "mes cahiers",
            "file hierarchy",
            "hierarchy diagram",
        ] {
            XCTAssertNil(interval(query), query)
        }
        for query in ["Qu'ai-je fait hier ?", "fichier ouvert hier", "Hier ?", "le plan d'hier"] {
            XCTAssertEqual(interval(query)?.start, yesterday, query)
            XCTAssertEqual(interval(query)?.end, today, query)
        }
        for query in ["fichiers ouverts aujourd'hui", "fichiers ouverts aujourd’hui"] {
            XCTAssertEqual(interval(query)?.start, today, query)
        }
        let ranged = try XCTUnwrap(interval("fichier ouvert aujourd'hui de 14h à 16h"))
        XCTAssertEqual(ranged.start, today.addingTimeInterval(14 * 3600))
        XCTAssertEqual(ranged.end, today.addingTimeInterval(16 * 3600))
        let week = try XCTUnwrap(calendar.dateInterval(of: .weekOfYear, for: now))
        XCTAssertEqual(interval("fichiers de cette semaine")?.start, week.start)
    }

    func testClockRangesNeedATimeMarkerAndAcceptTypographicDashes() throws {
        let calendar = utcCalendar
        let now = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 8, day: 30, hour: 18))
        )
        let today = calendar.startOfDay(for: now)
        let yesterday = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: today))
        func interval(_ query: String) -> DateInterval? {
            ComputerHistorySearchService.explicitTemporalInterval(
                for: query,
                now: now,
                calendar: calendar
            )
        }

        for query in [
            "comparaison méthode 1 et 2",
            "mode 3 a 4",
            "upgrade from 5 to 6",
            "entre 2 et 3 fichiers",
        ] {
            XCTAssertNil(interval(query), query)
        }
        XCTAssertEqual(interval("hier, entre 2 et 3 fichiers")?.start, yesterday)
        XCTAssertEqual(interval("hier, entre 2 et 3 fichiers")?.end, today)

        for query in ["Qu'ai-je fait hier 14h–16h ?", "hier 14h—16h", "hier de 14h à 16h"] {
            let ranged = try XCTUnwrap(interval(query), query)
            XCTAssertEqual(ranged.start, yesterday.addingTimeInterval(14 * 3600), query)
            XCTAssertEqual(ranged.end, yesterday.addingTimeInterval(16 * 3600), query)
        }
        let morning = try XCTUnwrap(interval("from 9 to 11am"))
        XCTAssertEqual(morning.start, today.addingTimeInterval(9 * 3600))
        XCTAssertEqual(morning.end, today.addingTimeInterval(11 * 3600))
        let french = try XCTUnwrap(interval("de 9 à 11h"))
        XCTAssertEqual(french.start, today.addingTimeInterval(9 * 3600))
        XCTAssertEqual(french.end, today.addingTimeInterval(11 * 3600))
    }

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
}
