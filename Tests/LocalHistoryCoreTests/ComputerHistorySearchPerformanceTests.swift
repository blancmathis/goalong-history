import Foundation
import XCTest

@testable import LocalHistoryCore

final class ComputerHistorySearchPerformanceTests: XCTestCase {
    func testPreparedQueryBoundsRawNormalizedTokensAndExpansions() {
        let oversizedToken = String(
            repeating: "x",
            count: SearchText.maximumQueryTokenUTF8Bytes * 2
        )
        let distinctTokens = (0..<500).map { "token\($0)" }.joined(separator: " ")
        let oversizedQuery =
            "document conversation task completed blocked proposal code \(oversizedToken) \(distinctTokens)"

        let prepared = SearchText.PreparedQuery(oversizedQuery)

        XCTAssertLessThanOrEqual(
            prepared.raw.utf8.count,
            SearchText.maximumRawQueryUTF8Bytes
        )
        XCTAssertLessThanOrEqual(
            prepared.normalized.utf8.count,
            SearchText.maximumNormalizedQueryUTF8Bytes
        )
        XCTAssertEqual(
            prepared.literalTokens.count,
            SearchText.maximumLiteralQueryTokens
        )
        XCTAssertTrue(
            prepared.literalTokens.allSatisfy {
                $0.utf8.count <= SearchText.maximumQueryTokenUTF8Bytes
            }
        )
        XCTAssertLessThanOrEqual(
            prepared.tokens.count,
            SearchText.maximumExpandedQueryTokens
        )
        XCTAssertLessThanOrEqual(
            prepared.tokens.count - prepared.literalTokens.count,
            SearchText.maximumSemanticExpansionTokens
        )
        XCTAssertEqual(Set(prepared.tokens).count, prepared.tokens.count)
    }

    func testPreparedQueryAndRawSourceScoringAreDeterministic() {
        let query = "DOCUMENT conversation tâche proposal aurora"
        let first = SearchText.PreparedQuery(query)
        let second = SearchText.PreparedQuery(query)
        let document = "Aurora proposal document discussed in a conversation"

        XCTAssertEqual(first.raw, second.raw)
        XCTAssertEqual(first.normalized, second.normalized)
        XCTAssertEqual(first.literalTokens, second.literalTokens)
        XCTAssertEqual(first.tokens, second.tokens)
        XCTAssertEqual(first.tokenSet, second.tokenSet)
        XCTAssertEqual(
            SearchText.rawSourceRelevance(query: first, document: document),
            SearchText.rawSourceRelevance(query: second, document: document)
        )
        XCTAssertEqual(
            SearchText.rawSourceRelevance(query: first, document: document),
            SearchText.relevance(query: first, document: document)
        )
    }

    func testAskBudgetRejectsAFifthThirtyTwoMiBProjectionAndSharesTheDeadline() {
        let startUptime: TimeInterval = 1_000
        var budget = ComputerHistoryAskBudget(
            maximumProjectionBytes: 512 * 1_024 * 1_024,
            maximumElapsedSeconds: 90,
            startedAtUptime: startUptime
        )
        let dayProjectionBytes: Int64 = 32 * 1_024 * 1_024

        for _ in 0..<4 {
            XCTAssertTrue(budget.reserveProjectionBytes(dayProjectionBytes))
        }
        XCTAssertFalse(budget.reserveProjectionBytes(dayProjectionBytes))
        XCTAssertEqual(
            budget.retainedProjectionBytes,
            ComputerHistoryAskBudget.productionMaximumProjectionBytes
        )
        XCTAssertEqual(
            budget.remainingElapsedSeconds(atUptime: startUptime + 44),
            1
        )
        XCTAssertFalse(budget.hasTimeRemaining(atUptime: startUptime + 45))
    }

