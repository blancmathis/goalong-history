#if os(macOS)
    import Darwin
    import Foundation
    import LocalHistoryCore

    struct ShareMinuteRow {
        let anchorSequence: UInt64
        let start: Date
        let end: Date
        let appSummary: String
        let categorySummary: String
        let canRevealDetails: Bool
        var level: ShareLevel
    }

    enum ShareBuildError: Error, CustomStringConvertible {
        case noSeals
        case brokenSeal(UInt64)
        case missingEvents(UInt64)
        case brokenEvent(String)
        case cancelled
        case sourceIncomplete(String)

        var description: String {
            switch self {
            case .noSeals: return "No sealed minutes are available for this day."
            case .brokenSeal(let sequence): return "Minute seal \(sequence) failed local integrity validation."
            case .missingEvents(let sequence):
                return
                    "The detailed events for minute seal \(sequence) are no longer available. Use Completely private for that minute."
            case .brokenEvent(let root): return "Event \(root.prefix(12))… failed local integrity validation."
            case .cancelled: return "Share loading was cancelled."
            case .sourceIncomplete(let detail): return "Share source is incomplete: \(detail)"
            }
        }
    }

    struct ShareEventReadLimits: Equatable {
        var maximumSourceBytes: Int64 = 384 * 1_024 * 1_024
        var maximumLineBytes = 2 * 1_024 * 1_024
        var maximumRequiredRoots = 131_072
        var maximumRetainedSummaryBytes: Int64 = 32 * 1_024 * 1_024
        var maximumRetainedEventBytes: Int64 = 256 * 1_024 * 1_024
        var maximumSealRows = 2_880
        var maximumAuxiliaryFiles = 4_096
        var maximumAuxiliaryRows = 262_144
        var maximumAuxiliaryBytes: Int64 = 256 * 1_024 * 1_024
        var maximumCachedDays = 2
        var readChunkBytes = 256 * 1_024

        static let production = ShareEventReadLimits()

        func validated() -> ShareEventReadLimits {
            ShareEventReadLimits(
                maximumSourceBytes: min(max(1, maximumSourceBytes), 512 * 1_024 * 1_024),
                maximumLineBytes: min(max(1, maximumLineBytes), 8 * 1_024 * 1_024),
                maximumRequiredRoots: min(max(1, maximumRequiredRoots), 262_144),
                maximumRetainedSummaryBytes: min(
                    max(1, maximumRetainedSummaryBytes),
                    64 * 1_024 * 1_024
                ),
                maximumRetainedEventBytes: min(
                    max(1, maximumRetainedEventBytes),
                    384 * 1_024 * 1_024
                ),
                maximumSealRows: min(max(1, maximumSealRows), 4_320),
                maximumAuxiliaryFiles: min(max(1, maximumAuxiliaryFiles), 16_384),
                maximumAuxiliaryRows: min(max(1, maximumAuxiliaryRows), 1_048_576),
                maximumAuxiliaryBytes: min(
                    max(1, maximumAuxiliaryBytes),
                    1_024 * 1_024 * 1_024
                ),
                maximumCachedDays: min(max(1, maximumCachedDays), 4),
                readChunkBytes: min(max(4 * 1_024, readChunkBytes), 1 * 1_024 * 1_024)
            )
        }
    }

    struct ShareEventReadDiagnostics: Equatable {
        var bytesRead: Int64 = 0
        var decodedRows = 0
        var retainedSummaries = 0
        var retainedEstimatedBytes: Int64 = 0
        var usedWarmCache = false
        var usedAppendScan = false
        var usedFullScan = false
    }

    final class SharePackageBuilder {
        typealias DayFileURL = (Date) -> URL

        private struct FileIdentity: Equatable {
            let device: UInt64
            let inode: UInt64
            let size: Int64
            let modificationSeconds: Int64
            let modificationNanoseconds: Int64
            let changeSeconds: Int64
            let changeNanoseconds: Int64

            var stableFileIdentity: String { "\(device):\(inode)" }
        }

        private struct EventSummary {
            let application: String?
            let category: String?
        }

        private struct EventSummaryCacheEntry {
            var identity: FileIdentity
            var tailFingerprint: String
            var coveredRoots: Set<String>
            var summaries: [String: EventSummary]
            var estimatedBytes: Int64
            var lastAccess: UInt64
        }

        private struct JSONLScanOutcome {
            let identity: FileIdentity
            let bytesRead: Int64
            let decodedRows: Int
            let tailFingerprint: String
        }

        private enum JSONLScanError: Error {
            case cachedPrefixChanged
        }

        private let eventFileURL: DayFileURL
        private let sealFileURL: DayFileURL
        private let sealsDirectory: URL
        private let receiptsDirectory: URL
        private let limits: ShareEventReadLimits
        private let afterSourceReadForTesting: ((URL) throws -> Void)?
        private let cacheLock = NSLock()
        private var eventSummaryCache: [String: EventSummaryCacheEntry] = [:]
        private var accessSequence: UInt64 = 0
        private var latestReadDiagnostics = ShareEventReadDiagnostics()

        init(
            eventFileURL: @escaping DayFileURL = AppPaths.eventFileURL,
            sealFileURL: @escaping DayFileURL = AppPaths.sealFileURL,
            sealsDirectory: URL = AppPaths.sealsDirectory,
            receiptsDirectory: URL = AppPaths.receiptsDirectory,
            limits: ShareEventReadLimits = .production,
            afterSourceReadForTesting: ((URL) throws -> Void)? = nil
        ) {
            self.eventFileURL = eventFileURL
            self.sealFileURL = sealFileURL
            self.sealsDirectory = sealsDirectory.standardizedFileURL
            self.receiptsDirectory = receiptsDirectory.standardizedFileURL
            self.limits = limits.validated()
            self.afterSourceReadForTesting = afterSourceReadForTesting
        }

        var readDiagnostics: ShareEventReadDiagnostics {
            cacheLock.lock()
            defer { cacheLock.unlock() }
            return latestReadDiagnostics
        }

        func discardTransientCaches() {
            cacheLock.lock()
            eventSummaryCache.removeAll(keepingCapacity: false)
            latestReadDiagnostics = ShareEventReadDiagnostics()
            cacheLock.unlock()
        }

        func minuteRows(
            for day: Date = Date(),
            cancellation: @escaping () -> Bool = { false }
        ) throws -> [ShareMinuteRow] {
            let seals = try loadSeals(for: day, cancellation: cancellation)
            guard !seals.isEmpty else { throw ShareBuildError.noSeals }
            let requiredRoots = try requiredRootSet(for: seals, cancellation: cancellation)
            let summaries = try loadEventSummaries(
                for: day,
                requiredRoots: requiredRoots,
                cancellation: cancellation
            )

            return try seals.map { seal in
                guard !cancellation() else { throw ShareBuildError.cancelled }
                let available = seal.eventRoots.allSatisfy { summaries[$0] != nil }
                let minuteEvents = seal.eventRoots.compactMap { summaries[$0] }
                let apps = uniqueValues(minuteEvents.compactMap(\.application).filter { !$0.isEmpty })
                let categories = uniqueValues(minuteEvents.compactMap(\.category).filter { !$0.isEmpty })
                return ShareMinuteRow(
                    anchorSequence: seal.anchorSequence,
                    start: seal.minuteStart,
                    end: seal.minuteEnd,
                    appSummary: apps.isEmpty ? "—" : apps.joined(separator: ", "),
                    categorySummary: categories.isEmpty ? "—" : categories.joined(separator: ", "),
                    canRevealDetails: available,
                    level: available ? .applicationOnly : .privateOnly
                )
            }
        }

        func build(
            for day: Date = Date(),
            levels: [UInt64: ShareLevel],
            cancellation: @escaping () -> Bool = { false }
        ) throws -> DaySharePackage {
            let seals = try loadSeals(for: day, cancellation: cancellation)
            guard let first = seals.first, let last = seals.last else { throw ShareBuildError.noSeals }
            try validateSealChain(seals, cancellation: cancellation)
            let deviceIDs = uniqueValues(seals.map(\.deviceID))

            let eventsByRoot = try loadEventsByRoot(
                for: day,
                requiredRoots: try requiredRootSet(for: seals, cancellation: cancellation),
                cancellation: cancellation
            )
            let boundarySeals = try loadBoundarySeals(
                for: day,
                seals: seals,
                cancellation: cancellation
            )
            try validateBoundarySeals(boundarySeals, first: first, last: last)
            let receiptSequences = Set(
                seals.map(\.anchorSequence)
                    + [boundarySeals.before?.anchorSequence, boundarySeals.after?.anchorSequence]
                    .compactMap { $0 }
            )
            let receipts = try loadReceiptsBySequence(
                requiredSequences: receiptSequences,
                cancellation: cancellation
            )
            let disclosures = try seals.map { seal in
                guard !cancellation() else { throw ShareBuildError.cancelled }
                return try makeDisclosure(
                    seal: seal,
                    level: levels[seal.anchorSequence] ?? .privateOnly,
                    eventLevel: nil,
                    eventsByRoot: eventsByRoot,
                    receipts: receipts
                )
            }

            // Boundary proofs prevent a user from silently dropping the first/last bad minutes of a calendar day.
            // They reveal only time + coverage for the immediately adjacent anchor, never its event structure.
            let boundaryBefore: MinuteDisclosure?
            if let seal = boundarySeals.before {
                boundaryBefore = try makeDisclosure(
                    seal: seal, level: .privateOnly, eventLevel: nil, eventsByRoot: [:], receipts: receipts)
            } else {
                boundaryBefore = nil
            }
            let boundaryAfter: MinuteDisclosure?
            if let seal = boundarySeals.after {
                boundaryAfter = try makeDisclosure(
                    seal: seal, level: .privateOnly, eventLevel: nil, eventsByRoot: [:], receipts: receipts)
            } else {
                boundaryAfter = nil
            }

            return DaySharePackage(
                schemaVersion: deviceIDs.count > 1 ? 4 : 2,
                deviceID: first.deviceID,
                deviceIDs: deviceIDs,
                localDay: AppPaths.localDayString(for: day),
                classifierVersion: LocalClassifier.version,
                boundaryBefore: boundaryBefore,
                boundaryAfter: boundaryAfter,
                minutes: disclosures
            )
        }

        func build(
            for day: Date = Date(),
            sharingRules: [String: SharingVisibility],
            defaultVisibility: SharingVisibility,
            cancellation: @escaping () -> Bool = { false }
        ) throws -> DaySharePackage {
            let seals = try loadSeals(for: day, cancellation: cancellation)
            guard let first = seals.first, let last = seals.last else { throw ShareBuildError.noSeals }
            try validateSealChain(seals, cancellation: cancellation)
            let deviceIDs = uniqueValues(seals.map(\.deviceID))

            let eventsByRoot = try loadEventsByRoot(
                for: day,
                requiredRoots: try requiredRootSet(for: seals, cancellation: cancellation),
                cancellation: cancellation
            )
            let boundarySeals = try loadBoundarySeals(
                for: day,
                seals: seals,
                cancellation: cancellation
            )
            try validateBoundarySeals(boundarySeals, first: first, last: last)
            let receiptSequences = Set(
                seals.map(\.anchorSequence)
                    + [boundarySeals.before?.anchorSequence, boundarySeals.after?.anchorSequence]
                    .compactMap { $0 }
            )
            let receipts = try loadReceiptsBySequence(
                requiredSequences: receiptSequences,
                cancellation: cancellation
            )
            let eventLevel: (HistoryEvent) -> ShareLevel = { event in
                guard let subject = SharingSubjectKey.forEvent(event) else { return .privateOnly }
                let visibility = sharingRules[subject] ?? defaultVisibility
                if event.url?.host != nil, visibility == .identity, event.schemaVersion < 3 {
                    // v2 committed the host together with the complete URL and window context.
                    // Category-only is the strongest safe identity fallback for those old events.
                    return .categoryOnly
                }
                return visibility.shareLevel
            }
            let disclosures = try seals.map { seal in
                guard !cancellation() else { throw ShareBuildError.cancelled }
                return try makeDisclosure(
                    seal: seal,
                    level: .mixed,
                    eventLevel: eventLevel,
                    eventsByRoot: eventsByRoot,
                    receipts: receipts
                )
            }

            let boundaryBefore: MinuteDisclosure?
            if let seal = boundarySeals.before {
                boundaryBefore = try makeDisclosure(
                    seal: seal, level: .privateOnly, eventLevel: nil, eventsByRoot: [:], receipts: receipts)
            } else {
                boundaryBefore = nil
            }
            let boundaryAfter: MinuteDisclosure?
            if let seal = boundarySeals.after {
                boundaryAfter = try makeDisclosure(
                    seal: seal, level: .privateOnly, eventLevel: nil, eventsByRoot: [:], receipts: receipts)
            } else {
                boundaryAfter = nil
            }

            return DaySharePackage(
                schemaVersion: deviceIDs.count > 1 ? 4 : 3,
                deviceID: first.deviceID,
                deviceIDs: deviceIDs,
                localDay: AppPaths.localDayString(for: day),
                classifierVersion: LocalClassifier.version,
                boundaryBefore: boundaryBefore,
                boundaryAfter: boundaryAfter,
                minutes: disclosures
            )
        }

        func write(
            _ package: DaySharePackage,
            to url: URL,
            cancellation: () -> Bool = { false }
        ) throws {
            guard !cancellation() else { throw ShareBuildError.cancelled }
            let output = JSONEncoder()
            output.dateEncodingStrategy = .iso8601
            output.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try output.encode(package)
            guard !cancellation() else { throw ShareBuildError.cancelled }
            try data.write(to: url, options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }

        private func makeDisclosure(
            seal: LocalMinuteSeal,
            level: ShareLevel,
            eventLevel: ((HistoryEvent) -> ShareLevel)?,
            eventsByRoot: [String: HistoryEvent],
            receipts: [UInt64: AnchorReceipt]
        ) throws -> MinuteDisclosure {
            guard verifyLocalSeal(seal) else { throw ShareBuildError.brokenSeal(seal.anchorSequence) }

            let resolvedEvents = seal.eventRoots.compactMap { eventsByRoot[$0] }
            let hasEveryEvent = resolvedEvents.count == seal.eventRoots.count
            let eventLevels: [ShareLevel]
            let resolvedMinuteLevel: ShareLevel
            if let eventLevel {
                guard hasEveryEvent else {
                    throw ShareBuildError.missingEvents(seal.anchorSequence)
                }
                eventLevels = resolvedEvents.map(eventLevel)
                let uniqueLevels = Set(eventLevels)
                if eventLevels.isEmpty || uniqueLevels == [.privateOnly] {
                    resolvedMinuteLevel = .privateOnly
                } else if uniqueLevels.count == 1, let only = uniqueLevels.first {
                    resolvedMinuteLevel = only
                } else {
                    resolvedMinuteLevel = .mixed
                }
            } else {
                eventLevels = Array(repeating: level, count: seal.eventRoots.count)
                resolvedMinuteLevel = level
            }

            let minuteFields = seal.minuteFields.map { field -> FieldDisclosure in
                let revealOpening: Bool
                switch field.name {
                case "time", "coverage":
                    revealOpening = true
                case "events_root", "event_count":
                    revealOpening = resolvedMinuteLevel != .privateOnly
                default:
                    revealOpening = false
                }
                return FieldDisclosure(
                    name: field.name,
                    commitmentHex: field.commitmentHex,
                    opening: revealOpening ? field.opening : nil
                )
            }

            var eventRoots: [String]? = nil
            var eventDisclosures: [EventDisclosure]? = nil
            if resolvedMinuteLevel != .privateOnly {
                var built: [EventDisclosure] = []
                for (index, root) in seal.eventRoots.enumerated() {
                    guard let event = eventsByRoot[root] else {
                        throw ShareBuildError.missingEvents(seal.anchorSequence)
                    }
                    guard verifyLocalEvent(event) else { throw ShareBuildError.brokenEvent(root) }

                    let resolvedEventLevel = eventLevels[index]

                    let commitments = event.integrity?.fieldCommitments ?? []
                    let fields = commitments.map { field -> FieldDisclosure in
                        let reveal: Bool
                        switch resolvedEventLevel {
                        case .everything:
                            reveal = true
                        case .applicationOnly:
                            let identityField =
                                event.url?.host != nil && event.schemaVersion >= 3
                                ? "website" : "application"
                            reveal = ["time", identityField, "coverage", "trust"].contains(field.name)
                        case .categoryOnly:
                            reveal = ["time", "classification", "coverage", "trust"].contains(field.name)
                        case .privateOnly:
                            reveal = false
                        case .mixed:
                            reveal = false
                        }
                        return FieldDisclosure(
                            name: field.name,
                            commitmentHex: field.commitmentHex,
                            opening: reveal ? field.opening : nil
                        )
                    }
                    built.append(
                        EventDisclosure(
                            eventRoot: root,
                            fieldCommitments: fields,
                            rawEvent: nil,
                            schemaVersion: event.schemaVersion,
                            shareLevel: resolvedEventLevel
                        ))
                }
                eventRoots = seal.eventRoots
                eventDisclosures = built
            }

            let receipt = receipts[seal.anchorSequence].flatMap { candidate in
                candidate.deviceID == seal.deviceID && candidate.anchorHash == seal.anchorHash
                    ? candidate : nil
            }
            let disclosure = MinuteDisclosure(
                anchorSequence: seal.anchorSequence,
                minuteRoot: seal.minuteRoot,
                previousAnchorHash: seal.previousAnchorHash,
                anchorHash: seal.anchorHash,
                shareLevel: resolvedMinuteLevel,
                minuteFields: minuteFields,
                eventRoots: eventRoots,
                events: eventDisclosures,
                signatureBase64: seal.signatureBase64,
                signatureAlgorithm: seal.signatureAlgorithm,
                publicKeyBase64: seal.publicKeyBase64,
                deviceID: seal.deviceID,
                trustTier: receipt?.appAttestAccepted == true ? "app_attest" : seal.trustTier,
                liveReceiptID: receipt?.receiptID
            )
            guard disclosure.verifiesStructure() else { throw ShareBuildError.brokenSeal(seal.anchorSequence) }
            return disclosure
        }

        private func verifyLocalSeal(_ seal: LocalMinuteSeal) -> Bool {
            guard seal.minuteFields.allSatisfy({ $0.opening.commitmentHex() == $0.commitmentHex }) else { return false }
            guard let byName = commitmentsByUniqueName(seal.minuteFields) else { return false }
            let leaves = IntegrityDomains.minuteFieldOrder.compactMap { name -> (String, String)? in
                guard let value = byName[name] else { return nil }
                return (name, value)
            }
            guard leaves.count == IntegrityDomains.minuteFieldOrder.count else { return false }
            guard MerkleTree.root(labeledHexValues: leaves) == seal.minuteRoot else { return false }
            guard
                ChainHash.anchor(
                    sequence: seal.anchorSequence, previous: seal.previousAnchorHash, minuteRoot: seal.minuteRoot)
                    == seal.anchorHash
            else { return false }
            let eventsRoot = MerkleTree.root(
                labeledHexValues: seal.eventRoots.enumerated().map { ("event:\($0.offset)", $0.element) })
            guard let rootField = seal.minuteFields.first(where: { $0.name == "events_root" }),
                rootField.opening.fields["events_root"] == eventsRoot,
                let countField = seal.minuteFields.first(where: { $0.name == "event_count" }),
                countField.opening.fields["count"] == String(seal.eventRoots.count)
            else { return false }
            return true
        }

        private func verifyLocalEvent(_ event: HistoryEvent) -> Bool {
            guard let integrity = event.integrity else { return false }
            guard integrity.fieldCommitments.allSatisfy({ $0.opening.commitmentHex() == $0.commitmentHex }) else {
                return false
            }
            guard let byName = commitmentsByUniqueName(integrity.fieldCommitments) else { return false }
            let fieldOrder = IntegrityDomains.eventFieldOrder(for: event.schemaVersion)
            let leaves = fieldOrder.compactMap { name -> (String, String)? in
                guard let value = byName[name] else { return nil }
                return (name, value)
            }
            guard leaves.count == fieldOrder.count else { return false }
            guard MerkleTree.root(labeledHexValues: leaves) == integrity.eventRoot else { return false }
            return ChainHash.event(
                sequence: integrity.sequence, previous: integrity.previousEventHash, eventRoot: integrity.eventRoot)
                == integrity.eventHash
        }

        private func openingFields(_ event: HistoryEvent, name: String) -> [String: String]? {
            event.integrity?.fieldCommitments.first(where: { $0.name == name })?.opening.fields
        }

        private func commitmentsByUniqueName(
            _ commitments: [LocalFieldCommitment]
        ) -> [String: String]? {
            var byName: [String: String] = [:]
            byName.reserveCapacity(commitments.count)
            for commitment in commitments {
                guard byName.updateValue(commitment.commitmentHex, forKey: commitment.name) == nil else {
                    return nil
                }
            }
            return byName
        }

        private func validateSealChain(
            _ seals: [LocalMinuteSeal],
            cancellation: () -> Bool
        ) throws {
            for (current, next) in zip(seals, seals.dropFirst()) {
                guard !cancellation() else { throw ShareBuildError.cancelled }
                guard current.anchorSequence < UInt64.max,
                    next.anchorSequence == current.anchorSequence + 1,
                    next.previousAnchorHash == current.anchorHash
                else {
                    throw ShareBuildError.sourceIncomplete(
                        "seal chain breaks between anchors \(current.anchorSequence) and \(next.anchorSequence)"
                    )
                }
            }
        }

        private func validateBoundarySeals(
            _ boundaries: (before: LocalMinuteSeal?, after: LocalMinuteSeal?),
            first: LocalMinuteSeal,
            last: LocalMinuteSeal
        ) throws {
            if let before = boundaries.before {
                guard before.anchorHash == first.previousAnchorHash else {
                    throw ShareBuildError.sourceIncomplete(
                        "anchor \(before.anchorSequence) is not the previous boundary of anchor \(first.anchorSequence)"
                    )
                }
            }
            if let after = boundaries.after {
                guard after.previousAnchorHash == last.anchorHash else {
                    throw ShareBuildError.sourceIncomplete(
                        "anchor \(after.anchorSequence) is not the next boundary of anchor \(last.anchorSequence)"
                    )
                }
            }
        }

        private func requiredRootSet(
            for seals: [LocalMinuteSeal],
            cancellation: () -> Bool
        ) throws -> Set<String> {
            var roots = Set<String>()
            for seal in seals {
                guard !cancellation() else { throw ShareBuildError.cancelled }
                for root in seal.eventRoots {
                    roots.insert(root)
                    guard roots.count <= limits.maximumRequiredRoots else {
                        throw ShareBuildError.sourceIncomplete(
                            "more than \(limits.maximumRequiredRoots) event roots are required"
                        )
                    }
                }
            }
            return roots
        }

        private func loadEventSummaries(
            for day: Date,
            requiredRoots: Set<String>,
            cancellation: @escaping () -> Bool
        ) throws -> [String: EventSummary] {
            guard !requiredRoots.isEmpty else {
                cacheLock.lock()
                latestReadDiagnostics = ShareEventReadDiagnostics(usedWarmCache: true)
                cacheLock.unlock()
                return [:]
            }

            let file = eventFileURL(day).standardizedFileURL
            let cacheKey = file.path
            cacheLock.lock()
            defer { cacheLock.unlock() }
            guard !cancellation() else { throw ShareBuildError.cancelled }

            guard let currentIdentity = try fileIdentity(at: file) else {
                eventSummaryCache.removeValue(forKey: cacheKey)
                latestReadDiagnostics = ShareEventReadDiagnostics()
                return [:]
            }
            guard currentIdentity.size <= limits.maximumSourceBytes else {
                throw ShareBuildError.sourceIncomplete(
                    "\(file.lastPathComponent) exceeds the \(limits.maximumSourceBytes)-byte read limit"
                )
            }

            accessSequence &+= 1
            let access = accessSequence
            if var cached = eventSummaryCache[cacheKey],
                cached.identity == currentIdentity,
                requiredRoots.isSubset(of: cached.coveredRoots)
            {
                cached.lastAccess = access
                eventSummaryCache[cacheKey] = cached
                latestReadDiagnostics = ShareEventReadDiagnostics(
                    retainedSummaries: cached.summaries.count,
                    retainedEstimatedBytes: cached.estimatedBytes,
                    usedWarmCache: true
                )
                return summaries(in: cached.summaries, for: requiredRoots)
            }

            if let cached = eventSummaryCache[cacheKey],
                cached.identity.device == currentIdentity.device,
                cached.identity.inode == currentIdentity.inode,
                currentIdentity.size > cached.identity.size
            {
                let newlyRequired = requiredRoots.subtracting(cached.coveredRoots)
                var additions: [String: EventSummary] = [:]
                do {
                    if let outcome = try scanJSONLines(
                        HistoryEvent.self,
                        at: file,
                        startingAt: cached.identity.size,
                        expectedPrefixTailFingerprint: cached.tailFingerprint,
                        cancellation: cancellation,
                        onValue: { event, _ in
                            guard let root = event.integrity?.eventRoot,
                                requiredRoots.contains(root)
                            else { return }
                            additions[root] = self.summary(for: event)
                        }
                    ), newlyRequired.isSubset(of: Set(additions.keys)) {
                        var retained = summaries(in: cached.summaries, for: requiredRoots)
                        retained.merge(additions) { _, latest in latest }
                        let estimatedBytes = estimatedSummaryBytes(
                            summaries: retained,
                            coveredRoots: requiredRoots
                        )
                        guard estimatedBytes <= limits.maximumRetainedSummaryBytes else {
                            throw ShareBuildError.sourceIncomplete(
                                "share summary cache exceeds the \(limits.maximumRetainedSummaryBytes)-byte limit"
                            )
                        }
                        eventSummaryCache[cacheKey] = EventSummaryCacheEntry(
                            identity: outcome.identity,
                            tailFingerprint: outcome.tailFingerprint,
                            coveredRoots: requiredRoots,
                            summaries: retained,
                            estimatedBytes: estimatedBytes,
                            lastAccess: access
                        )
                        pruneEventSummaryCache()
                        latestReadDiagnostics = ShareEventReadDiagnostics(
                            bytesRead: outcome.bytesRead,
                            decodedRows: outcome.decodedRows,
                            retainedSummaries: retained.count,
                            retainedEstimatedBytes: estimatedBytes,
                            usedAppendScan: true
                        )
                        return retained
                    }
                } catch JSONLScanError.cachedPrefixChanged {
                    // A same-inode rewrite invalidates the append cursor. A bounded
                    // full pass is the only safe way to avoid stale disclosures.
                }
            }

            var retained: [String: EventSummary] = [:]
            guard
                let outcome = try scanJSONLines(
                    HistoryEvent.self,
                    at: file,
                    cancellation: cancellation,
                    onValue: { event, _ in
                        guard let root = event.integrity?.eventRoot,
                            requiredRoots.contains(root)
                        else { return }
                        retained[root] = self.summary(for: event)
                    }
                )
            else {
                eventSummaryCache.removeValue(forKey: cacheKey)
                latestReadDiagnostics = ShareEventReadDiagnostics()
                return [:]
            }

            let estimatedBytes = estimatedSummaryBytes(
                summaries: retained,
                coveredRoots: requiredRoots
            )
            guard estimatedBytes <= limits.maximumRetainedSummaryBytes else {
                throw ShareBuildError.sourceIncomplete(
                    "share summary cache exceeds the \(limits.maximumRetainedSummaryBytes)-byte limit"
                )
            }
            eventSummaryCache[cacheKey] = EventSummaryCacheEntry(
                identity: outcome.identity,
                tailFingerprint: outcome.tailFingerprint,
                coveredRoots: requiredRoots,
                summaries: retained,
                estimatedBytes: estimatedBytes,
                lastAccess: access
            )
            pruneEventSummaryCache()
            latestReadDiagnostics = ShareEventReadDiagnostics(
                bytesRead: outcome.bytesRead,
                decodedRows: outcome.decodedRows,
                retainedSummaries: retained.count,
                retainedEstimatedBytes: estimatedBytes,
                usedFullScan: true
            )
            return retained
        }

        private func summary(for event: HistoryEvent) -> EventSummary {
            EventSummary(
                application: openingFields(event, name: "application")?["name"],
                category: openingFields(event, name: "classification")?["category"]
            )
        }

        private func summaries(
            in source: [String: EventSummary],
            for roots: Set<String>
        ) -> [String: EventSummary] {
            var result: [String: EventSummary] = [:]
            result.reserveCapacity(min(source.count, roots.count))
            for root in roots {
                if let value = source[root] { result[root] = value }
            }
            return result
        }

        private func estimatedSummaryBytes(
            summaries: [String: EventSummary],
            coveredRoots: Set<String>
        ) -> Int64 {
            let rootBytes = coveredRoots.reduce(into: Int64(0)) {
                $0 += Int64($1.utf8.count + 96)
            }
            return summaries.reduce(into: rootBytes) { total, pair in
                total += Int64(
                    pair.key.utf8.count
                        + (pair.value.application?.utf8.count ?? 0)
                        + (pair.value.category?.utf8.count ?? 0)
                        + 160
                )
            }
        }

        private func pruneEventSummaryCache() {
            while eventSummaryCache.count > limits.maximumCachedDays,
                let oldest = eventSummaryCache.min(by: {
                    $0.value.lastAccess < $1.value.lastAccess
                })?.key
            {
                eventSummaryCache.removeValue(forKey: oldest)
            }
        }

        private func loadSeals(
            for day: Date,
            cancellation: @escaping () -> Bool
        ) throws -> [LocalMinuteSeal] {
            try decodeSealFile(sealFileURL(day), cancellation: cancellation)
        }

        private func decodeSealFile(
            _ file: URL,
            cancellation: @escaping () -> Bool
        ) throws -> [LocalMinuteSeal] {
            var seals: [LocalMinuteSeal] = []
            var retainedBytes: Int64 = 0
            _ = try scanJSONLines(
                LocalMinuteSeal.self,
                at: file,
                cancellation: cancellation,
                onValue: { seal, lineBytes in
                    guard seals.count < self.limits.maximumSealRows else {
                        throw ShareBuildError.sourceIncomplete(
                            "\(file.lastPathComponent) exceeds the \(self.limits.maximumSealRows)-seal limit"
                        )
                    }
                    guard Int64(lineBytes) <= self.limits.maximumRetainedSummaryBytes - retainedBytes else {
                        throw ShareBuildError.sourceIncomplete(
                            "\(file.lastPathComponent) exceeds the retained seal budget"
                        )
                    }
                    seals.append(seal)
                    retainedBytes += Int64(lineBytes)
                }
            )
            return seals.sorted { $0.anchorSequence < $1.anchorSequence }
        }

        private func loadBoundarySeals(
            for day: Date,
            seals: [LocalMinuteSeal],
            cancellation: @escaping () -> Bool
        ) throws -> (before: LocalMinuteSeal?, after: LocalMinuteSeal?) {
            guard let first = seals.first, let last = seals.last else { return (nil, nil) }
            let beforeSequence = first.anchorSequence > 1 ? first.anchorSequence - 1 : nil
            let afterSequence = last.anchorSequence < UInt64.max ? last.anchorSequence + 1 : nil
            guard beforeSequence != nil || afterSequence != nil else { return (nil, nil) }

            let currentPath = sealFileURL(day).standardizedFileURL.path
            let listed = try journalFiles(in: sealsDirectory, suffix: ".seals.jsonl")
            var ordered: [URL] = []
            if let previousDay = Calendar.current.date(byAdding: .day, value: -1, to: day) {
                ordered.append(sealFileURL(previousDay).standardizedFileURL)
            }
            if let nextDay = Calendar.current.date(byAdding: .day, value: 1, to: day) {
                ordered.append(sealFileURL(nextDay).standardizedFileURL)
            }
            ordered.append(contentsOf: listed)

            var seenPaths = Set<String>()
            ordered = ordered.filter {
                let path = $0.standardizedFileURL.path
                return path != currentPath && seenPaths.insert(path).inserted
            }
            guard ordered.count <= limits.maximumAuxiliaryFiles else {
                throw ShareBuildError.sourceIncomplete(
                    "more than \(limits.maximumAuxiliaryFiles) seal journals were discovered"
                )
            }

            var before: LocalMinuteSeal?
            var after: LocalMinuteSeal?
            var decodedRows = 0
            var sourceBytes: Int64 = 0
            for file in ordered {
                guard !cancellation() else { throw ShareBuildError.cancelled }
                let outcome = try scanJSONLines(
                    LocalMinuteSeal.self,
                    at: file,
                    maximumSourceBytes: limits.maximumAuxiliaryBytes - sourceBytes,
                    cancellation: cancellation,
                    onValue: { seal, _ in
                        decodedRows += 1
                        guard decodedRows <= self.limits.maximumAuxiliaryRows else {
                            throw ShareBuildError.sourceIncomplete(
                                "boundary lookup exceeds the \(self.limits.maximumAuxiliaryRows)-row limit"
                            )
                        }
                        if seal.anchorSequence == beforeSequence {
                            guard before == nil || before == seal else {
                                throw ShareBuildError.sourceIncomplete(
                                    "conflicting seal \(seal.anchorSequence)"
                                )
                            }
                            before = seal
                        }
                        if seal.anchorSequence == afterSequence {
                            guard after == nil || after == seal else {
                                throw ShareBuildError.sourceIncomplete(
                                    "conflicting seal \(seal.anchorSequence)"
                                )
                            }
                            after = seal
                        }
                    }
                )
                sourceBytes += outcome?.identity.size ?? 0
                if beforeSequence == nil || before != nil,
                    afterSequence == nil || after != nil
                {
                    break
                }
            }
            return (before, after)
        }

        private func loadEventsByRoot(
            for day: Date,
            requiredRoots: Set<String>,
            cancellation: @escaping () -> Bool
        ) throws -> [String: HistoryEvent] {
            guard requiredRoots.count <= limits.maximumRequiredRoots else {
                throw ShareBuildError.sourceIncomplete(
                    "more than \(limits.maximumRequiredRoots) event roots are required"
                )
            }
            guard !requiredRoots.isEmpty else { return [:] }

            var result: [String: HistoryEvent] = [:]
            var retainedSizes: [String: Int64] = [:]
            var retainedBytes: Int64 = 0
            _ = try scanJSONLines(
                HistoryEvent.self,
                at: eventFileURL(day),
                cancellation: cancellation,
                onValue: { event, lineBytes in
                    guard let root = event.integrity?.eventRoot,
                        requiredRoots.contains(root)
                    else { return }
                    let previousBytes = retainedSizes[root] ?? 0
                    let nextBytes = Int64(lineBytes)
                    guard
                        nextBytes <= self.limits.maximumRetainedEventBytes
                            - retainedBytes + previousBytes
                    else {
                        throw ShareBuildError.sourceIncomplete(
                            "referenced events exceed the \(self.limits.maximumRetainedEventBytes)-byte export limit"
                        )
                    }
                    result[root] = event
                    retainedSizes[root] = nextBytes
                    retainedBytes += nextBytes - previousBytes
                }
            )
            return result
        }

        private func loadReceiptsBySequence(
            requiredSequences: Set<UInt64>,
            cancellation: @escaping () -> Bool
        ) throws -> [UInt64: AnchorReceipt] {
            guard !requiredSequences.isEmpty else { return [:] }
            let files = try journalFiles(in: receiptsDirectory, suffix: ".receipts.jsonl")
            guard files.count <= limits.maximumAuxiliaryFiles else {
                throw ShareBuildError.sourceIncomplete(
                    "more than \(limits.maximumAuxiliaryFiles) receipt journals were discovered"
                )
            }
            var result: [UInt64: AnchorReceipt] = [:]
            var decodedRows = 0
            var sourceBytes: Int64 = 0
            for file in files {
                guard !cancellation() else { throw ShareBuildError.cancelled }
                let outcome = try scanJSONLines(
                    AnchorReceipt.self,
                    at: file,
                    maximumSourceBytes: limits.maximumAuxiliaryBytes - sourceBytes,
                    cancellation: cancellation,
                    onValue: { receipt, _ in
                        decodedRows += 1
                        guard decodedRows <= self.limits.maximumAuxiliaryRows else {
                            throw ShareBuildError.sourceIncomplete(
                                "receipt lookup exceeds the \(self.limits.maximumAuxiliaryRows)-row limit"
                            )
                        }
                        if requiredSequences.contains(receipt.anchorSequence) {
                            result[receipt.anchorSequence] = receipt
                        }
                    }
                )
                sourceBytes += outcome?.identity.size ?? 0
            }
            return result
        }

        private func journalFiles(in directory: URL, suffix: String) throws -> [URL] {
            var directoryInformation = stat()
            guard lstat(directory.path, &directoryInformation) == 0 else {
                if errno == ENOENT { return [] }
                throw sourceUnavailable(directory, operation: "inspect directory")
            }
            guard directoryInformation.st_mode & S_IFMT == S_IFDIR else {
                throw ShareBuildError.sourceIncomplete(
                    "\(directory.lastPathComponent) is not a directory"
                )
            }
            var enumerationError: Error?
            guard
                let enumerator = FileManager.default.enumerator(
                    at: directory,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants],
                    errorHandler: { _, error in
                        enumerationError = error
                        return false
                    }
                )
            else {
                throw ShareBuildError.sourceIncomplete(
                    "cannot enumerate \(directory.lastPathComponent)"
                )
            }
            var files: [URL] = []
            while let file = enumerator.nextObject() as? URL {
                guard file.lastPathComponent.hasSuffix(suffix) else { continue }
                files.append(file)
                guard files.count <= limits.maximumAuxiliaryFiles else {
                    throw ShareBuildError.sourceIncomplete(
                        "more than \(limits.maximumAuxiliaryFiles) \(suffix) journals were discovered"
                    )
                }
            }
            if let enumerationError {
                throw ShareBuildError.sourceIncomplete(
                    "cannot enumerate \(directory.lastPathComponent): \(enumerationError.localizedDescription)"
                )
            }
            return files.sorted { $0.lastPathComponent < $1.lastPathComponent }
        }

        @discardableResult
        private func scanJSONLines<Value: Decodable>(
            _ type: Value.Type,
            at file: URL,
            startingAt requestedOffset: Int64 = 0,
            expectedPrefixTailFingerprint: String? = nil,
            maximumSourceBytes requestedMaximumSourceBytes: Int64? = nil,
            cancellation: @escaping () -> Bool,
            onValue: (Value, Int) throws -> Void
        ) throws -> JSONLScanOutcome? {
            guard !cancellation() else { throw ShareBuildError.cancelled }
            let maximumSourceBytes = min(
                limits.maximumSourceBytes,
                max(1, requestedMaximumSourceBytes ?? limits.maximumSourceBytes)
            )
            guard let initialIdentity = try fileIdentity(at: file) else { return nil }
            guard initialIdentity.size <= maximumSourceBytes else {
                throw ShareBuildError.sourceIncomplete(
                    "\(file.lastPathComponent) exceeds the \(maximumSourceBytes)-byte read limit"
                )
            }

            let descriptor = Darwin.open(file.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            guard descriptor >= 0 else {
                if errno == ENOENT { return nil }
                throw sourceUnavailable(file, operation: "open")
            }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? handle.close() }

            var openedInformation = stat()
            guard fstat(descriptor, &openedInformation) == 0 else {
                throw sourceUnavailable(file, operation: "inspect open file")
            }
            guard openedInformation.st_mode & S_IFMT == S_IFREG else {
                throw ShareBuildError.sourceIncomplete(
                    "\(file.lastPathComponent) is not a regular file"
                )
            }
            let openedIdentity = identity(from: openedInformation)
            guard openedIdentity == initialIdentity else {
                throw ShareBuildError.sourceIncomplete(
                    "\(file.lastPathComponent) changed before it could be read"
                )
            }
            guard openedIdentity.size <= maximumSourceBytes else {
                throw ShareBuildError.sourceIncomplete(
                    "\(file.lastPathComponent) exceeds the \(maximumSourceBytes)-byte read limit"
                )
            }
            guard requestedOffset >= 0, requestedOffset <= openedIdentity.size else {
                throw JSONLScanError.cachedPrefixChanged
            }

            var bytesRead: Int64 = 0
            if let expectedPrefixTailFingerprint {
                let prefix = try tailFingerprint(descriptor: descriptor, endingAt: requestedOffset)
                bytesRead += prefix.bytesRead
                guard prefix.value == expectedPrefixTailFingerprint else {
                    throw JSONLScanError.cachedPrefixChanged
                }
            }
            do {
                try handle.seek(toOffset: UInt64(requestedOffset))
            } catch {
                throw sourceUnavailable(file, operation: "seek")
            }

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            var pending = Data()
            pending.reserveCapacity(min(limits.readChunkBytes, limits.maximumLineBytes))
            var remaining = openedIdentity.size - requestedOffset
            var decodedRows = 0

            func append<C: Collection>(_ bytes: C) throws where C.Element == UInt8 {
                guard bytes.count <= limits.maximumLineBytes - pending.count else {
                    throw ShareBuildError.sourceIncomplete(
                        "a row in \(file.lastPathComponent) exceeds \(limits.maximumLineBytes) bytes"
                    )
                }
                pending.append(contentsOf: bytes)
            }

            func finishLine() throws {
                guard !pending.isEmpty else { return }
                guard !cancellation() else { throw ShareBuildError.cancelled }
                let lineBytes = pending.count
                let decoded: Value
                do {
                    decoded = try autoreleasepool {
                        try decoder.decode(type, from: pending)
                    }
                } catch {
                    throw ShareBuildError.sourceIncomplete(
                        "invalid JSONL row \(decodedRows + 1) in \(file.lastPathComponent)"
                    )
                }
                decodedRows += 1
                try onValue(decoded, lineBytes)
                pending.removeAll(keepingCapacity: true)
            }

            while remaining > 0 {
                guard !cancellation() else { throw ShareBuildError.cancelled }
                let requestedBytes = Int(min(Int64(limits.readChunkBytes), remaining))
                let chunk: Data
                do {
                    guard let value = try handle.read(upToCount: requestedBytes), !value.isEmpty else {
                        throw ShareBuildError.sourceIncomplete(
                            "\(file.lastPathComponent) ended while it was being read"
                        )
                    }
                    chunk = value
                } catch let error as ShareBuildError {
                    throw error
                } catch {
                    throw sourceUnavailable(file, operation: "read")
                }
                remaining -= Int64(chunk.count)
                bytesRead += Int64(chunk.count)

                var segmentStart = chunk.startIndex
                while segmentStart < chunk.endIndex,
                    let newline = chunk[segmentStart...].firstIndex(of: 0x0A)
                {
                    try append(chunk[segmentStart..<newline])
                    try finishLine()
                    segmentStart = chunk.index(after: newline)
                }
                if segmentStart < chunk.endIndex {
                    try append(chunk[segmentStart..<chunk.endIndex])
                }
            }

            guard pending.isEmpty else {
                throw ShareBuildError.sourceIncomplete(
                    "unterminated JSONL row in \(file.lastPathComponent)"
                )
            }
            guard !cancellation() else { throw ShareBuildError.cancelled }
            try afterSourceReadForTesting?(file)

            var finalInformation = stat()
            guard fstat(descriptor, &finalInformation) == 0 else {
                throw sourceUnavailable(file, operation: "reinspect open file")
            }
            let finalIdentity = identity(from: finalInformation)
            guard finalIdentity == openedIdentity else {
                throw ShareBuildError.sourceIncomplete(
                    "\(file.lastPathComponent) changed while it was read"
                )
            }
            guard let pathIdentity = try fileIdentity(at: file), pathIdentity == openedIdentity else {
                throw ShareBuildError.sourceIncomplete(
                    "\(file.lastPathComponent) was replaced while it was read"
                )
            }
            if let expectedPrefixTailFingerprint {
                let prefix = try tailFingerprint(descriptor: descriptor, endingAt: requestedOffset)
                bytesRead += prefix.bytesRead
                guard prefix.value == expectedPrefixTailFingerprint else {
                    throw JSONLScanError.cachedPrefixChanged
                }
            }
            let tail = try tailFingerprint(descriptor: descriptor, endingAt: openedIdentity.size)
            bytesRead += tail.bytesRead
            return JSONLScanOutcome(
                identity: openedIdentity,
                bytesRead: bytesRead,
                decodedRows: decodedRows,
                tailFingerprint: tail.value
            )
        }

        private func fileIdentity(at file: URL) throws -> FileIdentity? {
            var information = stat()
            guard lstat(file.path, &information) == 0 else {
                if errno == ENOENT { return nil }
                throw sourceUnavailable(file, operation: "inspect")
            }
            guard information.st_mode & S_IFMT == S_IFREG else {
                throw ShareBuildError.sourceIncomplete(
                    "\(file.lastPathComponent) is not a regular file"
                )
            }
            return identity(from: information)
        }

        private func identity(from information: stat) -> FileIdentity {
            FileIdentity(
                device: UInt64(information.st_dev),
                inode: UInt64(information.st_ino),
                size: max(0, Int64(information.st_size)),
                modificationSeconds: Int64(information.st_mtimespec.tv_sec),
                modificationNanoseconds: Int64(information.st_mtimespec.tv_nsec),
                changeSeconds: Int64(information.st_ctimespec.tv_sec),
                changeNanoseconds: Int64(information.st_ctimespec.tv_nsec)
            )
        }

        private func tailFingerprint(
            descriptor: Int32,
            endingAt offset: Int64
        ) throws -> (value: String, bytesRead: Int64) {
            let byteCount = Int(min(512, max(0, offset)))
            guard byteCount > 0 else { return (SHA256Digest.hashHex(Data()), 0) }
            var data = Data(count: byteCount)
            let startOffset = offset - Int64(byteCount)
            var totalRead = 0
            while totalRead < byteCount {
                let result = data.withUnsafeMutableBytes { bytes -> Int in
                    guard let baseAddress = bytes.baseAddress else { return -1 }
                    return pread(
                        descriptor,
                        baseAddress.advanced(by: totalRead),
                        byteCount - totalRead,
                        off_t(startOffset) + off_t(totalRead)
                    )
                }
                if result > 0 {
                    totalRead += result
                    continue
                }
                if result < 0, errno == EINTR { continue }
                throw ShareBuildError.sourceIncomplete("event journal changed while it was fingerprinted")
            }
            return (SHA256Digest.hashHex(data), Int64(totalRead))
        }

        private func sourceUnavailable(_ file: URL, operation: String) -> ShareBuildError {
            let code = errno
            let message = String(cString: strerror(code))
            return .sourceIncomplete(
                "cannot \(operation) \(file.lastPathComponent) (\(message), errno \(code))"
            )
        }

        private func uniqueValues(_ values: [String]) -> [String] {
            var seen = Set<String>()
            return values.filter { seen.insert($0).inserted }
        }
    }
#endif
