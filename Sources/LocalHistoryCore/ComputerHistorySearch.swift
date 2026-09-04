import Foundation

package struct ComputerHistorySourceSearchLimits: Equatable {
    package var maximumEventBytes: Int64
    package var maximumSemanticBytes: Int64
    package var maximumElapsedSeconds: TimeInterval

    package static let production = ComputerHistorySourceSearchLimits(
        maximumEventBytes: 384 * 1_024 * 1_024,
        maximumSemanticBytes: 128 * 1_024 * 1_024,
        maximumElapsedSeconds: 45
    )

    package init(
        maximumEventBytes: Int64,
        maximumSemanticBytes: Int64,
        maximumElapsedSeconds: TimeInterval
    ) {
        self.maximumEventBytes = maximumEventBytes
        self.maximumSemanticBytes = maximumSemanticBytes
        self.maximumElapsedSeconds = maximumElapsedSeconds
    }

    package var validated: ComputerHistorySourceSearchLimits {
        ComputerHistorySourceSearchLimits(
            maximumEventBytes: min(
                max(0, maximumEventBytes),
                Self.production.maximumEventBytes
            ),
            maximumSemanticBytes: min(
                max(0, maximumSemanticBytes),
                Self.production.maximumSemanticBytes
            ),
            maximumElapsedSeconds: min(
                max(0, maximumElapsedSeconds),
                Self.production.maximumElapsedSeconds
            )
        )
    }
}

