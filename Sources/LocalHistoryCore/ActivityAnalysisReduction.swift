import Foundation

extension ActivityAnalysisEngine {
    static func representativeMinutes(from events: [HistoryEvent], calendar: Calendar) -> [MinutePoint] {
        var byMinute: [Int64: MinuteAccumulator] = [:]
        for event in events {
            guard event.suppressionReason == nil, event.app != nil, isUseful(event) else { continue }
            let key = minuteKey(event.timestamp)
            let score = representativeScore(event)
            var accumulator = byMinute[key] ?? MinuteAccumulator(
                representative: event,
                score: score,
                eventCount: 0,
                inputEventCount: 0,
                semanticTexts: [],
                observedContexts: []
            )
            accumulator.eventCount += 1
            if event.pointer != nil || event.keyboard != nil || event.scroll != nil {
                accumulator.inputEventCount += 1
            }
            if let semantic = semanticText(from: event) {
                accumulator.semanticTexts.append(semantic)
            }
            if let app = event.app {
                let context = ObservedContext(
                    appName: app.name,
                    host: normalizedHost(event.url?.host),
                    pageTitle: cleanPageTitle(event.window?.title, appName: app.name),
                    URL: event.url?.value
                )
                if !accumulator.observedContexts.contains(where: { $0.identity == context.identity }) {
                    accumulator.observedContexts.append(context)
                }
            }
            if score >= accumulator.score {
                accumulator.representative = event
                accumulator.score = score
            }
            byMinute[key] = accumulator
        }

        return byMinute.keys.sorted().compactMap { key in
            guard let value = byMinute[key], let app = value.representative.app else { return nil }
            let semantic = distinct(value.semanticTexts, maximum: 3, maximumLength: 800).joined(separator: "\n")
            let cleanedSemantic = semantic.isEmpty ? nil : semantic
            return MinutePoint(
                minuteStart: Date(timeIntervalSince1970: TimeInterval(key * 60)),
                appName: app.name,
                bundleIdentifier: app.bundleIdentifier,
                host: normalizedHost(value.representative.url?.host),
                pageTitle: cleanPageTitle(value.representative.window?.title, appName: app.name),
                URL: value.representative.url?.value,
                observedContexts: value.observedContexts,
                category: value.representative.classification?.category,
                isWork: value.representative.classification?.isWork,
                eventCount: value.eventCount,
                inputEventCount: value.inputEventCount,
                semanticText: cleanedSemantic,
                requestSnippets: cleanedSemantic.map { requestCandidates(in: $0, event: value.representative) } ?? []
            )
        }
    }

    static func buildBlocks(from points: [MinutePoint]) -> [BlockBuilder] {
        var result: [BlockBuilder] = []
        for point in points {
            guard var last = result.popLast() else {
                result.append(BlockBuilder(points: [point]))
                continue
            }
            if shouldMerge(last, point) {
                last.append(point)
                result.append(last)
            } else {
                result.append(last)
                result.append(BlockBuilder(points: [point]))
            }
        }
        return result
    }

    static func shouldMerge(_ block: BlockBuilder, _ point: MinutePoint) -> Bool {
        let previous = block.last
        let minuteGap = Int(point.minuteStart.timeIntervalSince(previous.minuteStart) / 60)
        guard minuteGap >= 0, minuteGap <= 4 else { return false }

        if let lhs = previous.host, let rhs = point.host, lhs == rhs { return true }
        if previous.bundleIdentifier == point.bundleIdentifier || previous.appName == point.appName {
            if previous.host == nil && point.host == nil { return true }
            if tokenSimilarity(previous.pageTitle, point.pageTitle) >= 0.22 { return true }
            if minuteGap <= 1 && (previous.pageTitle == nil || point.pageTitle == nil) { return true }
        }
        if previous.category == point.category,
           previous.category != nil,
           minuteGap <= 1,
           workflowCategory(previous.category)
        {
            return true
        }
        if block.points.count <= 1 && minuteGap <= 1 { return true }
        return false
    }

    static func bridgeShortBlocks(_ blocks: [ActivityFocusBlock]) -> [ActivityFocusBlock] {
        guard blocks.count > 1 else { return blocks }
        var output: [ActivityFocusBlock] = []
        var index = 0
        while index < blocks.count {
            let current = blocks[index]
            if current.activeSeconds <= 60, let previous = output.last {
                let gap = current.start.timeIntervalSince(previous.end)
                let related = !Set(current.hosts).isDisjoint(with: Set(previous.hosts))
                    || !Set(current.applications).isDisjoint(with: Set(previous.applications))
                    || (current.category != nil && current.category == previous.category)
                if gap <= 60, related {
                    output.removeLast()
                    output.append(mergeBlocks(previous, current))
                    index += 1
                    continue
                }
            }
            output.append(current)
            index += 1
        }
        return output
    }

    static func mergeBlocks(_ lhs: ActivityFocusBlock, _ rhs: ActivityFocusBlock) -> ActivityFocusBlock {
        let requests = distinct(lhs.requestSnippets + rhs.requestSnippets, maximum: 4, maximumLength: 240)
        let contexts = distinct(lhs.contextSnippets + rhs.contextSnippets, maximum: 5, maximumLength: 240)
        let applications = distinct(lhs.applications + rhs.applications, maximum: 5, maximumLength: 120)
        let hosts = distinct(lhs.hosts + rhs.hosts, maximum: 5, maximumLength: 160)
        let titles = distinct(lhs.pageTitles + rhs.pageTitles, maximum: 6, maximumLength: 200)
        let URLs = distinct(lhs.URLs + rhs.URLs, maximum: 6, maximumLength: 512)
        let category = lhs.category ?? rhs.category
        let title = blockTitle(
            requests: requests,
            context: contexts,
            pageTitles: titles,
            hosts: hosts,
            applications: applications,
            category: category
        )
        return ActivityFocusBlock(
            id: stableIdentifier("\(lhs.start.timeIntervalSince1970)|\(title)"),
            start: lhs.start,
            end: max(lhs.end, rhs.end),
            activeSeconds: lhs.activeSeconds + rhs.activeSeconds,
            title: title,
            applications: applications,
            hosts: hosts,
            pageTitles: titles,
            URLs: URLs,
            category: category,
            isWork: lhs.isWork ?? rhs.isWork,
            eventCount: lhs.eventCount + rhs.eventCount,
            inputEventCount: lhs.inputEventCount + rhs.inputEventCount,
            contextSnippets: contexts,
            requestSnippets: requests
        )
    }

    static func selectFocusBlocks(
        _ blocks: [ActivityFocusBlock],
        maximum: Int
    ) -> [ActivityFocusBlock] {
        guard blocks.count > maximum else { return blocks }
        return blocks
            .sorted { left, right in
                let leftScore = left.activeSeconds
                    + (left.requestSnippets.isEmpty ? 0 : 600)
                    + (left.contextSnippets.isEmpty ? 0 : 180)
                let rightScore = right.activeSeconds
                    + (right.requestSnippets.isEmpty ? 0 : 600)
                    + (right.contextSnippets.isEmpty ? 0 : 180)
                if leftScore == rightScore { return left.start < right.start }
                return leftScore > rightScore
            }
            .prefix(maximum)
            .sorted { $0.start < $1.start }
    }

}
