import Foundation

extension ActivityAnalysisEngine {
    static func makeSites(
        from points: [MinutePoint],
        blocks: [ActivityFocusBlock],
        options: ActivityAnalysisOptions
    ) -> [ActivitySiteSummary] {
        struct PageCounter {
            var title: String
            var URL: String?
            var seconds = 0
            var firstSeen: Date
            var lastSeen: Date
        }
        struct SiteCounter {
            var seconds = 0
            var pages: [String: PageCounter] = [:]
        }

        var counters: [String: SiteCounter] = [:]
        for point in points {
            let webContexts = point.observedContexts.filter { $0.host != nil }
            let contextsByHost = Dictionary(grouping: webContexts, by: { $0.host! })
            let hosts = contextsByHost.keys.sorted()
            guard !hosts.isEmpty else { continue }

            let baseHostSeconds = 60 / hosts.count
            var hostRemainder = 60 % hosts.count
            for host in hosts {
                let hostSeconds = baseHostSeconds + (hostRemainder > 0 ? 1 : 0)
                if hostRemainder > 0 { hostRemainder -= 1 }
                var site = counters[host] ?? SiteCounter()
                site.seconds += hostSeconds

                var uniquePages: [String: ObservedContext] = [:]
                for context in contextsByHost[host] ?? [] {
                    let pageTitle = context.pageTitle ?? context.URL ?? host
                    let pageKey = context.URL ?? pageTitle.lowercased()
                    uniquePages[pageKey] = context
                }
                let pageKeys = uniquePages.keys.sorted()
                let basePageSeconds = pageKeys.isEmpty ? 0 : hostSeconds / pageKeys.count
                var pageRemainder = pageKeys.isEmpty ? 0 : hostSeconds % pageKeys.count
                for pageKey in pageKeys {
                    guard let context = uniquePages[pageKey] else { continue }
                    let seconds = basePageSeconds + (pageRemainder > 0 ? 1 : 0)
                    if pageRemainder > 0 { pageRemainder -= 1 }
                    let pageTitle = context.pageTitle ?? context.URL ?? host
                    var page = site.pages[pageKey] ?? PageCounter(
                        title: pageTitle,
                        URL: context.URL,
                        firstSeen: point.minuteStart,
                        lastSeen: point.minuteStart
                    )
                    page.seconds += seconds
                    page.firstSeen = min(page.firstSeen, point.minuteStart)
                    page.lastSeen = max(page.lastSeen, point.minuteStart)
                    site.pages[pageKey] = page
                }
                counters[host] = site
            }
        }

        return counters.map { host, counter in
            let pages = counter.pages.values
                .sorted {
                    if $0.seconds == $1.seconds { return $0.firstSeen < $1.firstSeen }
                    return $0.seconds > $1.seconds
                }
                .prefix(options.maximumPagesPerSite)
                .map {
                    ActivityPageSummary(
                        title: $0.title,
                        URL: $0.URL,
                        activeSeconds: $0.seconds,
                        firstSeen: $0.firstSeen,
                        lastSeen: $0.lastSeen
                    )
                }
            let visits = blocks.filter { $0.hosts.contains(host) }.count
            return ActivitySiteSummary(
                host: host,
                activeSeconds: counter.seconds,
                visitCount: visits,
                pageCount: counter.pages.count,
                pages: pages
            )
        }
        .sorted {
            if $0.activeSeconds == $1.activeSeconds { return $0.host < $1.host }
            return $0.activeSeconds > $1.activeSeconds
        }
        .prefix(options.maximumSites)
        .map { $0 }
    }

    static func makeApplications(
        from points: [MinutePoint],
        blocks: [ActivityFocusBlock]
    ) -> [ActivityApplicationSummary] {
        struct Counter {
            var name: String
            var bundleIdentifier: String?
            var seconds = 0
        }
        var counters: [String: Counter] = [:]
        for point in points {
            let key = point.bundleIdentifier ?? "name:\(point.appName)"
            var counter = counters[key] ?? Counter(name: point.appName, bundleIdentifier: point.bundleIdentifier)
            counter.seconds += 60
            counters[key] = counter
        }
        return counters.map { _, counter in
            ActivityApplicationSummary(
                name: counter.name,
                bundleIdentifier: counter.bundleIdentifier,
                activeSeconds: counter.seconds,
                focusBlockCount: blocks.filter { $0.applications.contains(counter.name) }.count
            )
        }
        .sorted {
            if $0.activeSeconds == $1.activeSeconds { return $0.name < $1.name }
            return $0.activeSeconds > $1.activeSeconds
        }
    }

    static func makeRequests(
        from events: [HistoryEvent],
        options: ActivityAnalysisOptions
    ) -> [ActivityRequestSummary] {
        struct Builder {
            var text: String
            var firstSeen: Date
            var lastSeen: Date
            var occurrences: Int
            var application: String?
            var host: String?
            var confidence: Double
        }
        var builders: [String: Builder] = [:]
        for event in events {
            guard let semantic = semanticText(from: event) else { continue }
            for candidate in requestCandidates(in: semantic, event: event) {
                let normalizedKey = normalizedComparable(candidate)
                guard !normalizedKey.isEmpty else { continue }
                let key = builders.keys.first(where: {
                    tokenSimilarity($0, normalizedKey) >= 0.82
                }) ?? normalizedKey
                let AIContext = isAIContext(event)
                var builder = builders[key] ?? Builder(
                    text: candidate,
                    firstSeen: event.timestamp,
                    lastSeen: event.timestamp,
                    occurrences: 0,
                    application: event.app?.name,
                    host: normalizedHost(event.url?.host),
                    confidence: AIContext ? 0.88 : 0.62
                )
                builder.occurrences += 1
                builder.firstSeen = min(builder.firstSeen, event.timestamp)
                builder.lastSeen = max(builder.lastSeen, event.timestamp)
                builder.confidence = max(builder.confidence, AIContext ? 0.88 : 0.62)
                builders[key] = builder
            }
        }
        return builders.map { key, value in
            ActivityRequestSummary(
                id: stableIdentifier(key),
                text: value.text,
                firstSeen: value.firstSeen,
                lastSeen: value.lastSeen,
                occurrences: value.occurrences,
                application: value.application,
                host: value.host,
                confidence: value.confidence
            )
        }
        .sorted {
            if $0.firstSeen == $1.firstSeen { return $0.occurrences > $1.occurrences }
            return $0.firstSeen < $1.firstSeen
        }
        .prefix(options.maximumRequests)
        .map { $0 }
    }

    static func makeHighlights(
        from events: [HistoryEvent],
        requests: [ActivityRequestSummary],
        options: ActivityAnalysisOptions
    ) -> [ActivityContextHighlight] {
        let requestKeys = Set(requests.map { normalizedComparable($0.text) })
        var seen = Set<String>()
        var output: [ActivityContextHighlight] = []
        for event in events {
            guard let semantic = semanticText(from: event) else { continue }
            for line in splitSemanticLines(semantic) {
                let cleaned = bounded(line, maximum: 300)
                let key = normalizedComparable(cleaned)
                guard cleaned.count >= 24, !key.isEmpty, !requestKeys.contains(key), seen.insert(key).inserted else {
                    continue
                }
                output.append(
                    ActivityContextHighlight(
                        id: stableIdentifier("\(event.timestamp.timeIntervalSince1970)|\(key)"),
                        text: cleaned,
                        firstSeen: event.timestamp,
                        application: event.app?.name,
                        host: normalizedHost(event.url?.host)
                    )
                )
                if output.count >= options.maximumContextHighlights { return output }
            }
        }
        return output
    }

}
