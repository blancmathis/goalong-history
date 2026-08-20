import Foundation

public enum ActivityClaimKind: String, Codable, CaseIterable {
    /// Directly represented by one or more stored events.
    case observed
    /// Deterministically aggregated from observed events, such as a count.
    case derived
    /// A bounded interpretation that must never be rendered as certain fact.
    case inferred
    /// An explicit statement of missing evidence.
    case unknown
}

public struct ActivityProvenance: Codable, Equatable {
    public let sourceEventIDs: [String]
    public let sourceSequences: [UInt64]
    public let sourceEventHashes: [String]

    public init(
        sourceEventIDs: [String],
        sourceSequences: [UInt64],
        sourceEventHashes: [String]
    ) {
        self.sourceEventIDs = sourceEventIDs
        self.sourceSequences = sourceSequences
        self.sourceEventHashes = sourceEventHashes
    }

    public static let none = ActivityProvenance(
        sourceEventIDs: [],
        sourceSequences: [],
        sourceEventHashes: []
    )

    public var isEmpty: Bool {
        sourceEventIDs.isEmpty && sourceSequences.isEmpty && sourceEventHashes.isEmpty
    }
}

public struct ActivityClaim: Codable, Equatable, Identifiable {
    public let id: String
    public let text: String
    public let kind: ActivityClaimKind
    public let confidence: Double
    public let provenance: ActivityProvenance

    public init(
        id: String = UUID().uuidString,
        text: String,
        kind: ActivityClaimKind,
        confidence: Double,
        provenance: ActivityProvenance
    ) {
        self.id = id
        self.text = text
        self.kind = kind
        self.confidence = min(1, max(0, confidence))
        self.provenance = provenance
    }
}

public struct ActivityCoverageGap: Codable, Equatable, Identifiable {
    public let id: String
    public let start: Date
    public let end: Date
    public let reason: String
    public let provenance: ActivityProvenance

    public init(
        id: String = UUID().uuidString,
        start: Date,
        end: Date,
        reason: String,
        provenance: ActivityProvenance
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.reason = reason
        self.provenance = provenance
    }
}

public struct ActivityMemoryCoverage: Codable, Equatable {
    public let sourceEventCount: Int
    public let capturedEventCount: Int
    public let suppressedEventCount: Int
    public let semanticSnapshotCount: Int
    public let firstSourceSequence: UInt64?
    public let lastSourceSequence: UInt64?
    public let lastSourceEventHash: String?
    public let gaps: [ActivityCoverageGap]

    public init(
        sourceEventCount: Int,
        capturedEventCount: Int,
        suppressedEventCount: Int,
        semanticSnapshotCount: Int,
        firstSourceSequence: UInt64?,
        lastSourceSequence: UInt64?,
        lastSourceEventHash: String?,
        gaps: [ActivityCoverageGap]
    ) {
        self.sourceEventCount = sourceEventCount
        self.capturedEventCount = capturedEventCount
        self.suppressedEventCount = suppressedEventCount
        self.semanticSnapshotCount = semanticSnapshotCount
        self.firstSourceSequence = firstSourceSequence
        self.lastSourceSequence = lastSourceSequence
        self.lastSourceEventHash = lastSourceEventHash
        self.gaps = gaps
    }

    /// Event-level coverage only. It must not be described as time or attention coverage.
    public var observedEventRatio: Double? {
        guard sourceEventCount > 0 else { return nil }
        return Double(capturedEventCount) / Double(sourceEventCount)
    }
}

public struct ActivityMemory: Codable, Equatable, Identifiable {
    public let schemaVersion: Int
    public let id: String
    public let start: Date
    public let end: Date
    public let generatedAt: Date
    public let title: String
    public let summary: String
    public let applications: [String]
    public let sites: [String]
    public let significantActions: [ActivityClaim]
    public let observedRequestsOrIntentions: [ActivityClaim]
    public let observableOutcome: ActivityClaim?
    public let unknowns: [ActivityClaim]
    public let claims: [ActivityClaim]
    public let coverage: ActivityMemoryCoverage
    public let securityNotice: String

