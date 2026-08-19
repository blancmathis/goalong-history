import Foundation

extension ActivityAnalysisEngine {
    struct WebInteractionSeed {
        let kind: ActivityWebInteractionKind
        let label: String
        let role: String?
        let count: Int
        let detail: String?
    }

    struct WebInteractionCounter {
        let id: String
        let kind: ActivityWebInteractionKind
        let label: String
        let role: String?
        let pageTitle: String?
        let URL: String?
        var count: Int
        var firstSeen: Date
        var lastSeen: Date
        var detail: String?

        mutating func add(_ seed: WebInteractionSeed, at date: Date) {
            count += max(1, seed.count)
            firstSeen = min(firstSeen, date)
            lastSeen = max(lastSeen, date)
            if let seedDetail = seed.detail {
                // For grouped clicks, keep the richest/latest detail. A later event can
                // reveal that the action was the second click in a double-click sequence,
                // while the first event only contained the pointer button and coordinates.
                if detail == nil || seedDetail.contains("click sequence") {
                    detail = seedDetail
                }
            }
        }

        func finish() -> ActivityWebInteractionSummary {
            ActivityWebInteractionSummary(
                id: id,
                kind: kind,
                label: label,
                role: role,
                pageTitle: pageTitle,
                URL: URL,
                count: count,
                firstSeen: firstSeen,
                lastSeen: lastSeen,
                detail: detail
            )
        }
    }

    struct RememberedContextCounter {
        let text: String
        var firstSeen: Date
        var lastSeen: Date

        mutating func observe(at date: Date) {
            firstSeen = min(firstSeen, date)
            lastSeen = max(lastSeen, date)
        }
    }

