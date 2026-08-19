import Foundation

public enum ActivityAnalysisEngine {
    public static func analyze(
        events: [HistoryEvent],
        day: Date,
        calendar: Calendar = .current,
        options: ActivityAnalysisOptions = .default,
        generatedAt: Date = Date()
    ) -> ActivityDayAnalysis {
        let dayStart = calendar.startOfDay(for: day)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)
            ?? dayStart.addingTimeInterval(86_400)
        let inDay = events
            .filter { $0.timestamp >= dayStart && $0.timestamp < dayEnd }
            .sorted { $0.timestamp < $1.timestamp }

        let privateMinuteKeys = Set(
            inDay.compactMap { event -> Int64? in
                guard event.suppressionReason != nil else { return nil }
                return minuteKey(event.timestamp)
            }
        )

        let semanticEvents = inDay.filter { $0.suppressionReason == nil && semanticText(from: $0) != nil }
        let points = representativeMinutes(from: inDay, calendar: calendar)
        let blockBuilders = buildBlocks(from: points)
        var blocks = blockBuilders.map { $0.finish() }
        blocks = bridgeShortBlocks(blocks)
        blocks = selectFocusBlocks(blocks, maximum: options.maximumFocusBlocks)

        let sites = makeSites(from: points, events: inDay, blocks: blocks, options: options)
        let applications = makeApplications(from: points, blocks: blocks)
        let requests = makeRequests(from: semanticEvents, options: options)
        let highlights = makeHighlights(from: semanticEvents, requests: requests, options: options)

        let activeSeconds = points.count * 60
        let workSeconds = points.filter { $0.isWork == true }.count * 60
        let integrityRows = inDay.compactMap(\.integrity)
        let coverage = ActivityAnalysisCoverage(
            sourceEventCount: inDay.count,
            representativeMinuteCount: points.count,
            privateMinuteCount: privateMinuteKeys.count,
            semanticSnapshotCount: semanticEvents.count,
            semanticContextEnabledInData: !semanticEvents.isEmpty,
            sourceFirstSequence: integrityRows.first?.sequence,
            sourceLastSequence: integrityRows.last?.sequence,
            sourceLastEventHash: integrityRows.last?.eventHash
        )
        let headline = makeHeadline(blocks: blocks, applications: applications, sites: sites)

        let base = ActivityDayAnalysis(
            dayStart: dayStart,
            dayEnd: dayEnd,
            generatedAt: generatedAt,
            headline: headline,
            activeSeconds: activeSeconds,
            workSeconds: workSeconds,
            focusBlocks: blocks,
            sites: sites,
            applications: applications,
            requests: requests,
            contextHighlights: highlights,
            coverage: coverage,
            agentMarkdown: "",
            estimatedAgentTokens: 0
        )
        let markdown = ActivityAgentDigestRenderer.render(base, tokenBudget: options.agentTokenBudget)
        return ActivityDayAnalysis(
            schemaVersion: base.schemaVersion,
            dayStart: base.dayStart,
            dayEnd: base.dayEnd,
            generatedAt: base.generatedAt,
            headline: base.headline,
            activeSeconds: base.activeSeconds,
            workSeconds: base.workSeconds,
            focusBlocks: base.focusBlocks,
            sites: base.sites,
            applications: base.applications,
            requests: base.requests,
            contextHighlights: base.contextHighlights,
            coverage: base.coverage,
            agentMarkdown: markdown,
            estimatedAgentTokens: estimatedTokens(markdown)
        )
    }

    public static func estimatedTokens(_ text: String) -> Int {
        max(1, Int(ceil(Double(text.utf8.count) / 4.0)))
    }

    struct ObservedContext {
        let appName: String
        let host: String?
        let pageTitle: String?
        let URL: String?

        var identity: String {
            [appName, host ?? "", URL ?? pageTitle ?? ""].joined(separator: "|")
        }
    }

    struct MinutePoint {
        let minuteStart: Date
        let appName: String
        let bundleIdentifier: String?
        let host: String?
        let pageTitle: String?
        let URL: String?
        let observedContexts: [ObservedContext]
        let category: String?
        let isWork: Bool?
        let eventCount: Int
        let inputEventCount: Int
        let semanticText: String?
        let requestSnippets: [String]
    }

    struct MinuteAccumulator {
        var representative: HistoryEvent
        var score: Int
        var eventCount: Int
        var inputEventCount: Int
        var semanticTexts: [String]
        var observedContexts: [ObservedContext]
    }

    struct BlockBuilder {
        var points: [MinutePoint]

        var last: MinutePoint { points[points.count - 1] }

        mutating func append(_ point: MinutePoint) {
            points.append(point)
        }

        func finish() -> ActivityFocusBlock {
            let appCounts = frequency(points.map(\.appName))
            let observedContexts = points.flatMap(\.observedContexts)
            let hostCounts = frequency(observedContexts.compactMap(\.host))
            let titleCounts = frequency(observedContexts.compactMap(\.pageTitle))
            let URLCounts = frequency(observedContexts.compactMap(\.URL))
            let categoryCounts = frequency(points.compactMap(\.category))
            let context = distinct(
                points.compactMap(\.semanticText).flatMap(splitSemanticLines),
                maximum: 5,
                maximumLength: 240
            )
            let requests = distinct(
                points.flatMap(\.requestSnippets),
                maximum: 4,
                maximumLength: 240
            )
            let applications = sortedKeys(appCounts, limit: 5)
            let hosts = sortedKeys(hostCounts, limit: 5)
            let titles = sortedKeys(titleCounts, limit: 6)
            let URLs = sortedKeys(URLCounts, limit: 6)
            let category = sortedKeys(categoryCounts, limit: 1).first
            let workVotes = points.compactMap(\.isWork)
            let isWork: Bool? = workVotes.isEmpty ? nil : workVotes.filter { $0 }.count * 2 >= workVotes.count
            let start = points.first?.minuteStart ?? Date()
            let end = (points.last?.minuteStart ?? start).addingTimeInterval(60)
            let title = blockTitle(
                requests: requests,
                context: context,
                pageTitles: titles,
                hosts: hosts,
                applications: applications,
                category: category
            )
            return ActivityFocusBlock(
                id: stableIdentifier("\(start.timeIntervalSince1970)|\(title)"),
                start: start,
                end: end,
                activeSeconds: points.count * 60,
                title: title,
                applications: applications,
                hosts: hosts,
                pageTitles: titles,
                URLs: URLs,
                category: category,
                isWork: isWork,
                eventCount: points.reduce(0) { $0 + $1.eventCount },
                inputEventCount: points.reduce(0) { $0 + $1.inputEventCount },
                contextSnippets: context,
                requestSnippets: requests
            )
        }
    }
}
