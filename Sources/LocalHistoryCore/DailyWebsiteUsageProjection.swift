import Foundation

public struct DailyWebsiteSourceUsage: Codable, Equatable, Identifiable, Sendable {
    public let applicationName: String
    public let bundleIdentifier: String?
    public let foregroundSeconds: TimeInterval
    public let eventCount: Int
    public let identityProofAvailable: Bool

    public var id: String {
        if let bundleIdentifier, !bundleIdentifier.isEmpty {
            return "bundle:\(bundleIdentifier.lowercased())"
        }
        return "name:\(applicationName.lowercased())"
    }

    public init(
        applicationName: String,
        bundleIdentifier: String?,
        foregroundSeconds: TimeInterval,
        eventCount: Int,
        identityProofAvailable: Bool
    ) {
        self.applicationName = applicationName
        self.bundleIdentifier = bundleIdentifier
        self.foregroundSeconds = max(0, foregroundSeconds)
        self.eventCount = max(0, eventCount)
        self.identityProofAvailable = identityProofAvailable
    }
}

public struct DailyWebsiteUsage: Codable, Equatable, Identifiable, Sendable {
    public let host: String
    public let foregroundSeconds: TimeInterval
    public let activeMinuteCount: Int
    public let eventCount: Int
    public let sourceApplications: [String]
    public let primaryBundleIdentifier: String?
    public let sourceUsage: [DailyWebsiteSourceUsage]
    public let category: String?
    public let identityProofAvailable: Bool

    public var id: String { host }

    private enum CodingKeys: String, CodingKey {
        case host
        case foregroundSeconds
        case activeMinuteCount
        case eventCount
        case sourceApplications
        case primaryBundleIdentifier
        case sourceUsage
        case category
        case identityProofAvailable
    }

    public init(
        host: String,
        foregroundSeconds: TimeInterval,
        activeMinuteCount: Int,
        eventCount: Int,
        sourceApplications: [String],
        primaryBundleIdentifier: String?,
        sourceUsage: [DailyWebsiteSourceUsage] = [],
        category: String?,
        identityProofAvailable: Bool
    ) {
        self.host = host
        self.foregroundSeconds = max(0, foregroundSeconds)
        self.activeMinuteCount = max(0, activeMinuteCount)
        self.eventCount = max(0, eventCount)
        self.sourceApplications = sourceApplications
        self.primaryBundleIdentifier = primaryBundleIdentifier
        self.sourceUsage = sourceUsage
        self.category = category
        self.identityProofAvailable = identityProofAvailable
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            host: try container.decode(String.self, forKey: .host),
            foregroundSeconds: try container.decode(
                TimeInterval.self,
                forKey: .foregroundSeconds
            ),
            activeMinuteCount: try container.decode(Int.self, forKey: .activeMinuteCount),
            eventCount: try container.decode(Int.self, forKey: .eventCount),
            sourceApplications: try container.decode([String].self, forKey: .sourceApplications),
            primaryBundleIdentifier: try container.decodeIfPresent(
                String.self,
                forKey: .primaryBundleIdentifier
            ),
            sourceUsage: try container.decodeIfPresent(
                [DailyWebsiteSourceUsage].self,
                forKey: .sourceUsage
            ) ?? [],
            category: try container.decodeIfPresent(String.self, forKey: .category),
            identityProofAvailable: try container.decode(
                Bool.self,
                forKey: .identityProofAvailable
            )
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(host, forKey: .host)
        try container.encode(foregroundSeconds, forKey: .foregroundSeconds)
        try container.encode(activeMinuteCount, forKey: .activeMinuteCount)
        try container.encode(eventCount, forKey: .eventCount)
        try container.encode(sourceApplications, forKey: .sourceApplications)
        try container.encodeIfPresent(primaryBundleIdentifier, forKey: .primaryBundleIdentifier)
        try container.encode(sourceUsage, forKey: .sourceUsage)
        try container.encodeIfPresent(category, forKey: .category)
        try container.encode(identityProofAvailable, forKey: .identityProofAvailable)
    }
}

