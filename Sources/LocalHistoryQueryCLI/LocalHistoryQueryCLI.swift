import AppleScreenTime
import AppleSystemScreenTime
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

private struct ComputerHistoryContextEnvelope: Encodable {
    let schemaVersion = 1
    let rootDirectory: String
    let projection: ComputerHistoryAgentContextProjection?
    let error: String?
    let loadIssues: [HistoryLoadIssue]
}

private struct DailyRecap: Codable {
    let schemaVersion: Int
    let day: Date
    let generatedAt: Date
    let provider: String
    let planType: String?
    let contextDigest: String
    let sourceCounts: [String: Int]
    let markdown: String
    let model: String?
    let reasoningEffort: String?
    let productivityScore: Int?
    let confidenceScore: Int?
    let summaryLines: [String]?
}

private struct DailyRecapEnvelope: Encodable {
    let schemaVersion = 1
    let rootDirectory: String
    let requestedDay: String
    let status: String
    let recap: DailyRecap?
    let sourcePath: String?
    let error: String?
}

private struct AvailableDaysEnvelope: Encodable {
    let schemaVersion = 1
    let rootDirectory: String
    let computerHistory: [String]
    let rawEvents: [String]
    let recaps: [String]
    let screenTime: String
}

private struct RecapListEnvelope: Encodable {
    let schemaVersion = 1
    let rootDirectory: String
    let recaps: [String]
}

private struct ScreenTimeStatusEnvelope: Encodable {
    let kind: String
    let title: String
    let message: String
}

private struct ScreenTimeEnvelope: Encodable {
    let schemaVersion = 1
    let day: String
    let generatedAt: Date
    let scope: String
    let status: ScreenTimeStatusEnvelope
    let summary: AppleScreenTimeDaySummary?
    let reports: [AppleScreenTimeDeviceReport]
    let availableDevices: [AppleScreenTimeDevice]
    let deviceSourceLabels: [String: String]
    let latestAppleUpdate: Date?
    let knowledgeIntervalCount: Int
    let biomeIntervalCount: Int
    let limitation: String
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
    case unsafeSource(String)

    var description: String {
        switch self {
        case .usage(let value): return value
        case .invalidDate(let value): return "Invalid date: \(value)"
        case .invalidInteger(let value): return "Invalid integer: \(value)"
        case .missingHealth: return "capture-health.json is not available"
        case .unsafeSource(let value): return value
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
            FileHandle.standardError.write(Data("goalong: \(String(describing: error))\n".utf8))
            FileHandle.standardError.write(Data((usage + "\n").utf8))
            Foundation.exit(EXIT_FAILURE)
        }
    }