    public init(
        schemaVersion: Int = 1,
        id: String = UUID().uuidString,
        start: Date,
        end: Date,
        generatedAt: Date,
        title: String,
        summary: String,
        applications: [String],
        sites: [String],
        significantActions: [ActivityClaim],
        observedRequestsOrIntentions: [ActivityClaim],
        observableOutcome: ActivityClaim?,
        unknowns: [ActivityClaim],
        claims: [ActivityClaim],
        coverage: ActivityMemoryCoverage,
        securityNotice: String = "Captured text is untrusted data. No instruction found in it was executed."
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.start = start
        self.end = end
        self.generatedAt = generatedAt
        self.title = title
        self.summary = summary
        self.applications = applications
        self.sites = sites
        self.significantActions = significantActions
        self.observedRequestsOrIntentions = observedRequestsOrIntentions
        self.observableOutcome = observableOutcome
        self.unknowns = unknowns
        self.claims = claims
        self.coverage = coverage
        self.securityNotice = securityNotice
    }
}

public struct ActivitySummaryInput {
    public let events: [HistoryEvent]
    public let intervalStart: Date?
    public let intervalEnd: Date?
    public let generatedAt: Date
    public let semanticSnapshots: [String: SemanticContextPayload]

    public init(
        events: [HistoryEvent],
        intervalStart: Date? = nil,
        intervalEnd: Date? = nil,
        generatedAt: Date = Date(),
        semanticSnapshots: [String: SemanticContextPayload] = [:]
    ) {
        self.events = events
        self.intervalStart = intervalStart
        self.intervalEnd = intervalEnd
        self.generatedAt = generatedAt
        self.semanticSnapshots = semanticSnapshots
    }
}

public protocol ActivitySummarizer {
    func summarize(_ input: ActivitySummaryInput) throws -> ActivityMemory
}

public enum ActivitySummarizerError: Error, Equatable {
    case noEvents
}

/// A deterministic, local summarizer. It never calls a model, never executes tools,
/// and never treats captured text as instructions. Its interpretations are explicitly
/// marked as inferred and always carry source-event provenance.
public struct DeterministicActivitySummarizer: ActivitySummarizer {
    public init() {}

    public func summarize(_ input: ActivitySummaryInput) throws -> ActivityMemory {
        let ordered = input.events.sorted { left, right in
            if left.timestamp == right.timestamp { return left.id < right.id }
            return left.timestamp < right.timestamp
        }
        guard !ordered.isEmpty else { throw ActivitySummarizerError.noEvents }

        let start = input.intervalStart ?? ordered.first!.timestamp
        let end = input.intervalEnd ?? ordered.last!.timestamp
        let captured = ordered.filter { $0.suppressionReason == nil }
        let suppressed = ordered.filter { $0.suppressionReason != nil }
        let semantic = captured.filter { ActivityMemoryUtilities.semanticText(from: $0, semanticSnapshots: input.semanticSnapshots) != nil }

        let applications = ActivityMemoryUtilities.rankedDistinct(captured.compactMap { $0.app?.name })
        let sites = ActivityMemoryUtilities.rankedDistinct(captured.compactMap { ActivityMemoryUtilities.normalizedHost($0.url?.host) })
        let actions = makeActionClaims(from: captured)
        let requests = makeRequestClaims(from: semantic, semanticSnapshots: input.semanticSnapshots)
        let gaps = makeCoverageGaps(from: suppressed)
        let unknowns = makeUnknownClaims(events: ordered, semanticEvents: semantic, gaps: gaps)
        let outcome = makeObservableOutcome(from: captured, semanticSnapshots: input.semanticSnapshots)
        let coverage = makeCoverage(
            all: ordered,
            captured: captured,
            suppressed: suppressed,
            semantic: semantic,
            gaps: gaps
        )

        let title = makeTitle(applications: applications, sites: sites)
        let summary = makeSummary(
            applications: applications,
            sites: sites,
            actions: actions,
            requests: requests,
            gaps: gaps
        )
        let aggregateClaim = ActivityClaim(
            text: summary,
            kind: .derived,
            confidence: 1,
            provenance: ActivityMemoryUtilities.provenance(for: captured)
        )
        let claims = [aggregateClaim] + actions + requests + (outcome.map { [$0] } ?? []) + unknowns

        return ActivityMemory(
            start: start,
            end: max(start, end),
            generatedAt: input.generatedAt,
            title: title,
            summary: summary,
            applications: applications,
            sites: sites,
            significantActions: actions,
            observedRequestsOrIntentions: requests,
            observableOutcome: outcome,
            unknowns: unknowns,
            claims: claims,
            coverage: coverage
        )
    }

