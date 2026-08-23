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
    let loadIssues: [HistoryLoadIssue]
}

private struct ComputerHistoryResourceEnvelope: Encodable {
    let schemaVersion = 1
    let rootDirectory: String
    let resource: ComputerHistoryResourceReference?
    let relatedEpisodes: [ComputerHistoryEpisode]
    let reconstructedDays: Int
    let error: String?
    let loadIssues: [HistoryLoadIssue]
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
        values.removeSubrange(index ... index + 1)
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
                    limitation: "Health is based on persisted evidence. A created event tap is not considered proof until a real callback is observed."
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
            let end = Calendar.current.date(byAdding: .day, value: 1, to: start)!.addingTimeInterval(-0.001)
            let loaded = HistoryLocalStoreReader(rootDirectory: root).load(start: start, end: end)
            let memory = loaded.events.isEmpty
                ? nil
                : ComputerHistoryEngine.analyze(
                    events: loaded.events,
                    semanticSnapshots: loaded.semanticSnapshots,
                    day: start
                )
            try printJSON(
                ComputerHistoryEnvelope(
                    rootDirectory: root.path,
                    memory: memory,
                    error: memory == nil ? "No events were loaded for that day." : nil,
                    loadIssues: loaded.issues
                )
            )

        case "ask", "find":
            let days = try integer(arguments.removeOption("--days") ?? "30")
            guard !arguments.values.isEmpty else {
                throw CLIError.usage("\(command) requires a natural-language query")
            }
            let question = arguments.values.joined(separator: " ")
            let loaded = HistoryLocalStoreReader(rootDirectory: root).load()
            let memories = reconstructComputerHistory(
                loaded: loaded,
                maximumDays: min(max(1, days), 365)
            )
            let search = ComputerHistorySearchService(memories: memories)
            let answer = command == "find"
                ? search.findResources(question)
                : search.ask(question)
            try printJSON(
                ComputerHistoryAnswerEnvelope(
                    rootDirectory: root.path,
                    answer: answer,
                    reconstructedDays: memories.count,
                    loadIssues: loaded.issues
                )
            )

        case "resource":
            let days = try integer(arguments.removeOption("--days") ?? "30")
            guard let identifier = arguments.popFirst(), arguments.values.isEmpty else {
                throw CLIError.usage("resource requires exactly one RESOURCE_ID")
            }
            let loaded = HistoryLocalStoreReader(rootDirectory: root).load()
            let memories = reconstructComputerHistory(
                loaded: loaded,
                maximumDays: min(max(1, days), 365)
            )
            let search = ComputerHistorySearchService(memories: memories)
            let resource = search.resource(identifier: identifier)
            try printJSON(
                ComputerHistoryResourceEnvelope(
                    rootDirectory: root.path,
                    resource: resource,
                    relatedEpisodes: resource == nil
                        ? []
                        : search.episodes(referencing: identifier),
                    reconstructedDays: memories.count,
                    error: resource == nil
                        ? "No inspectable resource matched that stable identifier."
                        : nil,
                    loadIssues: loaded.issues
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
        loaded: HistoryLoadedData,
        maximumDays: Int
    ) -> [ComputerHistoryDayMemory] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: loaded.events) { event in
            calendar.startOfDay(for: event.timestamp)
        }
        let days = grouped.keys.sorted().suffix(maximumDays)
        var memories: [ComputerHistoryDayMemory] = []
        for day in days {
            guard let events = grouped[day], !events.isEmpty else { continue }
            let memory = ComputerHistoryEngine.analyze(
                events: events,
                semanticSnapshots: loaded.semanticSnapshots,
                day: day,
                priorMemories: memories
            )
            memories.append(memory)
        }
        return memories
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
      find [--days N] RESOURCE_QUERY
      resource [--days N] RESOURCE_ID
      search TEXT
      app NAME_OR_BUNDLE_ID
      site HOST
      gaps [--start ISO_OR_DAY] [--end ISO_OR_DAY]
      memories
      sources MEMORY_ID

    All commands are read-only and return JSON with coverage, provenance and load issues.
    `computer-history` preserves the full causal action sequence; `ask` supports natural
    questions about recent work, resources, status, standups and repeatable workflows.
    `find` performs evidence-gated resource retrieval and `resource` resolves one stable ID.
    """
}