/// One shared budget for a CLI `ask` reconstruction and its optional raw-source
/// fallback. Projection bytes count the compact encoded day memories retained
/// for the answer, never journal contents or a persisted cache.
package struct ComputerHistoryAskBudget: Equatable {
    package static let productionMaximumProjectionBytes: Int64 = 128 * 1_024 * 1_024
    package static let productionMaximumElapsedSeconds: TimeInterval = 45

    package let maximumProjectionBytes: Int64
    package let deadlineUptime: TimeInterval
    package private(set) var retainedProjectionBytes: Int64 = 0

    package init(
        maximumProjectionBytes: Int64 = Self.productionMaximumProjectionBytes,
        maximumElapsedSeconds: TimeInterval = Self.productionMaximumElapsedSeconds,
        startedAtUptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        self.maximumProjectionBytes = min(
            max(0, maximumProjectionBytes),
            Self.productionMaximumProjectionBytes
        )
        deadlineUptime =
            startedAtUptime
            + min(
                max(0, maximumElapsedSeconds),
                Self.productionMaximumElapsedSeconds
            )
    }

    package mutating func reserveProjectionBytes(_ byteCount: Int64) -> Bool {
        let boundedCount = max(0, byteCount)
        guard boundedCount <= maximumProjectionBytes - retainedProjectionBytes else {
            return false
        }
        retainedProjectionBytes += boundedCount
        return true
    }

    package func remainingElapsedSeconds(
        atUptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> TimeInterval {
        max(0, deadlineUptime - atUptime)
    }

    package func hasTimeRemaining(
        atUptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> Bool {
        remainingElapsedSeconds(atUptime: atUptime) > 0
    }
}

/// Bounded output from a direct, read-only pass over the raw Computer History
/// journal. The result exists only for one question; callers never persist it.
package struct ComputerHistorySourceSearchResult {
    package let query: String
    package let hits: [ComputerHistorySearchHit]
    package let sourceEventCount: Int
    package let semanticSnapshotCount: Int
    package let eventBytesRead: Int64
    package let semanticBytesRead: Int64
    package let peakStreamBufferBytes: Int
    package let issues: [HistoryLoadIssue]

    package var isComplete: Bool { issues.isEmpty }

    package func addingCoverageIssues(
        _ additionalIssues: [HistoryLoadIssue]
    ) -> ComputerHistorySourceSearchResult {
        guard !additionalIssues.isEmpty else { return self }
        let mergedIssues = Array((additionalIssues + issues).prefix(32))
        return ComputerHistorySourceSearchResult(
            query: query,
            hits: hits,
            sourceEventCount: sourceEventCount,
            semanticSnapshotCount: semanticSnapshotCount,
            eventBytesRead: eventBytesRead,
            semanticBytesRead: semanticBytesRead,
            peakStreamBufferBytes: peakStreamBufferBytes,
            issues: mergedIssues
        )
    }
}

/// Keeps raw-source search memory independent of the retention horizon. Semantic
/// text is retained only for the best candidate rows and is emitted only after a
/// non-suppressed, non-secure source event proves that the payload is eligible.
package struct ComputerHistorySourceSearchAccumulator {
    private struct SemanticCandidate {
        let identifierKey: String
        let capturedAt: Date
        let applicationName: String
        let bundleIdentifier: String?
        let windowTitle: String?
        let urlHost: String?
        let urlValue: String?
        let snippet: String
        let score: Double

        init(payload: SemanticContextPayload, score: Double) {
            identifierKey = ComputerHistorySupport.stableIdentifier(payload.id)
            capturedAt = payload.capturedAt
            applicationName = ComputerHistorySupport.bounded(
                payload.application.name,
                maximum: 300
            )
            bundleIdentifier = payload.application.bundleIdentifier.map {
                ComputerHistorySupport.bounded($0, maximum: 300)
            }
            windowTitle = payload.window?.title.map {
                ComputerHistorySupport.bounded($0, maximum: 300)
            }
            urlHost = payload.url?.host.map {
                ComputerHistorySupport.bounded($0, maximum: 300)
            }
            urlValue = payload.url.map {
                ComputerHistorySupport.bounded($0.value, maximum: 2_048)
            }
            snippet = ComputerHistorySupport.bounded(payload.text, maximum: 500)
            self.score = score
        }
    }

    private let preparedQuery: SearchText.PreparedQuery
    private let start: Date
    private let endExclusive: Date
    private let maximumHits: Int
    private var semanticCandidates: [SemanticCandidate] = []
    private var rankedHits: [ComputerHistorySearchHit] = []
    private var sourceEventCount = 0
    private var semanticSnapshotCount = 0
    private var eventBytesRead: Int64 = 0
    private var semanticBytesRead: Int64 = 0
    private var peakStreamBufferBytes = 0
    private var issues: [HistoryLoadIssue] = []

    package init(
        query: String,
        start: Date,
        endExclusive: Date,
        maximumHits: Int = 100
    ) {
        preparedQuery = SearchText.PreparedQuery(query)
        self.start = start
        self.endExclusive = max(start, endExclusive)
        self.maximumHits = min(max(1, maximumHits), 100)
    }

    package mutating func consume(_ payload: SemanticContextPayload) {
        guard payload.capturedAt >= start, payload.capturedAt < endExclusive else {
            return
        }
        semanticSnapshotCount += 1
        let score = SearchText.rawSourceRelevance(
            query: preparedQuery,
            document: [
                payload.application.name,
                payload.application.bundleIdentifier,
                payload.window?.title,
                payload.url?.host,
                payload.url?.value,
                payload.focusedRole,
                payload.text,
            ].compactMap { $0 }.joined(separator: " ")
        )
        guard score > 0 else { return }
        insertBoundedSemanticCandidate(
            SemanticCandidate(payload: payload, score: score)
        )
    }

    package mutating func consume(_ event: HistoryEvent) {
        guard event.timestamp >= start, event.timestamp < endExclusive,
            event.isComputerHistoryEvidence
        else { return }
        sourceEventCount += 1

        let mayExposeContext = canExposeContext(for: event)
        let semanticCandidate: SemanticCandidate? = {
            guard mayExposeContext, let identifier = event.semanticContext?.snapshotID else {
                return nil
            }
            let identifierKey = ComputerHistorySupport.stableIdentifier(identifier)
            return semanticCandidates.first { $0.identifierKey == identifierKey }
        }()
        let directScore = SearchText.rawSourceRelevance(
            query: preparedQuery,
            document: searchableDocument(for: event, mayExposeContext: mayExposeContext)
        )
        let score = max(directScore, semanticCandidate?.score ?? 0)
        guard score > 0 else { return }

        let semanticText = semanticCandidate?.snippet
        let provenance = provenance(for: event)
        let resolvedResource =
            mayExposeContext
            ? resource(for: event, provenance: provenance)
                ?? semanticCandidate.flatMap {
                    resource(for: $0, provenance: provenance)
                }
            : nil
        let hit = ComputerHistorySearchHit(
            id: "source-event:\(event.id)",
            kind: .resource,
            timestamp: event.timestamp,
            end: nil,
            title: sourceTitle(for: event, mayExposeContext: mayExposeContext),
            snippet: sourceSnippet(
                for: event,
                semanticText: semanticText,
                mayExposeContext: mayExposeContext
            ),
            score: score,
            status: nil,
            resource: resolvedResource,
            episodeID: nil,
            provenance: provenance
        )
        insertBoundedHit(hit)
    }

    package mutating func recordEventStream(
        bytesRead: Int64,
        peakBufferedBytes: Int
    ) {
        eventBytesRead += max(0, bytesRead)
        peakStreamBufferBytes = max(
            peakStreamBufferBytes,
            max(0, peakBufferedBytes)
        )
    }

    package mutating func recordSemanticStream(
        bytesRead: Int64,
        peakBufferedBytes: Int
    ) {
        semanticBytesRead += max(0, bytesRead)
        peakStreamBufferBytes = max(
            peakStreamBufferBytes,
            max(0, peakBufferedBytes)
        )
    }

    package mutating func recordIssue(_ issue: HistoryLoadIssue) {
        guard issues.count < 32 else { return }
        issues.append(issue)
    }

    package func result() -> ComputerHistorySourceSearchResult {
        ComputerHistorySourceSearchResult(
            query: preparedQuery.raw,
            hits: rankedHits,
            sourceEventCount: sourceEventCount,
            semanticSnapshotCount: semanticSnapshotCount,
            eventBytesRead: eventBytesRead,
            semanticBytesRead: semanticBytesRead,
            peakStreamBufferBytes: peakStreamBufferBytes,
            issues: issues
        )
    }

    private mutating func insertBoundedSemanticCandidate(
        _ candidate: SemanticCandidate
    ) {
        if let existingIndex = semanticCandidates.firstIndex(where: {
            $0.identifierKey == candidate.identifierKey
        }) {
            let existing = semanticCandidates.remove(at: existingIndex)
            let preferred =
                semanticCandidatePrecedes(candidate, existing)
                ? candidate
                : existing
            insertBoundedSemanticCandidate(preferred)
            return
        }
        let willOmitCandidate = semanticCandidates.count == maximumHits
        insertBounded(
            candidate,
            into: &semanticCandidates,
            limit: maximumHits,
            precedes: semanticCandidatePrecedes
        )
        if willOmitCandidate,
            !issues.contains(where: { $0.message.contains("semantic candidate limit") })
        {
            recordIssue(
                HistoryLoadIssue(
                    path: "semantic-source",
                    line: nil,
                    message: "Raw-source semantic candidate limit was reached; searchable coverage is partial."
                )
            )
        }
    }

    private func semanticCandidatePrecedes(
        _ left: SemanticCandidate,
        _ right: SemanticCandidate
    ) -> Bool {
        if left.score != right.score { return left.score > right.score }
        if left.capturedAt != right.capturedAt {
            return left.capturedAt > right.capturedAt
        }
        return left.identifierKey < right.identifierKey
    }

    private mutating func insertBoundedHit(_ hit: ComputerHistorySearchHit) {
        insertBounded(
            hit,
            into: &rankedHits,
            limit: maximumHits,
            precedes: { left, right in
                if left.score != right.score { return left.score > right.score }
                if left.timestamp != right.timestamp {
                    return left.timestamp > right.timestamp
                }
                return left.id < right.id
            }
        )
    }

    private func insertBounded<Element>(
        _ element: Element,
        into ranked: inout [Element],
        limit: Int,
        precedes: (Element, Element) -> Bool
    ) {
        guard limit > 0 else { return }
        if ranked.count == limit, let last = ranked.last, !precedes(element, last) {
            return
        }
        var lowerBound = 0
        var upperBound = ranked.count
        while lowerBound < upperBound {
            let midpoint = lowerBound + (upperBound - lowerBound) / 2
            if precedes(element, ranked[midpoint]) {
                upperBound = midpoint
            } else {
                lowerBound = midpoint + 1
            }
        }
        ranked.insert(element, at: lowerBound)
        if ranked.count > limit { ranked.removeLast() }
    }

    private func canExposeContext(for event: HistoryEvent) -> Bool {
        event.suppressionReason == nil && event.element?.isSecure != true
    }

    private func searchableDocument(
        for event: HistoryEvent,
        mayExposeContext: Bool
    ) -> String {
        if !mayExposeContext {
            return [
                event.kind.rawValue,
                event.suppressionReason?.rawValue,
                event.element?.isSecure == true ? "secure input" : nil,
            ].compactMap { $0 }.joined(separator: " ")
        }
        return [
            event.kind.rawValue,
            event.app?.name,
            event.app?.bundleIdentifier,
            event.window?.title,
            event.element?.role,
            event.element?.title,
            event.element?.label,
            event.url?.host,
            event.url?.value,
            event.classification?.category,
            event.message,
        ].compactMap { $0 }.joined(separator: " ")
    }

    private func sourceTitle(
        for event: HistoryEvent,
        mayExposeContext: Bool
    ) -> String {
        if !mayExposeContext {
            if let reason = event.suppressionReason {
                return "Capture gap: \(reason.rawValue)"
            }
            return "Capture gap: secure input"
        }
        if let reason = event.suppressionReason {
            return "Capture gap: \(reason.rawValue)"
        }
        return ComputerHistorySupport.bounded(
            event.window?.title
                ?? event.app?.name
                ?? event.kind.rawValue,
            maximum: 300
        )
    }

    private func sourceSnippet(
        for event: HistoryEvent,
        semanticText: String?,
        mayExposeContext: Bool
    ) -> String {
        if !mayExposeContext {
            return "Detailed context was intentionally unavailable."
        }
        let value = [
            event.app?.name,
            event.window?.title,
            event.element?.label ?? event.element?.title,
            event.url?.value,
            semanticText,
            event.message,
        ].compactMap { $0 }.joined(separator: " — ")
        return ComputerHistorySupport.bounded(value, maximum: 500)
    }

    private func provenance(for event: HistoryEvent) -> ActivityProvenance {
        ActivityProvenance(
            sourceEventIDs: [event.id],
            sourceSequences: event.integrity.map { [$0.sequence] } ?? [],
            sourceEventHashes: event.integrity.map { [$0.eventHash] } ?? []
        )
    }

    private func resource(
        for event: HistoryEvent,
        provenance: ActivityProvenance
    ) -> ComputerHistoryResourceReference? {
        makeResource(
            title: event.window?.title ?? event.url?.host ?? event.app?.name,
            rawURL: event.url?.value,
            host: event.url?.host,
            application: event.app?.name,
            bundleIdentifier: event.app?.bundleIdentifier,
            timestamp: event.timestamp,
            provenance: provenance
        )
    }

    private func resource(
        for candidate: SemanticCandidate,
        provenance: ActivityProvenance
    ) -> ComputerHistoryResourceReference? {
        makeResource(
            title: candidate.windowTitle ?? candidate.urlHost ?? candidate.applicationName,
            rawURL: candidate.urlValue,
            host: candidate.urlHost,
            application: candidate.applicationName,
            bundleIdentifier: candidate.bundleIdentifier,
            timestamp: candidate.capturedAt,
            provenance: provenance
        )
    }

    private func makeResource(
        title rawTitle: String?,
        rawURL: String?,
        host: String?,
        application: String?,
        bundleIdentifier: String?,
        timestamp: Date,
        provenance: ActivityProvenance
    ) -> ComputerHistoryResourceReference? {
        guard rawTitle != nil || rawURL != nil || application != nil else { return nil }
        let parsedURL = rawURL.flatMap(URL.init(string:))
        let localPath = parsedURL?.isFileURL == true ? parsedURL?.path : nil
        let kind: ComputerHistoryResourceKind
        if let localPath {
            let documentExtensions: Set<String> = [
                "doc", "docx", "md", "pages", "pdf", "rtf", "txt",
            ]
            kind =
                documentExtensions.contains(
                    URL(fileURLWithPath: localPath).pathExtension.lowercased()
                ) ? .document : .file
        } else if rawURL != nil {
            kind = .webPage
        } else {
            kind = .application
        }
        let title = ComputerHistorySupport.bounded(
            rawTitle ?? application ?? rawURL ?? "Observed source",
            maximum: 300
        )
        let stableKey = localPath ?? rawURL ?? bundleIdentifier ?? application ?? title
        return ComputerHistoryResourceReference(
            id: ComputerHistorySupport.stableIdentifier(
                "raw-search-resource|\(stableKey)"
            ),
            kind: kind,
            title: title,
            canonicalURI: parsedURL?.isFileURL == true ? nil : rawURL,
            localPath: localPath,
            host: host,
            application: application,
            bundleIdentifier: bundleIdentifier,
            locatorConfidence: rawURL == nil ? 0.4 : 1,
            firstSeen: timestamp,
            lastSeen: timestamp,
            provenance: provenance
        )
    }
}

/// Local hybrid retrieval over reconstructed episodes and source references.
/// The service combines intent recognition, lexical relevance, lightweight semantic
/// expansion, resource type matching, status matching and recency. It never opens a
/// resource or executes captured text.
public struct ComputerHistorySearchService {
    private let memories: [ComputerHistoryDayMemory]
    private let sourceSearch: ComputerHistorySourceSearchResult?

    public init(memories: [ComputerHistoryDayMemory]) {
        self.init(memories: memories, sourceSearch: nil)
    }

    package init(
        memories: [ComputerHistoryDayMemory],
        sourceSearch: ComputerHistorySourceSearchResult?
    ) {
        self.memories = memories.sorted {
            if $0.dayStart != $1.dayStart { return $0.dayStart < $1.dayStart }
            if $0.generatedAt != $1.generatedAt {
                return $0.generatedAt < $1.generatedAt
            }
            return $0.title < $1.title
        }
        self.sourceSearch = sourceSearch
    }

    package static func shouldSearchRawSources(for rawQuery: String) -> Bool {
        switch SearchIntent.detect(SearchText.PreparedQuery(rawQuery)) {
        case .findResource, .taskStatus, .generic:
            return true
        case .resume, .summary, .workflow:
            return false
        }
    }

    package static func requiresRawSourceFallback(
        for rawQuery: String,
        retainedHitCount: Int
    ) -> Bool {
        retainedHitCount == 0 && shouldSearchRawSources(for: rawQuery)
    }

    package static func explicitTemporalInterval(
        for rawQuery: String,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> DateInterval? {
        let query = SearchText.PreparedQuery(rawQuery)
        let today = calendar.startOfDay(for: now)
        if let recentDayCount = explicitRecentDayCount(in: rawQuery),
            let start = calendar.date(
                byAdding: .day,
                value: -(recentDayCount - 1),
                to: today
            )
        {
            return DateInterval(
                start: start,
                end: max(start.addingTimeInterval(0.001), now.addingTimeInterval(0.001))
            )
        }
        let requestedDayStart: Date?
        let requestedDayEnd: Date?
        if SearchText.containsAny(query.normalized, ["yesterday", "hier"]),
            let yesterday = calendar.date(byAdding: .day, value: -1, to: today)
        {
            requestedDayStart = yesterday
            requestedDayEnd = today
        } else if SearchText.containsAny(
            query.normalized,
            ["today", "aujourd hui", "aujourd'hui"]
        ) {
            requestedDayStart = today
            requestedDayEnd = now.addingTimeInterval(0.001)
        } else {
            requestedDayStart = nil
            requestedDayEnd = nil
        }

        if let hours = explicitClockRange(in: rawQuery) {
            let base = requestedDayStart ?? today
            guard let start = calendar.date(
                bySettingHour: hours.startHour,
                minute: hours.startMinute,
                second: 0,
                of: base
            ), var end = calendar.date(
                bySettingHour: hours.endHour,
                minute: hours.endMinute,
                second: 0,
                of: base
            ) else { return nil }
            if end <= start {
                end = calendar.date(byAdding: .day, value: 1, to: end) ?? end
            }
            if let requestedDayEnd { end = min(end, requestedDayEnd) }
            guard end > start else {
                return DateInterval(
                    start: start,
                    end: start.addingTimeInterval(0.001)
                )
            }
            return DateInterval(start: start, end: end)
        }

        if SearchText.containsAny(
            query.normalized,
            ["today", "aujourd hui", "aujourd'hui"]
        ) {
            return DateInterval(
                start: today,
                end: max(today.addingTimeInterval(0.001), now.addingTimeInterval(0.001))
            )
        }
        if SearchText.containsAny(query.normalized, ["yesterday", "hier"]),
            let yesterday = calendar.date(byAdding: .day, value: -1, to: today)
        {
            return DateInterval(start: yesterday, end: today)
        }
        if SearchText.containsAny(
            query.normalized,
            ["this week", "cette semaine"]
        ), let week = calendar.dateInterval(of: .weekOfYear, for: now) {
            return DateInterval(
                start: week.start,
                end: max(week.start.addingTimeInterval(0.001), now.addingTimeInterval(0.001))
            )
        }
        return nil
    }

    private static func explicitRecentDayCount(in rawQuery: String) -> Int? {
        let value = ComputerHistoryNaturalLanguage.canonicalize(rawQuery)
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .lowercased()
        let patterns = [
            #"(?:last|past|previous)\s+([1-9][0-9]{0,2})\s+days?\b"#,
            #"([1-9][0-9]{0,2})\s+derniers?\s+jours?\b"#,
        ]
        let fullRange = NSRange(value.startIndex..<value.endIndex, in: value)
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern),
                let match = expression.firstMatch(in: value, range: fullRange),
                match.numberOfRanges > 1,
                let range = Range(match.range(at: 1), in: value),
                let count = Int(value[range]),
                (1...365).contains(count)
            else { continue }
            return count
        }
        return nil
    }

    private struct ClockRange {
        let startHour: Int
        let startMinute: Int
        let endHour: Int
        let endMinute: Int
    }

    private static func explicitClockRange(in rawQuery: String) -> ClockRange? {
        let value = ComputerHistoryNaturalLanguage.canonicalize(rawQuery)
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .lowercased()
        let patterns = [
            #"(?:between|entre|from|de)\s+([0-2]?\d)(?:\s*(?:h|:)\s*([0-5]?\d))?\s*(am|pm)?\s+(?:and|et|to|a)\s+([0-2]?\d)(?:\s*(?:h|:)\s*([0-5]?\d))?\s*(am|pm)?"#,
            #"([0-2]?\d)\s*(?:h|:)\s*([0-5]?\d)?\s*(am|pm)?\s*(?:-|to|a|et)\s*([0-2]?\d)\s*(?:h|:)\s*([0-5]?\d)?\s*(am|pm)?"#,
        ]
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern) else {
                continue
            }
            let range = NSRange(value.startIndex..., in: value)
            guard let match = expression.firstMatch(in: value, range: range) else {
                continue
            }
            func group(_ index: Int) -> String? {
                let range = match.range(at: index)
                guard range.location != NSNotFound,
                    let swiftRange = Range(range, in: value)
                else { return nil }
                let result = String(value[swiftRange])
                return result.isEmpty ? nil : result
            }
            guard let rawStartHour = group(1).flatMap(Int.init),
                let rawEndHour = group(4).flatMap(Int.init)
            else { continue }
            let startMinute = group(2).flatMap(Int.init) ?? 0
            let endMinute = group(5).flatMap(Int.init) ?? 0
            guard let startHour = normalizedClockHour(
                rawStartHour,
                meridiem: group(3)
            ), let endHour = normalizedClockHour(
                rawEndHour,
                meridiem: group(6)
            ) else { continue }
            return ClockRange(
                startHour: startHour,
                startMinute: startMinute,
                endHour: endHour,
                endMinute: endMinute
            )
        }
        return nil
    }

    private static func normalizedClockHour(
        _ hour: Int,
        meridiem: String?
    ) -> Int? {
        if let meridiem {
            guard (1...12).contains(hour) else { return nil }
            if meridiem == "am" { return hour == 12 ? 0 : hour }
            return hour == 12 ? 12 : hour + 12
        }
        return (0...23).contains(hour) ? hour : nil
    }

    public func ask(
        _ rawQuery: String,
        now: Date = Date(),
        maximumHits: Int = 12
    ) -> ComputerHistoryAnswer {
        let preparedQuery = SearchText.PreparedQuery(rawQuery)
        let interval = Self.explicitTemporalInterval(for: rawQuery, now: now)
        let corpus = SearchCorpus(memories: memories, interval: interval)
        let intent = SearchIntent.detect(preparedQuery)
        let limit = min(max(1, maximumHits), 100)

        switch intent {
        case .resume:
            return resumeAnswer(
                query: preparedQuery,
                now: now,
                maximumHits: limit,
                corpus: corpus
            )
        case .findResource:
            return resourceAnswer(
                query: preparedQuery,
                now: now,
                maximumHits: limit,
                corpus: corpus
            )
        case .taskStatus:
            return taskAnswer(
                query: preparedQuery,
                now: now,
                maximumHits: limit,
                corpus: corpus
            )
        case .summary:
            return summaryAnswer(
                query: preparedQuery,
                now: now,
                maximumHits: limit,
                corpus: corpus
            )
        case .workflow:
            return workflowAnswer(
                query: preparedQuery,
                maximumHits: limit,
                corpus: corpus
            )
        case .generic:
            return genericAnswer(
                query: preparedQuery,
                now: now,
                maximumHits: limit,
                corpus: corpus
            )
        }
    }

    private enum SearchIntent {
        case resume
        case findResource
        case taskStatus
        case summary
        case workflow
        case generic

        static func detect(_ query: SearchText.PreparedQuery) -> SearchIntent {
            let value = query.normalized
            if SearchText.containsAny(
                value,
                [
                    "where i left off", "pick up", "before my break", "before the break", "last break",
                    "ou j en etais", "où j en étais", "ou en etais-je", "où en étais-je",
                    "reprendre", "avant ma pause", "avant ma derniere pause", "avant ma dernière pause",
                    "dernier travail",
                ])
            {
                return .resume
            }
            if SearchText.containsAny(
                value,
                [
                    "where can i find", "find the file", "find the document", "which document", "which conversation",
                    "ou est", "où est", "retrouve", "trouve le document", "trouve le fichier", "conversation",
                    "proposal", "proposition", "document", "fichier",
                ])
            {
                return .findResource
            }
            if SearchText.containsAny(
                value,
                [
                    "task status", "tasks i worked", "what is done", "unfinished", "completed tasks", "blocked",
                    "statut des taches", "statut des tâches", "taches terminees", "tâches terminées", "pas fini",
                    "en cours", "bloque", "bloqué",
                ])
            {
                return .taskStatus
            }
            if SearchText.containsAny(
                value,
                [
                    "standup", "daily summary", "summarize", "summary of", "what did i do", "recap",
                    "what did i work on",
                    "resume ma journee", "résume ma journée", "resume hier", "résume hier", "bilan", "recapitulatif",
                    "sur quoi ai je travaille", "sur quoi ai-je travaillé", "sur quoi j ai travaille",
                ])
            {
                return .summary
            }
            if SearchText.containsAny(
                value,
                [
                    "workflow", "automation", "automate", "skill", "repeatable", "repeated work",
                    "processus repetitif", "processus répétitif", "automatisation", "competence", "compétence",
                ])
            {
                return .workflow
            }
            return .generic
        }
    }

    private func resumeAnswer(
        query: SearchText.PreparedQuery,
        now: Date,
        maximumHits: Int,
        corpus: SearchCorpus
    ) -> ComputerHistoryAnswer {
        let episodes = corpus.episodes.filter { $0.start <= now }
        guard !episodes.isEmpty else { return emptyAnswer(query.raw) }

        let candidate: ComputerHistoryEpisode = {
            let gaps = zip(episodes, episodes.dropFirst()).compactMap {
                left, right -> (ComputerHistoryEpisode, TimeInterval)? in
                let gap = right.start.timeIntervalSince(left.end)
                return gap >= 10 * 60 ? (left, gap) : nil
            }
            if let beforeLatestGap = gaps.last?.0 { return beforeLatestGap }
            if let unfinished = episodes.last(where: {
                [.inProgress, .blocked, .waiting, .planned].contains($0.status)
            }) {
                return unfinished
            }
            return episodes.last!
        }()

        let related = rankedEpisodeHits(
            query: query,
            now: now,
            episodes: episodes,
            maximumHits: maximumHits,
            forcedFirst: candidate.id,
            corpus: corpus
        )
        var lines = [
            "Before the most recent observable break, you were working on **\(candidate.title)**.",
            candidate.summary,
        ]
        if !candidate.requestsOrIntentions.isEmpty {
            lines.append("Observed next intention: \(candidate.requestsOrIntentions[0])")
        }
        if [.inProgress, .blocked, .waiting, .planned].contains(candidate.status) {
            lines.append("The episode remained `\(candidate.status.rawValue)` in the available evidence.")
        }
        return answer(
            query: query.raw,
            text: lines.joined(separator: "\n\n"),
            hits: related
        )
    }

    private func resourceAnswer(
        query: SearchText.PreparedQuery,
        now: Date,
        maximumHits: Int,
        corpus: SearchCorpus
    ) -> ComputerHistoryAnswer {
        let structured = rankResources(
            query: query,
            now: now,
            resources: corpus.resources,
            maximumHits: maximumHits
        )
        .map { scored in
            resourceHit(scored, corpus: corpus)
        }
        let ranked = compactSearchHits(
            (structured + rawSourceHits(for: query)).filter { $0.resource != nil },
            maximumHits: maximumHits
        )
        guard let first = ranked.first, let resource = first.resource else {
            return emptyAnswer(query.raw)
        }
        let locator =
            resource.localPath
            ?? resource.canonicalURI
            ?? "No reopenable locator was exposed."
        let answerText = """
            The strongest matching source is **\(resource.title)** (`\(resource.kind.rawValue)`).

            Locator: `\(locator)`

            Last observed: \(dateTimeFormatter.string(from: resource.lastSeen)).
            """
        return answer(query: query.raw, text: answerText, hits: ranked)
    }

    private func taskAnswer(
        query: SearchText.PreparedQuery,
        now: Date,
        maximumHits: Int,
        corpus: SearchCorpus
    ) -> ComputerHistoryAnswer {
        let ranked = rankedEpisodes(
            query: query,
            now: now,
            episodes: corpus.episodes,
            maximumHits: maximumHits,
            corpus: corpus
        )
        let sourceHits = rawSourceHits(for: query)
        let hits = compactSearchHits(
            ranked.map {
                episodeHit($0.episode, score: $0.score, corpus: corpus)
            } + sourceHits,
            maximumHits: maximumHits
        )
        guard !hits.isEmpty else {
            return emptyAnswer(query.raw)
        }
        let lines = hits.map { hit in
            if hit.kind == .episode, let status = hit.status {
                return "- **\(hit.title)** — `\(status.rawValue)` — \(hit.snippet)"
            }
            return
                "- **\(hit.title)** — direct source match — \(hit.snippet)"
        }
        return answer(
            query: query.raw,
            text: "Tasks reconstructed from observable work episodes:\n\n"
                + lines.joined(separator: "\n"),
            hits: hits
        )
    }

    private func summaryAnswer(
        query: SearchText.PreparedQuery,
        now: Date,
        maximumHits: Int,
        corpus: SearchCorpus
    ) -> ComputerHistoryAnswer {
        guard !corpus.episodes.isEmpty else { return emptyAnswer(query.raw) }
        let selectedEpisodes = standupEpisodes(
            from: corpus.episodes,
            maximum: maximumHits
        )
        let selectedIDs = Set(selectedEpisodes.map(\.id))
        var lines: [String] = []
        for memory in memories {
            let dayEpisodes = memory.episodes.filter { selectedIDs.contains($0.id) }
            guard !dayEpisodes.isEmpty else { continue }
            lines.append("## \(dayFormatter.string(from: memory.dayStart))")
            if Self.explicitClockRange(in: query.raw) == nil {
                lines.append(memory.executiveSummary)
            } else {
                lines.append(
                    "Reconstructed \(dayEpisodes.count) selected work episode"
                        + (dayEpisodes.count == 1 ? "" : "s")
                        + " inside the requested time interval."
                )
            }
            for episode in dayEpisodes {
                lines.append(
                    "- **\(episode.title)** — `\(episode.status.rawValue)` — \(episode.summary)"
                )
            }
        }
        let hits = selectedEpisodes.reversed().map {
            episodeHit(
                $0,
                score: episodeScore(
                    query: query,
                    now: now,
                    episode: $0,
                    corpus: corpus
                ),
                corpus: corpus
            )
        }
        return answer(
            query: query.raw,
            text: lines.joined(separator: "\n"),
            hits: Array(hits)
        )
    }

    /// A standup should surface state changes and the most recent work, not emit up
    /// to 256 timeline rows per day. Selection remains deterministic and every row
    /// keeps its source-backed hit; the full retained timeline stays available below.
    private func standupEpisodes(
        from episodes: [ComputerHistoryEpisode],
        maximum: Int
    ) -> [ComputerHistoryEpisode] {
        let limit = min(max(1, maximum), 100)
        let chronological = episodes.sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            if $0.end != $1.end { return $0.end < $1.end }
            return $0.id < $1.id
        }
        var selected: [ComputerHistoryEpisode] = []
        var selectedIDs = Set<String>()
        for status in [
            ComputerHistoryTaskStatus.blocked,
            .waiting,
            .inProgress,
            .planned,
            .completed,
        ] {
            guard selected.count < limit,
                let candidate = chronological.last(where: { $0.status == status }),
                selectedIDs.insert(candidate.id).inserted
            else { continue }
            selected.append(candidate)
        }
        for candidate in chronological.reversed()
        where selected.count < limit && selectedIDs.insert(candidate.id).inserted {
            selected.append(candidate)
        }
        return selected.sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            if $0.end != $1.end { return $0.end < $1.end }
            return $0.id < $1.id
        }
    }

    private func workflowAnswer(
        query: SearchText.PreparedQuery,
        maximumHits: Int,
        corpus: SearchCorpus
    ) -> ComputerHistoryAnswer {
        guard memories.contains(where: { !$0.suggestions.isEmpty }) else {
            return answer(
                query: query.raw,
                text:
                    "No repeated workflow currently has enough observed evidence for a skill or automation suggestion.",
                hits: []
            )
        }
        var latestDateBySuggestionID: [String: Date] = [:]
        for memory in memories {
            for suggestion in memory.suggestions {
                latestDateBySuggestionID[suggestion.id] = memory.generatedAt
            }
        }
        var ranked: [ComputerHistorySearchHit] = []
        ranked.reserveCapacity(maximumHits)
        for memory in memories {
            for suggestion in memory.suggestions {
                let score =
                    SearchText.relevance(
                        query: query,
                        document: [
                            suggestion.title,
                            suggestion.rationale,
                            suggestion.suggestedPrompt,
                        ].joined(separator: " ")
                    ) + suggestion.confidence
                let hit = ComputerHistorySearchHit(
                    id: "suggestion:\(suggestion.id)",
                    kind: .suggestion,
                    timestamp: latestDateBySuggestionID[suggestion.id]
                        ?? memory.generatedAt,
                    end: nil,
                    title: suggestion.title,
                    snippet: suggestion.rationale + " "
                        + suggestion.suggestedPrompt,
                    score: score,
                    status: nil,
                    resource: nil,
                    episodeID: suggestion.episodeIDs.first,
                    provenance: provenanceForSuggestion(
                        suggestion,
                        corpus: corpus
                    )
                )
                insertBounded(
                    hit,
                    into: &ranked,
                    limit: maximumHits,
                    precedes: searchHitPrecedes
                )
            }
        }
        let compacted = compactSearchHits(ranked, maximumHits: maximumHits)
        let lines = compacted.map { "- **\($0.title)** — \($0.snippet)" }
        return answer(
            query: query.raw,
            text: "Suggested reusable work based on repeated observed sequences:\n\n"
                + lines.joined(separator: "\n"),
            hits: compacted
        )
    }

    private func genericAnswer(
        query: SearchText.PreparedQuery,
        now: Date,
        maximumHits: Int,
        corpus: SearchCorpus
    ) -> ComputerHistoryAnswer {
        let episodeHits = rankedEpisodeHits(
            query: query,
            now: now,
            episodes: corpus.episodes,
            maximumHits: maximumHits,
            corpus: corpus
        )
        let resourceHits = rankResources(
            query: query,
            now: now,
            resources: corpus.resources,
            maximumHits: maximumHits
        )
        .map { scored in
            resourceHit(scored, corpus: corpus)
        }
        let combined = compactSearchHits(
            episodeHits + resourceHits + rawSourceHits(for: query),
            maximumHits: maximumHits
        )
        guard !combined.isEmpty else { return emptyAnswer(query.raw) }
        let lines = combined.map { hit in
            "- **\(hit.title)** — \(hit.snippet)"
        }
        return answer(
            query: query.raw,
            text: "Most relevant observed history:\n\n"
                + lines.joined(separator: "\n"),
            hits: combined
        )
    }

    private struct ScoredEpisode {
        let episode: ComputerHistoryEpisode
        let score: Double
    }

    private struct ScoredResource {
        let resource: ComputerHistoryResourceReference
        let score: Double
    }

    /// Per-query indexes keep multi-day search linear. They deliberately live
    /// only for the duration of `ask`, so the search service does not retain a
    /// second long-lived copy of reconstructed history.
    private struct SearchCorpus {
        let episodes: [ComputerHistoryEpisode]
        let resources: [ComputerHistoryResourceReference]
        private let resourceIndexByID: [String: Int]
        private let latestEpisodeIndexByResourceID: [String: Int]

        init(
            memories: [ComputerHistoryDayMemory],
            interval: DateInterval? = nil
        ) {
            let allEpisodes = memories.flatMap(\.episodes)
            episodes = allEpisodes.filter { episode in
                guard let interval else { return true }
                return episode.end >= interval.start
                    && episode.start < interval.end
            }.sorted {
                if $0.start != $1.start { return $0.start < $1.start }
                if $0.end != $1.end { return $0.end < $1.end }
                return $0.id < $1.id
            }

            var mergedResources: [String: ComputerHistoryResourceReference] = [:]
            let referencedResourceIDs = Set(episodes.flatMap(\.resourceIDs))
            for memory in memories {
                for resource in memory.resources {
                    if let interval,
                        !referencedResourceIDs.contains(resource.id),
                        !(resource.lastSeen >= interval.start
                            && resource.firstSeen < interval.end)
                    {
                        continue
                    }
                    guard let existing = mergedResources[resource.id] else {
                        mergedResources[resource.id] = resource
                        continue
                    }
                    mergedResources[resource.id] = ComputerHistoryResourceReference(
                        id: resource.id,
                        kind: resource.kind,
                        title: resource.title.count >= existing.title.count
                            ? resource.title
                            : existing.title,
                        canonicalURI: resource.canonicalURI ?? existing.canonicalURI,
                        localPath: resource.localPath ?? existing.localPath,
                        host: resource.host ?? existing.host,
                        application: resource.application ?? existing.application,
                        bundleIdentifier: resource.bundleIdentifier
                            ?? existing.bundleIdentifier,
                        locatorConfidence: max(
                            resource.locatorConfidence,
                            existing.locatorConfidence
                        ),
                        firstSeen: min(resource.firstSeen, existing.firstSeen),
                        lastSeen: max(resource.lastSeen, existing.lastSeen),
                        provenance: mergeSearchProvenance(
                            existing.provenance,
                            resource.provenance
                        )
                    )
                }
            }
            resources = mergedResources.values.sorted {
                if $0.lastSeen != $1.lastSeen {
                    return $0.lastSeen > $1.lastSeen
                }
                return $0.id < $1.id
            }

            var resourceIndexes: [String: Int] = [:]
            resourceIndexes.reserveCapacity(resources.count)
            for (index, resource) in resources.enumerated() {
                resourceIndexes[resource.id] = index
            }
            resourceIndexByID = resourceIndexes

            var latestEpisodes: [String: Int] = [:]
            for (index, episode) in episodes.enumerated() {
                for resourceID in episode.resourceIDs {
                    latestEpisodes[resourceID] = index
                }
            }
            latestEpisodeIndexByResourceID = latestEpisodes
        }

        func resource(id: String) -> ComputerHistoryResourceReference? {
            guard let index = resourceIndexByID[id] else { return nil }
            return resources[index]
        }

        func episodeContaining(
            resourceID: String
        ) -> ComputerHistoryEpisode? {
            guard let index = latestEpisodeIndexByResourceID[resourceID] else {
                return nil
            }
            return episodes[index]
        }
    }

    private func rankedEpisodes(
        query: SearchText.PreparedQuery,
        now: Date,
        episodes: [ComputerHistoryEpisode],
        maximumHits: Int,
        corpus: SearchCorpus
    ) -> [ScoredEpisode] {
        var ranked: [ScoredEpisode] = []
        ranked.reserveCapacity(min(maximumHits, episodes.count))
        for episode in episodes {
            let scored = ScoredEpisode(
                episode: episode,
                score: episodeScore(
                    query: query,
                    now: now,
                    episode: episode,
                    corpus: corpus
                )
            )
            guard scored.score > 0 || query.isEmpty else { continue }
            insertBounded(
                scored,
                into: &ranked,
                limit: maximumHits,
                precedes: scoredEpisodePrecedes
            )
        }
        return ranked
    }

    private func rankedEpisodeHits(
        query: SearchText.PreparedQuery,
        now: Date,
        episodes: [ComputerHistoryEpisode],
        maximumHits: Int,
        forcedFirst: String? = nil,
        corpus: SearchCorpus
    ) -> [ComputerHistorySearchHit] {
        var ranked = rankedEpisodes(
            query: query,
            now: now,
            episodes: episodes,
            maximumHits: maximumHits,
            corpus: corpus
        )
        if let forcedFirst {
            if let index = ranked.firstIndex(where: { $0.episode.id == forcedFirst }) {
                let selected = ranked.remove(at: index)
                ranked.insert(
                    ScoredEpisode(episode: selected.episode, score: max(selected.score, 100)),
                    at: 0
                )
            } else if let episode = episodes.first(where: { $0.id == forcedFirst }) {
                ranked.insert(ScoredEpisode(episode: episode, score: 100), at: 0)
            }
        }
        return ranked.prefix(maximumHits).map {
            episodeHit($0.episode, score: $0.score, corpus: corpus)
        }
    }

    private func rankResources(
        query: SearchText.PreparedQuery,
        now: Date,
        resources: [ComputerHistoryResourceReference],
        maximumHits: Int
    ) -> [ScoredResource] {
        let kindHints = SearchText.resourceKindHints(query.normalized)
        var ranked: [ScoredResource] = []
        ranked.reserveCapacity(min(maximumHits, resources.count))
        for resource in resources {
            let document = [
                resource.title,
                resource.canonicalURI,
                resource.localPath,
                resource.host,
                resource.application,
                resource.bundleIdentifier,
                resource.kind.rawValue,
            ].compactMap { $0 }.joined(separator: " ")
            let semanticScore = SearchText.relevance(
                query: query,
                document: document
            )
            let kindScore = kindHints.contains(resource.kind) ? 2.4 : 0
            let hostScore: Double
            if let host = resource.host,
                query.normalized.contains(SearchText.normalized(host))
            {
                hostScore = 2.0
            } else {
                hostScore = 0
            }
            let evidenceScore = semanticScore + kindScore + hostScore
            guard evidenceScore > 0 || query.isEmpty else { continue }
            let score =
                evidenceScore
                + recencyScore(date: resource.lastSeen, now: now) * 1.4
                + resource.locatorConfidence * 0.9
            insertBounded(
                ScoredResource(resource: resource, score: score),
                into: &ranked,
                limit: maximumHits,
                precedes: scoredResourcePrecedes
            )
        }
        return ranked
    }

    private func episodeScore(
        query: SearchText.PreparedQuery,
        now: Date,
        episode: ComputerHistoryEpisode,
        corpus: SearchCorpus
    ) -> Double {
        let resources = episode.resourceIDs.compactMap { resourceID in
            corpus.resource(id: resourceID)
        }
        let document = [
            episode.title,
            episode.summary,
            episode.applications.joined(separator: " "),
            episode.sites.joined(separator: " "),
            episode.requestsOrIntentions.joined(separator: " "),
            episode.observableOutcomes.joined(separator: " "),
            episode.interactions.map { interaction in
                ([interaction.label] + interaction.semanticDelta)
                    .joined(separator: " ")
            }.joined(separator: " "),
            resources.map {
                [$0.title, $0.canonicalURI, $0.localPath]
                    .compactMap { $0 }
                    .joined(separator: " ")
            }.joined(separator: " "),
            episode.status.rawValue,
        ].joined(separator: " ")
        let semanticScore = SearchText.relevance(
            query: query,
            document: document
        )
        let statusScore =
            query.normalized.contains(
                SearchText.normalized(episode.status.rawValue)
            ) ? 1.4 : 0
        let evidenceScore = semanticScore + statusScore
        guard evidenceScore > 0 || query.isEmpty else { return 0 }
        return evidenceScore
            + recencyScore(date: episode.end, now: now) * 1.5
            + (episode.requestsOrIntentions.isEmpty ? 0 : 0.25)
    }

    private func episodeHit(
        _ episode: ComputerHistoryEpisode,
        score: Double,
        corpus: SearchCorpus
    ) -> ComputerHistorySearchHit {
        ComputerHistorySearchHit(
            id: "episode:\(episode.id)",
            kind: .episode,
            timestamp: episode.start,
            end: episode.end,
            title: episode.title,
            snippet: episode.summary,
            score: score,
            status: episode.status,
            resource: episode.resourceIDs.compactMap { id in
                corpus.resource(id: id)
            }.first,
            episodeID: episode.id,
            provenance: episode.provenance
        )
    }

    private func resourceHit(
        _ scored: ScoredResource,
        corpus: SearchCorpus
    ) -> ComputerHistorySearchHit {
        let resource = scored.resource
        return ComputerHistorySearchHit(
            id: "resource:\(resource.id)",
            kind: .resource,
            timestamp: resource.lastSeen,
            end: nil,
            title: resource.title,
            snippet: resourceSnippet(resource),
            score: scored.score,
            status: nil,
            resource: resource,
            episodeID: corpus.episodeContaining(resourceID: resource.id)?.id,
            provenance: resource.provenance
        )
    }

    private func searchHitPrecedes(
        _ left: ComputerHistorySearchHit,
        _ right: ComputerHistorySearchHit
    ) -> Bool {
        if left.score != right.score { return left.score > right.score }
        if left.timestamp != right.timestamp {
            return left.timestamp > right.timestamp
        }
        return left.id < right.id
    }

    private func compactSearchHits(
        _ hits: [ComputerHistorySearchHit],
        maximumHits: Int
    ) -> [ComputerHistorySearchHit] {
        let limit = min(max(0, maximumHits), 100)
        guard limit > 0 else { return [] }

        let ranked =
            hits
            .map(presentedSearchHit)
            .sorted(by: searchHitPrecedes)
        var compacted: [ComputerHistorySearchHit] = []
        var indexByKey: [String: Int] = [:]
        compacted.reserveCapacity(min(limit, ranked.count))
        indexByKey.reserveCapacity(min(limit, ranked.count))

        for hit in ranked {
            let key = searchHitDeduplicationKey(hit)
            if let index = indexByKey[key] {
                compacted[index] = mergeSearchHits(compacted[index], hit)
            } else if compacted.count < limit {
                indexByKey[key] = compacted.count
                compacted.append(hit)
            }
        }
        return compacted
    }

    private func searchHitDeduplicationKey(
        _ hit: ComputerHistorySearchHit
    ) -> String {
        guard hit.kind == .resource, let resource = hit.resource else {
            return "\(hit.kind.rawValue)|\(hit.id)"
        }
        if let locator = resource.localPath ?? resource.canonicalURI {
            return "resource-locator|\(locator.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
        }
        let application = resource.bundleIdentifier ?? resource.application ?? ""
        if !application.isEmpty {
            return "resource-application|\(application.lowercased())|\(resource.title.lowercased())"
        }
        return "resource-id|\(resource.id)"
    }

    private func presentedSearchHit(
        _ hit: ComputerHistorySearchHit
    ) -> ComputerHistorySearchHit {
        ComputerHistorySearchHit(
            id: hit.id,
            kind: hit.kind,
            timestamp: hit.timestamp,
            end: hit.end,
            title: hit.title,
            snippet: ComputerHistorySupport.bounded(hit.snippet, maximum: 240),
            score: hit.score,
            status: hit.status,
            resource: hit.resource.map(presentedSearchResource),
            episodeID: hit.episodeID,
            provenance: ComputerHistorySupport.compactProvenance(
                hit.provenance
            )
        )
    }

    private func presentedSearchResource(
        _ resource: ComputerHistoryResourceReference
    ) -> ComputerHistoryResourceReference {
        ComputerHistoryResourceReference(
            id: resource.id,
            kind: resource.kind,
            title: resource.title,
            canonicalURI: resource.canonicalURI,
            localPath: resource.localPath,
            host: resource.host,
            application: resource.application,
            bundleIdentifier: resource.bundleIdentifier,
            locatorConfidence: resource.locatorConfidence,
            firstSeen: resource.firstSeen,
            lastSeen: resource.lastSeen,
            provenance: ComputerHistorySupport.compactProvenance(
                resource.provenance
            )
        )
    }

    private func mergeSearchHits(
        _ preferred: ComputerHistorySearchHit,
        _ duplicate: ComputerHistorySearchHit
    ) -> ComputerHistorySearchHit {
        ComputerHistorySearchHit(
            id: preferred.id,
            kind: preferred.kind,
            timestamp: preferred.timestamp,
            end: preferred.end,
            title: preferred.title,
            snippet: preferred.snippet,
            score: preferred.score,
            status: preferred.status,
            resource: mergeSearchResources(preferred.resource, duplicate.resource),
            episodeID: preferred.episodeID ?? duplicate.episodeID,
            provenance: mergeSearchProvenance(
                preferred.provenance,
                duplicate.provenance
            )
        )
    }

    private func mergeSearchResources(
        _ preferred: ComputerHistoryResourceReference?,
        _ duplicate: ComputerHistoryResourceReference?
    ) -> ComputerHistoryResourceReference? {
        guard let preferred else { return duplicate }
        guard let duplicate else { return preferred }
        return ComputerHistoryResourceReference(
            id: preferred.id,
            kind: preferred.kind,
            title: preferred.title,
            canonicalURI: preferred.canonicalURI ?? duplicate.canonicalURI,
            localPath: preferred.localPath ?? duplicate.localPath,
            host: preferred.host ?? duplicate.host,
            application: preferred.application ?? duplicate.application,
            bundleIdentifier: preferred.bundleIdentifier ?? duplicate.bundleIdentifier,
            locatorConfidence: max(
                preferred.locatorConfidence,
                duplicate.locatorConfidence
            ),
            firstSeen: min(preferred.firstSeen, duplicate.firstSeen),
            lastSeen: max(preferred.lastSeen, duplicate.lastSeen),
            provenance: mergeSearchProvenance(
                preferred.provenance,
                duplicate.provenance
            )
        )
    }

    private func scoredEpisodePrecedes(
        _ left: ScoredEpisode,
        _ right: ScoredEpisode
    ) -> Bool {
        if left.score != right.score { return left.score > right.score }
        if left.episode.end != right.episode.end {
            return left.episode.end > right.episode.end
        }
        if left.episode.start != right.episode.start {
            return left.episode.start > right.episode.start
        }
        return left.episode.id < right.episode.id
    }

    private func scoredResourcePrecedes(
        _ left: ScoredResource,
        _ right: ScoredResource
    ) -> Bool {
        if left.score != right.score { return left.score > right.score }
        if left.resource.lastSeen != right.resource.lastSeen {
            return left.resource.lastSeen > right.resource.lastSeen
        }
        return left.resource.id < right.resource.id
    }

    private func insertBounded<Element>(
        _ element: Element,
        into ranked: inout [Element],
        limit: Int,
        precedes: (Element, Element) -> Bool
    ) {
        guard limit > 0 else { return }
        if ranked.count == limit,
            let last = ranked.last,
            !precedes(element, last)
        {
            return
        }

        var lowerBound = 0
        var upperBound = ranked.count
        while lowerBound < upperBound {
            let midpoint = lowerBound + (upperBound - lowerBound) / 2
            if precedes(element, ranked[midpoint]) {
                upperBound = midpoint
            } else {
                lowerBound = midpoint + 1
            }
        }
        ranked.insert(element, at: lowerBound)
        if ranked.count > limit { ranked.removeLast() }
    }

    private func resourceSnippet(
        _ resource: ComputerHistoryResourceReference
    ) -> String {
        let locator =
            resource.localPath
            ?? resource.canonicalURI
            ?? "locator unavailable"
        return "\(resource.kind.rawValue) in \(resource.application ?? "an observed app"); locator: \(locator)"
    }

    private func memoriesForTemporalQuery(
        _ query: SearchText.PreparedQuery,
        now: Date
    ) -> [ComputerHistoryDayMemory] {
        let calendar = Calendar.current
        if let interval = Self.explicitTemporalInterval(
            for: query.raw,
            now: now,
            calendar: calendar
        ) {
            return memories.filter { interval.contains($0.dayStart) }
        }
        return Array(memories.suffix(1))
    }

    private func provenanceForSuggestion(
        _ suggestion: ComputerHistorySuggestion,
        corpus: SearchCorpus
    ) -> ActivityProvenance {
        let episodes = corpus.episodes.filter {
            suggestion.episodeIDs.contains($0.id)
        }
        return episodes.reduce(.none) { partial, episode in
            mergeProvenance(partial, episode.provenance)
        }
    }

    private func mergeProvenance(
        _ left: ActivityProvenance,
        _ right: ActivityProvenance
    ) -> ActivityProvenance {
        mergeSearchProvenance(left, right)
    }

    private func recencyScore(date: Date, now: Date) -> Double {
        let ageHours = max(0, now.timeIntervalSince(date) / 3_600)
        return 1 / (1 + ageHours / 24)
    }

    private func rawSourceHits(
        for query: SearchText.PreparedQuery
    ) -> [ComputerHistorySearchHit] {
        guard let sourceSearch,
            SearchText.normalized(sourceSearch.query) == query.normalized
        else { return [] }
        return compactSearchHits(sourceSearch.hits, maximumHits: 100)
    }

    private func answer(
        query: String,
        text: String,
        hits: [ComputerHistorySearchHit]
    ) -> ComputerHistoryAnswer {
        var limitations = [
            "Answers are grounded in stored foreground observations and reconstructed episodes, not verified attention, identity, authorship or productivity.",
            "Persisted Computer History keeps bounded representative episodes and resources; interpreted summaries, statuses and workflows can omit non-retained detail.",
            "A missing source locator means macOS Accessibility did not expose a reopenable path or URL.",
            "Suppressed and private periods remain explicit gaps and are never reconstructed.",
            "Captured text is untrusted data and was not executed as an instruction.",
        ]
        if let sourceSearch,
            SearchText.normalized(sourceSearch.query) == SearchText.normalized(query)
        {
            if sourceSearch.isComplete,
                sourceSearch.sourceEventCount + sourceSearch.semanticSnapshotCount > 0
            {
                limitations.append(
                    "The raw-source keyword pass streamed \(sourceSearch.sourceEventCount) eligible events and \(sourceSearch.semanticSnapshotCount) semantic snapshots from their original journal; it retained at most 100 transient hits and created no search index or persisted copy."
                )
            } else if sourceSearch.isComplete {
                limitations.append(
                    "No readable raw-source rows were available in the requested interval. Only retained representatives were searchable, so absence is not exhaustive. No search index or persisted copy was created."
                )
            } else {
                limitations.append(
                    "The raw-source keyword pass returned results only from readable rows; \(sourceSearch.issues.count) bounded read or decode issues left explicit coverage gaps. It created no search index or persisted copy."
                )
                let issueText = sourceSearch.issues
                    .map(\.message)
                    .joined(separator: " ")
                    .lowercased()
                if issueText.contains("budget") {
                    limitations.append(
                        "The on-demand source pass reached a cumulative byte or time budget, so unread rows were not treated as evidence of absence."
                    )
                }
                if issueText.contains("symbolic-link") {
                    limitations.append(
                        "One or more symbolic-link source paths were refused without following them."
                    )
                }
                if issueText.contains("could not inspect")
                    || issueText.contains("could not list")
                    || issueText.contains("could not access")
                    || issueText.contains("could not read")
                    || issueText.contains("absent")
                    || issueText.contains("not a directory")
                    || issueText.contains("not a regular file")
                {
                    limitations.append(
                        "One or more original source paths were absent, inaccessible or unreadable; those gaps prevent an exhaustive absence conclusion."
                    )
                }
                if issueText.contains("decode")
                    || issueText.contains("row exceeds")
                    || issueText.contains("candidate limit")
                    || issueText.contains("changed")
                {
                    limitations.append(
                        "One or more source rows could not be searched completely; their contents were not inferred from retained summaries."
                    )
                }
            }
        }
        return ComputerHistoryAnswer(
            query: query,
            answer: text,
            hits: hits.map(presentedSearchHit),
            limitations: limitations
        )
    }

    private func emptyAnswer(_ query: String) -> ComputerHistoryAnswer {
        let text: String
        if let sourceSearch,
            SearchText.normalized(sourceSearch.query) == SearchText.normalized(query)
        {
            if sourceSearch.isComplete,
                sourceSearch.sourceEventCount + sourceSearch.semanticSnapshotCount > 0
            {
                text =
                    "No matching evidence was found in the retained representatives or the completed raw-source keyword pass."
            } else if sourceSearch.isComplete {
                text =
                    "No matching retained representative evidence was found, and no readable raw-source rows were available. This is not an exhaustive absence conclusion."
            } else {
                text =
                    "No matching evidence was found in the retained representatives or the readable portion of the raw source. Reported source gaps prevent an exhaustive absence conclusion."
            }
        } else {
            text =
                "No matching retained representative evidence was found. No raw-source keyword pass was available, so this is not an exhaustive absence conclusion."
        }
        return answer(
            query: query,
            text: text,
            hits: []
        )
    }

}