/// Production safety envelope for the transient website projection. These
/// limits bound source work and retained metadata without persisting a second
/// copy of browsing history.
public struct DailyWebsiteUsageLimits: Equatable, Sendable {
    public static let production = DailyWebsiteUsageLimits(
        maximumHosts: 4_096,
        maximumSourceApplicationsPerHost: 8,
        maximumCategoriesPerHost: 8,
        maximumSourceRows: 200_000,
        maximumSourceBytes: 128 * 1_024 * 1_024,
        maximumRetainedBytes: 4 * 1_024 * 1_024,
        maximumReadSeconds: 10
    )

    package let maximumHosts: Int
    package let maximumSourceApplicationsPerHost: Int
    package let maximumCategoriesPerHost: Int
    package let maximumSourceRows: Int
    package let maximumSourceBytes: Int64
    package let maximumRetainedBytes: Int64
    package let maximumReadSeconds: TimeInterval

    package init(
        maximumHosts: Int,
        maximumSourceApplicationsPerHost: Int,
        maximumCategoriesPerHost: Int,
        maximumSourceRows: Int,
        maximumSourceBytes: Int64,
        maximumRetainedBytes: Int64,
        maximumReadSeconds: TimeInterval
    ) {
        self.maximumHosts = max(1, maximumHosts)
        self.maximumSourceApplicationsPerHost = max(1, maximumSourceApplicationsPerHost)
        self.maximumCategoriesPerHost = max(1, maximumCategoriesPerHost)
        self.maximumSourceRows = max(1, maximumSourceRows)
        self.maximumSourceBytes = max(1, maximumSourceBytes)
        self.maximumRetainedBytes = max(1, maximumRetainedBytes)
        self.maximumReadSeconds = max(0, maximumReadSeconds)
    }
}

/// Minimal row decoder for website aggregation. Unknown recorder payloads such
/// as window text, semantic context, messages and integrity commitments are
/// skipped by `JSONDecoder` instead of being allocated and immediately dropped.
struct DailyWebsiteUsageEventProjection: Decodable {
    private struct AppProjection: Decodable {
        let name: String
        let bundleIdentifier: String?
    }

    private struct URLProjection: Decodable {
        let value: String
        let host: String?
    }

    private struct ClassificationProjection: Decodable {
        let category: String
    }

    private struct MetadataProjection: Decodable {
        let idleSeconds: String?
        let accessibility: String?
        let inputMonitoring: String?
        let observationGap: String?

        private enum CodingKeys: String, CodingKey {
            case idleSeconds = "idle_seconds"
            case accessibility
            case inputMonitoring = "input_monitoring"
            case observationGap = "observation_gap"
        }

        var compactDictionary: [String: String]? {
            var values: [String: String] = [:]
            if let idleSeconds { values["idle_seconds"] = idleSeconds }
            if let accessibility { values["accessibility"] = accessibility }
            if let inputMonitoring { values["input_monitoring"] = inputMonitoring }
            if let observationGap { values["observation_gap"] = observationGap }
            return values.isEmpty ? nil : values
        }
    }

    let schemaVersion: Int
    let timestamp: Date
    let kind: EventKind
    private let app: AppProjection?
    private let url: URLProjection?
    private let hasPointer: Bool
    private let hasKeyboard: Bool
    private let hasScroll: Bool
    private let classification: ClassificationProjection?
    private let suppressionReason: SuppressionReason?
    private let metadata: MetadataProjection?

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case timestamp
        case kind
        case app
        case url
        case pointer
        case keyboard
        case scroll
        case classification
        case suppressionReason
        case metadata
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        kind = try container.decode(EventKind.self, forKey: .kind)
        app = try container.decodeIfPresent(AppProjection.self, forKey: .app)
        url = try container.decodeIfPresent(URLProjection.self, forKey: .url)
        hasPointer = try (
            container.contains(.pointer) && !container.decodeNil(forKey: .pointer)
        )
        hasKeyboard = try (
            container.contains(.keyboard) && !container.decodeNil(forKey: .keyboard)
        )
        hasScroll = try (
            container.contains(.scroll) && !container.decodeNil(forKey: .scroll)
        )
        classification = try container.decodeIfPresent(
            ClassificationProjection.self,
            forKey: .classification
        )
        suppressionReason = try container.decodeIfPresent(
            SuppressionReason.self,
            forKey: .suppressionReason
        )
        metadata = try container.decodeIfPresent(MetadataProjection.self, forKey: .metadata)
    }

    var historyEvent: HistoryEvent {
        let compactURL: URLSnapshot? = url.map {
            let scheme = URLComponents(string: $0.value)?.scheme?.lowercased()
            return URLSnapshot(
                value: scheme.map { "\($0)://" } ?? "",
                host: $0.host,
                redactionApplied: true
            )
        }
        return HistoryEvent(
            schemaVersion: schemaVersion,
            id: "",
            sessionID: "",
            timestamp: timestamp,
            kind: kind,
            app: app.map {
                AppSnapshot(
                    name: $0.name,
                    bundleIdentifier: $0.bundleIdentifier,
                    processIdentifier: 0
                )
            },
            url: compactURL,
            pointer: hasPointer
                ? PointerSnapshot(button: "", x: 0, y: 0, clickCount: 0)
                : nil,
            keyboard: hasKeyboard
                ? KeyboardSnapshot(category: "", key: nil, modifiers: [], isRepeat: false)
                : nil,
            scroll: hasScroll
                ? ScrollSnapshot(deltaX: 0, deltaY: 0, eventCount: 0)
                : nil,
            classification: classification.map {
                LocalClassification(
                    category: $0.category,
                    isWork: nil,
                    confidence: 0,
                    classifierVersion: ""
                )
            },
            suppressionReason: suppressionReason,
            metadata: metadata?.compactDictionary
        )
    }
}