    private func makeActionClaims(from events: [HistoryEvent]) -> [ActivityClaim] {
        let definitions: [(EventKind, String)] = [
            (.mouseClick, "click"),
            (.typingBurst, "typing burst"),
            (.scrollBurst, "scroll burst"),
            (.keyboardShortcut, "keyboard shortcut"),
            (.keyPressed, "navigation or special-key press"),
            (.windowChanged, "window change"),
            (.urlChanged, "page or URL change"),
            (.focusChanged, "focus change"),
            (.applicationActivated, "application activation"),
        ]
        var output: [ActivityClaim] = []
        for (kind, label) in definitions {
            let sources = events.filter { $0.kind == kind }
            guard !sources.isEmpty else { continue }
            let suffix = sources.count == 1 ? "" : "s"
            output.append(
                ActivityClaim(
                    text: "Observed \(sources.count) \(label)\(suffix).",
                    kind: .derived,
                    confidence: 1,
                    provenance: ActivityMemoryUtilities.provenance(for: sources)
                )
            )
        }
        return output
    }

    private func makeRequestClaims(
        from events: [HistoryEvent],
        semanticSnapshots: [String: SemanticContextPayload]
    ) -> [ActivityClaim] {
        var seen = Set<String>()
        var output: [ActivityClaim] = []
        for event in events {
            guard let text = ActivityMemoryUtilities.semanticText(from: event, semanticSnapshots: semanticSnapshots) else { continue }
            for line in ActivityMemoryUtilities.semanticLines(text) {
                guard ActivityMemoryUtilities.looksLikeRequestOrIntent(line) else { continue }
                let key = ActivityMemoryUtilities.normalized(line)
                guard seen.insert(key).inserted else { continue }
                output.append(
                    ActivityClaim(
                        text: "Potential request or intention visible in Accessibility context: \(ActivityMemoryUtilities.bounded(line, maximum: 320))",
                        kind: .inferred,
                        confidence: 0.62,
                        provenance: ActivityMemoryUtilities.provenance(for: [event])
                    )
                )
                if output.count >= 12 { return output }
            }
        }
        return output
    }

    private func makeObservableOutcome(
        from events: [HistoryEvent],
        semanticSnapshots: [String: SemanticContextPayload]
    ) -> ActivityClaim? {
        guard let event = events.last(where: { candidate in
            candidate.kind == .urlChanged
                || candidate.kind == .windowChanged
                || ActivityMemoryUtilities.semanticText(from: candidate, semanticSnapshots: semanticSnapshots) != nil
        }) else { return nil }

        var parts: [String] = []
        if let app = event.app?.name { parts.append(app) }
        if let window = event.window?.title, !window.isEmpty { parts.append(window) }
        if let host = ActivityMemoryUtilities.normalizedHost(event.url?.host) { parts.append(host) }
        if let semantic = ActivityMemoryUtilities.semanticText(from: event, semanticSnapshots: semanticSnapshots),
            let first = ActivityMemoryUtilities.semanticLines(semantic).first
        {
            parts.append(ActivityMemoryUtilities.bounded(first, maximum: 180))
        }
        guard !parts.isEmpty else { return nil }
        return ActivityClaim(
            text: "Last observable state in the interval: \(parts.joined(separator: " — ")).",
            kind: .observed,
            confidence: 1,
            provenance: ActivityMemoryUtilities.provenance(for: [event])
        )
    }

    private func makeUnknownClaims(
        events: [HistoryEvent],
        semanticEvents: [HistoryEvent],
        gaps: [ActivityCoverageGap]
    ) -> [ActivityClaim] {
        var output: [ActivityClaim] = []
        if semanticEvents.isEmpty {
            output.append(
                ActivityClaim(
                    text: "The exact content typed or read is unknown because no authorized semantic snapshot was captured.",
                    kind: .unknown,
                    confidence: 1,
                    provenance: ActivityMemoryUtilities.provenance(for: events)
                )
            )
        }
        if !gaps.isEmpty {
            output.append(
                ActivityClaim(
                    text: "Some periods are unknown because capture was suppressed or unavailable.",
                    kind: .unknown,
                    confidence: 1,
                    provenance: ActivityProvenance(
                        sourceEventIDs: gaps.flatMap { $0.provenance.sourceEventIDs },
                        sourceSequences: gaps.flatMap { $0.provenance.sourceSequences },
                        sourceEventHashes: gaps.flatMap { $0.provenance.sourceEventHashes }
                    )
                )
            )
        }
        output.append(
            ActivityClaim(
                text: "Foreground presence does not prove attention, identity, productivity or authorship.",
                kind: .unknown,
                confidence: 1,
                provenance: .none
            )
        )
        return output
    }