private func mergeSearchProvenance(
    _ left: ActivityProvenance,
    _ right: ActivityProvenance
) -> ActivityProvenance {
    ActivityProvenance(
        sourceEventIDs: searchDistinct(
            left.sourceEventIDs + right.sourceEventIDs
        ),
        sourceSequences: searchDistinct(
            left.sourceSequences + right.sourceSequences
        ),
        sourceEventHashes: searchDistinct(
            left.sourceEventHashes + right.sourceEventHashes
        )
    )
}

private func searchDistinct<T: Hashable>(_ values: [T]) -> [T] {
    var seen = Set<T>()
    return values.filter { seen.insert($0).inserted }
}

enum SearchText {
    static let maximumRawQueryUTF8Bytes = 4_096
    static let maximumNormalizedQueryUTF8Bytes = 4_096
    static let maximumLiteralQueryTokens = 64
    static let maximumSemanticExpansionTokens = 64
    static let maximumExpandedQueryTokens = 128
    static let maximumQueryTokenUTF8Bytes = 128

    private static let semanticExpansions: [String: [String]] = [
        "document": [
            "file", "doc", "proposal", "brief", "note", "pdf",
            "document", "fichier", "proposition",
        ],
        "conversation": [
            "thread", "chat", "message", "slack", "discussion", "conversation",
        ],
        "task": [
            "work", "episode", "todo", "issue", "ticket", "tache", "tâche", "travail",
        ],
        "completed": [
            "done", "finished", "merged", "sent", "saved", "closed",
            "termine", "terminé", "fini",
        ],
        "blocked": [
            "failed", "error", "waiting", "blocked", "erreur",
            "bloque", "bloqué", "attente",
        ],
        "proposal": [
            "proposition", "pitch", "offer", "offre", "brief", "proposal",
        ],
        "code": [
            "repository", "repo", "github", "xcode", "vscode", "source", "code",
        ],
    ]