/// One-pass, transient website projection shared by the app and read-only CLI.
/// It retains only domains and bounded counters; full URLs, titles and page text
/// never enter the result and nothing is persisted.
public struct DailyWebsiteUsageAccumulator {
    private struct SourceCounter {
        let applicationName: String
        let bundleIdentifier: String?
        var foregroundSeconds: TimeInterval = 0
        var eventCount = 0
        var identityProofAvailable = true
    }

    private struct Counter {
        var foregroundSeconds: TimeInterval = 0
        var activeMinuteCount = 0
        var activeMinuteWords: [UInt64]?
        var eventCount = 0
        var sourceCounters: [String: SourceCounter] = [:]
        var categories: [String: Int] = [:]
        var identityProofAvailable = true
    }

    private static let maximumHostBytes = 253
    private static let maximumApplicationNameBytes = 128
    private static let maximumBundleIdentifierBytes = 255
    private static let maximumCategoryBytes = 64
    private static let estimatedCounterBytes: Int64 = 256
    private static let estimatedSourceCounterBytes: Int64 = 64
    private static let estimatedStoredStringOverheadBytes: Int64 = 64

    private let dayStart: Date
    private let dayEnd: Date
    private let currentTime: Date
    private let limits: DailyWebsiteUsageLimits
    private let activeMinuteWordCount: Int
    private var counters: [String: Counter] = [:]
    private var pendingEvent: HistoryEvent?
    private var isFinished = false
    private var retainedEstimatedBytes: Int64 = 0

    public private(set) var sourceEventCount = 0
    public private(set) var wasTruncated = false
    public private(set) var peakEstimatedRetainedBytes: Int64 = 0

