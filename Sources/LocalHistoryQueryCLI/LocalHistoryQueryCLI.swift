import Foundation
import LocalHistoryCore

private struct HealthEnvelope: Encodable {
    let schemaVersion = 1
    let rootDirectory: String
    let snapshot: CaptureHealthSnapshot?
    let assessment: CaptureHealthAssessment?
    let loadIssues: [HistoryLoadIssue]
    let limitation: String
}

private struct QueryEnvelope: Encodable {
    let schemaVersion = 1
    let rootDirectory: String
    let result: HistoryQueryResult
    let loadIssues: [HistoryLoadIssue]
}

private struct SummaryEnvelope: Encodable {
    let schemaVersion = 1
    let rootDirectory: String
    let memory: ActivityMemory?
    let error: String?
    let loadIssues: [HistoryLoadIssue]
}

private struct ComputerHistoryEnvelope: Encodable {
    let schemaVersion = 1
    let rootDirectory: String
    let memory: ComputerHistoryDayMemory?
    let error: String?
    let loadIssues: [HistoryLoadIssue]
}

private struct ComputerHistoryAnswerEnvelope: Encodable {
    let schemaVersion = 1
    let rootDirectory: String
    let answer: ComputerHistoryAnswer
    let reconstructedDays: Int
    let retainedProjectionBytes: Int64
    let loadIssues: [HistoryLoadIssue]
}

private struct ComputerHistoryReconstruction {
    let memories: [ComputerHistoryDayMemory]
    let loadIssues: [HistoryLoadIssue]
    let sourceSearch: ComputerHistorySourceSearchResult?
    let retainedProjectionBytes: Int64
    let limitations: [String]
}

private enum CLIError: Error, CustomStringConvertible {
    case usage(String)
    case invalidDate(String)
    case invalidInteger(String)
    case missingHealth

    var description: String {
        switch self {
        case .usage(let value): return value
        case .invalidDate(let value): return "Invalid date: \(value)"
        case .invalidInteger(let value): return "Invalid integer: \(value)"
        case .missingHealth: return "capture-health.json is not available"
        }
    }
}

private struct Arguments {
    var values: [String]

    mutating func removeOption(_ name: String) -> String? {
        guard let index = values.firstIndex(of: name) else { return nil }
        guard values.indices.contains(index + 1) else { return nil }
        let value = values[index + 1]
        values.removeSubrange(index...index + 1)
        return value
    }

    mutating func removeFlag(_ name: String) -> Bool {
        guard let index = values.firstIndex(of: name) else { return false }
        values.remove(at: index)
        return true
    }

    mutating func popFirst() -> String? {
        values.isEmpty ? nil : values.removeFirst()
    }
}

@main
private enum LocalHistoryQueryCLI {
    static func main() {
        do {
            try run()
        } catch {
            FileHandle.standardError.write(Data("goalong-history-query: \(String(describing: error))\n".utf8))
            FileHandle.standardError.write(Data((usage + "\n").utf8))
            Foundation.exit(EXIT_FAILURE)
        }
    }