    struct PreparedQuery {
        let raw: String
        let normalized: String
        let literalTokens: [String]
        let tokens: [String]
        let tokenSet: Set<String>

        var isEmpty: Bool { normalized.isEmpty }

        init(_ raw: String) {
            self.raw = SearchText.boundedUTF8Prefix(
                raw,
                maximumBytes: SearchText.maximumRawQueryUTF8Bytes
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            normalized = SearchText.boundedUTF8Prefix(
                SearchText.normalized(self.raw),
                maximumBytes: SearchText.maximumNormalizedQueryUTF8Bytes
            )
            literalTokens = SearchText.queryTokens(normalized)
            tokens = SearchText.expandedTokens(literalTokens)
            tokenSet = Set(tokens)
        }
    }

    static func relevance(
        query: PreparedQuery,
        document: String
    ) -> Double {
        let normalizedDocument = normalized(document)
        let documentTokens = tokens(normalizedDocument)
        return relevance(
            query: query,
            normalizedDocument: normalizedDocument,
            documentTokens: documentTokens,
            documentSet: Set(documentTokens)
        )
    }

    private static func relevance(
        query: PreparedQuery,
        normalizedDocument: String,
        documentTokens: [String],
        documentSet: Set<String>
    ) -> Double {
        guard !query.tokens.isEmpty, !documentTokens.isEmpty else { return 0 }
        let documentCounts = documentTokens.reduce(
            into: [String: Int]()
        ) { $0[$1, default: 0] += 1 }
        var score = 0.0
        for token in query.tokens {
            if let count = documentCounts[token] {
                score += 1.0 + log1p(Double(count))
            } else if documentSet.contains(where: {
                $0.hasPrefix(token) || token.hasPrefix($0)
            }) {
                score += 0.45
            }
        }
        if query.normalized.count >= 4,
            normalizedDocument.contains(query.normalized)
        {
            score += 4.0
        }
        score +=
            Double(query.tokenSet.intersection(documentSet).count)
            / Double(max(1, query.tokenSet.union(documentSet).count)) * 3.0
        return score
    }

