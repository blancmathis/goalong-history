import AgentActivity
import AppleScreenTime
import AppleSystemScreenTime
import Dispatch
import Foundation
import LocalHistoryCore

private struct GoalongCLIErrorEnvelope: Encodable {
    let schemaVersion = 1
    let status = "error"
    let error: String
    let usage = "goalong help"
}

private struct GoalongCLIVersionEnvelope: Encodable {
    let schemaVersion = 1
    let name = "goalong"
    let appVersion: String
    let buildNumber: String
    let cliContractSchemaVersion: Int
    let commandDataSchemaVersion: Int
}

private struct GoalongSourceDiagnostic: Encodable {
    let state: String
    let consentEnabled: Bool?
    let configuredSourceCount: Int?
    let itemCount: Int?
    let availableItemCount: Int?
    let missingItemCount: Int?
    let inaccessibleItemCount: Int?
    let storedMetadataBytes: Int64?
    let maximumItemCount: Int?
    let latestObservedAt: Date?
    let dates: [String]
    let providers: [String]
    let detail: String
    let limitations: [String]
}

private struct GoalongAnalysisDiagnostic: Encodable {
    let state: String
    let consentEnabled: Bool
    let savedRecapCount: Int
    let latestSavedRecapDay: String?
    let connectionProbe: String
    let detail: String
}

private struct GoalongRuntimeDiagnostic: Encodable {
    let appRunningForActiveScreenTime: Bool
    let brokerState: String
    let detail: String
}

private struct GoalongStatusSources: Encodable {
    let computerHistory: GoalongSourceDiagnostic
    let screenTime: GoalongSourceDiagnostic
    let aiConversations: GoalongSourceDiagnostic
    let dailyRecaps: GoalongSourceDiagnostic
    let chatGPTAnalysis: GoalongAnalysisDiagnostic
}

private struct HealthEnvelope: Encodable {
    let schemaVersion = 2
    let generatedAt: Date
    let rootDirectory: String
    let overallState: String
    let snapshot: CaptureHealthSnapshot?
    let assessment: CaptureHealthAssessment?
    let runtime: GoalongRuntimeDiagnostic
    let sources: GoalongStatusSources
    let loadIssues: [HistoryLoadIssue]
    let limitations: [String]
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
    let sourceMode: String
    let sourceBytesRead: Int64
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
    let screenTime: ScreenTimeAskContext
    let loadIssues: [HistoryLoadIssue]
}

private struct ComputerHistoryContextEnvelope: Encodable {
    let schemaVersion = 1
    let rootDirectory: String
    let sourceMode: String
    let sourceBytesRead: Int64
    let projection: ComputerHistoryAgentContextProjection?
    let error: String?
    let loadIssues: [HistoryLoadIssue]
}

private struct ComputerHistoryActivitiesEnvelope: Encodable {
    let schemaVersion = 1
    let rootDirectory: String
    let day: String
    let sourceMode: String
    let sourceBytesRead: Int64
    let coverage: ComputerHistoryCoverage?
    let totalActivityCount: Int
    let activityOffset: Int
    let returnedActivityCount: Int
    let nextActivityOffset: Int?
    let activities: [ComputerHistoryActivityIndexEntry]
    let error: String?
    let loadIssues: [HistoryLoadIssue]
    let nextStep: String
}

private struct ComputerHistoryActivityEnvelope: Encodable {
    let schemaVersion = 1
    let rootDirectory: String
    let day: String
    let sourceMode: String
    let sourceBytesRead: Int64
    let activity: ComputerHistoryEpisode?
    let totalInteractionCount: Int
    let interactionOffset: Int
    let returnedInteractionCount: Int
    let nextInteractionOffset: Int?
    let resources: [ComputerHistoryResourceReference]
    let error: String?
    let loadIssues: [HistoryLoadIssue]
}

private struct CompleteComputerHistoryIndexLoad {
    let index: ComputerHistoryActivityIndex?
    let sourceMode: String
    let sourceBytesRead: Int64
    let error: String?
    let loadIssues: [HistoryLoadIssue]
}

private struct CompleteComputerHistoryMemoryLoad {
    let memory: ComputerHistoryDayMemory?
    let sourceMode: String
    let sourceBytesRead: Int64
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
    let attestation: AnalysisRunAttestation?
    let proof: AnalysisProofReference?
}

private struct DailyRecapIntegrityEnvelope: Encodable {
    let status: String
    let localDeviceSignatureValid: Bool
    let savedResultMatches: Bool
    let limitation: String
}

private struct DailyRecapEnvelope: Encodable {
    let schemaVersion = 1
    let rootDirectory: String
    let requestedDay: String
    let status: String
    let recap: DailyRecap?
    let integrity: DailyRecapIntegrityEnvelope?
    let sourcePath: String?
    let error: String?
}

private struct AvailableDaysEnvelope: Encodable {
    let schemaVersion = 1
    let rootDirectory: String
    let computerHistory: [String]
    let rawEvents: [String]
    let aiConversationCandidateDays: [String]
    let agentActivityIndexStatus: String
    let recaps: [String]
    let screenTimeDays: [String]
    let screenTime: String
}

private struct RecapListEnvelope: Encodable {
    let schemaVersion = 1
    let rootDirectory: String
    let recaps: [String]
}

private struct DailyRecapFileVerificationEnvelope: Encodable {
    let schemaVersion = 1
    let reportPath: String
    let reportBytes: Int
    let reportSHA256: String
    let status: String
    let recap: DailyRecap?
    let integrity: DailyRecapIntegrityEnvelope?
    let error: String?
}

private struct SharePackageVerificationEnvelope: Encodable {
    let schemaVersion = 1
    let packagePath: String
    let packageBytes: Int
    let packageSHA256: String
    let localDay: String?
    let createdAt: Date?
    let report: DaySharePackageVerificationReport?
    let status: String
    let error: String?
}

private struct AnalysisProofPackageVerificationEnvelope: Encodable {
    let schemaVersion = 1
    let packagePath: String
    let packageBytes: Int
    let packageSHA256: String
    let report: AnalysisProofVerificationReport?
    let status: String
    let error: String?
}

private struct AnalysisProofExportEnvelope: Encodable {
    let schemaVersion = 1
    let rootDirectory: String
    let requestedDay: String
    let packagePath: String?
    let packageBytes: Int
    let packageSHA256: String
    let report: AnalysisProofVerificationReport?
    let status: String
    let error: String?
}

struct ScreenTimeStatusEnvelope: Codable {
    let kind: String
    let title: String
    let message: String
}

struct ScreenTimeEnvelope: Codable {
    let schemaVersion: Int
    let day: String
    let generatedAt: Date
    let freshness: String?
    let scope: String
    let sourceAssurance: String?
    let status: ScreenTimeStatusEnvelope
    let summary: AppleScreenTimeDaySummary?
    let reports: [AppleScreenTimeDeviceReport]
    let availableDevices: [AppleScreenTimeDevice]
    let deviceSourceLabels: [String: String]
    let latestAppleUpdate: Date?
    let screenTimeAppUsageIntervalCount: Int
    let knowledgeIntervalCount: Int
    let biomeIntervalCount: Int
    let limitation: String
}

struct ScreenTimeAskUsage: Codable {
    let name: String
    let bundleIdentifier: String?
    let duration: TimeInterval
}

struct ScreenTimeAskDevice: Codable {
    let id: String
    let name: String
    let kind: String
    let screenOnDuration: TimeInterval
    let lastUpdatedAt: Date
}

struct ScreenTimeAskDay: Codable {
    let day: String
    let freshness: String?
    let sourceAssurance: String?
    let totalScreenOnDuration: TimeInterval?
    let devices: [ScreenTimeAskDevice]
    let applicationCount: Int
    let applications: [ScreenTimeAskUsage]
    let omittedApplicationCount: Int
    let latestAppleUpdate: Date?

    init(
        day: String,
        freshness: String? = nil,
        sourceAssurance: String? = nil,
        totalScreenOnDuration: TimeInterval?,
        devices: [ScreenTimeAskDevice],
        applicationCount: Int,
        applications: [ScreenTimeAskUsage],
        omittedApplicationCount: Int,
        latestAppleUpdate: Date?
    ) {
        self.day = day
        self.freshness = freshness
        self.sourceAssurance = sourceAssurance
        self.totalScreenOnDuration = totalScreenOnDuration
        self.devices = devices
        self.applicationCount = applicationCount
        self.applications = applications
        self.omittedApplicationCount = omittedApplicationCount
        self.latestAppleUpdate = latestAppleUpdate
    }
}

struct ScreenTimeAskContext: Encodable {
    let requested: Bool
    let refreshPolicy: String
    let generatedAt: Date?
    let sourceAssurance: String?
    let status: ScreenTimeStatusEnvelope?
    let days: [ScreenTimeAskDay]
    let issues: [String]
    let limitation: String?
    let nextStep: String?
}

struct ScreenTimeRangeEnvelope: Codable {
    let schemaVersion: Int
    let generatedAt: Date
    let freshness: String
    let sourceAssurance: String?
    let status: ScreenTimeStatusEnvelope
    let days: [ScreenTimeAskDay]
    let limitation: String
}

private struct DailyWebsitesStatusEnvelope: Encodable {
    let kind: String
    let message: String
}

private struct DailyWebsiteRowEnvelope: Encodable {
    let host: String
    let foregroundSeconds: TimeInterval
    let eventCount: Int
    let sourceApplications: [String]
    let sourceUsage: [DailyWebsiteSourceUsage]
}

private struct DailyWebsitesEnvelope: Encodable {
    let schemaVersion = 2
    let rootDirectory: String
    let day: String
    let generatedAt: Date
    let status: DailyWebsitesStatusEnvelope
    let scope: String
    let includedInApplicationTotals: Bool
    let sourceBytesRead: Int64
    let sourceRowCount: Int
    let sourceEventCount: Int
    let peakStreamBufferBytes: Int
    let peakEstimatedRetainedBytes: Int64
    let totalWebsiteCount: Int
    let offset: Int
    let returnedWebsiteCount: Int
    let nextOffset: Int?
    let websites: [DailyWebsiteRowEnvelope]
    let loadIssues: [HistoryLoadIssue]
    let limitation: String
}

private struct AgentConversationMessageEnvelope: Encodable {
    let role: String
    let text: String
}

private struct AgentConversationSourceEnvelope: Encodable {
    let kind: String
    let path: String
    let locator: String?
    let availability: String
    let byteCount: Int64
    let sha256: String
    let sha256Scope: String
    let startOffset: Int64
    let endOffset: Int64
    let projectionIsComplete: Bool
    let sourceCreatedAt: Date?
    let sourceModifiedAt: Date?
}

private struct AgentConversationEnvelope: Encodable {
    let id: String
    let provider: String
    let providerName: String
    let title: String
    let startedAt: Date?
    let endedAt: Date?
    let readStatus: String
    let source: AgentConversationSourceEnvelope
    let userPromptCount: Int
    let finalAnswerCount: Int
    let messages: [AgentConversationMessageEnvelope]
    let messagesTruncated: Bool
    let error: String?
}

private struct AgentConversationsEnvelope: Encodable {
    let schemaVersion = 1
    let rootDirectory: String
    let requestedDay: String
    let generatedAt: Date
    let status: String
    let indexedConversationCount: Int
    let relevantConversationCount: Int
    let candidateOffset: Int
    let visitedConversationCandidateCount: Int
    let nextCandidateOffset: Int?
    let returnedConversationCount: Int
    let noVisibleMessageCandidateCount: Int
    let outputDroppedConversationCount: Int
    let omittedConversationCount: Int
    let currentSourceBytesRead: Int64
    let outputByteBudget: Int
    let conversations: [AgentConversationEnvelope]
    let issues: [String]
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

public enum GoalongQueryCLI {
    public static func main(arguments rawArguments: [String] = Array(CommandLine.arguments.dropFirst())) {
        do {
            try run(arguments: rawArguments)
        } catch {
            let payload = GoalongCLIErrorEnvelope(error: String(describing: error))
            if let data = try? encodedJSON(payload) {
                FileHandle.standardError.write(data)
            } else {
                FileHandle.standardError.write(Data("{\"status\":\"error\"}\n".utf8))
            }
            Foundation.exit(EXIT_FAILURE)
        }
    }