    static func makeSites(
        from points: [MinutePoint],
        events: [HistoryEvent],
        blocks: [ActivityFocusBlock],
        options: ActivityAnalysisOptions
    ) -> [ActivitySiteSummary] {
        struct PageCounter {
            var title: String
            var URL: String?
            var seconds = 0
            var firstSeen: Date
            var lastSeen: Date
            var eventCount = 0
            var clickCount = 0
            var typingBurstCount = 0
            var scrollBurstCount = 0
            var shortcutCount = 0
            var semanticSnapshotCount = 0
            var interactions: [String: WebInteractionCounter] = [:]
            var rememberedContext: [String: RememberedContextCounter] = [:]
        }

        struct SiteCounter {
            var seconds = 0
            var pages: [String: PageCounter] = [:]
            var sourceApplications = Set<String>()
        }

        var counters: [String: SiteCounter] = [:]

        // First allocate representative foreground minutes across every observed host and page.
        // Multiple sites seen within the same compressed minute split that minute rather than
        // being silently discarded in favor of the last browser event.
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
                    let pageKey = pageIdentity(URL: context.URL, title: pageTitle, host: host)
                    uniquePages[pageKey] = context
                    site.sourceApplications.insert(context.appName)
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

        // Enrich the minute-level time model with every web event. This is where click targets,
        // grouped typing/scroll activity and opt-in visible page memory are retained.
        for event in events where event.suppressionReason == nil {
            guard let rawHost = event.url?.host,
                let host = normalizedHost(rawHost),
                !host.isEmpty
            else { continue }

            let URLValue = event.url?.value
            let pageTitle = cleanPageTitle(event.window?.title, appName: event.app?.name ?? "")
                ?? URLValue
                ?? host
            let pageKey = pageIdentity(URL: URLValue, title: pageTitle, host: host)

            var site = counters[host] ?? SiteCounter()
            if let appName = event.app?.name, !appName.isEmpty {
                site.sourceApplications.insert(appName)
            }
            var page = site.pages[pageKey] ?? PageCounter(
                title: pageTitle,
                URL: URLValue,
                firstSeen: event.timestamp,
                lastSeen: event.timestamp
            )
            page.eventCount += 1
            page.firstSeen = min(page.firstSeen, event.timestamp)
            page.lastSeen = max(page.lastSeen, event.timestamp)
            if page.URL == nil { page.URL = URLValue }
            if isGenericTitle(page.title), !isGenericTitle(pageTitle) { page.title = pageTitle }

            if let semantic = semanticText(from: event) {
                page.semanticSnapshotCount += 1
                for line in splitSemanticLines(semantic) {
                    let text = bounded(line, maximum: 700)
                    let key = normalizedComparable(text)
                    guard text.count >= 12, !key.isEmpty else { continue }
                    var remembered = page.rememberedContext[key] ?? RememberedContextCounter(
                        text: text,
                        firstSeen: event.timestamp,
                        lastSeen: event.timestamp
                    )
                    remembered.observe(at: event.timestamp)
                    page.rememberedContext[key] = remembered
                }
            }

            if let seed = webInteractionSeed(for: event) {
                switch seed.kind {
                case .click: page.clickCount += max(1, seed.count)
                case .typing: page.typingBurstCount += 1
                case .scroll: page.scrollBurstCount += 1
                case .shortcut: page.shortcutCount += 1
                }

                let interactionKey = [
                    pageKey,
                    seed.kind.rawValue,
                    normalizedComparable(seed.label),
                    seed.role ?? "",
                ].joined(separator: "|")
                let interactionID = stableIdentifier(interactionKey)
                var counter = page.interactions[interactionKey] ?? WebInteractionCounter(
                    id: interactionID,
                    kind: seed.kind,
                    label: seed.label,
                    role: seed.role,
                    pageTitle: pageTitle,
                    URL: URLValue,
                    count: 0,
                    firstSeen: event.timestamp,
                    lastSeen: event.timestamp,
                    detail: seed.detail
                )
                counter.add(seed, at: event.timestamp)
                page.interactions[interactionKey] = counter
            }

            site.pages[pageKey] = page
            counters[host] = site
        }

        return counters.map { host, counter in
            let allPages = counter.pages.values.sorted {
                if $0.seconds == $1.seconds {
                    if $0.lastSeen == $1.lastSeen { return $0.title < $1.title }
                    return $0.lastSeen > $1.lastSeen
                }
                return $0.seconds > $1.seconds
            }

            let pageSummaries = allPages.prefix(options.maximumPagesPerSite).map { page in
                let allInteractions = page.interactions.values
                    .map { $0.finish() }
                    .sorted {
                        if $0.firstSeen == $1.firstSeen { return $0.label < $1.label }
                        return $0.firstSeen < $1.firstSeen
                    }
                let allContext = page.rememberedContext.values.sorted {
                    if $0.firstSeen == $1.firstSeen { return $0.text < $1.text }
                    return $0.firstSeen < $1.firstSeen
                }
                return ActivityPageSummary(
                    title: page.title,
                    URL: page.URL,
                    activeSeconds: page.seconds,
                    firstSeen: page.firstSeen,
                    lastSeen: page.lastSeen,
                    eventCount: page.eventCount,
                    clickCount: page.clickCount,
                    typingBurstCount: page.typingBurstCount,
                    scrollBurstCount: page.scrollBurstCount,
                    shortcutCount: page.shortcutCount,
                    semanticSnapshotCount: page.semanticSnapshotCount,
                    interactions: Array(allInteractions.prefix(options.maximumWebInteractionsPerPage)),
                    rememberedContext: allContext
                        .prefix(options.maximumRememberedContextPerPage)
                        .map(\.text),
                    interactionsTruncated: allInteractions.count > options.maximumWebInteractionsPerPage,
                    rememberedContextTruncated: allContext.count > options.maximumRememberedContextPerPage
                )
            }

            let allInteractions = allPages
                .flatMap { $0.interactions.values.map { $0.finish() } }
                .sorted {
                    if $0.firstSeen == $1.firstSeen { return $0.label < $1.label }
                    return $0.firstSeen < $1.firstSeen
                }

            var siteContextByKey: [String: RememberedContextCounter] = [:]
            for remembered in allPages.flatMap({ $0.rememberedContext.values }) {
                let key = normalizedComparable(remembered.text)
                guard !key.isEmpty else { continue }
                var existing = siteContextByKey[key] ?? remembered
                existing.observe(at: remembered.firstSeen)
                existing.observe(at: remembered.lastSeen)
                siteContextByKey[key] = existing
            }
            let allSiteContext = siteContextByKey.values.sorted {
                if $0.firstSeen == $1.firstSeen { return $0.text < $1.text }
                return $0.firstSeen < $1.firstSeen
            }

            let visits = blocks.filter { $0.hosts.contains(host) }.count
            return ActivitySiteSummary(
                host: host,
                activeSeconds: counter.seconds,
                visitCount: visits,
                pageCount: allPages.count,
                pages: pageSummaries,
                sourceApplications: counter.sourceApplications.sorted {
                    $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
                },
                clickCount: allPages.reduce(0) { $0 + $1.clickCount },
                typingBurstCount: allPages.reduce(0) { $0 + $1.typingBurstCount },
                scrollBurstCount: allPages.reduce(0) { $0 + $1.scrollBurstCount },
                shortcutCount: allPages.reduce(0) { $0 + $1.shortcutCount },
                semanticSnapshotCount: allPages.reduce(0) { $0 + $1.semanticSnapshotCount },
                interactions: Array(allInteractions.prefix(options.maximumWebInteractionsPerSite)),
                rememberedContext: allSiteContext
                    .prefix(options.maximumRememberedContextPerSite)
                    .map(\.text),
                pagesTruncated: allPages.count > options.maximumPagesPerSite,
                interactionsTruncated: allInteractions.count > options.maximumWebInteractionsPerSite,
                rememberedContextTruncated: allSiteContext.count > options.maximumRememberedContextPerSite
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

    static func webInteractionSeed(for event: HistoryEvent) -> WebInteractionSeed? {
        let target = webTargetLabel(event.element)
        let role = event.element?.role ?? event.element?.subrole

        switch event.kind {
        case .mouseClick:
            guard let pointer = event.pointer else { return nil }
            let fallback = "Unlabelled \(pointer.button) click at \(Int(pointer.x.rounded())), \(Int(pointer.y.rounded()))"
            let label = target ?? fallback
            return WebInteractionSeed(
                kind: .click,
                label: bounded(label, maximum: 220),
                role: role,
                count: 1,
                detail: [
                    "\(pointer.button) button",
                    "x \(Int(pointer.x.rounded()))",
                    "y \(Int(pointer.y.rounded()))",
                    pointer.clickCount > 1 ? "click sequence \(pointer.clickCount)" : nil,
                ].compactMap { $0 }.joined(separator: " · ")
            )

        case .typingBurst:
            let keystrokes = event.metadata?["keystroke_count"].flatMap(Int.init)
            let duration = event.metadata?["duration_ms"].flatMap(Int.init)
            let label = target.map { "Typed in \($0)" } ?? "Typed on page"
            let parts: [String?] = [
                keystrokes.map { "\($0) key events" },
                duration.map { "\($0) ms" },
                "content not decoded",
            ]
            return WebInteractionSeed(
                kind: .typing,
                label: bounded(label, maximum: 220),
                role: role,
                count: 1,
                detail: parts.compactMap { $0 }.joined(separator: " · ")
            )

        case .scrollBurst:
            guard let scroll = event.scroll else { return nil }
            let direction: String
            if abs(scroll.deltaY) >= abs(scroll.deltaX) {
                direction = scroll.deltaY < 0 ? "down" : "up"
            } else {
                direction = scroll.deltaX < 0 ? "right" : "left"
            }
            let label = target.map { "Scrolled \(direction) in \($0)" } ?? "Scrolled \(direction)"
            return WebInteractionSeed(
                kind: .scroll,
                label: bounded(label, maximum: 220),
                role: role,
                count: 1,
                detail: "\(scroll.eventCount) grouped scroll events"
            )

        case .keyboardShortcut:
            guard let keyboard = event.keyboard else { return nil }
            let keys = (keyboard.modifiers + [keyboard.key].compactMap { $0 }).joined(separator: "+")
            let label = keys.isEmpty ? "Keyboard shortcut" : "Shortcut \(keys)"
            return WebInteractionSeed(
                kind: .shortcut,
                label: label,
                role: role,
                count: 1,
                detail: target.map { "Target: \($0)" }
            )

        default:
            return nil
        }
    }

    static func webTargetLabel(_ element: ElementSnapshot?) -> String? {
        guard let element else { return nil }
        let candidates = [element.title, element.label, element.identifier]
            .compactMap { value in
                value?.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
        if let candidate = candidates.first { return candidate }

        let rawRole = element.role ?? element.subrole
        guard let rawRole, !rawRole.isEmpty else { return nil }
        let cleaned = rawRole
            .replacingOccurrences(of: "AX", with: "")
            .replacingOccurrences(of: "_", with: " ")
        return cleaned.isEmpty ? nil : cleaned
    }

    static func pageIdentity(URL: String?, title: String, host: String) -> String {
        if let URL, !URL.isEmpty { return URL }
        let normalizedTitle = normalizedComparable(title)
        return normalizedTitle.isEmpty ? host : "\(host)|\(normalizedTitle)"
    }
}