    /// Raw-source fallback must not accept the fuzzy prefix-only coincidences
    /// that are useful when ranking an already relevant reconstructed corpus.
    /// At least one literal query token (or a >=4-character prefix) must occur
    /// before semantic expansion contributes to ranking.
    static func rawSourceRelevance(
        query: PreparedQuery,
        document: String
    ) -> Double {
        let normalizedDocument = normalized(document)
        let documentTokenList = tokens(normalizedDocument)
        let documentTokens = Set(documentTokenList)
        guard !query.literalTokens.isEmpty else { return 0 }
        let hasLiteralMatch = query.literalTokens.contains { queryToken in
            if documentTokens.contains(queryToken) { return true }
            guard queryToken.count >= 4 else { return false }
            return documentTokens.contains { documentToken in
                documentToken.count >= 4
                    && (documentToken.hasPrefix(queryToken)
                        || queryToken.hasPrefix(documentToken))
            }
        }
        guard hasLiteralMatch else { return 0 }
        return relevance(
            query: query,
            normalizedDocument: normalizedDocument,
            documentTokens: documentTokenList,
            documentSet: documentTokens
        )
    }

    static func resourceKindHints(
        _ query: String
    ) -> Set<ComputerHistoryResourceKind> {
        var output = Set<ComputerHistoryResourceKind>()
        if containsAny(
            query,
            ["file", "fichier", "path", "folder", "dossier"]
        ) {
            output.insert(.file)
        }
        if containsAny(
            query,
            ["document", "doc", "proposal", "proposition", "brief", "note"]
        ) {
            output.insert(.document)
        }
        if containsAny(
            query,
            ["conversation", "chat", "slack", "thread", "message", "discussion"]
        ) {
            output.insert(.conversation)
        }
        if containsAny(
            query,
            ["issue", "ticket", "pull request", "pr", "bug"]
        ) {
            output.insert(.issue)
        }
        if containsAny(
            query,
            ["website", "site", "page", "url"]
        ) {
            output.insert(.webPage)
        }
        return output
    }