    private static func run() throws {
        var arguments = Arguments(values: Array(CommandLine.arguments.dropFirst()))
        let root = arguments.removeOption("--root").map(expandedURL) ?? defaultRoot
        guard let command = arguments.popFirst() else { throw CLIError.usage("Missing command") }

        switch command {
        case "status":
            let loaded = HistoryLocalStoreReader(rootDirectory: root).load()
            let assessment = loaded.captureHealth.map { CaptureHealthEvaluator.assess($0) }
            try printJSON(
                HealthEnvelope(
                    rootDirectory: root.path,
                    snapshot: loaded.captureHealth,
                    assessment: assessment,
                    loadIssues: loaded.issues,
                    limitation:
                        "Health is based on persisted evidence. A created event tap is not considered proof until a real callback is observed."
                )
            )

        case "recent":
            let minutes = try integer(arguments.removeOption("--minutes") ?? "60")
            let loaded = HistoryLocalStoreReader(rootDirectory: root).load(
                start: Date().addingTimeInterval(-TimeInterval(max(1, minutes) * 60)),
                end: Date()
            )
            let service = service(from: loaded)
            let result = service.recent(
                since: Date().addingTimeInterval(-TimeInterval(max(1, minutes) * 60)),
                actionsOnly: arguments.removeFlag("--actions-only"),
                gapsOnly: arguments.removeFlag("--gaps-only"),
                semanticOnly: arguments.removeFlag("--semantic-only")
            )
            try printQuery(result, loaded: loaded, root: root)

        case "day", "summary":
            guard let raw = arguments.popFirst() else { throw CLIError.usage("\(command) requires YYYY-MM-DD") }
            let start = try day(raw)
            let end = Calendar.current.date(byAdding: .day, value: 1, to: start)!.addingTimeInterval(-0.001)
            let loaded = HistoryLocalStoreReader(rootDirectory: root).load(start: start, end: end)
            if command == "day" {
                let result = service(from: loaded).recent(since: start, until: end)
                try printQuery(result, loaded: loaded, root: root)
            } else {
                do {
                    let memory = try DeterministicActivitySummarizer().summarize(
                        ActivitySummaryInput(
                            events: loaded.events,
                            intervalStart: start,
                            intervalEnd: end,
                            semanticSnapshots: loaded.semanticSnapshots
                        )
                    )
                    try printJSON(
                        SummaryEnvelope(
                            rootDirectory: root.path,
                            memory: memory,
                            error: nil,
                            loadIssues: loaded.issues
                        )
                    )
                } catch ActivitySummarizerError.noEvents {
                    try printJSON(
                        SummaryEnvelope(
                            rootDirectory: root.path,
                            memory: nil,
                            error: "No events were loaded for that day.",
                            loadIssues: loaded.issues
                        )
                    )
                }
            }

        case "computer-history":
            guard let raw = arguments.popFirst() else {
                throw CLIError.usage("computer-history requires YYYY-MM-DD")
            }
            let start = try day(raw)
            let end = Calendar.current.date(byAdding: .day, value: 1, to: start)!
            let loaded = HistoryLocalStoreReader(rootDirectory: root).loadComputerHistoryEvidence(
                start: start,
                endExclusive: end
            )
            let memory =
                loaded.sourceJournalSummary.eventCount == 0
                    || loaded.metrics.sourceChangedDuringRead
                    || loaded.metrics.sourceAccessWasIncomplete
                    || loaded.metrics.evidenceBudgetExceeded
                ? nil
                : ComputerHistoryEngine.analyze(
                    events: loaded.events,
                    semanticSnapshots: loaded.semanticSnapshots,
                    day: start,
                    sourceJournalSummary: loaded.sourceJournalSummary
                )
            let error: String? =
                if loaded.metrics.sourceChangedDuringRead {
                    "The original Computer History source changed during read; no partial day was analyzed."
                } else if loaded.metrics.sourceAccessWasIncomplete {
                    "An original Computer History source was absent, inaccessible or unsafe; no partial day was analyzed."
                } else if loaded.metrics.evidenceBudgetExceeded {
                    "The Computer History evidence working-set budget was exceeded; no partial day was analyzed."
                } else if memory == nil {
                    "No events were loaded for that day."
                } else {
                    nil
                }
            try printJSON(
                ComputerHistoryEnvelope(
                    rootDirectory: root.path,
                    memory: memory,
                    error: error,
                    loadIssues: loaded.issues
                )
            )

        case "ask":
            let days = try integer(arguments.removeOption("--days") ?? "30")
            guard !arguments.values.isEmpty else { throw CLIError.usage("ask requires a natural-language question") }
            let question = arguments.values.joined(separator: " ")
            let maximumDays = min(max(1, days), 365)
            let now = Date()
            let today = Calendar.current.startOfDay(for: now)
            let firstDay =
                Calendar.current.date(
                    byAdding: .day,
                    value: -(maximumDays - 1),
                    to: today
                ) ?? today
            let reconstruction = reconstructComputerHistory(
                reader: HistoryLocalStoreReader(rootDirectory: root),
                firstDay: firstDay,
                endExclusive: now,
                maximumDays: maximumDays,
                sourceSearchQuery: ComputerHistorySearchService.shouldSearchRawSources(
                    for: question
                ) ? question : nil
            )
            let baseAnswer = ComputerHistorySearchService(
                memories: reconstruction.memories,
                sourceSearch: reconstruction.sourceSearch
            ).ask(question)
            let answer = ComputerHistoryAnswer(
                schemaVersion: baseAnswer.schemaVersion,
                query: baseAnswer.query,
                generatedAt: baseAnswer.generatedAt,
                answer: baseAnswer.answer,
                hits: baseAnswer.hits,
                limitations: baseAnswer.limitations + reconstruction.limitations
            )
            try printJSON(
                ComputerHistoryAnswerEnvelope(
                    rootDirectory: root.path,
                    answer: answer,
                    reconstructedDays: reconstruction.memories.count,
                    retainedProjectionBytes: reconstruction.retainedProjectionBytes,
                    loadIssues: reconstruction.loadIssues
                )
            )

        case "search", "app", "site":
            guard !arguments.values.isEmpty else { throw CLIError.usage("\(command) requires a query") }
            let query = arguments.values.joined(separator: " ")
            let loaded = HistoryLocalStoreReader(rootDirectory: root).load()
            let service = service(from: loaded)
            let result: HistoryQueryResult
            switch command {
            case "search": result = service.textSearch(query)
            case "app": result = service.application(query)
            default: result = service.site(query)
            }
            try printQuery(result, loaded: loaded, root: root)

        case "gaps":
            let start = try arguments.removeOption("--start").map(parseTimestamp)
            let end = try arguments.removeOption("--end").map(parseTimestamp)
            let loaded = HistoryLocalStoreReader(rootDirectory: root).load(start: start, end: end)
            try printQuery(
                service(from: loaded).gaps(start: start, end: end),
                loaded: loaded,
                root: root
            )

        case "memories":
            let loaded = HistoryLocalStoreReader(rootDirectory: root).load()
            try printQuery(service(from: loaded).availableMemories(), loaded: loaded, root: root)

        case "sources":
            guard let identifier = arguments.popFirst() else { throw CLIError.usage("sources requires a memory ID") }
            let loaded = HistoryLocalStoreReader(rootDirectory: root).load()
            try printQuery(
                service(from: loaded).sources(forMemoryID: identifier),
                loaded: loaded,
                root: root
            )

        default:
            throw CLIError.usage("Unknown command: \(command)")
        }
    }