    private func makeCoverageGaps(from suppressedEvents: [HistoryEvent]) -> [ActivityCoverageGap] {
        let ordered = suppressedEvents.sorted { $0.timestamp < $1.timestamp }
        guard !ordered.isEmpty else { return [] }

        struct Builder {
            var reason: String
            var start: Date
            var end: Date
            var events: [HistoryEvent]
        }
        var builders: [Builder] = []
        for event in ordered {
            let reason = event.suppressionReason?.rawValue ?? "unknown"
            if var last = builders.popLast() {
                if last.reason == reason, event.timestamp.timeIntervalSince(last.end) <= 180 {
                    last.end = event.timestamp
                    last.events.append(event)
                    builders.append(last)
                } else {
                    builders.append(last)
                    builders.append(Builder(reason: reason, start: event.timestamp, end: event.timestamp, events: [event]))
                }
            } else {
                builders.append(Builder(reason: reason, start: event.timestamp, end: event.timestamp, events: [event]))
            }
        }
        return builders.map {
            ActivityCoverageGap(
                start: $0.start,
                end: max($0.start, $0.end),
                reason: $0.reason,
                provenance: ActivityMemoryUtilities.provenance(for: $0.events)
            )
        }
    }

    private func makeCoverage(
        all: [HistoryEvent],
        captured: [HistoryEvent],
        suppressed: [HistoryEvent],
        semantic: [HistoryEvent],
        gaps: [ActivityCoverageGap]
    ) -> ActivityMemoryCoverage {
        let integrity = all.compactMap { $0.integrity }
        return ActivityMemoryCoverage(
            sourceEventCount: all.count,
            capturedEventCount: captured.count,
            suppressedEventCount: suppressed.count,
            semanticSnapshotCount: semantic.count,
            firstSourceSequence: integrity.first?.sequence,
            lastSourceSequence: integrity.last?.sequence,
            lastSourceEventHash: integrity.last?.eventHash,
            gaps: gaps
        )
    }

    private func makeTitle(applications: [String], sites: [String]) -> String {
        if let app = applications.first, let site = sites.first {
            return "Activity in \(app) on \(site)"
        }
        if let app = applications.first { return "Activity in \(app)" }
        if let site = sites.first { return "Activity on \(site)" }
        return "Observed activity"
    }

    private func makeSummary(
        applications: [String],
        sites: [String],
        actions: [ActivityClaim],
        requests: [ActivityClaim],
        gaps: [ActivityCoverageGap]
    ) -> String {
        var sentences: [String] = []
        if !applications.isEmpty {
            sentences.append("Observed foreground activity in \(applications.prefix(4).joined(separator: ", ")).")
        } else {
            sentences.append("No foreground application was captured with usable context.")
        }
        if !sites.isEmpty {
            sentences.append("Observed sites: \(sites.prefix(4).joined(separator: ", ")).")
        }
        if !actions.isEmpty {
            sentences.append(actions.prefix(5).map(\.text).joined(separator: " "))
        }
        if !requests.isEmpty {
            sentences.append("Accessible text contained \(requests.count) possible request or intention candidate(s); these are interpretations, not verified authorship.")
        }
        if !gaps.isEmpty {
            sentences.append("\(gaps.count) capture gap(s) remain explicit.")
        }
        return sentences.joined(separator: " ")
    }
}