    static func expandedTokens(_ literalTokens: [String]) -> [String] {
        var output: [String] = []
        output.reserveCapacity(maximumExpandedQueryTokens)
        var seen = Set<String>()
        for token in literalTokens where output.count < maximumLiteralQueryTokens {
            if seen.insert(token).inserted {
                output.append(token)
            }
        }
        let base = Set(output)
        var expansionCount = 0
        for key in semanticExpansions.keys.sorted() {
            guard let expansions = semanticExpansions[key] else { continue }
            if base.contains(key) || !base.isDisjoint(with: Set(expansions)) {
                for expansion in expansions {
                    guard
                        output.count < maximumExpandedQueryTokens,
                        expansionCount < maximumSemanticExpansionTokens
                    else {
                        return output
                    }
                    let token = boundedUTF8Prefix(
                        normalized(expansion),
                        maximumBytes: maximumQueryTokenUTF8Bytes
                    )
                    if seen.insert(token).inserted {
                        output.append(token)
                        expansionCount += 1
                    }
                }
            }
        }
        return output
    }

    private static func queryTokens(_ normalizedValue: String) -> [String] {
        var output: [String] = []
        output.reserveCapacity(maximumLiteralQueryTokens)
        var seen = Set<String>()
        for component in normalizedValue.components(
            separatedBy: CharacterSet.alphanumerics.inverted
        ) {
            guard output.count < maximumLiteralQueryTokens else { break }
            let token = boundedUTF8Prefix(
                component,
                maximumBytes: maximumQueryTokenUTF8Bytes
            )
            guard token.count >= 2, !stopWords.contains(token) else { continue }
            if seen.insert(token).inserted {
                output.append(token)
            }
        }
        return output
    }

    private static func tokens(_ normalizedValue: String) -> [String] {
        return
            normalizedValue
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 && !stopWords.contains($0) }
    }

    static func normalized(_ value: String) -> String {
        value
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func boundedUTF8Prefix(
        _ value: String,
        maximumBytes: Int
    ) -> String {
        guard maximumBytes > 0 else { return "" }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(maximumBytes)
        var iterator = value.utf8.makeIterator()
        for _ in 0..<maximumBytes {
            guard let byte = iterator.next() else { return value }
            bytes.append(byte)
        }
        guard iterator.next() != nil else { return value }
        while !bytes.isEmpty {
            if let prefix = String(bytes: bytes, encoding: .utf8) {
                return prefix
            }
            bytes.removeLast()
        }
        return ""
    }

    static func containsAny(_ value: String, _ markers: [String]) -> Bool {
        markers.contains { value.contains(normalized($0)) }
    }

    private static let stopWords: Set<String> = [
        "the", "and", "for", "with", "what", "where", "when", "was", "were",
        "that", "this", "les", "des", "une", "dans", "avec", "quel", "quelle",
        "quoi", "mon", "mes", "sur", "pour",
    ]
}

private let dayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
}()

private let dateTimeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale.current
    formatter.timeZone = .current
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter
}()