    private static func reconstructComputerHistory(
        reader: HistoryLocalStoreReader,
        firstDay: Date,
        endExclusive: Date,
        maximumDays: Int,
        sourceSearchQuery: String?
    ) -> ComputerHistoryReconstruction {
        let calendar = Calendar.current
        var memories: [ComputerHistoryDayMemory] = []
        var issues: [HistoryLoadIssue] = []
        var askCoverageIssues: [HistoryLoadIssue] = []
        var limitations: [String] = []
        var askBudget = ComputerHistoryAskBudget()
        let projectionEncoder = JSONEncoder()
        projectionEncoder.dateEncodingStrategy = .iso8601
        var day = calendar.startOfDay(for: firstDay)
        let boundedEnd = max(day, endExclusive)
        var visitedDays = 0

        func appendAskIssue(_ message: String) {
            guard !askCoverageIssues.contains(where: { $0.message == message }) else {
                return
            }
            let issue = HistoryLoadIssue(
                path: "computer-history-ask",
                line: nil,
                message: message
            )
            askCoverageIssues.append(issue)
            if issues.count < 256 {
                issues.append(issue)
            }
        }

        while day < boundedEnd, visitedDays < maximumDays {
            guard askBudget.hasTimeRemaining() else {
                appendAskIssue(
                    "Computer History ask reconstruction stopped at the shared 45-second time budget."
                )
                limitations.append(
                    "The requested history interval exceeded the shared 45-second ask budget; unvisited days were not treated as evidence of absence."
                )
                break
            }
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            let intervalEnd = min(nextDay, boundedEnd)
            let dayResult = autoreleasepool {
                () -> (
                    memory: ComputerHistoryDayMemory?,
                    issues: [HistoryLoadIssue],
                    wasCancelled: Bool,
                    sourceWasUnstable: Bool,
                    sourceAccessWasIncomplete: Bool,
                    evidenceBudgetWasExceeded: Bool
                ) in
                let loaded = reader.loadComputerHistoryEvidence(
                    start: day,
                    endExclusive: intervalEnd,
                    shouldContinue: { askBudget.hasTimeRemaining() }
                )
                guard !loaded.metrics.wasCancelled else {
                    return (nil, loaded.issues, true, false, false, false)
                }
                guard !loaded.metrics.sourceChangedDuringRead else {
                    return (nil, loaded.issues, false, true, false, false)
                }
                guard !loaded.metrics.sourceAccessWasIncomplete else {
                    return (nil, loaded.issues, false, false, true, false)
                }
                guard !loaded.metrics.evidenceBudgetExceeded else {
                    return (nil, loaded.issues, false, false, false, true)
                }
                guard loaded.sourceJournalSummary.eventCount > 0 else {
                    return (nil, loaded.issues, false, false, false, false)
                }
                guard askBudget.hasTimeRemaining() else {
                    return (nil, loaded.issues, true, false, false, false)
                }
                return (
                    ComputerHistoryEngine.analyze(
                        events: loaded.events,
                        semanticSnapshots: loaded.semanticSnapshots,
                        day: day,
                        priorMemories: memories,
                        sourceJournalSummary: loaded.sourceJournalSummary
                    ),
                    loaded.issues,
                    false,
                    false,
                    false,
                    false
                )
            }
            if issues.count < 256 {
                issues.append(contentsOf: dayResult.issues.prefix(256 - issues.count))
            }
            if dayResult.wasCancelled {
                appendAskIssue(
                    "Computer History ask reconstruction stopped at the shared 45-second time budget."
                )
                limitations.append(
                    "The requested history interval exceeded the shared 45-second ask budget; unvisited source rows and days were not treated as evidence of absence."
                )
                break
            }
            if dayResult.sourceWasUnstable {
                appendAskIssue(
                    "Computer History ask rejected an original source that changed during read."
                )
                limitations.append(
                    "An original Computer History source changed while it was being read; that day and all later requested days were not reconstructed, instead of treating a mixed or causally incomplete view as evidence."
                )
                break
            }
            if dayResult.sourceAccessWasIncomplete {
                appendAskIssue(
                    "Computer History ask rejected an absent, inaccessible or unsafe original source."
                )
                limitations.append(
                    "An original Computer History source was absent, inaccessible or unsafe; that day and all later requested days were not reconstructed, and missing evidence was not treated as absent activity."
                )
                break
            }
            if dayResult.evidenceBudgetWasExceeded {
                appendAskIssue(
                    "Computer History ask rejected a day that exceeded the retained-evidence working-set budget."
                )
                limitations.append(
                    "The retained-evidence working-set budget was exceeded; that day and all later requested days were not reconstructed, and omitted evidence was not treated as absent."
                )
                break
            }
            if let memory = dayResult.memory {
                let projectionBytes = Int64(
                    (try? projectionEncoder.encode(memory).count)
                        ?? Int.max
                )
                guard askBudget.reserveProjectionBytes(projectionBytes) else {
                    appendAskIssue(
                        "Computer History ask reconstruction stopped at the 134217728-byte retained projection budget."
                    )
                    limitations.append(
                        "The requested interval exceeded the 128 MiB transient projection budget; omitted days were not treated as evidence of absence."
                    )
                    break
                }
                memories.append(memory)
            }
            day = nextDay
            visitedDays += 1
        }
        if !askBudget.hasTimeRemaining(),
            !limitations.contains(where: { $0.contains("shared 45-second ask budget") })
        {
            appendAskIssue(
                "Computer History ask reconstruction reached the shared 45-second time budget."
            )
            limitations.append(
                "The Computer History ask reached its shared 45-second budget; later source coverage may be partial and was not treated as evidence of absence."
            )
        }
        let rawSourceSearch = sourceSearchQuery.map {
            reader.searchComputerHistorySource(
                query: $0,
                start: firstDay,
                endExclusive: boundedEnd,
                limits: ComputerHistorySourceSearchLimits(
                    maximumEventBytes: ComputerHistorySourceSearchLimits.production.maximumEventBytes,
                    maximumSemanticBytes: ComputerHistorySourceSearchLimits.production.maximumSemanticBytes,
                    maximumElapsedSeconds: askBudget.remainingElapsedSeconds()
                )
            ).addingCoverageIssues(askCoverageIssues)
        }
        if let rawSourceSearch {
            for issue in rawSourceSearch.issues
            where issues.count < 256 && !issues.contains(where: { $0.id == issue.id }) {
                issues.append(issue)
            }
        }
        return ComputerHistoryReconstruction(
            memories: memories,
            loadIssues: issues,
            sourceSearch: rawSourceSearch,
            retainedProjectionBytes: askBudget.retainedProjectionBytes,
            limitations: limitations
        )
    }