    public init(
        day: Date,
        currentTime: Date = Date(),
        calendar: Calendar = .current,
        limits: DailyWebsiteUsageLimits = .production
    ) {
        dayStart = calendar.startOfDay(for: day)
        dayEnd = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day))
            ?? calendar.startOfDay(for: day).addingTimeInterval(86_400)
        self.currentTime = currentTime
        self.limits = limits
        let minuteSlotCount = max(
            1,
            min(1_600, Int(ceil(dayEnd.timeIntervalSince(dayStart) / 60)))
        )
        activeMinuteWordCount = (minuteSlotCount + 63) / 64
    }

    /// Events must arrive in source timestamp order. Every event remains a time
    /// boundary even when it is not itself eligible for website attribution.
    public mutating func ingest(_ event: HistoryEvent) {
        guard !isFinished,
            event.timestamp >= dayStart,
            event.timestamp < dayEnd
        else { return }
        guard sourceEventCount < limits.maximumSourceRows else {
            wasTruncated = true
            return
        }
        if let pendingEvent {
            // File sequence is authoritative. Rare recorder clock jitter must
            // not reject an otherwise complete day, so a backwards timestamp
            // contributes a zero-length boundary instead of negative time.
            attribute(pendingEvent, until: max(pendingEvent.timestamp, event.timestamp))
        }
        pendingEvent = event
        sourceEventCount += 1
    }

    public mutating func finish() -> [DailyWebsiteUsage] {
        if !isFinished, let pendingEvent {
            let isCurrentDay = currentTime >= dayStart && currentTime < dayEnd
            let tailEnd = isCurrentDay
                ? min(currentTime, dayEnd)
                : min(pendingEvent.timestamp.addingTimeInterval(60), dayEnd)
            attribute(pendingEvent, until: tailEnd)
        }
        pendingEvent = nil
        isFinished = true

        return counters.map { host, counter in
            let sourceUsage = counter.sourceCounters.values
                .map {
                    DailyWebsiteSourceUsage(
                        applicationName: $0.applicationName,
                        bundleIdentifier: $0.bundleIdentifier,
                        foregroundSeconds: $0.foregroundSeconds,
                        eventCount: $0.eventCount,
                        identityProofAvailable: $0.identityProofAvailable
                    )
                }
                .sorted { left, right in
                    if left.foregroundSeconds != right.foregroundSeconds {
                        return left.foregroundSeconds > right.foregroundSeconds
                    }
                    if left.eventCount != right.eventCount {
                        return left.eventCount > right.eventCount
                    }
                    return left.applicationName.localizedCaseInsensitiveCompare(
                        right.applicationName
                    ) == .orderedAscending
                }
            let applications = sourceUsage.map(\.applicationName)
            let category = counter.categories.max { left, right in
                if left.value == right.value { return left.key > right.key }
                return left.value < right.value
            }?.key
            return DailyWebsiteUsage(
                host: host,
                foregroundSeconds: counter.foregroundSeconds,
                activeMinuteCount: counter.activeMinuteCount,
                eventCount: counter.eventCount,
                sourceApplications: applications,
                primaryBundleIdentifier: sourceUsage.first?.bundleIdentifier,
                sourceUsage: sourceUsage,
                category: category,
                identityProofAvailable: counter.identityProofAvailable
            )
        }.filter {
            $0.foregroundSeconds > 0 || $0.eventCount > 0
        }.sorted {
            if $0.foregroundSeconds == $1.foregroundSeconds {
                return $0.host.localizedCaseInsensitiveCompare($1.host) == .orderedAscending
            }
            return $0.foregroundSeconds > $1.foregroundSeconds
        }
    }

    public static func trackedHost(from snapshot: URLSnapshot?) -> String? {
        guard let snapshot,
            let host = displayableHost(snapshot.host)
        else { return nil }

        let rawURL = snapshot.value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !rawURL.isEmpty,
            let scheme = URLComponents(string: rawURL)?.scheme?.lowercased(),
            !scheme.isEmpty,
            scheme != "http",
            scheme != "https"
        {
            return nil
        }
        return host
    }

    public static func displayableHost(_ host: String?) -> String? {
        guard var value = host?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        else { return nil }
        while value.hasSuffix(".") { value.removeLast() }
        if value.hasPrefix("www.") { value.removeFirst(4) }
        guard !value.isEmpty,
            value.utf8.count <= maximumHostBytes,
            value != "-",
            value.range(
                of: #"^[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?$"#,
                options: .regularExpression
            ) != nil,
            !value.contains("..")
        else { return nil }
        return value
    }

    private mutating func attribute(_ event: HistoryEvent, until nextTimestamp: Date) {
        guard event.kind != .agentArtifactCaptured,
            event.suppressionReason == nil,
            let app = event.app,
            Self.isActiveUsageEvidence(event),
            let host = Self.trackedHost(from: event.url)
        else { return }

        if counters[host] == nil {
            guard counters.count < limits.maximumHosts,
                reserveRetainedBytes(
                    Self.estimatedCounterBytes + Int64(host.utf8.count)
                )
            else {
                wasTruncated = true
                return
            }
        }

        let observedSeconds = min(
            75,
            max(0, min(nextTimestamp, dayEnd).timeIntervalSince(event.timestamp))
        )
        var counter = counters[host] ?? Counter()
        counter.foregroundSeconds += observedSeconds
        counter.eventCount += 1
        if let applicationName = boundedStoredString(
            app.name,
            maximumBytes: Self.maximumApplicationNameBytes
        ) {
            let bundleIdentifier = boundedStoredString(
                app.bundleIdentifier,
                maximumBytes: Self.maximumBundleIdentifierBytes
            )
            let sourceKey = Self.sourceKey(
                applicationName: applicationName,
                bundleIdentifier: bundleIdentifier
            )
            if var source = counter.sourceCounters[sourceKey] {
                source.foregroundSeconds += observedSeconds
                source.eventCount += 1
                if event.schemaVersion < 3 { source.identityProofAvailable = false }
                counter.sourceCounters[sourceKey] = source
            } else if counter.sourceCounters.count < limits.maximumSourceApplicationsPerHost {
                let retainedBytes = Self.estimatedSourceCounterBytes
                    + Self.estimatedStoredStringOverheadBytes
                    + Int64(applicationName.utf8.count)
                    + Self.estimatedStoredStringOverheadBytes
                    + Int64(sourceKey.utf8.count)
                    + (bundleIdentifier.map {
                        Self.estimatedStoredStringOverheadBytes + Int64($0.utf8.count)
                    } ?? 0)
                if reserveRetainedBytes(retainedBytes) {
                    counter.sourceCounters[sourceKey] = SourceCounter(
                        applicationName: applicationName,
                        bundleIdentifier: bundleIdentifier,
                        foregroundSeconds: observedSeconds,
                        eventCount: 1,
                        identityProofAvailable: event.schemaVersion >= 3
                    )
                } else {
                    wasTruncated = true
                }
            } else {
                wasTruncated = true
            }
        }
        if event.pointer != nil || event.keyboard != nil || event.scroll != nil {
            let minuteSlot = Int(floor(event.timestamp.timeIntervalSince(dayStart) / 60))
            if minuteSlot >= 0, minuteSlot < activeMinuteWordCount * 64 {
                if counter.activeMinuteWords == nil {
                    let estimatedBitmapBytes = Int64(64 + activeMinuteWordCount * 8)
                    if reserveRetainedBytes(estimatedBitmapBytes) {
                        counter.activeMinuteWords = [UInt64](
                            repeating: 0,
                            count: activeMinuteWordCount
                        )
                    } else {
                        wasTruncated = true
                    }
                }
                if counter.activeMinuteWords != nil {
                    let wordIndex = minuteSlot / 64
                    let mask = UInt64(1) << UInt64(minuteSlot % 64)
                    if counter.activeMinuteWords![wordIndex] & mask == 0 {
                        counter.activeMinuteWords![wordIndex] |= mask
                        counter.activeMinuteCount += 1
                    }
                }
            }
        }
        if let category = boundedStoredString(
            event.classification?.category,
            maximumBytes: Self.maximumCategoryBytes
        ) {
            if counter.categories[category] != nil {
                counter.categories[category, default: 0] += 1
            } else if counter.categories.count < limits.maximumCategoriesPerHost {
                if reserveRetainedBytes(
                    Self.estimatedStoredStringOverheadBytes + Int64(category.utf8.count)
                ) {
                    counter.categories[category] = 1
                } else {
                    wasTruncated = true
                }
            } else {
                wasTruncated = true
            }
        }
        if event.schemaVersion < 3 { counter.identityProofAvailable = false }
        counters[host] = counter
    }

    private static func sourceKey(
        applicationName: String,
        bundleIdentifier: String?
    ) -> String {
        if let bundleIdentifier, !bundleIdentifier.isEmpty {
            return "bundle:\(bundleIdentifier.lowercased())"
        }
        let normalizedName = applicationName
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
        return "name:\(normalizedName)"
    }

    private mutating func reserveRetainedBytes(_ requestedBytes: Int64) -> Bool {
        let bounded = max(0, requestedBytes)
        guard bounded <= limits.maximumRetainedBytes - retainedEstimatedBytes else {
            return false
        }
        retainedEstimatedBytes += bounded
        peakEstimatedRetainedBytes = max(peakEstimatedRetainedBytes, retainedEstimatedBytes)
        return true
    }

    private mutating func boundedStoredString(
        _ value: String?,
        maximumBytes: Int
    ) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
            !trimmed.isEmpty
        else { return nil }
        guard trimmed.utf8.count <= maximumBytes else {
            wasTruncated = true
            return nil
        }
        return trimmed
    }

    private static func isActiveUsageEvidence(_ event: HistoryEvent) -> Bool {
        guard event.kind == .heartbeat else { return true }
        guard let rawIdleSeconds = event.metadata?["idle_seconds"],
            let idleSeconds = Double(rawIdleSeconds)
        else { return false }
        return idleSeconds < 90
    }
}