    private static func run(arguments rawArguments: [String]) throws {
        var arguments = Arguments(values: rawArguments)
        let root = arguments.removeOption("--root").map(expandedURL) ?? defaultRoot
        guard let command = arguments.popFirst() else { throw CLIError.usage("Missing command") }

        switch command {
        case "help", "--help", "-h":
            let machineReadable = arguments.removeFlag("--json")
            guard arguments.values.isEmpty else {
                throw CLIError.usage("help accepts only --json")
            }
            if machineReadable {
                try printJSON(GoalongCLIContract.capabilities)
            } else {
                FileHandle.standardOutput.write(Data((usage + "\n").utf8))
            }

        case "capabilities":
            guard arguments.values.isEmpty else {
                throw CLIError.usage("capabilities does not accept arguments")
            }
            try printJSON(GoalongCLIContract.capabilities)

        case "version", "--version":
            guard arguments.values.isEmpty else {
                throw CLIError.usage("version does not accept arguments")
            }
            try printJSON(versionEnvelope())

        case "status":
            guard arguments.values.isEmpty else {
                throw CLIError.usage("status does not accept arguments")
            }
            FileHandle.standardOutput.write(try statusPayload(rootDirectory: root))

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
            let loaded = loadCompleteComputerHistoryMemory(
                reader: HistoryLocalStoreReader(rootDirectory: root),
                dayStart: dayStart,
                start: start,
                end: end,
                allowsValidatedDayIndex: requestedStart == nil
            )
            if command == "computer-history-context" {
                try printJSON(
                    ComputerHistoryContextEnvelope(
                        rootDirectory: root.path,
                        sourceMode: loaded.sourceMode,
                        sourceBytesRead: loaded.sourceBytesRead,
                        projection: loaded.memory.map {
                            ComputerHistoryAgentContextRenderer.render(
                                $0,
                                tokenBudget: tokenBudget
                            )
                        },
                        error: loaded.error,
                        loadIssues: loaded.loadIssues
                    )
                )
            } else {
                try printJSON(
                    ComputerHistoryEnvelope(
                        rootDirectory: root.path,
                        sourceMode: loaded.sourceMode,
                        sourceBytesRead: loaded.sourceBytesRead,
                        memory: loaded.memory,
                        error: loaded.error,
                        loadIssues: loaded.loadIssues
                    )
                )
            }

        case "activities":
            let limit = try integer(arguments.removeOption("--limit") ?? "256")
            let offset = try integer(arguments.removeOption("--offset") ?? "0")
            guard (1...1_000).contains(limit), offset >= 0 else {
                throw CLIError.usage("activities requires --limit 1...1000 and --offset >= 0")
            }
            let raw = arguments.popFirst() ?? "today"
            guard arguments.values.isEmpty else {
                throw CLIError.usage("activities accepts one date plus --limit and --offset")
            }
            let dayStart = try day(raw)
            let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: dayStart)!
            let loaded = loadCompleteComputerHistoryIndex(
                reader: HistoryLocalStoreReader(rootDirectory: root),
                dayStart: dayStart,
                dayEnd: dayEnd
            )
            let allActivities = loaded.index?.activities ?? []
            let activities = Array(allActivities.dropFirst(offset).prefix(limit))
            let nextOffset =
                offset + activities.count < allActivities.count
                ? offset + activities.count
                : nil
            let dayKey = localDayString(dayStart)
            try printJSON(
                ComputerHistoryActivitiesEnvelope(
                    rootDirectory: root.path,
                    day: dayKey,
                    sourceMode: loaded.sourceMode,
                    sourceBytesRead: loaded.sourceBytesRead,
                    coverage: loaded.index?.coverage,
                    totalActivityCount: allActivities.count,
                    activityOffset: offset,
                    returnedActivityCount: activities.count,
                    nextActivityOffset: nextOffset,
                    activities: activities,
                    error: loaded.error,
                    loadIssues: loaded.loadIssues,
                    nextStep:
                        nextOffset.map {
                            "Run goalong activities \(dayKey) --offset \($0) --limit \(limit) for the next page."
                        } ?? "Run goalong activity ACTIVITY_ID \(dayKey) for its ordered interactions and source references."
                )
            )

        case "activity":
            let limit = try integer(arguments.removeOption("--limit") ?? "100")
            let offset = try integer(arguments.removeOption("--offset") ?? "0")
            guard (1...500).contains(limit), offset >= 0 else {
                throw CLIError.usage("activity requires --limit 1...500 and --offset >= 0")
            }
            guard let identifier = arguments.popFirst() else {
                throw CLIError.usage("activity requires an activity ID")
            }
            let raw = arguments.popFirst() ?? "today"
            guard arguments.values.isEmpty else {
                throw CLIError.usage("activity accepts an activity ID, one date, --limit and --offset")
            }
            let dayStart = try day(raw)
            let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: dayStart)!
            let loaded = HistoryLocalStoreReader(rootDirectory: root)
                .loadComputerHistoryEvidence(start: dayStart, endExclusive: dayEnd)
            let detail = validComputerHistoryLoad(loaded)
                ? ComputerHistoryEngine.exactActivity(
                    id: identifier,
                    events: loaded.events,
                    semanticSnapshots: loaded.semanticSnapshots,
                    day: dayStart
                )
                : nil
            let totalInteractionCount = detail?.episode.totalInteractionCount ?? 0
            let pageInteractions = Array(
                (detail?.episode.interactions ?? []).dropFirst(offset).prefix(limit)
            )
            let activity = detail.map {
                pagedActivity($0.episode, interactions: pageInteractions)
            }
            let nextOffset =
                offset + pageInteractions.count < totalInteractionCount
                ? offset + pageInteractions.count
                : nil
            let loadError = computerHistoryLoadError(
                loaded: loaded,
                hasResult: validComputerHistoryLoad(loaded)
            )
            let dayKey = localDayString(dayStart)
            try printJSON(
                ComputerHistoryActivityEnvelope(
                    rootDirectory: root.path,
                    day: dayKey,
                    sourceMode: "authoritativeJournals",
                    sourceBytesRead:
                        loaded.metrics.eventBytesRead + loaded.metrics.semanticBytesRead,
                    activity: activity,
                    totalInteractionCount: totalInteractionCount,
                    interactionOffset: offset,
                    returnedInteractionCount: pageInteractions.count,
                    nextInteractionOffset: nextOffset,
                    resources: detail?.resources ?? [],
                    error: loadError
                        ?? (detail == nil
                            ? "No activity with ID \(identifier) exists in the authoritative source for \(dayKey)."
                            : nil),
                    loadIssues: loaded.issues
                )
            )

        case "screen-time":
            let macOnly = arguments.removeFlag("--mac-only")
            let selectedDeviceIDs = (arguments.removeOption("--devices") ?? "")
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard selectedDeviceIDs.count <= 32 else {
                throw CLIError.usage("--devices accepts at most 32 comma-separated device IDs")
            }
            guard !macOnly || selectedDeviceIDs.isEmpty else {
                throw CLIError.usage("Use either --mac-only or --devices, not both")
            }
            let raw = arguments.popFirst() ?? "today"
            guard arguments.values.isEmpty else {
                throw CLIError.usage(
                    "screen-time accepts one date and either --mac-only or --devices <id,id>"
                )
            }
            try printScreenTime(
                root: root,
                day: try day(raw),
                macOnly: macOnly,
                selectedDeviceIDs: selectedDeviceIDs
            )

        case "websites":
            let limit = try integer(arguments.removeOption("--limit") ?? "100")
            let offset = try integer(arguments.removeOption("--offset") ?? "0")
            guard (1...1_000).contains(limit) else {
                throw CLIError.usage("--limit must be between 1 and 1000")
            }
            guard (0...50_000).contains(offset) else {
                throw CLIError.usage("--offset must be between 0 and 50000")
            }
            let raw = arguments.popFirst() ?? "today"
            guard arguments.values.isEmpty else {
                throw CLIError.usage(
                    "websites accepts one date and the optional --limit and --offset values"
                )
            }
            try printDailyWebsites(
                root: root,
                day: try day(raw),
                limit: limit,
                offset: offset
            )

        case "ai-conversations":
            let tokenBudget = try integer(arguments.removeOption("--tokens") ?? "40000")
            let conversationLimit = try integer(arguments.removeOption("--limit") ?? "24")
            let candidateOffset = try integer(arguments.removeOption("--offset") ?? "0")
            guard (2_048...100_000).contains(tokenBudget) else {
                throw CLIError.usage("--tokens must be between 2048 and 100000")
            }
            guard (1...256).contains(conversationLimit) else {
                throw CLIError.usage("--limit must be between 1 and 256")
            }
            guard (0...50_000).contains(candidateOffset) else {
                throw CLIError.usage("--offset must be between 0 and 50000")
            }
            let raw = arguments.popFirst() ?? "today"
            guard arguments.values.isEmpty else {
                throw CLIError.usage(
                    "ai-conversations accepts one date and the optional --tokens, --limit and --offset values"
                )
            }
            try printAgentConversations(
                root: root,
                day: try day(raw),
                tokenBudget: tokenBudget,
                conversationLimit: conversationLimit,
                candidateOffset: candidateOffset
            )

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
                        integrity: nil,
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
                let integrity = recapIntegrity(recap)
                try printJSON(
                    DailyRecapEnvelope(
                        rootDirectory: root.path,
                        requestedDay: dayString,
                        status: "available",
                        recap: recap,
                        integrity: integrity,
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
                        integrity: nil,
                        sourcePath: recapURL.path,
                        error: String(describing: error)
                    )
                )
            }

        case "verify-recap":
            guard let rawPath = arguments.popFirst(), arguments.values.isEmpty else {
                throw CLIError.usage("verify-recap requires exactly one report path")
            }
            let reportURL = expandedURL(rawPath)
            do {
                let data = try readStableRegularFile(reportURL, maximumBytes: 64 * 1_024)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let recap = try decoder.decode(DailyRecap.self, from: data)
                let integrity = recapIntegrity(recap)
                let status: String
                switch integrity.status {
                case "locallySigned": status = "locallyValid"
                case "legacyUnsigned": status = "legacyUnsigned"
                default: status = "invalid"
                }
                try printJSON(
                    DailyRecapFileVerificationEnvelope(
                        reportPath: reportURL.path,
                        reportBytes: data.count,
                        reportSHA256: SHA256Digest.hashHex(data),
                        status: status,
                        recap: recap,
                        integrity: integrity,
                        error: status == "invalid" ? "The local analysis attestation is invalid." : nil
                    )
                )
            } catch {
                try printJSON(
                    DailyRecapFileVerificationEnvelope(
                        reportPath: reportURL.path,
                        reportBytes: 0,
                        reportSHA256: "",
                        status: "inaccessibleOrInvalid",
                        recap: nil,
                        integrity: nil,
                        error: String(describing: error)
                    )
                )
            }