    private static func service(from loaded: HistoryLoadedData) -> HistoryQueryService {
        HistoryQueryService(
            events: loaded.events,
            memories: loaded.memories,
            semanticSnapshots: loaded.semanticSnapshots
        )
    }

    private static func printQuery(
        _ result: HistoryQueryResult,
        loaded: HistoryLoadedData,
        root: URL
    ) throws {
        try printJSON(
            QueryEnvelope(
                rootDirectory: root.path,
                result: result,
                loadIssues: loaded.issues
            )
        )
    }

    private static func printJSON<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(0x0A)
        FileHandle.standardOutput.write(data)
    }

    private static func integer(_ raw: String) throws -> Int {
        guard let value = Int(raw) else { throw CLIError.invalidInteger(raw) }
        return value
    }

    private static func day(_ raw: String) throws -> Date {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        guard let value = formatter.date(from: raw) else { throw CLIError.invalidDate(raw) }
        return Calendar.current.startOfDay(for: value)
    }

    private static func parseTimestamp(_ raw: String) throws -> Date {
        if let value = fractionalISO.date(from: raw) ?? basicISO.date(from: raw) { return value }
        return try day(raw)
    }

    private static func expandedURL(_ raw: String) -> URL {
        let expanded = NSString(string: raw).expandingTildeInPath
        return URL(fileURLWithPath: expanded, isDirectory: true)
    }

    private static let defaultRoot: URL = {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
        return base.appendingPathComponent("LocalHistory", isDirectory: true)
    }()

    private static let fractionalISO: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let basicISO: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let usage = """
        Usage: goalong-history-query [--root PATH] COMMAND

          status
          recent [--minutes N] [--actions-only] [--gaps-only] [--semantic-only]
          day YYYY-MM-DD
          summary YYYY-MM-DD
          computer-history YYYY-MM-DD
          ask [--days N] NATURAL_LANGUAGE_QUESTION
          search TEXT
          app NAME_OR_BUNDLE_ID
          site HOST
          gaps [--start ISO_OR_DAY] [--end ISO_OR_DAY]
          memories
          sources MEMORY_ID

        All commands are read-only and return JSON with coverage, provenance and load issues.
        `computer-history` analyzes the complete causal action sequence and returns exact
        coverage totals plus a bounded representative projection. `ask` uses those
        projections and a bounded transient source-keyword pass when useful; it supports
        questions about recent work, resources, status, standups and repeatable workflows.
        """
}