public enum ActivityMemoryMarkdownRenderer {
    public static func render(_ memory: ActivityMemory) -> String {
        var lines: [String] = [
            "# \(memory.title)",
            "",
            "- Interval: \(iso.string(from: memory.start)) → \(iso.string(from: memory.end))",
            "- Generated: \(iso.string(from: memory.generatedAt))",
            "- Coverage: \(memory.coverage.capturedEventCount)/\(memory.coverage.sourceEventCount) event rows observed; \(memory.coverage.gaps.count) explicit gap(s)",
            "",
            memory.summary,
            "",
        ]

        appendClaims(memory.significantActions, title: "Observed actions", to: &lines)
        appendClaims(memory.observedRequestsOrIntentions, title: "Requests or intentions", to: &lines)
        if let outcome = memory.observableOutcome {
            appendClaims([outcome], title: "Last observable state", to: &lines)
        }
        appendClaims(memory.unknowns, title: "Unknowns and limits", to: &lines)

        if !memory.coverage.gaps.isEmpty {
            lines.append("## Capture gaps")
            for gap in memory.coverage.gaps {
                lines.append("- \(iso.string(from: gap.start)) → \(iso.string(from: gap.end)): \(gap.reason) [sources: \(sourceLabel(gap.provenance))]")
            }
            lines.append("")
        }

        lines.append("## Security")
        lines.append(memory.securityNotice)
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private static func appendClaims(_ claims: [ActivityClaim], title: String, to lines: inout [String]) {
        guard !claims.isEmpty else { return }
        lines.append("## \(title)")
        for claim in claims {
            lines.append("- [\(claim.kind.rawValue), confidence \(Int((claim.confidence * 100).rounded()))%] \(claim.text) [sources: \(sourceLabel(claim.provenance))]")
        }
        lines.append("")
    }

    private static func sourceLabel(_ provenance: ActivityProvenance) -> String {
        if !provenance.sourceSequences.isEmpty {
            let sorted = provenance.sourceSequences.sorted()
            if sorted.count == 1 { return "seq \(sorted[0])" }
            return "seq \(sorted.first!)-\(sorted.last!)"
        }
        if !provenance.sourceEventIDs.isEmpty {
            return provenance.sourceEventIDs.prefix(3).joined(separator: ",")
        }
        return "none"
    }

    private static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

enum ActivityMemoryUtilities {
    static func semanticText(
        from event: HistoryEvent,
        semanticSnapshots: [String: SemanticContextPayload] = [:]
    ) -> String? {
        SemanticContextResolver.text(for: event, semanticSnapshots: semanticSnapshots)
    }
    
    static func provenance(for events: [HistoryEvent]) -> ActivityProvenance {
        let IDs = distinctPreservingOrder(events.map(\.id))
        let integrity = events.compactMap(\.integrity)
        return ActivityProvenance(
            sourceEventIDs: IDs,
            sourceSequences: distinctPreservingOrder(integrity.map(\.sequence)),
            sourceEventHashes: distinctPreservingOrder(integrity.map(\.eventHash))
        )
    }
    
    static func rankedDistinct(_ values: [String]) -> [String] {
        var counts: [String: Int] = [:]
        var firstIndex: [String: Int] = [:]
        for (index, raw) in values.enumerated() {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            counts[value, default: 0] += 1
            firstIndex[value, default: index] = min(firstIndex[value, default: index], index)
        }
        return counts.keys.sorted { left, right in
            if counts[left] == counts[right] {
                return firstIndex[left, default: 0] < firstIndex[right, default: 0]
            }
            return counts[left, default: 0] > counts[right, default: 0]
        }
    }
    
    static func normalizedHost(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let value = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
    
    static func semanticLines(_ text: String) -> [String] {
        text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 4 }
    }
    
    static func looksLikeRequestOrIntent(_ line: String) -> Bool {
        let normalizedLine = normalized(line)
        if normalizedLine.hasSuffix("?") { return true }
        let prefixes = [
            "please ", "can you ", "could you ", "would you ", "help me ",
            "create ", "build ", "write ", "explain ", "find ", "research ",
            "compare ", "summarize ", "review ", "fix ", "implement ",
            "je veux ", "peux-tu ", "pourrais-tu ", "aide-moi ", "crée ",
            "explique ", "cherche ", "compare ", "résume ", "corrige ",
            "implémente ",
        ]
        return prefixes.contains { normalizedLine.hasPrefix($0) }
    }
    
    static func normalized(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    static func bounded(_ value: String, maximum: Int) -> String {
        if value.count <= maximum { return value }
        return String(value.prefix(maximum)) + "…"
    }
    
    static func distinctPreservingOrder<T: Hashable>(_ values: [T]) -> [T] {
        var seen = Set<T>()
        return values.filter { seen.insert($0).inserted }
    }
}