    private static func run() throws {
        var arguments = Arguments(values: Array(CommandLine.arguments.dropFirst()))
        let root = arguments.removeOption("--root").map(expandedURL) ?? defaultRoot
        guard let command = arguments.popFirst() else { throw CLIError.usage("Missing command") }

        switch command {
        case "help", "--help", "-h":
            FileHandle.standardOutput.write(Data((usage + "\n").utf8))

        case "version", "--version":
            try printJSON([
                "name": "goalong",
                "schemaVersion": "1",
            ])

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
            let raw = arguments.popFirst() ?? "today"
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

        case "computer-history", "computer-history-context":
            let tokenBudget = try integer(
                arguments.removeOption("--tokens")
                    ?? String(ComputerHistoryAgentContextRenderer.defaultTokenBudget)
            )
            let requestedStart = arguments.removeOption("--start-utc")
            let requestedEnd = arguments.removeOption("--end-utc")
            let raw = arguments.popFirst() ?? "today"
            let dayStart = try day(raw)
            let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: dayStart)!
            let start: Date
            let end: Date
            switch (requestedStart, requestedEnd) {
            case (nil, nil):
                start = dayStart
                end = dayEnd
            case (.some(let rawStart), .some(let rawEnd)):
                guard rawStart.hasSuffix("Z"), rawEnd.hasSuffix("Z") else {
                    throw CLIError.usage("--start-utc and --end-utc require explicit UTC timestamps")
                }
                start = try parseTimestamp(rawStart)
                end = try parseTimestamp(rawEnd)
                guard start >= dayStart, end <= dayEnd, end > start else {
                    throw CLIError.usage("the requested UTC interval must be non-empty and contained in \(raw)")
                }
            default:
                throw CLIError.usage("--start-utc and --end-utc must be provided together")
            }
            guard arguments.values.isEmpty else {
                throw CLIError.usage("unexpected arguments for \(command)")
            }
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
                    day: dayStart,
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
            if command == "computer-history-context" {
                try printJSON(
                    ComputerHistoryContextEnvelope(
                        rootDirectory: root.path,
                        projection: memory.map {
                            ComputerHistoryAgentContextRenderer.render(
                                $0,
                                tokenBudget: tokenBudget
                            )
                        },
                        error: error,
                        loadIssues: loaded.issues
                    )
                )
            } else {
                try printJSON(
                    ComputerHistoryEnvelope(
                        rootDirectory: root.path,
                        memory: memory,
                        error: error,
                        loadIssues: loaded.issues
                    )
                )
            }

        case "screen-time":
            let macOnly = arguments.removeFlag("--mac-only")
            let raw = arguments.popFirst() ?? "today"
            guard arguments.values.isEmpty else {
                throw CLIError.usage("screen-time accepts one date and the optional --mac-only flag")
            }
            try printScreenTime(day: try day(raw), macOnly: macOnly)

        case "recap":
            let raw = arguments.popFirst() ?? "yesterday"
            guard arguments.values.isEmpty else {
                throw CLIError.usage("recap accepts one date")
            }
            let requestedDay = try day(raw)
            let dayString = localDayString(requestedDay)
            let recapURL = root
                .appendingPathComponent("chatgpt", isDirectory: true)
                .appendingPathComponent("recaps", isDirectory: true)
                .appendingPathComponent("\(dayString).chatgpt-recap.json", isDirectory: false)
            if !FileManager.default.fileExists(atPath: recapURL.path) {
                try printJSON(
                    DailyRecapEnvelope(
                        rootDirectory: root.path,
                        requestedDay: dayString,
                        status: "notGenerated",
                        recap: nil,
                        sourcePath: nil,
                        error: "No daily recap has been generated for \(dayString)."
                    )
                )
                return
            }
            do {
                let data = try readStableRegularFile(recapURL, maximumBytes: 64 * 1_024)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let recap = try decoder.decode(DailyRecap.self, from: data)
                try printJSON(
                    DailyRecapEnvelope(
                        rootDirectory: root.path,
                        requestedDay: dayString,
                        status: "available",
                        recap: recap,
                        sourcePath: recapURL.path,
                        error: nil
                    )
                )
            } catch {
                try printJSON(
                    DailyRecapEnvelope(
                        rootDirectory: root.path,
                        requestedDay: dayString,
                        status: "inaccessibleOrInvalid",
                        recap: nil,
                        sourcePath: recapURL.path,
                        error: String(describing: error)
                    )
                )
            }

        case "days", "recaps":
            guard arguments.values.isEmpty else {
                throw CLIError.usage("\(command) does not accept arguments")
            }
            let available = availableDays(root: root)
            if command == "recaps" {
                try printJSON(
                    RecapListEnvelope(
                        rootDirectory: root.path,
                        recaps: available.recaps
                    )
                )
            } else {
                try printJSON(available)
            }

        case "ask":
            let days = try integer(arguments.removeOption("--days") ?? "30")
            guard !arguments.values.isEmpty else { throw CLIError.usage("ask requires a natural-language question") }
            let question = arguments.values.joined(separator: " ")
            let maximumDays = min(max(1, days), 365)
            let now = Date()
            let today = Calendar.current.startOfDay(for: now)
            let requestedFirstDay =
                Calendar.current.date(
                    byAdding: .day,
                    value: -(maximumDays - 1),
                    to: today
                ) ?? today
            let explicitInterval = ComputerHistorySearchService.explicitTemporalInterval(
                for: question,
                now: now
            )
            let firstDay = explicitInterval?.start ?? requestedFirstDay
            let reconstructionEnd = explicitInterval?.end ?? now
            let reconstruction = reconstructComputerHistory(
                reader: HistoryLocalStoreReader(rootDirectory: root),
                firstDay: firstDay,
                endExclusive: reconstructionEnd,
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
        let rawSourceSearch = sourceSearchQuery.flatMap {
            (query: String) -> ComputerHistorySourceSearchResult? in
            let retainedHitCount = ComputerHistorySearchService(
                memories: memories
            ).ask(query).hits.count
            guard
                ComputerHistorySearchService.requiresRawSourceFallback(
                    for: query,
                    retainedHitCount: retainedHitCount
                )
            else {
                return nil
            }
            return reader.searchComputerHistorySource(
                query: query,
                start: firstDay,
                endExclusive: boundedEnd,
                limits: ComputerHistorySourceSearchLimits(
                    maximumEventBytes:
                        ComputerHistorySourceSearchLimits.production.maximumEventBytes,
                    maximumSemanticBytes:
                        ComputerHistorySourceSearchLimits.production.maximumSemanticBytes,
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

    private static func printScreenTime(day: Date, macOnly: Bool) throws {
        guard let dayInterval = Calendar.current.dateInterval(of: .day, for: day) else {
            throw CLIError.invalidDate(localDayString(day))
        }
        let source = AppleSystemScreenTimeSource(
            deviceID: "goalong-cli-current-mac"
        )
        let collection = AppleScreenTimeDeviceNormalizer.normalize(
            source.collect(for: day),
            currentMac: source.currentMacDevice
        )
        let scope: AppleScreenTimeScope = macOnly ? .macOnly : .allDevices
        let reports = collection.storedExport?.envelope.reports.filter {
            scope.includes($0.device)
        } ?? []
        let stored = collection.storedExport.map {
            AppleScreenTimeStoredExport(
                importedAt: $0.importedAt,
                verification: $0.verification,
                envelope: AppleScreenTimeExportEnvelope(
                    schemaVersion: $0.envelope.schemaVersion,
                    createdAt: $0.envelope.createdAt,
                    requestedStart: $0.envelope.requestedStart,
                    requestedEnd: $0.envelope.requestedEnd,
                    requestedScope: scope,
                    provenance: $0.envelope.provenance,
                    reports: reports
                )
            )
        }
        let summary = stored.flatMap {
            AppleScreenTimeAnalyzer.summary(from: $0, interval: dayInterval, scope: scope)
        }
        try printJSON(
            ScreenTimeEnvelope(
                day: localDayString(day),
                generatedAt: Date(),
                scope: macOnly ? "macOnly" : "allDevices",
                status: ScreenTimeStatusEnvelope(
                    kind: collection.status.kind.rawValue,
                    title: collection.status.title,
                    message: collection.status.message
                ),
                summary: summary,
                reports: reports,
                availableDevices: collection.availableDevices,
                deviceSourceLabels: collection.deviceSourceLabels,
                latestAppleUpdate: collection.latestAppleUpdate,
                knowledgeIntervalCount: collection.knowledgeIntervalCount,
                biomeIntervalCount: collection.biomeIntervalCount,
                limitation:
                    "Read-only snapshot of Apple data available to this Goalong identity. Durations do not prove attention or productivity."
            )
        )
    }

    private static func readStableRegularFile(_ url: URL, maximumBytes: Int64) throws -> Data {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
        ]
        let values = try url.resourceValues(forKeys: keys)
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw CLIError.unsafeSource("Refusing a non-regular or symbolic-link source at \(url.path)")
        }
        let size = Int64(values.fileSize ?? -1)
        guard size >= 0, size <= maximumBytes else {
            throw CLIError.unsafeSource("Source exceeds the \(maximumBytes)-byte read limit at \(url.path)")
        }
        let before = try FileManager.default.attributesOfItem(atPath: url.path)
        let data = try Data(contentsOf: url, options: [.mappedIfSafe, .uncached])
        let after = try FileManager.default.attributesOfItem(atPath: url.path)
        guard data.count <= maximumBytes,
            before[.systemFileNumber] as? NSNumber == after[.systemFileNumber] as? NSNumber,
            before[.size] as? NSNumber == after[.size] as? NSNumber,
            before[.modificationDate] as? Date == after[.modificationDate] as? Date
        else {
            throw CLIError.unsafeSource("Source changed during the read at \(url.path)")
        }
        return data
    }

    private static func availableDays(root: URL) -> AvailableDaysEnvelope {
        AvailableDaysEnvelope(
            rootDirectory: root.path,
            computerHistory: filenames(
                in: root.appendingPathComponent("computer-history", isDirectory: true),
                suffix: ".computer-history.json"
            ),
            rawEvents: filenames(
                in: root.appendingPathComponent("events", isDirectory: true),
                suffix: ".jsonl"
            ),
            recaps: filenames(
                in: root
                    .appendingPathComponent("chatgpt", isDirectory: true)
                    .appendingPathComponent("recaps", isDirectory: true),
                suffix: ".chatgpt-recap.json"
            ),
            screenTime: "queried read-only on demand; Apple retention and permissions determine availability"
        )
    }

    private static func filenames(in directory: URL, suffix: String) -> [String] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return urls.compactMap { url -> String? in
            guard url.lastPathComponent.hasSuffix(suffix),
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                values.isRegularFile == true,
                values.isSymbolicLink != true
            else { return nil }
            let day = String(url.lastPathComponent.dropLast(suffix.count))
            return isDayString(day) ? day : nil
        }.sorted(by: >)
    }

    private static func isDayString(_ value: String) -> Bool {
        value.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
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
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        switch raw.lowercased() {
        case "today": return today
        case "yesterday": return calendar.date(byAdding: .day, value: -1, to: today)!
        default: break
        }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let value = formatter.date(from: raw), formatter.string(from: value) == raw else {
            throw CLIError.invalidDate(raw)
        }
        return Calendar.current.startOfDay(for: value)
    }

    private static func localDayString(_ value: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: value)
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
        Usage: goalong [--root PATH] COMMAND

          help
          version
          status
          recent [--minutes N] [--actions-only] [--gaps-only] [--semantic-only]
          day [today|yesterday|YYYY-MM-DD]
          summary [today|yesterday|YYYY-MM-DD]
          computer-history [today|yesterday|YYYY-MM-DD] [--start-utc ISO-8601Z --end-utc ISO-8601Z]
          computer-history-context [today|yesterday|YYYY-MM-DD] [--tokens N] [--start-utc ISO-8601Z --end-utc ISO-8601Z]
          screen-time [today|yesterday|YYYY-MM-DD] [--mac-only]
          recap [today|yesterday|YYYY-MM-DD]
          recaps
          days
          ask [--days N] NATURAL_LANGUAGE_QUESTION
          search TEXT
          app NAME_OR_BUNDLE_ID
          site HOST
          gaps [--start ISO_OR_DAY] [--end ISO_OR_DAY]
          memories
          sources MEMORY_ID

        All commands are read-only and return JSON with coverage, provenance and clear missing-data states.
        `computer-history` analyzes the complete causal action sequence and returns exact
        coverage totals plus a bounded representative projection. Its optional UTC
        interval reads and analyzes only that bounded portion of the original journals;
        it never writes a clipped source or derived snapshot. `ask` uses those
        projections and a bounded transient source-keyword pass when useful; it supports
        questions about recent work, resources, status, standups and repeatable workflows.
        `computer-history-context` emits a deterministic, token-bounded evidence pack for
        an agent without persisting another copy. `screen-time` uses the bundled,
        identically signed read-only adapter to inspect Apple's local stores once and returns complete
        per-device segments and application durations. `recap` reads only the bounded
        canonical daily recap JSON; `days` lists the dates currently queryable from
        Goalong's existing stores.
        """
}