        case "export-proof":
            let outputPath = arguments.removeOption("--output")
            let raw = arguments.popFirst() ?? "yesterday"
            guard arguments.values.isEmpty else {
                throw CLIError.usage("export-proof accepts one date and optional --output PATH")
            }
            let requestedDay = try day(raw)
            let dayString = localDayString(requestedDay)
            let recapURL = root
                .appendingPathComponent("chatgpt", isDirectory: true)
                .appendingPathComponent("recaps", isDirectory: true)
                .appendingPathComponent("\(dayString).chatgpt-recap.json", isDirectory: false)
            do {
                let recapData = try readStableRegularFile(recapURL, maximumBytes: 64 * 1_024)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let recap = try decoder.decode(DailyRecap.self, from: recapData)
                guard let proof = recap.proof,
                    UUID(uuidString: proof.executionID) != nil,
                    proof.proofDirectoryName == proof.executionID
                else {
                    throw CLIError.usage(
                        "No standalone analysis proof is available for \(dayString); regenerate this day with the current Goalong build"
                    )
                }
                let proofDirectory = root
                    .appendingPathComponent("chatgpt", isDirectory: true)
                    .appendingPathComponent("proofs", isDirectory: true)
                    .appendingPathComponent(proof.proofDirectoryName, isDirectory: true)
                let names = [
                    "manifest.json", "definition.jws", "context-manifest.json",
                    "provider-request.json", "provider-response.json", "result.json",
                    "device-public-key.x963", "run.jws",
                ]
                var entries: [String: Data] = [:]
                for name in names {
                    entries[name] = try readStableRegularFile(
                        proofDirectory.appendingPathComponent(name, isDirectory: false),
                        maximumBytes: 4 * 1_024 * 1_024
                    )
                }
                let archive = try GoalongProofArchive.create(entries: entries)
                let report = try GoalongProofPackageVerifier.verify(archive: archive)
                guard report.isLocallyValid else {
                    throw CLIError.usage("The local proof failed verification and was not exported")
                }
                let destination: URL
                if let outputPath {
                    destination = expandedFileURL(outputPath)
                } else {
                    destination = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                        .appendingPathComponent(
                            "\(dayString)-\(String(proof.executionID.prefix(8))).goalong-proof",
                            isDirectory: false
                        )
                }
                guard destination.pathExtension == "goalong-proof" else {
                    throw CLIError.usage("--output must end in .goalong-proof")
                }
                guard !FileManager.default.fileExists(atPath: destination.path) else {
                    throw CLIError.usage("The export destination already exists: \(destination.path)")
                }
                try archive.write(to: destination, options: [.atomic])
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: destination.path
                )
                let persisted = try readStableRegularFile(
                    destination,
                    maximumBytes: Int64(GoalongProofArchive.maximumArchiveBytes)
                )
                let persistedReport = try GoalongProofPackageVerifier.verify(archive: persisted)
                try printJSON(
                    AnalysisProofExportEnvelope(
                        rootDirectory: root.path,
                        requestedDay: dayString,
                        packagePath: destination.path,
                        packageBytes: persisted.count,
                        packageSHA256: GoalongProofDigest.sha256(persisted),
                        report: persistedReport,
                        status: persistedReport.isLocallyValid ? "locallyValid" : "invalid",
                        error: persistedReport.isLocallyValid ? nil : persistedReport.issues.joined(separator: ", ")
                    )
                )
            } catch {
                try printJSON(
                    AnalysisProofExportEnvelope(
                        rootDirectory: root.path,
                        requestedDay: dayString,
                        packagePath: nil,
                        packageBytes: 0,
                        packageSHA256: "",
                        report: nil,
                        status: "unavailableOrInvalid",
                        error: String(describing: error)
                    )
                )
            }

        case "verify-proof":
            guard let rawPath = arguments.popFirst(), arguments.values.isEmpty else {
                throw CLIError.usage("verify-proof requires exactly one .goalong-proof path")
            }
            let packageURL = expandedFileURL(rawPath)
            do {
                let data = try readStableRegularFile(
                    packageURL,
                    maximumBytes: Int64(GoalongProofArchive.maximumArchiveBytes)
                )
                let report = try GoalongProofPackageVerifier.verify(archive: data)
                try printJSON(
                    AnalysisProofPackageVerificationEnvelope(
                        packagePath: packageURL.path,
                        packageBytes: data.count,
                        packageSHA256: GoalongProofDigest.sha256(data),
                        report: report,
                        status: report.isLocallyValid ? "locallyValid" : "invalid",
                        error: report.isLocallyValid ? nil : report.issues.joined(separator: ", ")
                    )
                )
            } catch {
                try printJSON(
                    AnalysisProofPackageVerificationEnvelope(
                        packagePath: packageURL.path,
                        packageBytes: 0,
                        packageSHA256: "",
                        report: nil,
                        status: "inaccessibleOrInvalid",
                        error: String(describing: error)
                    )
                )
            }

        case "verify-share":
            guard let rawPath = arguments.popFirst(), arguments.values.isEmpty else {
                throw CLIError.usage("verify-share requires exactly one package path")
            }
            let packageURL = expandedURL(rawPath)
            do {
                let data = try readStableRegularFile(
                    packageURL,
                    maximumBytes: 384 * 1_024 * 1_024
                )
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let package = try decoder.decode(DaySharePackage.self, from: data)
                let report = package.verificationReport()
                try printJSON(
                    SharePackageVerificationEnvelope(
                        packagePath: packageURL.path,
                        packageBytes: data.count,
                        packageSHA256: SHA256Digest.hashHex(data),
                        localDay: package.localDay,
                        createdAt: package.createdAt,
                        report: report,
                        status: report.isLocallyValid ? "locallyValid" : "invalid",
                        error: report.isLocallyValid
                            ? nil : report.issues.joined(separator: ", ")
                    )
                )
            } catch {
                try printJSON(
                    SharePackageVerificationEnvelope(
                        packagePath: packageURL.path,
                        packageBytes: 0,
                        packageSHA256: "",
                        localDay: nil,
                        createdAt: nil,
                        report: nil,
                        status: "inaccessibleOrInvalid",
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
            let screenTime = freshScreenTimeContext(
                root: root,
                question: question,
                firstDay: explicitInterval?.start ?? today,
                endExclusive: explicitInterval?.end ?? now,
                maximumDays: maximumDays
            )
            if questionUsesOnlyFreshScreenTime(question) {
                try printJSON(
                    ComputerHistoryAnswerEnvelope(
                        rootDirectory: root.path,
                        answer: ComputerHistoryAnswer(
                            query: question,
                            generatedAt: now,
                            answer: screenTime.days.isEmpty
                                ? "Screen Time was requested, but no daily result was available. Inspect screenTime.status and screenTime.issues."
                                : "Stored completed-day and/or refreshed active-day Screen Time is returned in screenTime. Computer History was not read because this question asks only for Screen Time.",
                            hits: [],
                            limitations: [
                                "This direct Screen Time route deliberately skips unrelated Computer History journals to minimize latency, CPU and memory.",
                                "Screen Time durations do not by themselves prove attention, productivity or intent.",
                            ]
                        ),
                        reconstructedDays: 0,
                        retainedProjectionBytes: 0,
                        screenTime: screenTime,
                        loadIssues: []
                    )
                )
                return
            }
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
                    screenTime: screenTime,
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

    private static func completeComputerHistoryIndex(
        loaded: ComputerHistoryEvidenceLoad,
        dayStart: Date
    ) -> ComputerHistoryActivityIndex? {
        guard validComputerHistoryLoad(loaded) else { return nil }
        return ComputerHistoryEngine.completeActivityIndex(
            events: loaded.events,
            semanticSnapshots: loaded.semanticSnapshots,
            day: dayStart,
            sourceJournalSummary: loaded.sourceJournalSummary
        )
    }

    private static func loadCompleteComputerHistoryIndex(
        reader: HistoryLocalStoreReader,
        dayStart: Date,
        dayEnd: Date
    ) -> CompleteComputerHistoryIndexLoad {
        let stored = reader.loadCurrentComputerHistoryMemory(day: dayStart)
        if let memory = stored.memory {
            return CompleteComputerHistoryIndexLoad(
                index: ComputerHistoryActivityIndex(
                    dayStart: memory.dayStart,
                    dayEnd: memory.dayEnd,
                    generatedAt: memory.generatedAt,
                    activities: memory.episodes.map(
                        ComputerHistoryActivityIndexEntry.init
                    ),
                    coverage: memory.coverage
                ),
                sourceMode: "validatedBoundedIndex",
                sourceBytesRead: stored.bytesRead,
                error: nil,
                loadIssues: []
            )
        }

        let loaded = reader.loadComputerHistoryEvidence(
            start: dayStart,
            endExclusive: dayEnd
        )
        let index = completeComputerHistoryIndex(
            loaded: loaded,
            dayStart: dayStart
        )
        let error = computerHistoryLoadError(
            loaded: loaded,
            hasResult: index != nil
        )
        return CompleteComputerHistoryIndexLoad(
            index: index,
            sourceMode: "authoritativeJournals",
            sourceBytesRead:
                stored.bytesRead
                + loaded.metrics.eventBytesRead
                + loaded.metrics.semanticBytesRead,
            error: error,
            loadIssues: error == nil ? loaded.issues : stored.issues + loaded.issues
        )
    }

    private static func loadCompleteComputerHistoryMemory(
        reader: HistoryLocalStoreReader,
        dayStart: Date,
        start: Date,
        end: Date,
        allowsValidatedDayIndex: Bool
    ) -> CompleteComputerHistoryMemoryLoad {
        var validationBytesRead: Int64 = 0
        var validationIssues: [HistoryLoadIssue] = []
        if allowsValidatedDayIndex {
            let stored = reader.loadCurrentComputerHistoryMemory(day: dayStart)
            validationBytesRead = stored.bytesRead
            validationIssues = stored.issues
            if let memory = stored.memory {
                return CompleteComputerHistoryMemoryLoad(
                    memory: memory,
                    sourceMode: "validatedBoundedIndex",
                    sourceBytesRead: stored.bytesRead,
                    error: nil,
                    loadIssues: []
                )
            }
        }

        let loaded = reader.loadComputerHistoryEvidence(
            start: start,
            endExclusive: end
        )
        let isValid = validComputerHistoryLoad(loaded)
        let memory = isValid
            ? ComputerHistoryEngine.analyze(
                events: loaded.events,
                semanticSnapshots: loaded.semanticSnapshots,
                day: dayStart,
                sourceJournalSummary: loaded.sourceJournalSummary
            )
            : nil
        return CompleteComputerHistoryMemoryLoad(
            memory: memory,
            sourceMode: "authoritativeJournals",
            sourceBytesRead:
                validationBytesRead
                + loaded.metrics.eventBytesRead
                + loaded.metrics.semanticBytesRead,
            error: computerHistoryLoadError(loaded: loaded, hasResult: memory != nil),
            loadIssues: validationIssues + loaded.issues
        )
    }

    private static func validComputerHistoryLoad(
        _ loaded: ComputerHistoryEvidenceLoad
    ) -> Bool {
        loaded.sourceJournalSummary.eventCount > 0
            && !loaded.metrics.sourceChangedDuringRead
            && !loaded.metrics.sourceAccessWasIncomplete
            && !loaded.metrics.evidenceBudgetExceeded
    }

    private static func computerHistoryLoadError(
        loaded: ComputerHistoryEvidenceLoad,
        hasResult: Bool
    ) -> String? {
        if loaded.metrics.sourceChangedDuringRead {
            return "The original Computer History source changed during read; no partial result was returned."
        }
        if loaded.metrics.sourceAccessWasIncomplete {
            return "An original Computer History source was absent, inaccessible or unsafe; no partial result was returned."
        }
        if loaded.metrics.evidenceBudgetExceeded {
            return "The Computer History evidence working-set budget was exceeded; no partial result was returned."
        }
        if !hasResult { return "No events were loaded for that day." }
        return nil
    }

    private static func pagedActivity(
        _ episode: ComputerHistoryEpisode,
        interactions: [ComputerHistoryInteraction]
    ) -> ComputerHistoryEpisode {
        ComputerHistoryEpisode(
            id: episode.id,
            start: episode.start,
            end: episode.end,
            title: episode.title,
            summary: episode.summary,
            status: episode.status,
            statusConfidence: episode.statusConfidence,
            applications: episode.applications,
            sites: episode.sites,
            resourceIDs: episode.resourceIDs,
            requestsOrIntentions: episode.requestsOrIntentions,
            observableOutcomes: episode.observableOutcomes,
            interactions: interactions,
            sourceInteractionCount: episode.totalInteractionCount,
            eventCount: episode.eventCount,
            semanticSnapshotCount: episode.semanticSnapshotCount,
            workflowFingerprint: episode.workflowFingerprint,
            provenance: episode.provenance
        )
    }

    private static func service(from loaded: HistoryLoadedData) -> HistoryQueryService {
        HistoryQueryService(
            events: loaded.events,
            memories: loaded.memories,
            semanticSnapshots: loaded.semanticSnapshots
        )
    }

    public static func screenTimePayload(
        day rawDay: String,
        macOnly: Bool,
        selectedDeviceIDs: [String] = [],
        collectionProvider: ((Date) -> AppleSystemScreenTimeCollection)? = nil,
        currentMacProvider: (() -> AppleScreenTimeDevice)? = nil
    ) throws -> Data {
        try encodedScreenTime(
            day: try day(rawDay),
            macOnly: macOnly,
            selectedDeviceIDs: selectedDeviceIDs,
            collectionProvider: collectionProvider,
            currentMacProvider: currentMacProvider
        )
    }

    public static func screenTimeRangePayload(
        days rawDays: [String],
        collectionProvider: ((DateInterval) -> AppleSystemScreenTimeCollection)? = nil,
        dailyCollectionProvider: ((Date) -> AppleSystemScreenTimeCollection)? = nil,
        currentMacProvider: (() -> AppleScreenTimeDevice)? = nil
    ) throws -> Data {
        guard (1...31).contains(rawDays.count) else {
            throw CLIError.usage("Screen Time range requires between 1 and 31 days")
        }

        let calendar = Calendar.current
        let requestedDays = try rawDays
            .map(day)
            .map { calendar.startOfDay(for: $0) }
        let uniqueDays = Array(Set(requestedDays)).sorted()
        guard let firstDay = uniqueDays.first,
            let lastDay = uniqueDays.last,
            let lastInterval = calendar.dateInterval(of: .day, for: lastDay),
            let exclusiveLimit = calendar.date(byAdding: .day, value: 31, to: firstDay),
            lastInterval.end <= exclusiveLimit
        else {
            throw CLIError.usage("Screen Time range must stay within 31 consecutive days")
        }

        let requestedInterval = DateInterval(start: firstDay, end: lastInterval.end)
        let generatedAt = Date()
        let collections: [AppleSystemScreenTimeCollection]
        let freshness: String
        if let dailyCollectionProvider, let currentMacProvider {
            let currentMac = currentMacProvider()
            collections = uniqueDays.map {
                AppleScreenTimeDeviceNormalizer.normalize(
                    dailyCollectionProvider($0),
                    currentMac: currentMac
                )
            }
            freshness = rangeFreshness(for: collections)
        } else {
            let rawCollection: AppleSystemScreenTimeCollection
            let currentMac: AppleScreenTimeDevice
            if let collectionProvider, let currentMacProvider {
                rawCollection = collectionProvider(requestedInterval)
                currentMac = currentMacProvider()
            } else {
                throw CLIError.unsafeSource(
                    "Screen Time range reads require Goalong's daily repository; direct Apple access from the CLI is disabled."
                )
            }
            let collection = AppleScreenTimeDeviceNormalizer.normalize(
                rawCollection,
                currentMac: currentMac
            )
            collections = Array(repeating: collection, count: uniqueDays.count)
            freshness = "singleOnDemandAppleRangeReadForThisRequest"
        }
        let compactDays = try zip(uniqueDays, collections).map {
            try compactScreenTimeDay(day: $0.0, collection: $0.1)
        }
        let status = aggregateScreenTimeStatus(collections)
        let assurances = Set(collections.compactMap {
            $0.storedExport?.envelope.provenance.sourceAssurance.rawValue
        })
        return try encodedJSON(
            ScreenTimeRangeEnvelope(
                schemaVersion: 1,
                generatedAt: generatedAt,
                freshness: freshness,
                sourceAssurance: assurances.count == 1 ? assurances.first : nil,
                status: ScreenTimeStatusEnvelope(
                    kind: status.kind.rawValue,
                    title: status.title,
                    message: status.message
                ),
                days: compactDays,
                limitation: screenTimeLimitation(
                    provenance: collections.compactMap(\.storedExport).last?.envelope.provenance
                )
            )
        )
    }

    static func questionRequiresFreshScreenTime(_ question: String) -> Bool {
        let normalized = normalizedScreenTimeQuestion(question)

        let directPhrases = [
            "screen time", "screentime", "temps d ecran", "temps ecran",
            "all devices", "tous les appareils", "iphone", "ipad", "apple watch",
        ]
        if directPhrases.contains(where: normalized.contains) { return true }

        let durationPhrases = [
            "combien de temps", "combien d heures", "temps passe", "temps perdu",
            "heures productives", "productivite", "how long", "how much time",
            "time spent", "hours spent", "productive hours", "wasted time", "productif",
            "productive", "efficacite", "efficiency",
        ]
        if durationPhrases.contains(where: normalized.contains) { return true }

        let rankingPhrases = ["plus utilise", "most used", "principal usage", "top app"]
        let usageSubjects = [
            " app ", "application", "site", "browser", "navigateur", "mac",
            "ordinateur", "telephone", "device", "appareil",
        ]
        let padded = " \(normalized) "
        return rankingPhrases.contains(where: normalized.contains)
            && usageSubjects.contains(where: padded.contains)
    }

    static func questionUsesOnlyFreshScreenTime(_ question: String) -> Bool {
        guard questionRequiresFreshScreenTime(question) else { return false }
        let normalized = normalizedScreenTimeQuestion(question)
        let hybridPhrases = [
            "productivite", "productive", "productivity", "efficacite", "efficiency",
            "temps perdu", "wasted time", "worked", "work on", "travaille", "travail",
            "summary", "summarize", "recap", "bilan", "resume ma journee",
            "analyse ma journee", "conversation", "agent",
        ]
        guard !hybridPhrases.contains(where: normalized.contains) else { return false }

        let directPhrases = [
            "screen time", "screentime", "temps d ecran", "temps ecran",
            "all devices", "tous les appareils", "iphone", "ipad", "apple watch",
        ]
        if directPhrases.contains(where: normalized.contains) { return true }

        let usageSubjects = [
            " app ", "application", "site", "browser", "navigateur", "mac",
            "ordinateur", "telephone", "device", "appareil",
        ]
        return usageSubjects.contains(where: " \(normalized) ".contains)
    }

    private static func normalizedScreenTimeQuestion(_ question: String) -> String {
        question
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func freshScreenTimeContext(
        root: URL,
        question: String,
        firstDay: Date,
        endExclusive: Date,
        maximumDays: Int,
        requestProvider: (URL, [String]) throws -> Data = { root, days in
            let parsedDays = try days.map(day)
            let today = Calendar.current.startOfDay(for: Date())
            if parsedDays.allSatisfy({ Calendar.current.startOfDay(for: $0) < today }) {
                return try storedScreenTimeRangePayload(root: root, days: days)
            }
            return try GoalongReadOnlyQueryBroker.requestScreenTimeRange(
                rootDirectory: root,
                days: days
            )
        }
    ) -> ScreenTimeAskContext {
        guard questionRequiresFreshScreenTime(question) else {
            return ScreenTimeAskContext(
                requested: false,
                refreshPolicy: "notNeededForThisQuestion",
                generatedAt: nil,
                sourceAssurance: nil,
                status: nil,
                days: [],
                issues: [],
                limitation: nil,
                nextStep: nil
            )
        }

        let calendar = Calendar.current
        var requestedDays: [Date] = []
        var cursor = calendar.startOfDay(for: firstDay)
        let boundedEnd = max(endExclusive, cursor.addingTimeInterval(1))
        while cursor < boundedEnd {
            requestedDays.append(cursor)
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor),
                next > cursor
            else { break }
            cursor = next
        }

        let maximumFreshDays = min(max(1, maximumDays), 31)
        let omittedDayCount = max(0, requestedDays.count - maximumFreshDays)
        if omittedDayCount > 0 {
            requestedDays = Array(requestedDays.suffix(maximumFreshDays))
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var days: [ScreenTimeAskDay] = []
        var issues: [String] = []
        var generatedAt: Date?
        var sourceAssurance: String?
        var status: ScreenTimeStatusEnvelope?
        var limitation: String?
        if omittedDayCount > 0 {
            issues.append(
                "The indirect Screen Time context is limited to the latest \(maximumFreshDays) requested days; \(omittedDayCount) older days were omitted to bound CPU and output size."
            )
        }

        let requestedDayStrings = requestedDays.map(localDayString)
        do {
            let payload = try requestProvider(root, requestedDayStrings)
            let envelope = try decoder.decode(ScreenTimeRangeEnvelope.self, from: payload)
            guard envelope.schemaVersion == 1,
                supportedScreenTimeRangeFreshness.contains(envelope.freshness)
            else {
                throw CLIError.unsafeSource("The Screen Time broker returned an unsupported range response.")
            }
            generatedAt = envelope.generatedAt
            sourceAssurance = envelope.sourceAssurance
            status = envelope.status
            limitation = envelope.limitation
            let returnedDays = Dictionary(grouping: envelope.days, by: \.day)
            for dayString in requestedDayStrings {
                guard let matches = returnedDays[dayString], matches.count == 1,
                    let day = matches.first
                else {
                    issues.append("\(dayString): stored/live Screen Time range omitted or duplicated this day.")
                    continue
                }
                days.append(day)
            }
            let unexpectedDays = Set(returnedDays.keys).subtracting(requestedDayStrings)
            if !unexpectedDays.isEmpty {
                issues.append(
                    "The Screen Time broker returned unexpected days: \(unexpectedDays.sorted().joined(separator: ", "))."
                )
            }
        } catch {
            issues.append("Stored/live Screen Time range read failed: \(error)")
        }

        let needsDirectDetail = days.contains { $0.omittedApplicationCount > 0 }
            || omittedDayCount > 0
        return ScreenTimeAskContext(
            requested: true,
            refreshPolicy: "completedDaysFromLocalStoreCurrentDayFromApple",
            generatedAt: generatedAt,
            sourceAssurance: sourceAssurance,
            status: status,
            days: days,
            issues: issues,
            limitation: limitation,
            nextStep: needsDirectDetail
                ? "Run goalong screen-time DAY for every application and source detail omitted from this compact indirect context."
                : nil
        )
    }

    private static func printScreenTime(
        root: URL,
        day: Date,
        macOnly: Bool,
        selectedDeviceIDs: [String]
    ) throws {
        guard capabilityConsentEnabled(
            rootDirectory: root,
            capability: "appleScreenTime"
        ) else {
            throw CLIError.unsafeSource(
                "Apple Screen Time is off in Goalong. Enable that source explicitly before the CLI reads active or stored daily records."
            )
        }
        let requestedDay = Calendar.current.startOfDay(for: day)
        let today = Calendar.current.startOfDay(for: Date())
        if requestedDay < today {
            FileHandle.standardOutput.write(
                try storedScreenTimePayload(
                    root: root,
                    day: requestedDay,
                    macOnly: macOnly,
                    selectedDeviceIDs: selectedDeviceIDs
                )
            )
            return
        }
        do {
            let payload = try GoalongReadOnlyQueryBroker.requestScreenTime(
                rootDirectory: root,
                day: localDayString(day),
                macOnly: macOnly,
                selectedDeviceIDs: selectedDeviceIDs
            )
            FileHandle.standardOutput.write(payload)
        } catch {
            throw CLIError.unsafeSource(
                "Apple Screen Time is unavailable. Open Goalong History and explicitly enable Screen Time; the CLI never reads Apple's protected stores directly. Broker error: \(error)"
            )
        }
    }

    static func storedScreenTimeRangePayload(
        root: URL,
        days rawDays: [String],
        now: Date = Date()
    ) throws -> Data {
        guard capabilityConsentEnabled(
            rootDirectory: root,
            capability: "appleScreenTime"
        ) else {
            throw CLIError.unsafeSource(
                "Apple Screen Time is off in Goalong. Stored daily records remain inaccessible until the source is enabled again."
            )
        }
        let calendar = Calendar.current
        let requestedDays = Array(
            Set(try rawDays.map(day).map { calendar.startOfDay(for: $0) })
        ).sorted()
        let today = calendar.startOfDay(for: now)
        guard requestedDays.allSatisfy({ $0 < today }) else {
            throw CLIError.usage("Stored Screen Time ranges can contain completed days only")
        }
        let archive = try AppleSystemScreenTimeDailyArchive(
            rootDirectory: root.appendingPathComponent("apple-screen-time", isDirectory: true),
            calendar: calendar,
            createIfMissing: false
        )
        let collections = Dictionary(uniqueKeysWithValues: requestedDays.map { requestedDay in
            (
                localDayString(requestedDay),
                archive.storedCollection(for: requestedDay, now: now)
                    ?? missingStoredScreenTimeCollection(for: requestedDay)
            )
        })
        let currentMac = currentMacDevice(in: Array(collections.values))
        return try screenTimeRangePayload(
            days: rawDays,
            dailyCollectionProvider: {
                collections[localDayString($0)] ?? missingStoredScreenTimeCollection(for: $0)
            },
            currentMacProvider: { currentMac }
        )
    }

    private static func storedScreenTimePayload(
        root: URL,
        day: Date,
        macOnly: Bool,
        selectedDeviceIDs: [String]
    ) throws -> Data {
        let archive = try AppleSystemScreenTimeDailyArchive(
            rootDirectory: root.appendingPathComponent("apple-screen-time", isDirectory: true),
            createIfMissing: false
        )
        let collection = archive.storedCollection(for: day)
            ?? missingStoredScreenTimeCollection(for: day)
        let currentMac = currentMacDevice(in: [collection])
        return try encodedScreenTime(
            day: day,
            macOnly: macOnly,
            selectedDeviceIDs: selectedDeviceIDs,
            collectionProvider: { _ in collection },
            currentMacProvider: { currentMac }
        )
    }

    private static func currentMacDevice(
        in collections: [AppleSystemScreenTimeCollection]
    ) -> AppleScreenTimeDevice {
        let devices = collections.flatMap(\.availableDevices)
        return devices.first(where: {
            $0.kind == .mac && $0.id.hasPrefix("apple-system-current-mac:")
        })
            ?? devices.first(where: { $0.kind == .mac })
            ?? AppleScreenTimeDevice(
                id: "goalong-cli-current-mac",
                name: "This Mac",
                kind: .mac
            )
    }

    private static func missingStoredScreenTimeCollection(
        for _: Date
    ) -> AppleSystemScreenTimeCollection {
        AppleSystemScreenTimeCollection(
            storedExport: nil,
            availableDevices: [],
            status: AppleSystemScreenTimeStatus(
                kind: .noAppleData,
                title: "No stored Screen Time for this completed day",
                message: "Goalong only reads Apple Screen Time while a day is active. No local daily record exists for this completed day."
            ),
            deviceSourceLabels: [:],
            latestAppleUpdate: nil,
            knowledgeIntervalCount: 0,
            biomeIntervalCount: 0,
            screenTimeAppUsageIntervalCount: 0,
            storageState: .missingCompletedDay
        )
    }

    private static func encodedScreenTime(
        day: Date,
        macOnly: Bool,
        selectedDeviceIDs: [String],
        collectionProvider: ((Date) -> AppleSystemScreenTimeCollection)? = nil,
        currentMacProvider: (() -> AppleScreenTimeDevice)? = nil
    ) throws -> Data {
        guard let dayInterval = Calendar.current.dateInterval(of: .day, for: day) else {
            throw CLIError.invalidDate(localDayString(day))
        }
        let rawCollection: AppleSystemScreenTimeCollection
        let currentMac: AppleScreenTimeDevice
        if let collectionProvider, let currentMacProvider {
            rawCollection = collectionProvider(day)
            currentMac = currentMacProvider()
        } else {
            throw CLIError.unsafeSource(
                "Screen Time reads require Goalong's daily repository; direct Apple access from the CLI is disabled."
            )
        }
        let collection = AppleScreenTimeDeviceNormalizer.normalize(
            rawCollection,
            currentMac: currentMac
        )
        let scope: AppleScreenTimeScope
        if macOnly {
            scope = .macOnly
        } else if !selectedDeviceIDs.isEmpty {
            scope = AppleScreenTimeScope(
                mode: .selectedDevices,
                selectedDeviceIDs: selectedDeviceIDs
            )
        } else {
            scope = .allDevices
        }
        let reports = collection.storedExport?.envelope.reports.filter {
            scope.includes($0.device)
        } ?? []
        // Keep Apple's explicit All Devices presentation available to the analyzer even when
        // the response exposes only the selected physical reports. When every physical device
        // is selected, summing individually rounded rows can differ from Apple's own aggregate.
        let summary = collection.storedExport.flatMap {
            AppleScreenTimeAnalyzer.summary(from: $0, interval: dayInterval, scope: scope)
        }
        let limitation = screenTimeLimitation(summary: summary)
        return try encodedJSON(
            ScreenTimeEnvelope(
                schemaVersion: 1,
                day: localDayString(day),
                generatedAt: Date(),
                freshness: screenTimeFreshness(for: collection.storageState),
                scope: scope.mode.rawValue,
                sourceAssurance: summary?.provenance.sourceAssurance.rawValue,
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
                screenTimeAppUsageIntervalCount: collection.screenTimeAppUsageIntervalCount,
                knowledgeIntervalCount: collection.knowledgeIntervalCount,
                biomeIntervalCount: collection.biomeIntervalCount,
                limitation: limitation
            )
        )
    }

    private static func compactScreenTimeDay(
        day: Date,
        collection: AppleSystemScreenTimeCollection
    ) throws -> ScreenTimeAskDay {
        guard let dayInterval = Calendar.current.dateInterval(of: .day, for: day) else {
            throw CLIError.invalidDate(localDayString(day))
        }
        let summary = collection.storedExport.flatMap {
            AppleScreenTimeAnalyzer.summary(
                from: $0,
                interval: dayInterval,
                scope: .allDevices
            )
        }
        let applications = summary?.topApplications ?? []
        let includedApplications = applications.prefix(24).map {
            ScreenTimeAskUsage(
                name: $0.resolvedName,
                bundleIdentifier: $0.bundleIdentifier,
                duration: $0.duration
            )
        }
        return ScreenTimeAskDay(
            day: localDayString(day),
            freshness: screenTimeFreshness(for: collection.storageState),
            sourceAssurance: summary?.provenance.sourceAssurance.rawValue,
            totalScreenOnDuration: summary?.totalScreenOnDuration,
            devices: summary?.deviceSummaries.map {
                ScreenTimeAskDevice(
                    id: $0.device.id,
                    name: $0.device.displayName,
                    kind: $0.device.kind.rawValue,
                    screenOnDuration: $0.screenOnDuration,
                    lastUpdatedAt: $0.lastUpdatedAt
                )
            } ?? [],
            applicationCount: applications.count,
            applications: includedApplications,
            omittedApplicationCount: max(0, applications.count - includedApplications.count),
            latestAppleUpdate: summary?.latestDataUpdate ?? collection.latestAppleUpdate
        )
    }

    private static let supportedScreenTimeRangeFreshness: Set<String> = [
        "singleOnDemandAppleRangeReadForThisRequest",
        "storedCompletedDaysOnly",
        "storedCompletedDaysPlusLiveCurrentDay",
        "liveCurrentDayOnly",
        "storedDayCoverageIncomplete",
    ]

    private static func screenTimeFreshness(
        for state: AppleSystemScreenTimeStorageState
    ) -> String {
        switch state {
        case .directAppleRead:
            return "collectedOnDemandForThisRequest"
        case .liveCurrentDayStored:
            return "liveCurrentDayReadAndStored"
        case .activeDayStoredFallback:
            return "storedActiveDayFallback"
        case .completedDayStored:
            return "storedCompletedDayNoAppleHistoryRead"
        case .missingCompletedDay:
            return "missingCompletedDayNoAppleHistoryRead"
        }
    }

    private static func rangeFreshness(
        for collections: [AppleSystemScreenTimeCollection]
    ) -> String {
        let states = Set(collections.map(\.storageState))
        if states == [.completedDayStored] { return "storedCompletedDaysOnly" }
        if states.isSubset(of: [.liveCurrentDayStored, .activeDayStoredFallback]) {
            return "liveCurrentDayOnly"
        }
        if states.contains(.missingCompletedDay) { return "storedDayCoverageIncomplete" }
        if states.contains(.completedDayStored),
           !states.isDisjoint(with: [.liveCurrentDayStored, .activeDayStoredFallback])
        {
            return "storedCompletedDaysPlusLiveCurrentDay"
        }
        return "singleOnDemandAppleRangeReadForThisRequest"
    }

    private static func aggregateScreenTimeStatus(
        _ collections: [AppleSystemScreenTimeCollection]
    ) -> AppleSystemScreenTimeStatus {
        guard let first = collections.first else {
            return AppleSystemScreenTimeStatus(
                kind: .noAppleData,
                title: "No Screen Time day requested",
                message: "No stored or active Screen Time day was requested."
            )
        }
        if collections.allSatisfy({ $0.status == first.status }) {
            return first.status
        }
        let unavailable = collections.filter { $0.storedExport == nil }.count
        return AppleSystemScreenTimeStatus(
            kind: unavailable == collections.count ? .noAppleData : .partial,
            title: unavailable == 0 ? "Screen Time loaded with source warnings" : "Screen Time coverage is incomplete",
            message: unavailable == 0
                ? "Every requested day was loaded; at least one day retained a source warning."
                : "\(unavailable) requested completed day(s) had no local Goalong Screen Time record; Apple history was not reopened."
        )
    }

    private static func screenTimeLimitation(
        summary: AppleScreenTimeDaySummary?
    ) -> String {
        screenTimeLimitation(provenance: summary?.provenance)
    }

    private static func screenTimeLimitation(
        provenance: AppleScreenTimeProvenance?
    ) -> String {
        if provenance?.usesAppleSettingsObservablePresentation == true {
            return "This legacy payload records an older observable Apple Settings presentation. Current Goalong versions no longer control System Settings. Durations do not prove attention or productivity."
        }
        if provenance?.usesScreenTimeAgentAggregateStore == true {
            return "Read-only snapshot of a private Apple ScreenTimeAgent aggregate. Apple does not publish this format as the Settings presentation contract, so exact parity is not certified. Durations do not prove attention or productivity."
        }
        return "Partial reconstruction from Apple ScreenTime.AppUsage, knowledgeC, or Biome. Apple’s private DeviceActivity aggregate was unavailable, so totals can differ from Settings. Durations do not prove attention or productivity."
    }

    private static func printDailyWebsites(
        root: URL,
        day: Date,
        limit: Int,
        offset: Int
    ) throws {
        let loaded = HistoryLocalStoreReader(rootDirectory: root)
            .loadDailyWebsiteUsage(day: day)
        let total = loaded.websites.count
        let boundedOffset = min(offset, total)
        let page = Array(loaded.websites.dropFirst(boundedOffset).prefix(limit))
        let nextOffset = boundedOffset + page.count < total
            ? boundedOffset + page.count
            : nil
        let statusMessage: String = {
            switch loaded.state {
            case .ready:
                return total == 0
                    ? "No public website was observed in the local journal for this day."
                    : "Complete ranked website usage loaded from the original local day journal."
            case .noSourceForDay:
                return "No local event journal exists for this day."
            case .sourceUnavailable:
                return "The original local event journal is absent, inaccessible or invalid."
            case .sourceChanged:
                return "The original local event journal changed during the read; no partial result was returned."
            case .cancelled:
                return "The bounded source read stopped before completion; no partial result was returned."
            case .bounded:
                return "A source or retained-metadata safety bound was reached; no partial ranking was returned."
            }
        }()

        try printJSON(
            DailyWebsitesEnvelope(
                rootDirectory: root.path,
                day: localDayString(loaded.day),
                generatedAt: Date(),
                status: DailyWebsitesStatusEnvelope(
                    kind: loaded.state.rawValue,
                    message: statusMessage
                ),
                scope: "thisMacGoalongObserved",
                includedInApplicationTotals: true,
                sourceBytesRead: loaded.sourceBytesRead,
                sourceRowCount: loaded.sourceRowCount,
                sourceEventCount: loaded.sourceEventCount,
                peakStreamBufferBytes: loaded.peakStreamBufferBytes,
                peakEstimatedRetainedBytes: loaded.peakEstimatedRetainedBytes,
                totalWebsiteCount: total,
                offset: boundedOffset,
                returnedWebsiteCount: page.count,
                nextOffset: nextOffset,
                websites: page.map {
                    DailyWebsiteRowEnvelope(
                        host: $0.host,
                        foregroundSeconds: $0.foregroundSeconds,
                        eventCount: $0.eventCount,
                        sourceApplications: $0.sourceApplications,
                        sourceUsage: $0.sourceUsage
                    )
                },
                loadIssues: loaded.issues,
                limitation:
                    "Website durations are a Goalong-observed breakdown of browser application time on this Mac and must never be added to application or Apple Screen Time totals. Apple does not expose reliable per-site iPhone or iPad detail here. Observations do not prove attention, identity, authorship or productivity."
            )
        )
    }

    private static func printAgentConversations(
        root: URL,
        day: Date,
        tokenBudget: Int,
        conversationLimit: Int,
        candidateOffset: Int
    ) throws {
        let dayStart = Calendar.current.startOfDay(for: day)
        let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: dayStart)!
        let requestedDay = localDayString(dayStart)
        let outputByteBudget = tokenBudget * 4
        guard capabilityConsentEnabled(
            rootDirectory: root,
            capability: "aiConversations"
        ) else {
            try printJSON(
                AgentConversationsEnvelope(
                    rootDirectory: root.path,
                    requestedDay: requestedDay,
                    generatedAt: Date(),
                    status: "consentRequired",
                    indexedConversationCount: 0,
                    relevantConversationCount: 0,
                    candidateOffset: candidateOffset,
                    visitedConversationCandidateCount: 0,
                    nextCandidateOffset: nil,
                    returnedConversationCount: 0,
                    noVisibleMessageCandidateCount: 0,
                    outputDroppedConversationCount: 0,
                    omittedConversationCount: 0,
                    currentSourceBytesRead: 0,
                    outputByteBudget: outputByteBudget,
                    conversations: [],
                    issues: [
                        "AI conversations are off in Goalong. Enable that source explicitly before the CLI reads provider-owned histories."
                    ],
                    limitation: agentConversationLimitation
                )
            )
            return
        }
        let activityRoot = root.appendingPathComponent("agent-activity-v2", isDirectory: true)
        guard FileManager.default.fileExists(atPath: activityRoot.path) else {
            try printJSON(
                AgentConversationsEnvelope(
                    rootDirectory: root.path,
                    requestedDay: requestedDay,
                    generatedAt: Date(),
                    status: "notIndexed",
                    indexedConversationCount: 0,
                    relevantConversationCount: 0,
                    candidateOffset: candidateOffset,
                    visitedConversationCandidateCount: 0,
                    nextCandidateOffset: nil,
                    returnedConversationCount: 0,
                    noVisibleMessageCandidateCount: 0,
                    outputDroppedConversationCount: 0,
                    omittedConversationCount: 0,
                    currentSourceBytesRead: 0,
                    outputByteBudget: outputByteBudget,
                    conversations: [],
                    issues: ["The lightweight Agent Activity index is not present."],
                    limitation: agentConversationLimitation
                )
            )
            return
        }

        let store: AgentActivityStore
        do {
            store = try AgentActivityStore(readOnlyRootDirectory: activityRoot)
        } catch {
            try printJSON(
                AgentConversationsEnvelope(
                    rootDirectory: root.path,
                    requestedDay: requestedDay,
                    generatedAt: Date(),
                    status: "indexInaccessibleOrInvalid",
                    indexedConversationCount: 0,
                    relevantConversationCount: 0,
                    candidateOffset: candidateOffset,
                    visitedConversationCandidateCount: 0,
                    nextCandidateOffset: nil,
                    returnedConversationCount: 0,
                    noVisibleMessageCandidateCount: 0,
                    outputDroppedConversationCount: 0,
                    omittedConversationCount: 0,
                    currentSourceBytesRead: 0,
                    outputByteBudget: outputByteBudget,
                    conversations: [],
                    issues: ["The lightweight Agent Activity index could not be opened read-only."],
                    limitation: agentConversationLimitation
                )
            )
            return
        }

        let allEntries = store.entries()
        let liveModifiedAtByID = Dictionary(
            uniqueKeysWithValues: allEntries.map { entry in
                (entry.id, agentEntryLiveModifiedAt(entry))
            }
        )
        let relevantEntries = allEntries.filter {
            agentEntry(
                $0,
                overlaps: dayStart,
                end: dayEnd,
                liveModifiedAt: liveModifiedAtByID[$0.id] ?? nil
            )
        }.sorted {
            let left = agentEntryPriority(
                $0,
                dayStart: dayStart,
                dayEnd: dayEnd,
                liveModifiedAt: liveModifiedAtByID[$0.id] ?? nil
            )
            let right = agentEntryPriority(
                $1,
                dayStart: dayStart,
                dayEnd: dayEnd,
                liveModifiedAt: liveModifiedAtByID[$1.id] ?? nil
            )
            if left != right { return left > right }
            return $0.id < $1.id
        }
        let perConversationContentBytes = max(
            2_048,
            min(
                32 * 1_024,
                max(outputByteBudget - 16 * 1_024, 2_048)
                    / max(min(relevantEntries.count, conversationLimit), 1)
            )
        )
        let maximumSourceBytes: Int64 = 512 * 1_024 * 1_024
        let maximumCandidateVisits = min(512, max(conversationLimit * 8, conversationLimit))
        let readDeadline = DispatchTime.now().uptimeNanoseconds + 30_000_000_000
        let maximumFileBytes = store.loadConfiguration().maximumFileBytes
        let interval = DateInterval(start: dayStart, end: dayEnd)
        var sourceBytesRead: Int64 = 0
        var conversations: [AgentConversationEnvelope] = []
        var issues: [String] = []
        var noVisibleMessageCandidateCount = 0
        var visitedConversationCandidateCount = 0
        var conversationCandidateOffsets: [Int] = []
        var outputDroppedConversationCount = 0
        var firstDroppedCandidateOffset: Int?

        for (relativeOffset, entry) in
            relevantEntries
            .dropFirst(min(candidateOffset, relevantEntries.count)).enumerated()
        {
            guard conversations.count < conversationLimit else { break }
            guard DispatchTime.now().uptimeNanoseconds < readDeadline else {
                issues.append(
                    "The 30-second direct-read budget was reached; use nextCandidateOffset to continue."
                )
                break
            }
            guard visitedConversationCandidateCount < maximumCandidateVisits else {
                issues.append(
                    "The bounded candidate-visit limit was reached; later metadata candidates were not opened."
                )
                break
            }
            visitedConversationCandidateCount += 1
            let indexedSource = agentSourceEnvelope(entry: entry)
            let liveModifiedAt = liveModifiedAtByID[entry.id] ?? nil
            guard
                entry.availability == .available
                    || agentEntryCanRetryDirectRead(entry, liveModifiedAt: liveModifiedAt)
            else {
                conversations.append(
                    AgentConversationEnvelope(
                        id: entry.id,
                        provider: entry.provider.rawValue,
                        providerName: entry.provider.displayName,
                        title: entry.watchedFolderName,
                        startedAt: entry.conversationStartedAt,
                        endedAt: entry.conversationEndedAt,
                        readStatus: entry.availability.rawValue,
                        source: indexedSource,
                        userPromptCount: 0,
                        finalAnswerCount: 0,
                        messages: [],
                        messagesTruncated: false,
                        error: "The original source is indexed as \(entry.availability.displayName.lowercased())."
                    )
                )
                conversationCandidateOffsets.append(candidateOffset + relativeOffset)
                continue
            }
            let remainingSourceBytes = maximumSourceBytes - sourceBytesRead
            guard remainingSourceBytes > 0 else {
                issues.append("The 512 MiB shared source-read budget was reached; later conversations were not opened.")
                break
            }
            do {
                let record = try store.directRead(
                    entryID: entry.id,
                    maximumBytes: min(maximumFileBytes, remainingSourceBytes),
                    expectedReference: entry.reference,
                    analysisInterval: interval
                )
                sourceBytesRead += max(
                    0,
                    (record.index.endOffset ?? record.byteCount)
                        - (record.index.startOffset ?? 0)
                )
                guard !record.summary.visibleMessages.isEmpty else {
                    noVisibleMessageCandidateCount += 1
                    continue
                }
                let bounded = boundedAgentMessages(
                    record.summary.visibleMessages,
                    maximumBytes: perConversationContentBytes
                )
                conversations.append(
                    AgentConversationEnvelope(
                        id: entry.id,
                        provider: entry.provider.rawValue,
                        providerName: entry.provider.displayName,
                        title: record.summary.title ?? entry.watchedFolderName,
                        startedAt: record.summary.startedAt ?? entry.conversationStartedAt,
                        endedAt: record.summary.endedAt ?? entry.conversationEndedAt,
                        readStatus: "available",
                        source: agentSourceEnvelope(record: record),
                        userPromptCount: record.summary.visibleMessages.filter { $0.role == .user }.count,
                        finalAnswerCount: record.summary.visibleMessages.filter { $0.role == .assistantFinal }.count,
                        messages: bounded.messages,
                        messagesTruncated: bounded.truncated || !record.projectionIsComplete,
                        error: nil
                    )
                )
                conversationCandidateOffsets.append(candidateOffset + relativeOffset)
            } catch let error as AgentSourceReadError {
                conversations.append(
                    unreadAgentConversation(entry: entry, source: indexedSource, error: error)
                )
                conversationCandidateOffsets.append(candidateOffset + relativeOffset)
            } catch {
                conversations.append(
                    AgentConversationEnvelope(
                        id: entry.id,
                        provider: entry.provider.rawValue,
                        providerName: entry.provider.displayName,
                        title: entry.watchedFolderName,
                        startedAt: entry.conversationStartedAt,
                        endedAt: entry.conversationEndedAt,
                        readStatus: "readFailed",
                        source: indexedSource,
                        userPromptCount: 0,
                        finalAnswerCount: 0,
                        messages: [],
                        messagesTruncated: false,
                        error: "The original source could not be read safely."
                    )
                )
                conversationCandidateOffsets.append(candidateOffset + relativeOffset)
            }
        }

        var omittedCount = max(relevantEntries.count - candidateOffset, 0)
            - conversations.count
            - noVisibleMessageCandidateCount
        while true {
            let naturalNextCandidateOffset = candidateOffset + visitedConversationCandidateCount
            let nextCandidateOffset: Int?
            if let firstDroppedCandidateOffset {
                nextCandidateOffset = firstDroppedCandidateOffset
            } else if naturalNextCandidateOffset < relevantEntries.count {
                nextCandidateOffset = naturalNextCandidateOffset
            } else {
                nextCandidateOffset = nil
            }
            let status: String
            if relevantEntries.isEmpty
                || (conversations.isEmpty
                    && naturalNextCandidateOffset >= relevantEntries.count
                    && outputDroppedConversationCount == 0)
            {
                status = "noConversations"
            } else if conversations.isEmpty, outputDroppedConversationCount > 0 {
                status = "outputBudgetExceeded"
            } else if omittedCount > 0 {
                status = "partial"
            } else {
                status = "available"
            }
            let envelope = AgentConversationsEnvelope(
                rootDirectory: root.path,
                requestedDay: requestedDay,
                generatedAt: Date(),
                status: status,
                indexedConversationCount: allEntries.count,
                relevantConversationCount: relevantEntries.count,
                candidateOffset: candidateOffset,
                visitedConversationCandidateCount: visitedConversationCandidateCount,
                nextCandidateOffset: nextCandidateOffset,
                returnedConversationCount: conversations.count,
                noVisibleMessageCandidateCount: noVisibleMessageCandidateCount,
                outputDroppedConversationCount: outputDroppedConversationCount,
                omittedConversationCount: max(omittedCount, 0),
                currentSourceBytesRead: sourceBytesRead,
                outputByteBudget: outputByteBudget,
                conversations: conversations,
                issues: Array(issues.prefix(32)),
                limitation: agentConversationLimitation
            )
            let data = try encodedJSON(envelope)
            if data.count <= outputByteBudget || conversations.isEmpty {
                FileHandle.standardOutput.write(data)
                return
            }
            let droppedCandidateOffset = conversationCandidateOffsets.removeLast()
            conversations.removeLast()
            outputDroppedConversationCount += 1
            firstDroppedCandidateOffset = min(
                firstDroppedCandidateOffset ?? droppedCandidateOffset,
                droppedCandidateOffset
            )
            if outputDroppedConversationCount == 1 {
                issues.append(
                    "The output budget removed one or more returned conversations; nextCandidateOffset resumes at the first removed candidate without skipping it."
                )
            }
            omittedCount += 1
        }
    }

    static func capabilityConsentEnabled(
        rootDirectory: URL,
        capability: String
    ) -> Bool {
        let file = rootDirectory.appendingPathComponent(
            "capability-consent.json",
            isDirectory: false
        )
        guard
            let data = try? readStableRegularFile(file, maximumBytes: 64 * 1_024),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            root["schemaVersion"] as? Int == 1,
            root["policyVersion"] as? Int == 1,
            let capabilities = root["capabilities"] as? [String: Any],
            let record = capabilities[capability] as? [String: Any],
            record["enabled"] as? Bool == true
        else { return false }
        return true
    }

    public static func capabilitiesPayload() throws -> Data {
        try encodedJSON(GoalongCLIContract.capabilities)
    }

    public static func versionPayload() throws -> Data {
        try encodedJSON(versionEnvelope())
    }

    public static func statusPayload(rootDirectory root: URL) throws -> Data {
        let loadedHealth = HistoryLocalStoreReader(rootDirectory: root).loadCaptureHealth()
        let assessment = loadedHealth.snapshot.map { CaptureHealthEvaluator.assess($0) }
        let computerHistoryConsent = capabilityConsentEnabled(
            rootDirectory: root,
            capability: "localComputerHistory"
        )
        let screenTimeConsent = capabilityConsentEnabled(
            rootDirectory: root,
            capability: "appleScreenTime"
        )
        let conversationConsent = capabilityConsentEnabled(
            rootDirectory: root,
            capability: "aiConversations"
        )
        let analysisConsent = capabilityConsentEnabled(
            rootDirectory: root,
            capability: "chatGPTAnalysis"
        )

        let eventDays = filenames(
            in: root.appendingPathComponent("events", isDirectory: true),
            suffix: ".jsonl"
        )
        let computerHistoryDays = filenames(
            in: root.appendingPathComponent("computer-history", isDirectory: true),
            suffix: ".computer-history.json"
        )
        let combinedComputerDays = Array(Set(eventDays + computerHistoryDays)).sorted(by: >)
        let computerHistory = computerHistoryDiagnostic(
            consentEnabled: computerHistoryConsent,
            days: combinedComputerDays,
            snapshot: loadedHealth.snapshot,
            assessment: assessment
        )

        let screenTimeDaysDirectory = root
            .appendingPathComponent("apple-screen-time", isDirectory: true)
            .appendingPathComponent("days", isDirectory: true)
        let screenTimeDays = screenTimeConsent
            ? filenames(in: screenTimeDaysDirectory, suffix: ".json")
            : []
        let brokerRunning = screenTimeConsent
            && GoalongReadOnlyQueryBroker.isRunning(rootDirectory: root)
        let screenTime = screenTimeDiagnostic(
            consentEnabled: screenTimeConsent,
            days: screenTimeDays,
            latestObservedAt: latestRegularFileModificationDate(
                in: screenTimeDaysDirectory,
                suffix: ".json"
            ),
            brokerRunning: brokerRunning
        )

        let aiConversations = agentActivityDiagnostic(
            root: root,
            consentEnabled: conversationConsent
        )
        let recapDirectory = root
            .appendingPathComponent("chatgpt", isDirectory: true)
            .appendingPathComponent("recaps", isDirectory: true)
        let recapDays = filenames(in: recapDirectory, suffix: ".chatgpt-recap.json")
        let dailyRecaps = GoalongSourceDiagnostic(
            state: recapDays.isEmpty ? "noData" : "ready",
            consentEnabled: nil,
            configuredSourceCount: nil,
            itemCount: recapDays.count,
            availableItemCount: recapDays.count,
            missingItemCount: 0,
            inaccessibleItemCount: 0,
            storedMetadataBytes: nil,
            maximumItemCount: nil,
            latestObservedAt: latestRegularFileModificationDate(
                in: recapDirectory,
                suffix: ".chatgpt-recap.json"
            ),
            dates: boundedStatusDates(recapDays),
            providers: [],
            detail: recapDays.isEmpty
                ? "No saved daily recap is currently available."
                : "Saved bounded daily recaps are readable locally.",
            limitations: recapDays.count > 32
                ? ["Only the newest 32 recap dates are listed in status; use `goalong recaps` for all dates."]
                : []
        )
        let chatGPTAnalysis = GoalongAnalysisDiagnostic(
            state: analysisConsent ? "connectionNotProbed" : "disabled",
            consentEnabled: analysisConsent,
            savedRecapCount: recapDays.count,
            latestSavedRecapDay: recapDays.first,
            connectionProbe: "notPerformed",
            detail: analysisConsent
                ? "ChatGPT analysis consent is enabled. The headless status command does not start Codex or inspect credentials; confirm the live account state in Goalong before generating a recap."
                : "ChatGPT analysis is disabled. Existing saved recaps remain readable."
        )
        let runtime = GoalongRuntimeDiagnostic(
            appRunningForActiveScreenTime: brokerRunning,
            brokerState: brokerRunning ? "ready" : (screenTimeConsent ? "unavailable" : "disabled"),
            detail: brokerRunning
                ? "The already-running Goalong app answered a metadata-only owner-local socket probe; no Apple data was read."
                : (screenTimeConsent
                    ? "The active-day Screen Time broker did not answer. Stored completed days remain locally readable."
                    : "The Screen Time broker is intentionally off because Goalong consent is disabled.")
        )
        let sourceStates = [computerHistory.state, screenTime.state, aiConversations.state]
        let overallState: String
        if sourceStates.contains(where: { ["inaccessibleOrInvalid", "permissionRequired", "unavailable"].contains($0) }) {
            overallState = "attentionRequired"
        } else if sourceStates.contains(where: { ["ready", "queryReady", "storedOnly", "availableHistorical"].contains($0) }) {
            overallState = "ready"
        } else {
            overallState = "setupRequired"
        }

        return try encodedJSON(
            HealthEnvelope(
                generatedAt: Date(),
                rootDirectory: root.path,
                overallState: overallState,
                snapshot: loadedHealth.snapshot,
                assessment: assessment,
                runtime: runtime,
                sources: GoalongStatusSources(
                    computerHistory: computerHistory,
                    screenTime: screenTime,
                    aiConversations: aiConversations,
                    dailyRecaps: dailyRecaps,
                    chatGPTAnalysis: chatGPTAnalysis
                ),
                loadIssues: loadedHealth.issues,
                limitations: [
                    "Status reads only bounded Goalong metadata and never opens provider conversation bodies or Apple data stores.",
                    "Computer History health requires an observed real callback; a created event tap alone is not proof.",
                    "ChatGPT account connectivity is intentionally not probed by the headless CLI because that would start the Codex bridge.",
                ]
            )
        )
    }

    private static func versionEnvelope() -> GoalongCLIVersionEnvelope {
        let info = executableBundleInfoDictionary() ?? Bundle.main.infoDictionary ?? [:]
        return GoalongCLIVersionEnvelope(
            appVersion: (info["CFBundleShortVersionString"] as? String) ?? "development",
            buildNumber: (info["CFBundleVersion"] as? String) ?? "development",
            cliContractSchemaVersion: GoalongCLIContract.schemaVersion,
            commandDataSchemaVersion: 1
        )
    }

    /// SwiftPM executables launched through the stable CLI symlink do not reliably populate
    /// `Bundle.main`. Resolve the physical executable first so the app and its embedded CLI both
    /// report the version from their signed enclosing bundle instead of a misleading development
    /// fallback.
    private static func executableBundleInfoDictionary() -> [String: Any]? {
        guard let argument = CommandLine.arguments.first, !argument.isEmpty else { return nil }
        let executable = URL(fileURLWithPath: argument, isDirectory: false)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let infoPlist = executable
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Info.plist", isDirectory: false)
        guard
            let values = try? infoPlist.resourceValues(forKeys: [
                .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
            ]),
            values.isRegularFile == true,
            values.isSymbolicLink != true,
            let size = values.fileSize,
            size > 0,
            size <= 1_048_576,
            let data = try? Data(contentsOf: infoPlist, options: [.mappedIfSafe]),
            let object = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            ),
            let dictionary = object as? [String: Any]
        else { return nil }
        return dictionary
    }

    private static func computerHistoryDiagnostic(
        consentEnabled: Bool,
        days: [String],
        snapshot: CaptureHealthSnapshot?,
        assessment: CaptureHealthAssessment?
    ) -> GoalongSourceDiagnostic {
        guard consentEnabled else {
            return GoalongSourceDiagnostic(
                state: "disabled",
                consentEnabled: false,
                configuredSourceCount: nil,
                itemCount: nil,
                availableItemCount: nil,
                missingItemCount: nil,
                inaccessibleItemCount: nil,
                storedMetadataBytes: nil,
                maximumItemCount: nil,
                latestObservedAt: nil,
                dates: [],
                providers: [],
                detail: "Computer History consent is disabled. Existing data remains locally stored but is hidden from this status summary.",
                limitations: []
            )
        }
        let state: String
        if let assessment {
            state = assessment.state.rawValue
        } else if days.isEmpty {
            state = "noData"
        } else {
            state = "availableHistorical"
        }
        var limitations = assessment?.limitations ?? []
        if days.count > 32 {
            limitations.append("Only the newest 32 Computer History dates are listed; use `goalong days` for all dates.")
        }
        return GoalongSourceDiagnostic(
            state: state,
            consentEnabled: true,
            configuredSourceCount: 1,
            itemCount: days.count,
            availableItemCount: days.count,
            missingItemCount: 0,
            inaccessibleItemCount: 0,
            storedMetadataBytes: nil,
            maximumItemCount: nil,
            latestObservedAt: snapshot?.lastInputEventAt ?? snapshot?.generatedAt,
            dates: boundedStatusDates(days),
            providers: ["Goalong local recorder"],
            detail: assessment?.detail
                ?? (days.isEmpty
                    ? "No Computer History day is currently available."
                    : "Historical Computer History days are readable; current capture health is unavailable."),
            limitations: limitations
        )
    }

    private static func screenTimeDiagnostic(
        consentEnabled: Bool,
        days: [String],
        latestObservedAt: Date?,
        brokerRunning: Bool
    ) -> GoalongSourceDiagnostic {
        guard consentEnabled else {
            return GoalongSourceDiagnostic(
                state: "disabled",
                consentEnabled: false,
                configuredSourceCount: nil,
                itemCount: nil,
                availableItemCount: nil,
                missingItemCount: nil,
                inaccessibleItemCount: nil,
                storedMetadataBytes: nil,
                maximumItemCount: nil,
                latestObservedAt: nil,
                dates: [],
                providers: [],
                detail: "Apple Screen Time consent is disabled. Stored dates remain hidden until the user enables this source.",
                limitations: []
            )
        }
        let state = brokerRunning ? "queryReady" : (days.isEmpty ? "unavailable" : "storedOnly")
        var limitations = [
            "Status does not read Apple data, so queryReady proves only that the owner-local broker can answer. Inspect sourceAssurance and status from an explicit `goalong screen-time DAY` query before claiming Apple Settings parity."
        ]
        if days.count > 32 {
            limitations.append("Only the newest 32 stored Screen Time dates are listed; use `goalong days` for all dates.")
        }
        return GoalongSourceDiagnostic(
            state: state,
            consentEnabled: true,
            configuredSourceCount: nil,
            itemCount: days.count,
            availableItemCount: days.count,
            missingItemCount: 0,
            inaccessibleItemCount: 0,
            storedMetadataBytes: nil,
            maximumItemCount: nil,
            latestObservedAt: latestObservedAt,
            dates: boundedStatusDates(days),
            providers: ["Apple Screen Time"],
            detail: brokerRunning
                ? "Stored days are readable and the running Goalong app can query the active day. The Apple source quality has not been probed by this metadata-only status command."
                : (days.isEmpty
                    ? "No stored day is available and the active-day broker is not running."
                    : "Stored completed days are readable; active-day refresh is unavailable until Goalong is running."),
            limitations: limitations
        )
    }

    private static func agentActivityDiagnostic(
        root: URL,
        consentEnabled: Bool
    ) -> GoalongSourceDiagnostic {
        guard consentEnabled else {
            return GoalongSourceDiagnostic(
                state: "disabled",
                consentEnabled: false,
                configuredSourceCount: nil,
                itemCount: nil,
                availableItemCount: nil,
                missingItemCount: nil,
                inaccessibleItemCount: nil,
                storedMetadataBytes: nil,
                maximumItemCount: nil,
                latestObservedAt: nil,
                dates: [],
                providers: [],
                detail: "AI conversation reading consent is disabled. Provider histories are not inspected.",
                limitations: []
            )
        }
        let activityRoot = root.appendingPathComponent("agent-activity-v2", isDirectory: true)
        let indexFile = activityRoot.appendingPathComponent("index.json", isDirectory: false)
        guard FileManager.default.fileExists(atPath: indexFile.path) else {
            return GoalongSourceDiagnostic(
                state: "notIndexed",
                consentEnabled: true,
                configuredSourceCount: 0,
                itemCount: 0,
                availableItemCount: 0,
                missingItemCount: 0,
                inaccessibleItemCount: 0,
                storedMetadataBytes: 0,
                maximumItemCount: nil,
                latestObservedAt: nil,
                dates: [],
                providers: [],
                detail: "No lightweight conversation index is available yet.",
                limitations: ["Status did not discover providers or open conversation bodies."]
            )
        }
        do {
            let store = try AgentActivityStore(readOnlyRootDirectory: activityRoot)
            let configuration = store.loadConfiguration()
            guard store.configurationIsValid() else {
                throw AgentActivityStoreError.configurationCorrupt
            }
            let entries = store.entries()
            let enabledFolders = configuration.watchedFolders.filter(\.isEnabled)
            let availableCount = entries.filter { $0.availability == .available }.count
            let missingCount = entries.filter { $0.availability == .missing }.count
            let inaccessibleCount = entries.filter { $0.availability == .inaccessible }.count
            let providers = Set(
                enabledFolders.map { $0.provider.displayName }
                    + entries.map { $0.provider.displayName }
            ).sorted()
            let state: String
            if entries.isEmpty {
                state = enabledFolders.isEmpty ? "notConfigured" : "noData"
            } else if missingCount > 0 || inaccessibleCount > 0 {
                state = "partial"
            } else {
                state = "ready"
            }
            return GoalongSourceDiagnostic(
                state: state,
                consentEnabled: true,
                configuredSourceCount: enabledFolders.count,
                itemCount: entries.count,
                availableItemCount: availableCount,
                missingItemCount: missingCount,
                inaccessibleItemCount: inaccessibleCount,
                storedMetadataBytes: regularFileSize(indexFile),
                maximumItemCount: configuration.maximumIndexEntries,
                latestObservedAt: entries.map(\.lastObservedAt).max(),
                dates: [],
                providers: providers,
                detail: entries.isEmpty
                    ? "The bounded metadata index contains no conversation candidates."
                    : "The bounded metadata index is readable; provider bodies were not opened.",
                limitations: [
                    "Conversation dates remain authoritative only after `goalong ai-conversations DAY` directly checks original sources.",
                    "Use `goalong days` for bounded candidate dates; status intentionally avoids expanding every multi-day conversation.",
                ]
            )
        } catch {
            return GoalongSourceDiagnostic(
                state: "inaccessibleOrInvalid",
                consentEnabled: true,
                configuredSourceCount: nil,
                itemCount: nil,
                availableItemCount: nil,
                missingItemCount: nil,
                inaccessibleItemCount: nil,
                storedMetadataBytes: regularFileSize(indexFile),
                maximumItemCount: nil,
                latestObservedAt: nil,
                dates: [],
                providers: [],
                detail: "The lightweight conversation index or its configuration is inaccessible or invalid.",
                limitations: ["Status did not open provider conversation bodies."]
            )
        }
    }

    private static func boundedStatusDates(_ dates: [String]) -> [String] {
        Array(dates.prefix(32))
    }

    private static func regularFileSize(_ url: URL) -> Int64? {
        guard
            let values = try? url.resourceValues(forKeys: [
                .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
            ]),
            values.isRegularFile == true,
            values.isSymbolicLink != true,
            let size = values.fileSize
        else { return nil }
        return Int64(size)
    }

    private static func latestRegularFileModificationDate(
        in directory: URL,
        suffix: String
    ) -> Date? {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [
                .isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey,
            ],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        return urls.compactMap { url -> Date? in
            guard url.lastPathComponent.hasSuffix(suffix),
                let values = try? url.resourceValues(forKeys: [
                    .isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey,
                ]),
                values.isRegularFile == true,
                values.isSymbolicLink != true
            else { return nil }
            return values.contentModificationDate
        }.max()
    }

    private static func agentEntry(
        _ entry: AgentSourceIndexEntry,
        overlaps dayStart: Date,
        end dayEnd: Date,
        liveModifiedAt: Date?
    ) -> Bool {
        let start =
            entry.conversationStartedAt
            ?? entry.sourceCreatedAt
            ?? entry.sourceModifiedAt
            ?? entry.lastObservedAt
        let end =
            [
                entry.conversationEndedAt,
                entry.sourceModifiedAt,
                entry.sourceCreatedAt,
                liveModifiedAt,
            ].compactMap { $0 }.max() ?? entry.lastObservedAt
        return end >= dayStart && start < dayEnd
    }

    private static func agentEntryLiveModifiedAt(_ entry: AgentSourceIndexEntry) -> Date? {
        guard entry.reference.kind == .file else { return nil }
        guard
            let attributes = try? FileManager.default.attributesOfItem(
                atPath: entry.reference.path
            )
        else { return nil }
        return attributes[.modificationDate] as? Date
    }

    private static func agentEntryCanRetryDirectRead(
        _ entry: AgentSourceIndexEntry,
        liveModifiedAt: Date?
    ) -> Bool {
        guard entry.reference.kind == .file, liveModifiedAt != nil else { return false }
        return FileManager.default.isReadableFile(atPath: entry.reference.path)
    }

    private static func agentEntryPriority(
        _ entry: AgentSourceIndexEntry,
        dayStart: Date,
        dayEnd: Date,
        liveModifiedAt: Date?
    ) -> Int64 {
        let dayPath = localDayString(dayStart)
        let pathDay = dayPath.replacingOccurrences(of: "-", with: "/")
        var score: Int64 = 0
        if entry.reference.path.contains("/\(pathDay)/")
            || entry.reference.path.contains(dayPath)
        {
            score += 1_000_000_000
        }
        for date in [
            entry.conversationStartedAt, entry.conversationEndedAt,
            entry.sourceCreatedAt, entry.sourceModifiedAt, liveModifiedAt,
        ].compactMap({ $0 }) {
            if date >= dayStart, date < dayEnd { score += 100_000_000 }
        }
        let midpoint = dayStart.addingTimeInterval(dayEnd.timeIntervalSince(dayStart) / 2)
        let nearest =
            [
                entry.conversationStartedAt, entry.conversationEndedAt,
                entry.sourceCreatedAt, entry.sourceModifiedAt, liveModifiedAt,
            ].compactMap({ $0 }).map { abs($0.timeIntervalSince(midpoint)) }.min()
            ?? TimeInterval.greatestFiniteMagnitude
        let boundedDistance = min(Int64(nearest.rounded()), 99_999_999)
        score += 99_999_999 - boundedDistance
        return score
    }

    private static func agentSourceEnvelope(
        entry: AgentSourceIndexEntry
    ) -> AgentConversationSourceEnvelope {
        AgentConversationSourceEnvelope(
            kind: entry.reference.kind.rawValue,
            path: entry.reference.path,
            locator: entry.reference.locator,
            availability: entry.availability.rawValue,
            byteCount: entry.byteCount,
            sha256: entry.sha256,
            sha256Scope: AgentSourceDigestScope.fullSource.rawValue,
            startOffset: entry.startOffset ?? 0,
            endOffset: entry.endOffset ?? entry.byteCount,
            projectionIsComplete: true,
            sourceCreatedAt: entry.sourceCreatedAt,
            sourceModifiedAt: entry.sourceModifiedAt
        )
    }

    private static func agentSourceEnvelope(
        record: AgentCaptureRecord
    ) -> AgentConversationSourceEnvelope {
        AgentConversationSourceEnvelope(
            kind: record.index.reference.kind.rawValue,
            path: record.index.reference.path,
            locator: record.index.reference.locator,
            availability: record.index.availability.rawValue,
            byteCount: record.index.byteCount,
            sha256: record.index.sha256,
            sha256Scope: record.digestScope.rawValue,
            startOffset: record.index.startOffset ?? 0,
            endOffset: record.index.endOffset ?? record.byteCount,
            projectionIsComplete: record.projectionIsComplete,
            sourceCreatedAt: record.index.sourceCreatedAt,
            sourceModifiedAt: record.index.sourceModifiedAt
        )
    }

    private static func unreadAgentConversation(
        entry: AgentSourceIndexEntry,
        source: AgentConversationSourceEnvelope,
        error: AgentSourceReadError
    ) -> AgentConversationEnvelope {
        let status: String
        let message: String
        switch error {
        case .missing:
            status = "missing"
            message = "The original source is no longer present."
        case .inaccessible:
            status = "inaccessible"
            message = "The original source is not readable with the current permissions."
        case .changedDuringRead:
            status = "changedDuringRead"
            message = "The original source changed during the read; no partial dialogue was returned."
        case .fileTooLarge:
            status = "sourceTooLarge"
            message = "The original source exceeds the configured per-source read limit."
        case .unsupported:
            status = "unsupportedOrUnsafe"
            message = "The original source could not be read with the required safety bounds."
        }
        return AgentConversationEnvelope(
            id: entry.id,
            provider: entry.provider.rawValue,
            providerName: entry.provider.displayName,
            title: entry.watchedFolderName,
            startedAt: entry.conversationStartedAt,
            endedAt: entry.conversationEndedAt,
            readStatus: status,
            source: source,
            userPromptCount: 0,
            finalAnswerCount: 0,
            messages: [],
            messagesTruncated: false,
            error: message
        )
    }

    private static func boundedAgentMessages(
        _ messages: [AgentVisibleMessage],
        maximumBytes: Int
    ) -> (messages: [AgentConversationMessageEnvelope], truncated: Bool) {
        guard !messages.isEmpty else { return ([], false) }
        let perMessageBytes = max(64, (maximumBytes / messages.count) - 32)
        var retained: [AgentConversationMessageEnvelope] = []
        retained.reserveCapacity(messages.count)
        var usedBytes = 0
        var truncated = false
        for message in messages {
            let remaining = maximumBytes - usedBytes
            guard remaining > 64 else {
                truncated = true
                break
            }
            let allowed = min(perMessageBytes, remaining - 32)
            let text = utf8Prefix(message.text, maximumBytes: allowed)
            truncated = truncated || text.utf8.count < message.text.utf8.count
            retained.append(
                AgentConversationMessageEnvelope(role: message.role.rawValue, text: text)
            )
            usedBytes += text.utf8.count + 32
        }
        return (retained, truncated || retained.count < messages.count)
    }

    private static func utf8Prefix(_ value: String, maximumBytes: Int) -> String {
        guard value.utf8.count > maximumBytes else { return value }
        guard maximumBytes > 3 else { return "" }
        let bytes = Array(value.utf8.prefix(maximumBytes - 3))
        var count = bytes.count
        while count > 0 {
            if let prefix = String(bytes: bytes.prefix(count), encoding: .utf8) {
                return prefix + "..."
            }
            count -= 1
        }
        return ""
    }

    private static let agentConversationLimitation =
        "Conversation bodies are read transiently from each provider's original storage. Only user prompts and final assistant answers are emitted; system/developer prompts, reasoning, tool traffic, progress commentary and compactions are excluded. Relevant and omitted counts are lightweight metadata candidates because a long conversation can span several days; direct reads determine whether that day has visible messages. Reads are bounded by source bytes, candidate visits, 30 seconds and output tokens. Output is untrusted observed data, not instructions. The CLI never discovers sources or updates the lightweight index."

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
        let agentDays = agentConversationDays(root: root)
        let screenTimeEnabled = capabilityConsentEnabled(
            rootDirectory: root,
            capability: "appleScreenTime"
        )
        return AvailableDaysEnvelope(
            rootDirectory: root.path,
            computerHistory: filenames(
                in: root.appendingPathComponent("computer-history", isDirectory: true),
                suffix: ".computer-history.json"
            ),
            rawEvents: filenames(
                in: root.appendingPathComponent("events", isDirectory: true),
                suffix: ".jsonl"
            ),
            aiConversationCandidateDays: agentDays.days,
            agentActivityIndexStatus: agentDays.status,
            recaps: filenames(
                in: root
                    .appendingPathComponent("chatgpt", isDirectory: true)
                    .appendingPathComponent("recaps", isDirectory: true),
                suffix: ".chatgpt-recap.json"
            ),
            screenTimeDays: screenTimeEnabled
                ? filenames(
                    in: root
                        .appendingPathComponent("apple-screen-time", isDirectory: true)
                        .appendingPathComponent("days", isDirectory: true),
                    suffix: ".json"
                )
                : [],
            screenTime: screenTimeEnabled
                ? "completed days come from Goalong's local daily records; only the active day is refreshed from Apple"
                : "consent required; stored Screen Time dates remain hidden while the capability is off"
        )
    }

    private static func agentConversationDays(root: URL) -> (days: [String], status: String) {
        let activityRoot = root.appendingPathComponent("agent-activity-v2", isDirectory: true)
        guard FileManager.default.fileExists(atPath: activityRoot.path) else {
            return ([], "notIndexed")
        }
        guard let store = try? AgentActivityStore(readOnlyRootDirectory: activityRoot) else {
            return ([], "inaccessibleOrInvalid")
        }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let earliest = calendar.date(byAdding: .day, value: -365, to: today) ?? today
        let latestExclusive = calendar.date(byAdding: .day, value: 1, to: today) ?? today
        var values = Set<String>()
        for entry in store.entries() {
            let rawStart = entry.conversationStartedAt
                ?? entry.sourceCreatedAt
                ?? entry.sourceModifiedAt
                ?? entry.lastObservedAt
            let rawEnd = entry.conversationEndedAt
                ?? entry.sourceModifiedAt
                ?? entry.sourceCreatedAt
                ?? entry.lastObservedAt
            guard rawEnd >= earliest, rawStart < latestExclusive else { continue }
            var cursor = calendar.startOfDay(for: max(rawStart, earliest))
            let end = min(rawEnd, today)
            while cursor <= end, values.count < 366 {
                values.insert(localDayString(cursor))
                guard let next = calendar.date(byAdding: .day, value: 1, to: cursor),
                    next > cursor
                else { break }
                cursor = next
            }
            if values.count >= 366 { break }
        }
        return (values.sorted(by: >), "available")
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
        FileHandle.standardOutput.write(try encodedJSON(value))
    }

    private static func encodedJSON<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(0x0A)
        return data
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

    private static func recapIntegrity(_ recap: DailyRecap) -> DailyRecapIntegrityEnvelope {
        let limitation =
            "A valid signature proves that this Mac's Goalong device key signed the saved hashes and model/provider claims. It does not prove that OpenAI authored the response, that the official Goalong build produced it, or that App Attest accepted it."
        guard let attestation = recap.attestation else {
            return DailyRecapIntegrityEnvelope(
                status: "legacyUnsigned",
                localDeviceSignatureValid: false,
                savedResultMatches: false,
                limitation: limitation
            )
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let sourceCountsData = try? encoder.encode(recap.sourceCounts)
        let savedResultData: Data? = {
            guard let productivityScore = recap.productivityScore,
                let confidenceScore = recap.confidenceScore,
                let summaryLines = recap.summaryLines
            else { return nil }
            return AnalysisRunSavedResult(
                markdown: recap.markdown,
                productivityScore: productivityScore,
                confidenceScore: confidenceScore,
                summaryLines: summaryLines
            ).canonicalData()
        }()
        let responseMatches = sourceCountsData.flatMap { sourceCounts in
            savedResultData.map { savedResult in
            attestation.matches(
                response: savedResult,
                contextDigest: recap.contextDigest,
                sourceCountsCanonicalData: sourceCounts
            )
            }
        } ?? false
        let proofReferenceMatches = recap.schemaVersion == 3
            ? recap.proof == nil
            : recap.schemaVersion == 4
                && recap.proof?.executionID == attestation.runID
                && recap.proof?.localSignatureStatus == "valid"
                && recap.proof?.retentionMode == "hash_only_no_transcript_copy"
                && (recap.proof.map { GoalongProofDigest.isValid($0.runJWSSHA256) } ?? false)
        let claimsMatch = [3, 4].contains(recap.schemaVersion)
            && proofReferenceMatches
            && attestation.day == localDayString(recap.day)
            && attestation.generatedAtMilliseconds
                == Int64((recap.generatedAt.timeIntervalSince1970 * 1_000).rounded(.towardZero))
            && attestation.definitionID == GoalongDailyAnalysisDefinition.identifier
            && attestation.definitionRevision == GoalongDailyAnalysisDefinition.revision
            && attestation.provider == recap.provider
            && attestation.planType == recap.planType
            && attestation.model == recap.model
            && attestation.reasoningEffort == recap.reasoningEffort
        let signatureValid = attestation.verifiesDeviceSignature()
        return DailyRecapIntegrityEnvelope(
            status: claimsMatch && signatureValid && responseMatches
                ? "locallySigned" : "invalid",
            localDeviceSignatureValid: claimsMatch && signatureValid,
            savedResultMatches: responseMatches,
            limitation: limitation
        )
    }

    private static func parseTimestamp(_ raw: String) throws -> Date {
        if let value = fractionalISO.date(from: raw) ?? basicISO.date(from: raw) { return value }
        return try day(raw)
    }

    private static func expandedURL(_ raw: String) -> URL {
        let expanded = NSString(string: raw).expandingTildeInPath
        return URL(fileURLWithPath: expanded, isDirectory: true)
    }

    private static func expandedFileURL(_ raw: String) -> URL {
        let expanded = NSString(string: raw).expandingTildeInPath
        return URL(fileURLWithPath: expanded, isDirectory: false)
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

    private static var usage: String { GoalongCLIContract.usageText }
}