    func testAskCoverageIssueMakesTheRawPassIncompleteWithoutInventingAbsence() {
        let issue = HistoryLoadIssue(
            path: "computer-history-ask",
            line: nil,
            message: "Computer History ask reconstruction stopped at the retained projection budget."
        )
        let result = ComputerHistorySourceSearchAccumulator(
            query: "unretained anchor",
            start: baseDate,
            endExclusive: baseDate.addingTimeInterval(60)
        ).result().addingCoverageIssues([issue])
        let answer = ComputerHistorySearchService(
            memories: [],
            sourceSearch: result
        ).ask("unretained anchor", now: baseDate.addingTimeInterval(60))

        XCTAssertFalse(result.isComplete)
        XCTAssertTrue(
            answer.answer.contains("prevent an exhaustive absence conclusion")
        )
        XCTAssertTrue(
            answer.limitations.contains {
                $0.contains("cumulative byte or time budget")
            }
        )
    }

    func testAskSourceChangeIssueMakesTheRawPassIncomplete() {
        let issue = HistoryLoadIssue(
            path: "computer-history-ask",
            line: nil,
            message: "Computer History ask rejected an original source that changed during read."
        )
        let result = ComputerHistorySourceSearchAccumulator(
            query: "unstable anchor",
            start: baseDate,
            endExclusive: baseDate.addingTimeInterval(60)
        ).result().addingCoverageIssues([issue])
        let answer = ComputerHistorySearchService(
            memories: [],
            sourceSearch: result
        ).ask("unstable anchor", now: baseDate.addingTimeInterval(60))

        XCTAssertFalse(result.isComplete)
        XCTAssertTrue(
            answer.answer.contains("prevent an exhaustive absence conclusion")
        )
        XCTAssertTrue(
            answer.limitations.contains {
                $0.contains("could not be searched completely")
            }
        )
    }

    func testWhatDidIWorkOnTodayUsesTheCompactSummaryPath() throws {
        let query = "What did I work on today?"
        let memory = makeMemory(day: 0, episodesPerDay: 3)
        let calendar = Calendar.current
        let now = baseDate.addingTimeInterval(1)

        XCTAssertFalse(
            ComputerHistorySearchService.shouldSearchRawSources(for: query),
            "A day-summary question must not stream the raw journals"
        )
        let interval = try XCTUnwrap(
            ComputerHistorySearchService.explicitTemporalInterval(
                for: query,
                now: now,
                calendar: calendar
            )
        )
        XCTAssertEqual(interval.start, calendar.startOfDay(for: now))
        XCTAssertEqual(interval.end, now.addingTimeInterval(0.001))

        let answer = ComputerHistorySearchService(memories: [memory]).ask(
            query,
            now: now,
            maximumHits: 12
        )

        XCTAssertTrue(answer.answer.contains(memory.executiveSummary))
        XCTAssertFalse(answer.answer.contains("Most relevant observed history"))
    }

    func testFrenchHourRangeProducesAnExactYesterdayInterval() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = try XCTUnwrap(
            calendar.date(
                from: DateComponents(
                    year: 2026,
                    month: 8,
                    day: 30,
                    hour: 18
                )
            )
        )
        let interval = try XCTUnwrap(
            ComputerHistorySearchService.explicitTemporalInterval(
                for: "Qu'est-ce que j'ai fait hier de 14h30 à 16h ?",
                now: now,
                calendar: calendar
            )
        )

        XCTAssertEqual(
            interval.start,
            calendar.date(
                from: DateComponents(
                    year: 2026,
                    month: 8,
                    day: 29,
                    hour: 14,
                    minute: 30
                )
            )
        )
        XCTAssertEqual(
            interval.end,
            calendar.date(
                from: DateComponents(
                    year: 2026,
                    month: 8,
                    day: 29,
                    hour: 16,
                    minute: 0
                )
            )
        )
    }

    func testEnglishMeridiemRangeUsesTodayWhenDayIsImplicit() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = try XCTUnwrap(
            calendar.date(
                from: DateComponents(
                    year: 2026,
                    month: 8,
                    day: 30,
                    hour: 18
                )
            )
        )
        let interval = try XCTUnwrap(
            ComputerHistorySearchService.explicitTemporalInterval(
                for: "What happened between 2:15pm and 4pm?",
                now: now,
                calendar: calendar
            )
        )

        XCTAssertEqual(
            calendar.component(.hour, from: interval.start),
            14
        )
        XCTAssertEqual(calendar.component(.minute, from: interval.start), 15)
        XCTAssertEqual(calendar.component(.hour, from: interval.end), 16)
        XCTAssertEqual(calendar.component(.minute, from: interval.end), 0)
    }

    func testExplicitRecentDayRangesUseCalendarDayBoundariesInEnglishAndFrench() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = try XCTUnwrap(
            calendar.date(
                from: DateComponents(
                    year: 2026,
                    month: 8,
                    day: 30,
                    hour: 18
                )
            )
        )

        for query in [
            "What was my screen time during the last 30 days?",
            "Quel a ete mon temps d'ecran pendant les 30 derniers jours ?",
        ] {
            let interval = try XCTUnwrap(
                ComputerHistorySearchService.explicitTemporalInterval(
                    for: query,
                    now: now,
                    calendar: calendar
                )
            )
            XCTAssertEqual(
                interval.start,
                calendar.date(
                    from: DateComponents(year: 2026, month: 8, day: 1)
                )
            )
            XCTAssertEqual(interval.end, now.addingTimeInterval(0.001))
        }
    }

    func testRawSourceFallbackRunsOnlyForAnUnansweredLexicalIntent() {
        XCTAssertFalse(
            ComputerHistorySearchService.requiresRawSourceFallback(
                for: "Which ScreenMind page was open?",
                retainedHitCount: 1
            )
        )
        XCTAssertTrue(
            ComputerHistorySearchService.requiresRawSourceFallback(
                for: "Which ScreenMind page was open?",
                retainedHitCount: 0
            )
        )
        XCTAssertFalse(
            ComputerHistorySearchService.requiresRawSourceFallback(
                for: "What did I work on today?",
                retainedHitCount: 0
            )
        )
    }

    func testGenericSearchDeduplicatesOneResourceAndBoundsPresentedSnippet() {
        let query = "screenmind"
        let timestamp = baseDate.addingTimeInterval(120)
        let resource = ComputerHistoryResourceReference(
            id: "screenmind-resource",
            kind: .webPage,
            title: "ScreenMind",
            canonicalURI: "https://screenminds.app/",
            localPath: nil,
            host: "screenminds.app",
            application: "Aside",
            bundleIdentifier: "at.studio.AsideBrowser",
            locatorConfidence: 1,
            firstSeen: timestamp.addingTimeInterval(-60),
            lastSeen: timestamp,
            provenance: .none
        )
        let repeatedSnippet = String(repeating: "ScreenMind grounded local memory. ", count: 30)
        let sourceHits = (0..<40).map { index in
            ComputerHistorySearchHit(
                id: "source-event-\(index)",
                kind: .resource,
                timestamp: timestamp.addingTimeInterval(TimeInterval(index)),
                end: nil,
                title: "ScreenMind",
                snippet: repeatedSnippet,
                score: 9 - Double(index) / 10,
                status: nil,
                resource: resource,
                episodeID: nil,
                provenance: ActivityProvenance(
                    sourceEventIDs: ["event-\(index)"],
                    sourceSequences: [UInt64(index + 1)],
                    sourceEventHashes: ["hash-\(index)"]
                )
            )
        }
        let sourceSearch = ComputerHistorySourceSearchResult(
            query: query,
            hits: sourceHits,
            sourceEventCount: sourceHits.count,
            semanticSnapshotCount: sourceHits.count,
            eventBytesRead: 8_192,
            semanticBytesRead: 8_192,
            peakStreamBufferBytes: 1_024,
            issues: []
        )

        let answer = ComputerHistorySearchService(
            memories: [],
            sourceSearch: sourceSearch
        ).ask(query, now: timestamp, maximumHits: 12)

        XCTAssertEqual(answer.hits.count, 1)
        XCTAssertLessThanOrEqual(answer.hits[0].snippet.count, 240)
        XCTAssertEqual(answer.hits[0].provenance.sourceEventIDs.count, 16)
        XCTAssertEqual(answer.hits[0].provenance.sourceSequences.count, 16)
        XCTAssertEqual(answer.hits[0].provenance.sourceEventHashes.count, 16)
        XCTAssertEqual(answer.hits[0].provenance.sourceEventIDs.first, "event-0")
        XCTAssertEqual(answer.hits[0].provenance.sourceEventIDs.last, "event-39")
        XCTAssertEqual(
            answer.answer.components(separatedBy: "**ScreenMind**").count - 1,
            1
        )
        XCTAssertLessThan(answer.answer.utf8.count, 512)
    }

    func testMultiDaySearchMatchesSingleDayResultsWithoutFalsePositives() {
        let targetDay = 29
        let targetEpisode = 17
        let memories = (0..<30).map {
            makeMemory(
                day: $0,
                episodesPerDay: 40,
                targetEpisode: $0 == targetDay ? targetEpisode : nil
            )
        }
        let targetOnly = ComputerHistorySearchService(
            memories: [memories[targetDay]]
        ).ask(
            "aurora ledger",
            now: baseDate.addingTimeInterval(31 * 86_400),
            maximumHits: 8
        )
        let multiDay = ComputerHistorySearchService(
            memories: memories.reversed()
        ).ask(
            "aurora ledger",
            now: baseDate.addingTimeInterval(31 * 86_400),
            maximumHits: 8
        )

        XCTAssertEqual(multiDay.hits.map(\.id), targetOnly.hits.map(\.id))
        XCTAssertEqual(multiDay.hits.map(\.score), targetOnly.hits.map(\.score))
        XCTAssertEqual(multiDay.hits.count, 2)
        XCTAssertTrue(
            multiDay.hits.allSatisfy {
                $0.title.localizedCaseInsensitiveContains("aurora ledger")
                    || $0.resource?.title.localizedCaseInsensitiveContains(
                        "aurora ledger"
                    ) == true
            }
        )

        let noMatch = ComputerHistorySearchService(memories: memories).ask(
            "zephyr quartz 92731",
            now: baseDate.addingTimeInterval(31 * 86_400)
        )
        XCTAssertTrue(noMatch.hits.isEmpty)
        XCTAssertEqual(
            noMatch.answer,
            "No matching retained representative evidence was found. No raw-source keyword pass was available, so this is not an exhaustive absence conclusion."
        )
    }

    func testVolumeRankingIsDeterministicAndHonorsTheLimit() {
        let memories = (0..<30).map {
            makeMemory(
                day: $0,
                episodesPerDay: 40,
                sharedTerm: "volumeanchor",
                identicalTimestamps: true
            )
        }
        let now = baseDate.addingTimeInterval(31 * 86_400)
        let forward = ComputerHistorySearchService(memories: memories).ask(
            "volumeanchor",
            now: now,
            maximumHits: 7
        )
        let reversed = ComputerHistorySearchService(
            memories: memories.reversed().map(reversingContent)
        ).ask(
            "volumeanchor",
            now: now,
            maximumHits: 7
        )

        XCTAssertEqual(forward.hits.count, 7)
        XCTAssertEqual(forward.hits.map(\.id), reversed.hits.map(\.id))
        XCTAssertEqual(forward.hits.map(\.score), reversed.hits.map(\.score))
    }

    private func makeMemory(
        day: Int,
        episodesPerDay: Int,
        targetEpisode: Int? = nil,
        sharedTerm: String? = nil,
        identicalTimestamps: Bool = false
    ) -> ComputerHistoryDayMemory {
        let dayStart = baseDate.addingTimeInterval(TimeInterval(day) * 86_400)
        var episodes: [ComputerHistoryEpisode] = []
        var resources: [ComputerHistoryResourceReference] = []
        episodes.reserveCapacity(episodesPerDay)
        resources.reserveCapacity(episodesPerDay)

        for index in 0..<episodesPerDay {
            let timestamp =
                identicalTimestamps
                ? dayStart
                : dayStart.addingTimeInterval(TimeInterval(index) * 60)
            let idSuffix = String(format: "%03d-%03d", day, index)
            let resourceID = "resource-\(idSuffix)"
            let isTarget = targetEpisode == index
            let searchableTitle =
                isTarget
                ? "Aurora ledger"
                : sharedTerm ?? "Routine item \(idSuffix)"
            resources.append(
                ComputerHistoryResourceReference(
                    id: resourceID,
                    kind: .document,
                    title: searchableTitle,
                    canonicalURI: "file:///tmp/\(resourceID).md",
                    localPath: "/tmp/\(resourceID).md",
                    host: nil,
                    application: "TextEdit",
                    bundleIdentifier: "com.apple.TextEdit",
                    locatorConfidence: 1,
                    firstSeen: timestamp,
                    lastSeen: timestamp,
                    provenance: .none
                )
            )
            episodes.append(
                ComputerHistoryEpisode(
                    id: "episode-\(idSuffix)",
                    start: timestamp,
                    end: timestamp.addingTimeInterval(30),
                    title: searchableTitle,
                    summary: "Observed work on \(searchableTitle)",
                    status: .inProgress,
                    statusConfidence: 0.8,
                    applications: ["TextEdit"],
                    sites: [],
                    resourceIDs: [resourceID],
                    requestsOrIntentions: [],
                    observableOutcomes: [],
                    interactions: [],
                    eventCount: 1,
                    semanticSnapshotCount: 1,
                    workflowFingerprint: "workflow-\(idSuffix)",
                    provenance: .none
                )
            )
        }

        return ComputerHistoryDayMemory(
            dayStart: dayStart,
            dayEnd: dayStart.addingTimeInterval(86_399),
            generatedAt: dayStart.addingTimeInterval(86_399),
            title: "Day \(day)",
            executiveSummary: "Observed \(episodesPerDay) work episodes.",
            episodes: episodes,
            resources: resources,
            workflowPatterns: [],
            suggestions: [],
            coverage: ComputerHistoryCoverage(
                sourceEventCount: episodesPerDay,
                actionEventCount: episodesPerDay,
                semanticSnapshotCount: episodesPerDay,
                linkedInteractionCount: 0,
                interactionsWithBeforeAndAfterContext: 0,
                resourceCount: resources.count,
                episodeCount: episodes.count,
                suppressedEventCount: 0,
                firstSourceSequence: nil,
                lastSourceSequence: nil,
                lastSourceEventHash: nil
            ),
            markdown: ""
        )
    }

    private func reversingContent(
        _ memory: ComputerHistoryDayMemory
    ) -> ComputerHistoryDayMemory {
        ComputerHistoryDayMemory(
            schemaVersion: memory.schemaVersion,
            dayStart: memory.dayStart,
            dayEnd: memory.dayEnd,
            generatedAt: memory.generatedAt,
            title: memory.title,
            executiveSummary: memory.executiveSummary,
            episodes: memory.episodes.reversed(),
            resources: memory.resources.reversed(),
            workflowPatterns: memory.workflowPatterns,
            suggestions: memory.suggestions,
            coverage: memory.coverage,
            markdown: memory.markdown,
            securityNotice: memory.securityNotice
        )
    }

    private var baseDate: Date {
        Date(timeIntervalSince1970: 1_777_590_000)
    }
}
