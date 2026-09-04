#if os(macOS)
    import AppKit
    import AppleScreenTime
    import Darwin
    import Foundation
    import SQLite3

    public enum AppleSystemScreenTimeStatusKind: String, Equatable, Sendable {
        case ready
        case localOnly
        case fullDiskAccessRequired
        case noAppleData
        case partial
    }

    public struct AppleSystemScreenTimeStatus: Equatable, Sendable {
        public let kind: AppleSystemScreenTimeStatusKind
        public let title: String
        public let message: String

        public init(kind: AppleSystemScreenTimeStatusKind, title: String, message: String) {
            self.kind = kind
            self.title = title
            self.message = message
        }

        public static let loading = AppleSystemScreenTimeStatus(
            kind: .noAppleData,
            title: "Reading Apple Screen Time",
            message: "Goalong History is checking Apple’s local Screen Time and iCloud-synced device stores."
        )
    }

    public struct AppleSystemScreenTimeCollection: Sendable {
        public let storedExport: AppleScreenTimeStoredExport?
        public let availableDevices: [AppleScreenTimeDevice]
        public let status: AppleSystemScreenTimeStatus
        public let deviceSourceLabels: [String: String]
        public let latestAppleUpdate: Date?
        public let knowledgeIntervalCount: Int
        public let biomeIntervalCount: Int
        public let screenTimeAppUsageIntervalCount: Int

        public init(
            storedExport: AppleScreenTimeStoredExport?,
            availableDevices: [AppleScreenTimeDevice],
            status: AppleSystemScreenTimeStatus,
            deviceSourceLabels: [String: String],
            latestAppleUpdate: Date?,
            knowledgeIntervalCount: Int,
            biomeIntervalCount: Int,
            screenTimeAppUsageIntervalCount: Int = 0
        ) {
            self.storedExport = storedExport
            self.availableDevices = availableDevices
            self.status = status
            self.deviceSourceLabels = deviceSourceLabels
            self.latestAppleUpdate = latestAppleUpdate
            self.knowledgeIntervalCount = knowledgeIntervalCount
            self.biomeIntervalCount = biomeIntervalCount
            self.screenTimeAppUsageIntervalCount = screenTimeAppUsageIntervalCount
        }
    }

    struct AppleSystemScreenTimePaths {
        let knowledgeDatabase: URL
        let biomeSyncDatabase: URL
        let biomeLocalDirectory: URL
        let biomeRemoteDirectory: URL
        let appleAccountDeviceDatabase: URL
        let biomeScreenTimeAppUsageDirectory: URL?
        let biomeRemoteScreenTimeAppUsageDirectory: URL?
        let screenTimeAdminLocalDatabase: URL?
        let screenTimeAdminCloudDatabase: URL?

        init(
            knowledgeDatabase: URL,
            biomeSyncDatabase: URL,
            biomeLocalDirectory: URL,
            biomeRemoteDirectory: URL,
            appleAccountDeviceDatabase: URL,
            biomeScreenTimeAppUsageDirectory: URL? = nil,
            biomeRemoteScreenTimeAppUsageDirectory: URL? = nil,
            screenTimeAdminLocalDatabase: URL? = nil,
            screenTimeAdminCloudDatabase: URL? = nil
        ) {
            self.knowledgeDatabase = knowledgeDatabase
            self.biomeSyncDatabase = biomeSyncDatabase
            self.biomeLocalDirectory = biomeLocalDirectory
            self.biomeRemoteDirectory = biomeRemoteDirectory
            self.appleAccountDeviceDatabase = appleAccountDeviceDatabase
            self.biomeScreenTimeAppUsageDirectory = biomeScreenTimeAppUsageDirectory
            self.biomeRemoteScreenTimeAppUsageDirectory = biomeRemoteScreenTimeAppUsageDirectory
            self.screenTimeAdminLocalDatabase = screenTimeAdminLocalDatabase
            self.screenTimeAdminCloudDatabase = screenTimeAdminCloudDatabase
        }

        static let `default`: AppleSystemScreenTimePaths = {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let library = home.appendingPathComponent("Library", isDirectory: true)
            let biome = library.appendingPathComponent("Biome", isDirectory: true)
            let appInFocus = biome
                .appendingPathComponent("streams", isDirectory: true)
                .appendingPathComponent("restricted", isDirectory: true)
                .appendingPathComponent("App.InFocus", isDirectory: true)
            let screenTimeStore = URL(
                fileURLWithPath: NSTemporaryDirectory(),
                isDirectory: true
            )
            .standardizedFileURL
            .deletingLastPathComponent()
            .appendingPathComponent("0", isDirectory: true)
            .appendingPathComponent("com.apple.ScreenTimeAgent", isDirectory: true)
            .appendingPathComponent("Store", isDirectory: true)
            return AppleSystemScreenTimePaths(
                knowledgeDatabase: library
                    .appendingPathComponent("Application Support", isDirectory: true)
                    .appendingPathComponent("Knowledge", isDirectory: true)
                    .appendingPathComponent("knowledgeC.db", isDirectory: false),
                biomeSyncDatabase: biome
                    .appendingPathComponent("sync", isDirectory: true)
                    .appendingPathComponent("sync.db", isDirectory: false),
                biomeLocalDirectory: appInFocus.appendingPathComponent("local", isDirectory: true),
                biomeRemoteDirectory: appInFocus.appendingPathComponent("remote", isDirectory: true),
                appleAccountDeviceDatabase: library
                    .appendingPathComponent("Application Support", isDirectory: true)
                    .appendingPathComponent("com.apple.akd", isDirectory: true)
                    .appendingPathComponent("devicelist.db", isDirectory: false),
                biomeScreenTimeAppUsageDirectory: biome
                    .appendingPathComponent("streams", isDirectory: true)
                    .appendingPathComponent("restricted", isDirectory: true)
                    .appendingPathComponent("ScreenTime.AppUsage", isDirectory: true)
                    .appendingPathComponent("local", isDirectory: true),
                biomeRemoteScreenTimeAppUsageDirectory: biome
                    .appendingPathComponent("streams", isDirectory: true)
                    .appendingPathComponent("restricted", isDirectory: true)
                    .appendingPathComponent("ScreenTime.AppUsage", isDirectory: true)
                    .appendingPathComponent("remote", isDirectory: true),
                screenTimeAdminLocalDatabase: screenTimeStore
                    .appendingPathComponent("RMAdminStore-Local.sqlite", isDirectory: false),
                screenTimeAdminCloudDatabase: screenTimeStore
                    .appendingPathComponent("RMAdminStore-Cloud.sqlite", isDirectory: false)
            )
        }()
    }

    struct AppleBiomeFileFingerprint: Equatable {
        let size: Int
        let modifiedAt: Date
    }

    struct AppleBiomeDeviceDescriptor: Equatable, Sendable {
        let hardwareIdentifier: String?
        let platform: Int?
    }

    struct AppleBiomeFileCacheLimits: Equatable {
        let maximumEntries: Int
        let maximumBytes: Int

        static let production = AppleBiomeFileCacheLimits(
            maximumEntries: 64,
            maximumBytes: 8 * 1_024 * 1_024
        )
    }

    struct AppleBiomeFileCacheSnapshot: Equatable {
        let entryCount: Int
        let retainedBytes: Int
        let paths: Set<String>
    }

    private enum AppleBiomeCachedPayload {
        case focus([AppleBiomeFocusEvent])
        case screenTimeAppUsage([AppleBiomeScreenTimeAppUsageEvent])
    }

    private struct AppleBiomeCachedFile {
        let fingerprint: AppleBiomeFileFingerprint
        let payload: AppleBiomeCachedPayload
        let retainedBytes: Int
        var lastAccess: UInt64
    }

    private struct AppleAccountDeviceCatalogCache {
        let fingerprint: AppleBiomeFileFingerprint
        let devices: [AppleAccountDeviceMetadata]
    }

    struct AppleBiomeFileCache {
        private let limits: AppleBiomeFileCacheLimits
        private var entries: [String: AppleBiomeCachedFile] = [:]
        private var retainedBytes = 0
        private var accessCounter: UInt64 = 0

        init(limits: AppleBiomeFileCacheLimits = .production) {
            self.limits = AppleBiomeFileCacheLimits(
                maximumEntries: max(1, limits.maximumEntries),
                maximumBytes: max(1, limits.maximumBytes)
            )
        }

        mutating func events(
            for path: String,
            fingerprint: AppleBiomeFileFingerprint
        ) -> [AppleBiomeFocusEvent]? {
            guard var entry = entries[path] else { return nil }
            guard entry.fingerprint == fingerprint else {
                entries.removeValue(forKey: path)
                retainedBytes -= entry.retainedBytes
                return nil
            }
            accessCounter &+= 1
            entry.lastAccess = accessCounter
            entries[path] = entry
            guard case .focus(let events) = entry.payload else { return nil }
            return events
        }

        mutating func screenTimeAppUsageEvents(
            for path: String,
            fingerprint: AppleBiomeFileFingerprint
        ) -> [AppleBiomeScreenTimeAppUsageEvent]? {
            guard var entry = entries[path] else { return nil }
            guard entry.fingerprint == fingerprint else {
                entries.removeValue(forKey: path)
                retainedBytes -= entry.retainedBytes
                return nil
            }
            accessCounter &+= 1
            entry.lastAccess = accessCounter
            entries[path] = entry
            guard case .screenTimeAppUsage(let events) = entry.payload else { return nil }
            return events
        }

        mutating func insert(
            path: String,
            fingerprint: AppleBiomeFileFingerprint,
            events: [AppleBiomeFocusEvent],
            retainedBytes incomingBytes: Int
        ) {
            insert(
                path: path,
                fingerprint: fingerprint,
                payload: .focus(events),
                retainedBytes: incomingBytes
            )
        }

        mutating func insert(
            path: String,
            fingerprint: AppleBiomeFileFingerprint,
            screenTimeAppUsageEvents: [AppleBiomeScreenTimeAppUsageEvent],
            retainedBytes incomingBytes: Int
        ) {
            insert(
                path: path,
                fingerprint: fingerprint,
                payload: .screenTimeAppUsage(screenTimeAppUsageEvents),
                retainedBytes: incomingBytes
            )
        }

        private mutating func insert(
            path: String,
            fingerprint: AppleBiomeFileFingerprint,
            payload: AppleBiomeCachedPayload,
            retainedBytes incomingBytes: Int
        ) {
            if let previous = entries.removeValue(forKey: path) {
                retainedBytes -= previous.retainedBytes
            }
            let boundedBytes = max(1, incomingBytes)
            guard boundedBytes <= limits.maximumBytes else { return }

            while !entries.isEmpty,
                entries.count >= limits.maximumEntries
                    || retainedBytes > limits.maximumBytes - boundedBytes
            {
                guard let oldest = entries.min(
                    by: { left, right in
                        if left.value.lastAccess == right.value.lastAccess {
                            return left.key < right.key
                        }
                        return left.value.lastAccess < right.value.lastAccess
                    }
                ) else { break }
                retainedBytes -= oldest.value.retainedBytes
                entries.removeValue(forKey: oldest.key)
            }

            accessCounter &+= 1
            entries[path] = AppleBiomeCachedFile(
                fingerprint: fingerprint,
                payload: payload,
                retainedBytes: boundedBytes,
                lastAccess: accessCounter
            )
            retainedBytes += boundedBytes
        }

        mutating func retainFiles(_ existingPaths: Set<String>, under directoryPath: String) {
            let prefix = directoryPath.hasSuffix("/") ? directoryPath : directoryPath + "/"
            removeEntries { path in
                path.hasPrefix(prefix) && !existingPaths.contains(path)
            }
        }

        mutating func removeMissingFiles(_ exists: (String) -> Bool) {
            removeEntries { !exists($0) }
        }

        var snapshot: AppleBiomeFileCacheSnapshot {
            AppleBiomeFileCacheSnapshot(
                entryCount: entries.count,
                retainedBytes: retainedBytes,
                paths: Set(entries.keys)
            )
        }

        private mutating func removeEntries(where shouldRemove: (String) -> Bool) {
            for key in entries.keys.filter(shouldRemove) {
                if let removed = entries.removeValue(forKey: key) {
                    retainedBytes -= removed.retainedBytes
                }
            }
        }
    }

    /// Reads Apple-generated Screen Time data already present on the Mac.
    ///
    /// - `ScreenTimeAgent` aggregate stores provide Apple-owned per-device totals and timed items.
    ///   They are the preferred private macOS source when the operating system makes them readable,
    ///   but Apple does not publish them as the Settings presentation contract.
    /// - Biome `ScreenTime.AppUsage` provides Apple application-usage transitions for this Mac,
    ///   including parent-bundle attribution for helper processes when the aggregate store is
    ///   unavailable.
    /// - `knowledgeC.db` provides Apple `/app/usage` intervals for the Mac and any device
    ///   rows Apple has synchronized into the database, and fills local coverage gaps.
    /// - Biome `App.InFocus` provides automatic iCloud-synced focus transitions for iPhone,
    ///   iPad and other devices when “Share Across Devices” is enabled.
    ///
    /// These are private on-disk Apple formats, not Goalong History’s recorder. The source is
    /// deliberately isolated so an Apple schema change cannot affect normal activity capture.
    public final class AppleSystemScreenTimeSource {
        public let currentMacDevice: AppleScreenTimeDevice

        private let paths: AppleSystemScreenTimePaths
        private let fileManager: FileManager
        private let calendar: Calendar
        private let nowProvider: () -> Date
        private var biomeFileCache: AppleBiomeFileCache
        private var accountDeviceCatalogCache: AppleAccountDeviceCatalogCache?

        public convenience init(deviceID: String) {
            self.init(deviceID: deviceID, paths: .default)
        }

        init(
            deviceID: String,
            paths: AppleSystemScreenTimePaths = .default,
            fileManager: FileManager = .default,
            calendar: Calendar = .current,
            nowProvider: @escaping () -> Date = Date.init,
            biomeCacheLimits: AppleBiomeFileCacheLimits = .production
        ) {
            self.paths = paths
            self.fileManager = fileManager
            self.calendar = calendar
            self.nowProvider = nowProvider
            biomeFileCache = AppleBiomeFileCache(limits: biomeCacheLimits)
            accountDeviceCatalogCache = nil
            self.currentMacDevice = AppleScreenTimeDevice(
                id: "apple-system-current-mac:\(deviceID)",
                name: Self.localHostName(),
                kind: .mac
            )
        }

        public func collect(for day: Date) -> AppleSystemScreenTimeCollection {
            guard let dayInterval = calendar.dateInterval(of: .day, for: day) else {
                return emptyCollection(
                    status: AppleSystemScreenTimeStatus(
                        kind: .noAppleData,
                        title: "Invalid day",
                        message: "The selected calendar day could not be resolved."
                    )
                )
            }

            let now = nowProvider()
            let effectiveEnd = calendar.isDateInToday(day) ? min(dayInterval.end, now) : dayInterval.end
            let requestedInterval = DateInterval(
                start: dayInterval.start,
                end: max(dayInterval.start, effectiveEnd)
            )
            return collect(
                requestedInterval: requestedInterval,
                envelopeInterval: dayInterval,
                now: now
            )
        }

        /// Reads one bounded multi-day interval in a single pass. Agent queries use this to
        /// avoid reopening and revalidating the same Apple databases once per requested day.
        /// The returned reports retain their original segments so callers can derive exact
        /// per-day summaries transiently without another source read or persisted snapshot.
        public func collect(for interval: DateInterval) -> AppleSystemScreenTimeCollection {
            let now = nowProvider()
            let start = calendar.startOfDay(for: interval.start)
            let requestedEnd = max(start, interval.end)
            let effectiveEnd = min(requestedEnd, now)
            let boundedEnd = max(start, effectiveEnd)
            return collect(
                requestedInterval: DateInterval(start: start, end: boundedEnd),
                envelopeInterval: DateInterval(start: start, end: requestedEnd),
                now: now
            )
        }

        private func collect(
            requestedInterval: DateInterval,
            envelopeInterval: DateInterval,
            now: Date
        ) -> AppleSystemScreenTimeCollection {
            let accountDevices = readAppleAccountDeviceCatalog()
            let adminRead = readScreenTimeAdminStores(interval: requestedInterval)
            if adminRead.readableStoreCount > 0 {
                let rawReports = makeAdminReports(from: adminRead.blocks)
                let reports = AppleScreenTimeDeviceIdentityResolver.resolve(
                    reports: rawReports,
                    accountDevices: accountDevices,
                    currentMacID: currentMacDevice.id,
                    now: now
                ).filter { Self.appearsInAppleSettingsScreenTime($0.device.kind) }
                let reportedDevicesByID = Dictionary(
                    uniqueKeysWithValues: reports.map { ($0.device.id, $0.device) }
                )
                let availableDevices = mergeDeviceLists(
                    adminRead.devices.map { reportedDevicesByID[$0.id] ?? $0 },
                    reports.map(\.device)
                )
                let warnings = [adminRead.warning].compactMap { $0 }
                let status = makeStatus(
                    hasData: !reports.isEmpty,
                    permissionDenied: adminRead.permissionDenied,
                    remoteDeviceCount: availableDevices.filter { $0.id != currentMacDevice.id }.count,
                    warnings: warnings,
                    privateAggregateStore: true
                )
                let info = Bundle.main.infoDictionary
                let provenance = AppleScreenTimeProvenance(
                    api: AppleScreenTimeProvenance.screenTimeAgentAggregateAPI,
                    collectorBundleIdentifier: Bundle.main.bundleIdentifier ?? "ai.goalong.localhistory",
                    collectorVersion: info?["CFBundleShortVersionString"] as? String ?? "unknown",
                    collectorPlatform: ProcessInfo.processInfo.operatingSystemVersionString,
                    authorization: .unknown,
                    fetchPolicy: .live,
                    euCustomerRequirementAcknowledged: false
                )
                let stored = reports.isEmpty
                    ? nil
                    : AppleScreenTimeStoredExport(
                        importedAt: now,
                        verification: .appleSystemStore,
                        envelope: AppleScreenTimeExportEnvelope(
                            requestedStart: envelopeInterval.start,
                            requestedEnd: envelopeInterval.end,
                            requestedScope: .allDevices,
                            provenance: provenance,
                            reports: reports
                        )
                    )
                return AppleSystemScreenTimeCollection(
                    storedExport: stored,
                    availableDevices: availableDevices,
                    status: status,
                    deviceSourceLabels: Dictionary(uniqueKeysWithValues: availableDevices.map {
                        ($0.id, "Apple Screen Time aggregate (private format)")
                    }),
                    latestAppleUpdate: adminRead.latestUpdate,
                    knowledgeIntervalCount: 0,
                    biomeIntervalCount: 0,
                    screenTimeAppUsageIntervalCount: 0
                )
            }
            let catalogRead = readDeviceCatalog()
            let knowledgeRead = readKnowledgeIntervals(
                interval: requestedInterval,
                catalog: catalogRead.devices
            )
            let biomeRead = readBiomeIntervals(
                interval: requestedInterval,
                now: now,
                catalog: catalogRead.devices
            )
            let screenTimeAppUsageRead = readScreenTimeAppUsageIntervals(
                interval: requestedInterval,
                now: now,
                catalog: catalogRead.devices
            )

            let fallbackMerged = mergeIntervals(
                preferred: knowledgeRead.values,
                supplemental: biomeRead.values
            )
            let appUsageHealthy = screenTimeAppUsageRead.warning == nil
                && !screenTimeAppUsageRead.permissionDenied
            let fallbackByDevice = Dictionary(grouping: fallbackMerged, by: { $0.device.id })
            let appUsageByDevice = Dictionary(
                grouping: screenTimeAppUsageRead.values,
                by: { $0.device.id }
            )
            let sourceDeviceIDs = Set(fallbackByDevice.keys).union(appUsageByDevice.keys)
            let merged = sourceDeviceIDs.sorted().flatMap { deviceID -> [UsageInterval] in
                let fallback = fallbackByDevice[deviceID] ?? []
                let appUsage = appUsageByDevice[deviceID] ?? []
                guard !appUsage.isEmpty else { return fallback }

                if appUsageHealthy {
                    // A healthy ScreenTime.AppUsage stream is Apple's complete source for this
                    // device. Filling its intentional gaps from knowledgeC or App.InFocus makes
                    // the total exceed Settings even when every visible app row already matches.
                    return appUsage
                }

                // A partial AppUsage read must not erase a concurrent application that a
                // readable fallback still reports. Keep every distinct app, deduplicate only
                // the same bundle, and surface the partial status above.
                return mergeAdjacent(normalizeIntervals(appUsage + fallback))
            }
            let rawReports = makeReports(from: merged)
            let resolvedReports = AppleScreenTimeDeviceIdentityResolver.resolve(
                reports: rawReports,
                accountDevices: accountDevices,
                currentMacID: currentMacDevice.id,
                now: now
            )
            // Preserve the complete Apple report after source merging. Default summaries remove
            // explicit lock/screen-saver rows, while an opt-in UI can reveal the source truth
            // without re-reading Apple stores or maintaining a second copy.
            let reports = resolvedReports.filter {
                Self.appearsInAppleSettingsScreenTime($0.device.kind)
            }
            let selectableDevices = AppleScreenTimeDeviceIdentityResolver.selectableDevices(
                catalogDevices: catalogRead.devices.values.map(\.device),
                reports: reports,
                accountDevices: accountDevices,
                currentMac: currentMacDevice,
                now: now
            ).filter { Self.appearsInAppleSettingsScreenTime($0.kind) }
            let discoveredDevices = mergeDeviceLists(selectableDevices)
            let latestUpdate = [
                knowledgeRead.latestUpdate,
                biomeRead.latestUpdate,
                screenTimeAppUsageRead.latestUpdate,
                reports.map(\.lastUpdatedAt).max(),
            ].compactMap { $0 }.max()

            let denied = adminRead.permissionDenied
                || catalogRead.permissionDenied
                || knowledgeRead.permissionDenied
                || biomeRead.permissionDenied
                || screenTimeAppUsageRead.permissionDenied
            let warnings = [
                adminRead.warning,
                catalogRead.warning,
                knowledgeRead.warning,
                biomeRead.warning,
                screenTimeAppUsageRead.warning,
            ]
                .compactMap { $0 }
            let remoteDeviceCount = discoveredDevices.filter { $0.id != currentMacDevice.id }.count
            let status = makeStatus(
                hasData: !rawReports.isEmpty,
                permissionDenied: denied,
                remoteDeviceCount: remoteDeviceCount,
                warnings: warnings
            )
            var resolvedSourceLabels = sourceLabels(
                devices: discoveredDevices,
                knowledgeDeviceIDs: Set(knowledgeRead.values.map(\.device.id)),
                biomeDeviceIDs: Set(biomeRead.values.map(\.device.id))
            )
            let currentMacIntervals = merged.filter { $0.device.id == currentMacDevice.id }
            if !currentMacIntervals.isEmpty {
                resolvedSourceLabels[currentMacDevice.id] = sourceLabel(for: currentMacIntervals)
            }

            guard !reports.isEmpty else {
                return AppleSystemScreenTimeCollection(
                    storedExport: nil,
                    availableDevices: discoveredDevices,
                    status: status,
                    deviceSourceLabels: resolvedSourceLabels,
                    latestAppleUpdate: latestUpdate,
                    knowledgeIntervalCount: knowledgeRead.values.count,
                    biomeIntervalCount: biomeRead.values.count,
                    screenTimeAppUsageIntervalCount: screenTimeAppUsageRead.values.count
                )
            }

            let info = Bundle.main.infoDictionary
            let provenance = AppleScreenTimeProvenance(
                api: sourceAPI(for: merged),
                collectorBundleIdentifier: Bundle.main.bundleIdentifier ?? "ai.goalong.localhistory",
                collectorVersion: info?["CFBundleShortVersionString"] as? String ?? "unknown",
                collectorPlatform: ProcessInfo.processInfo.operatingSystemVersionString,
                authorization: .unknown,
                fetchPolicy: .live,
                euCustomerRequirementAcknowledged: false
            )
            let envelope = AppleScreenTimeExportEnvelope(
                requestedStart: envelopeInterval.start,
                requestedEnd: envelopeInterval.end,
                requestedScope: .allDevices,
                provenance: provenance,
                reports: reports
            )
            let stored = AppleScreenTimeStoredExport(
                importedAt: now,
                verification: .appleSystemStore,
                envelope: envelope
            )

            return AppleSystemScreenTimeCollection(
                storedExport: stored,
                availableDevices: discoveredDevices,
                status: status,
                deviceSourceLabels: resolvedSourceLabels,
                latestAppleUpdate: latestUpdate,
                knowledgeIntervalCount: knowledgeRead.values.count,
                biomeIntervalCount: biomeRead.values.count,
                screenTimeAppUsageIntervalCount: screenTimeAppUsageRead.values.count
            )
        }

        private static func localHostName() -> String? {
            var buffer = [CChar](repeating: 0, count: Int(MAXHOSTNAMELEN))
            guard Darwin.gethostname(&buffer, buffer.count) == 0 else { return nil }
            let value = String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }

        private func emptyCollection(status: AppleSystemScreenTimeStatus) -> AppleSystemScreenTimeCollection {
            AppleSystemScreenTimeCollection(
                storedExport: nil,
                availableDevices: [currentMacDevice],
                status: status,
                deviceSourceLabels: [currentMacDevice.id: "Apple knowledgeC"],
                latestAppleUpdate: nil,
                knowledgeIntervalCount: 0,
                biomeIntervalCount: 0
            )
        }

        // MARK: - Apple Screen Time aggregate store

        /// `ScreenTimeAgent` persists Apple-owned per-device usage blocks. Reading these
        /// aggregates avoids reconstructing totals from focus events, but does not establish
        /// exact parity with the values or grouping rendered by System Settings.
        /// The databases are opened with SQLite read-only/query-only protections and are never
        /// copied into Goalong History.
        private struct AdminUsageBlock {
            let storePriority: Int
            let primaryKey: Int
            let device: AppleScreenTimeDevice
            let start: Date
            let end: Date
            let screenOnDuration: TimeInterval
            let lastUpdatedAt: Date
            let applications: [AppleScreenTimeApplicationUsage]

            var identity: String {
                "\(device.id)|\(start.timeIntervalSinceReferenceDate)|\(end.timeIntervalSinceReferenceDate)"
            }
        }

        private struct AdminStoreRead {
            let blocks: [AdminUsageBlock]
            let devices: [AppleScreenTimeDevice]
            let latestUpdate: Date?
            let permissionDenied: Bool
            let warning: String?
            let readableStoreCount: Int
            let currentMacAliases: Set<String>
            let currentMacNames: Set<String>

            static let empty = AdminStoreRead(
                blocks: [],
                devices: [],
                latestUpdate: nil,
                permissionDenied: false,
                warning: nil,
                readableStoreCount: 0,
                currentMacAliases: [],
                currentMacNames: []
            )
        }

        private struct AdminDeviceRow {
            let primaryKey: Int
            let identifier: String
            let name: String?
            let platform: Int?
        }

        private func readScreenTimeAdminStores(
            interval: DateInterval
        ) -> AdminStoreRead {
            let configured: [(URL?, Bool, Int)] = [
                (paths.screenTimeAdminLocalDatabase, true, 2),
                (paths.screenTimeAdminCloudDatabase, false, 1),
            ]
            var reads: [AdminStoreRead] = []
            for (url, isLocal, priority) in configured {
                guard let url else { continue }
                var status = stat()
                guard Darwin.lstat(url.path, &status) == 0 else {
                    if [EACCES, EPERM].contains(errno) {
                        reads.append(
                            AdminStoreRead(
                                blocks: [],
                                devices: [],
                                latestUpdate: nil,
                                permissionDenied: true,
                                warning: nil,
                                readableStoreCount: 0,
                                currentMacAliases: [],
                                currentMacNames: []
                            )
                        )
                    }
                    continue
                }
                reads.append(
                    readScreenTimeAdminStore(
                        url: url,
                        interval: interval,
                        treatsMacAsCurrentDevice: isLocal,
                        storePriority: priority
                    )
                )
            }
            guard !reads.isEmpty else { return .empty }

            let currentMacAliases = reads.reduce(into: Set<String>()) {
                $0.formUnion($1.currentMacAliases)
            }
            let currentMacNames = reads.reduce(into: Set<String>()) {
                $0.formUnion($1.currentMacNames)
            }
            func canonicalDevice(_ device: AppleScreenTimeDevice) -> AppleScreenTimeDevice {
                let normalizedName = device.displayName.lowercased()
                guard device.id == currentMacDevice.id
                    || currentMacAliases.contains(device.id)
                    || (device.kind == .mac && currentMacNames.contains(normalizedName))
                else { return device }
                return AppleScreenTimeDevice(
                    id: currentMacDevice.id,
                    name: device.name ?? currentMacDevice.name,
                    kind: .mac
                )
            }
            let canonicalBlocks = reads.flatMap(\.blocks).map { block in
                let device = canonicalDevice(block.device)
                return AdminUsageBlock(
                    storePriority: block.storePriority,
                    primaryKey: block.primaryKey,
                    device: device,
                    start: block.start,
                    end: block.end,
                    screenOnDuration: block.screenOnDuration,
                    lastUpdatedAt: block.lastUpdatedAt,
                    applications: block.applications
                )
            }
            var blocksByIdentity: [String: AdminUsageBlock] = [:]
            for block in canonicalBlocks {
                if let existing = blocksByIdentity[block.identity] {
                    let replacement = Self.preferredAdminBlock(existing, block)
                    blocksByIdentity[block.identity] = replacement
                } else {
                    blocksByIdentity[block.identity] = block
                }
            }
            let warnings = reads.compactMap(\.warning)
            return AdminStoreRead(
                blocks: blocksByIdentity.values.sorted {
                    if $0.device.id != $1.device.id { return $0.device.id < $1.device.id }
                    return $0.start < $1.start
                },
                devices: mergeDeviceLists(reads.flatMap(\.devices).map(canonicalDevice)),
                latestUpdate: reads.compactMap(\.latestUpdate).max(),
                permissionDenied: reads.contains(where: \.permissionDenied),
                warning: warnings.isEmpty ? nil : warnings.joined(separator: "; "),
                readableStoreCount: reads.reduce(0) { $0 + $1.readableStoreCount },
                currentMacAliases: currentMacAliases,
                currentMacNames: currentMacNames
            )
        }

        private static func preferredAdminBlock(
            _ lhs: AdminUsageBlock,
            _ rhs: AdminUsageBlock
        ) -> AdminUsageBlock {
            if lhs.lastUpdatedAt != rhs.lastUpdatedAt {
                return lhs.lastUpdatedAt > rhs.lastUpdatedAt ? lhs : rhs
            }
            if lhs.storePriority != rhs.storePriority {
                return lhs.storePriority > rhs.storePriority ? lhs : rhs
            }
            if lhs.applications.count != rhs.applications.count {
                return lhs.applications.count > rhs.applications.count ? lhs : rhs
            }
            return lhs
        }

        private func readScreenTimeAdminStore(
            url: URL,
            interval: DateInterval,
            treatsMacAsCurrentDevice: Bool,
            storePriority: Int
        ) -> AdminStoreRead {
            do {
                let database = try SQLiteReadConnection(path: url.path)
                let required: [String: Set<String>] = [
                    "ZCOREDEVICE": ["Z_PK", "ZIDENTIFIER", "ZNAME", "ZPLATFORM"],
                    "ZUSAGE": ["Z_PK", "ZDEVICE", "ZLASTUPDATEDDATE"],
                    "ZUSAGEBLOCK": [
                        "Z_PK", "ZUSAGE", "ZSTARTDATE", "ZDURATIONINMINUTES",
                        "ZSCREENTIMEINSECONDS", "ZLASTEVENTDATE",
                    ],
                    "ZUSAGECATEGORY": ["Z_PK", "ZBLOCK"],
                    "ZUSAGETIMEDITEM": [
                        "ZCATEGORY", "ZBUNDLEIDENTIFIER", "ZDOMAIN",
                        "ZTOTALTIMEINSECONDS", "ZUSAGETRUSTED",
                    ],
                ]
                let missing = try required.compactMap { table, columns -> String? in
                    let available = try database.tableColumns(table)
                    let absent = columns.subtracting(available).sorted()
                    return absent.isEmpty ? nil : "\(table).\(absent.joined(separator: ","))"
                }
                guard missing.isEmpty else {
                    return AdminStoreRead(
                        blocks: [],
                        devices: [],
                        latestUpdate: latestModificationDate(url),
                        permissionDenied: false,
                        warning: "Apple Screen Time aggregate schema changed: \(missing.joined(separator: "; "))",
                        readableStoreCount: 0,
                        currentMacAliases: [],
                        currentMacNames: []
                    )
                }

                let rawDevices: [AdminDeviceRow] = try database.query(
                    """
                    SELECT Z_PK, COALESCE(ZIDENTIFIER, ''), COALESCE(ZNAME, ''), ZPLATFORM
                    FROM ZCOREDEVICE
                    ORDER BY Z_PK
                    LIMIT 128
                    """
                ) { statement in
                    AdminDeviceRow(
                        primaryKey: SQLiteReadConnection.int(statement, column: 0) ?? 0,
                        identifier: SQLiteReadConnection.string(statement, column: 1),
                        name: {
                            let value = SQLiteReadConnection.string(statement, column: 2)
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                            return value.isEmpty ? nil : value
                        }(),
                        platform: SQLiteReadConnection.int(statement, column: 3)
                    )
                }
                let devicesByPrimaryKey = Dictionary(uniqueKeysWithValues: rawDevices.map { row in
                    (row.primaryKey, adminDevice(from: row, treatsMacAsCurrentDevice: treatsMacAsCurrentDevice))
                })
                let localMacRows = treatsMacAsCurrentDevice
                    ? rawDevices.filter {
                        let nameKind = AppleScreenTimeDeviceIdentityResolver.deviceKind(
                            model: nil,
                            name: $0.name
                        )
                        return nameKind == .mac || Self.deviceKind(platform: $0.platform) == .mac
                    }
                    : []
                let installedAppColumns = try database.tableColumns("ZINSTALLEDAPP")
                let installedDisplayNames: [String: String]
                if installedAppColumns.isSuperset(of: ["ZBUNDLEIDENTIFIER", "ZDISPLAYNAME"]) {
                    let rows: [(String, String)] = try database.query(
                        """
                        SELECT COALESCE(ZBUNDLEIDENTIFIER, ''), COALESCE(ZDISPLAYNAME, '')
                        FROM ZINSTALLEDAPP
                        WHERE ZBUNDLEIDENTIFIER IS NOT NULL AND ZDISPLAYNAME IS NOT NULL
                        LIMIT 20000
                        """
                    ) { statement in
                        let bundle = SQLiteReadConnection.string(statement, column: 0)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        let displayName = SQLiteReadConnection.string(statement, column: 1)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !bundle.isEmpty, !displayName.isEmpty else { return nil }
                        return (bundle.lowercased(), displayName)
                    }
                    installedDisplayNames = rows.reduce(into: [:]) { result, row in
                        result[row.0] = row.1
                    }
                } else {
                    installedDisplayNames = [:]
                }
                let appleStart = interval.start.timeIntervalSinceReferenceDate
                let appleEnd = interval.end.timeIntervalSinceReferenceDate
                let minimumDurations: [Int] = try database.query(
                    """
                    SELECT MIN(ZDURATIONINMINUTES)
                    FROM ZUSAGEBLOCK
                    WHERE ZDURATIONINMINUTES > 0
                      AND ZSTARTDATE < ?
                      AND ZSTARTDATE + (ZDURATIONINMINUTES * 60.0) > ?
                    """,
                    bind: { statement in
                        sqlite3_bind_double(statement, 1, appleEnd)
                        sqlite3_bind_double(statement, 2, appleStart)
                    }
                ) { statement in
                    SQLiteReadConnection.int(statement, column: 0)
                }
                guard let minimumDuration = minimumDurations.first else {
                    return AdminStoreRead(
                        blocks: [],
                        devices: Array(devicesByPrimaryKey.values),
                        latestUpdate: latestModificationDate(url),
                        permissionDenied: false,
                        warning: nil,
                        readableStoreCount: 1,
                        currentMacAliases: Set(localMacRows.map(\.identifier).filter { !$0.isEmpty }),
                        currentMacNames: Set(localMacRows.compactMap(\.name).map { $0.lowercased() })
                    )
                }

                struct RawBlock {
                    let primaryKey: Int
                    let device: AppleScreenTimeDevice
                    let start: Date
                    let end: Date
                    let screenOnDuration: TimeInterval
                    let lastUpdatedAt: Date
                }
                let rawBlocks: [RawBlock] = try database.query(
                    """
                    SELECT
                      b.Z_PK,
                      u.ZDEVICE,
                      b.ZSTARTDATE,
                      b.ZDURATIONINMINUTES,
                      b.ZSCREENTIMEINSECONDS,
                      b.ZLASTEVENTDATE,
                      u.ZLASTUPDATEDDATE
                    FROM ZUSAGEBLOCK b
                    JOIN ZUSAGE u ON u.Z_PK = b.ZUSAGE
                    WHERE b.ZDURATIONINMINUTES = ?
                      AND b.ZSTARTDATE < ?
                      AND b.ZSTARTDATE + (b.ZDURATIONINMINUTES * 60.0) > ?
                    ORDER BY b.ZSTARTDATE, b.Z_PK
                    LIMIT 20000
                    """,
                    bind: { statement in
                        sqlite3_bind_int64(statement, 1, sqlite3_int64(minimumDuration))
                        sqlite3_bind_double(statement, 2, appleEnd)
                        sqlite3_bind_double(statement, 3, appleStart)
                    }
                ) { statement in
                    let primaryKey = SQLiteReadConnection.int(statement, column: 0) ?? 0
                    let devicePrimaryKey = SQLiteReadConnection.int(statement, column: 1) ?? 0
                    guard let device = devicesByPrimaryKey[devicePrimaryKey],
                          let startValue = SQLiteReadConnection.double(statement, column: 2),
                          let durationMinutes = SQLiteReadConnection.double(statement, column: 3),
                          let rawScreenOn = SQLiteReadConnection.double(statement, column: 4),
                          durationMinutes > 0,
                          rawScreenOn >= 0
                    else { return nil }
                    let rawStart = Date(timeIntervalSinceReferenceDate: startValue)
                    let rawEnd = rawStart.addingTimeInterval(durationMinutes * 60)
                    guard let overlap = DateInterval(start: rawStart, end: rawEnd)
                        .intersection(with: interval)
                    else { return nil }
                    let ratio = overlap.duration / max(1, rawEnd.timeIntervalSince(rawStart))
                    let eventUpdate = SQLiteReadConnection.double(statement, column: 5)
                        .map(Date.init(timeIntervalSinceReferenceDate:))
                    let usageUpdate = SQLiteReadConnection.double(statement, column: 6)
                        .map(Date.init(timeIntervalSinceReferenceDate:))
                    return RawBlock(
                        primaryKey: primaryKey,
                        device: device,
                        start: overlap.start,
                        end: overlap.end,
                        screenOnDuration: min(overlap.duration, rawScreenOn * ratio),
                        lastUpdatedAt: maxDate(eventUpdate, usageUpdate) ?? overlap.end
                    )
                }
                let itemsByBlock = try readAdminTimedItems(
                    database: database,
                    appleStart: appleStart,
                    appleEnd: appleEnd,
                    durationMinutes: minimumDuration,
                    installedDisplayNames: installedDisplayNames,
                    blockDurations: Dictionary(uniqueKeysWithValues: rawBlocks.map {
                        ($0.primaryKey, max(1, $0.end.timeIntervalSince($0.start)))
                    })
                )
                let blocks = rawBlocks.map { block in
                    AdminUsageBlock(
                        storePriority: storePriority,
                        primaryKey: block.primaryKey,
                        device: block.device,
                        start: block.start,
                        end: block.end,
                        screenOnDuration: block.screenOnDuration,
                        lastUpdatedAt: block.lastUpdatedAt,
                        applications: itemsByBlock[block.primaryKey] ?? []
                    )
                }
                return AdminStoreRead(
                    blocks: blocks,
                    devices: Array(devicesByPrimaryKey.values),
                    latestUpdate: maxDate(
                        blocks.map(\.lastUpdatedAt).max(),
                        latestModificationDate(url)
                    ),
                    permissionDenied: false,
                    warning: rawBlocks.count == 20000
                        ? "Apple Screen Time aggregate daily block budget reached"
                        : nil,
                    readableStoreCount: 1,
                    currentMacAliases: Set(localMacRows.map(\.identifier).filter { !$0.isEmpty }),
                    currentMacNames: Set(localMacRows.compactMap(\.name).map { $0.lowercased() })
                )
            } catch {
                let denied = Self.looksLikePermissionFailure(error)
                    || (error as? SQLiteReadError)?.code == SQLITE_CANTOPEN
                return AdminStoreRead(
                    blocks: [],
                    devices: [],
                    latestUpdate: nil,
                    permissionDenied: denied,
                    warning: denied ? nil : "Apple Screen Time aggregate store: \(error)",
                    readableStoreCount: 0,
                    currentMacAliases: [],
                    currentMacNames: []
                )
            }
        }

        private func adminDevice(
            from row: AdminDeviceRow,
            treatsMacAsCurrentDevice: Bool
        ) -> AppleScreenTimeDevice {
            let kindFromName = AppleScreenTimeDeviceIdentityResolver.deviceKind(
                model: nil,
                name: row.name
            )
            let kind = kindFromName == .unknown
                ? Self.deviceKind(platform: row.platform)
                : kindFromName
            if treatsMacAsCurrentDevice, kind == .mac {
                return AppleScreenTimeDevice(
                    id: currentMacDevice.id,
                    name: row.name ?? currentMacDevice.name,
                    kind: .mac
                )
            }
            let identifier = row.identifier.trimmingCharacters(in: .whitespacesAndNewlines)
            return AppleScreenTimeDevice(
                id: identifier.isEmpty ? "screen-time-device:\(row.primaryKey)" : identifier,
                name: row.name,
                kind: kind
            )
        }

        private func readAdminTimedItems(
            database: SQLiteReadConnection,
            appleStart: TimeInterval,
            appleEnd: TimeInterval,
            durationMinutes: Int,
            installedDisplayNames: [String: String],
            blockDurations: [Int: TimeInterval]
        ) throws -> [Int: [AppleScreenTimeApplicationUsage]] {
            struct TimedItem {
                let blockPrimaryKey: Int
                let bundleIdentifier: String?
                let displayName: String?
                let duration: TimeInterval
            }
            let rows: [TimedItem] = try database.query(
                """
                SELECT
                  c.ZBLOCK,
                  COALESCE(i.ZBUNDLEIDENTIFIER, ''),
                  COALESCE(i.ZDOMAIN, ''),
                  i.ZTOTALTIMEINSECONDS
                FROM ZUSAGETIMEDITEM i
                JOIN ZUSAGECATEGORY c ON c.Z_PK = i.ZCATEGORY
                JOIN ZUSAGEBLOCK b ON b.Z_PK = c.ZBLOCK
                WHERE b.ZDURATIONINMINUTES = ?
                  AND b.ZSTARTDATE < ?
                  AND b.ZSTARTDATE + (b.ZDURATIONINMINUTES * 60.0) > ?
                  AND COALESCE(i.ZUSAGETRUSTED, 1) != 0
                  AND i.ZTOTALTIMEINSECONDS > 0
                ORDER BY c.ZBLOCK, i.ZTOTALTIMEINSECONDS DESC
                LIMIT 100000
                """,
                bind: { statement in
                    sqlite3_bind_int64(statement, 1, sqlite3_int64(durationMinutes))
                    sqlite3_bind_double(statement, 2, appleEnd)
                    sqlite3_bind_double(statement, 3, appleStart)
                }
            ) { statement in
                let blockPrimaryKey = SQLiteReadConnection.int(statement, column: 0) ?? 0
                let bundle = SQLiteReadConnection.string(statement, column: 1)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let domain = SQLiteReadConnection.string(statement, column: 2)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard let rawDuration = SQLiteReadConnection.double(statement, column: 3),
                      rawDuration > 0,
                      let maximum = blockDurations[blockPrimaryKey]
                else { return nil }
                // Apple can preserve the originating browser bundle on a web-domain row.
                // The domain is the user-visible Screen Time item, so it must win over the
                // browser identifier or the website would be misclassified as another app row.
                if !domain.isEmpty {
                    return TimedItem(
                        blockPrimaryKey: blockPrimaryKey,
                        bundleIdentifier: "website:\(domain.lowercased())",
                        displayName: domain,
                        duration: min(maximum, rawDuration)
                    )
                }
                if !bundle.isEmpty {
                    return TimedItem(
                        blockPrimaryKey: blockPrimaryKey,
                        bundleIdentifier: bundle,
                        displayName: installedDisplayNames[bundle.lowercased()]
                            ?? Self.applicationDisplayName(bundle),
                        duration: min(maximum, rawDuration)
                    )
                }
                return nil
            }
            return Dictionary(grouping: rows, by: \.blockPrimaryKey).mapValues { items in
                var durationByIdentifier: [String: TimedItem] = [:]
                for item in items {
                    let key = item.bundleIdentifier ?? item.displayName ?? "unknown"
                    if let current = durationByIdentifier[key] {
                        durationByIdentifier[key] = TimedItem(
                            blockPrimaryKey: item.blockPrimaryKey,
                            bundleIdentifier: item.bundleIdentifier ?? current.bundleIdentifier,
                            displayName: item.displayName ?? current.displayName,
                            duration: min(
                                blockDurations[item.blockPrimaryKey] ?? .greatestFiniteMagnitude,
                                current.duration + item.duration
                            )
                        )
                    } else {
                        durationByIdentifier[key] = item
                    }
                }
                return durationByIdentifier.values.map {
                    AppleScreenTimeApplicationUsage(
                        bundleIdentifier: $0.bundleIdentifier,
                        displayName: $0.displayName,
                        duration: $0.duration
                    )
                }
                .sorted {
                    if $0.duration != $1.duration { return $0.duration > $1.duration }
                    return $0.resolvedName.localizedCaseInsensitiveCompare($1.resolvedName) == .orderedAscending
                }
            }
        }

        private func makeAdminReports(
            from blocks: [AdminUsageBlock]
        ) -> [AppleScreenTimeDeviceReport] {
            Dictionary(grouping: blocks, by: { $0.device.id })
                .values
                .compactMap { rows -> AppleScreenTimeDeviceReport? in
                    guard let first = rows.first else { return nil }
                    return AppleScreenTimeDeviceReport(
                        device: first.device,
                        lastUpdatedAt: rows.map(\.lastUpdatedAt).max() ?? .distantPast,
                        segments: rows.map { row in
                            AppleScreenTimeSegment(
                                start: row.start,
                                end: row.end,
                                totalScreenOnDuration: row.screenOnDuration,
                                applications: row.applications
                            )
                        }
                    )
                }
        }

        // MARK: - knowledgeC

        private func readKnowledgeIntervals(
            interval: DateInterval,
            catalog: [String: DeviceCatalogEntry]
        ) -> SourceRead<UsageInterval> {
            guard fileManager.fileExists(atPath: paths.knowledgeDatabase.path) else {
                return SourceRead(values: [], latestUpdate: nil, permissionDenied: false, warning: nil)
            }

            do {
                let database = try SQLiteReadConnection(path: paths.knowledgeDatabase.path)
                let rows = try queryKnowledgeRows(database: database, interval: interval)
                let remoteIDs = Set(catalog.keys)
                let values = rows.compactMap { row -> UsageInterval? in
                    guard row.end > row.start else { return nil }
                    let start = max(row.start, interval.start)
                    let end = min(row.end, interval.end)
                    guard end > start else { return nil }

                    let modelKind = Self.deviceKind(model: row.model)
                    let device: AppleScreenTimeDevice
                    if row.deviceID.isEmpty
                        || (modelKind == .mac && !remoteIDs.contains(row.deviceID))
                    {
                        device = currentMacDevice
                    } else if let known = catalog[row.deviceID]?.device {
                        let knowledgeDevice = Self.makeRemoteDevice(
                            id: row.deviceID,
                            hardwareIdentifier: row.model,
                            platform: nil
                        )
                        device = Self.moreSpecificDevice(known, knowledgeDevice)
                    } else {
                        device = Self.makeRemoteDevice(
                            id: row.deviceID,
                            hardwareIdentifier: row.model,
                            platform: nil
                        )
                    }

                    return UsageInterval(
                        device: device,
                        bundleIdentifier: row.bundleIdentifier,
                        displayName: Self.applicationDisplayName(row.bundleIdentifier),
                        start: start,
                        end: end,
                        source: .knowledgeC
                    )
                }

                return SourceRead(
                    values: values,
                    latestUpdate: latestModificationDate(paths.knowledgeDatabase)
                        ?? values.map(\.end).max(),
                    permissionDenied: false,
                    warning: nil
                )
            } catch {
                let denied = Self.looksLikePermissionFailure(error)
                return SourceRead(
                    values: [],
                    latestUpdate: nil,
                    permissionDenied: denied,
                    warning: denied ? nil : "knowledgeC: \(error)"
                )
            }
        }

        private struct KnowledgeRow {
            let bundleIdentifier: String
            let start: Date
            let end: Date
            let deviceID: String
            let model: String
        }

        private func queryKnowledgeRows(
            database: SQLiteReadConnection,
            interval: DateInterval
        ) throws -> [KnowledgeRow] {
            let appleEpochOffset: TimeInterval = 978_307_200
            let start = interval.start.timeIntervalSince1970 - appleEpochOffset
            let end = interval.end.timeIntervalSince1970 - appleEpochOffset
            let objectColumns = try database.tableColumns("ZOBJECT")
            let metadataColumns = try database.tableColumns("ZSTRUCTUREDMETADATA")
            let (streamColumn, metadataJoin) = try Self.knowledgeStreamReference(
                objectColumns: objectColumns,
                metadataColumns: metadataColumns
            )

            let canonical = """
                SELECT
                  COALESCE(ZOBJECT.ZVALUESTRING, ''),
                  ZOBJECT.ZSTARTDATE,
                  ZOBJECT.ZENDDATE,
                  COALESCE(ZSOURCE.ZDEVICEID, ''),
                  COALESCE(ZSYNCPEER.ZMODEL, '')
                FROM ZOBJECT
                  \(metadataJoin)
                  LEFT JOIN ZSOURCE
                    ON ZOBJECT.ZSOURCE = ZSOURCE.Z_PK
                  LEFT JOIN ZSYNCPEER
                    ON ZSOURCE.ZDEVICEID = ZSYNCPEER.ZDEVICEID
                WHERE \(streamColumn) = '/app/usage'
                  AND ZOBJECT.ZENDDATE > ?1
                  AND ZOBJECT.ZSTARTDATE < ?2
                ORDER BY ZOBJECT.ZSTARTDATE ASC
                """

            return try database.query(canonical, bind: { statement in
                sqlite3_bind_double(statement, 1, start)
                sqlite3_bind_double(statement, 2, end)
            }) { statement in
                guard let startValue = SQLiteReadConnection.double(statement, column: 1),
                      let endValue = SQLiteReadConnection.double(statement, column: 2)
                else { return nil }
                let bundle = SQLiteReadConnection.string(statement, column: 0)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !bundle.isEmpty else { return nil }
                return KnowledgeRow(
                    bundleIdentifier: bundle,
                    start: Date(timeIntervalSince1970: startValue + appleEpochOffset),
                    end: Date(timeIntervalSince1970: endValue + appleEpochOffset),
                    deviceID: SQLiteReadConnection.string(statement, column: 3),
                    model: SQLiteReadConnection.string(statement, column: 4)
                )
            }
        }

        static func knowledgeStreamReference(
            objectColumns: Set<String>,
            metadataColumns: Set<String>
        ) throws -> (column: String, join: String) {
            if objectColumns.contains("ZSTREAMNAME") {
                return ("ZOBJECT.ZSTREAMNAME", "")
            }
            if metadataColumns.contains("ZSTREAMNAME") {
                return (
                    "ZSTRUCTUREDMETADATA.ZSTREAMNAME",
                    """
                      LEFT JOIN ZSTRUCTUREDMETADATA
                        ON ZOBJECT.ZSTRUCTUREDMETADATA = ZSTRUCTUREDMETADATA.Z_PK
                    """
                )
            }
            throw SQLiteReadError(
                code: SQLITE_SCHEMA,
                message: "knowledgeC does not expose an /app/usage stream column"
            )
        }

        // MARK: - Biome

        private func readScreenTimeAppUsageIntervals(
            interval: DateInterval,
            now: Date,
            catalog: [String: DeviceCatalogEntry]
        ) -> SourceRead<UsageInterval> {
            var reads: [SourceRead<UsageInterval>] = []
            if let directory = paths.biomeScreenTimeAppUsageDirectory,
               fileManager.fileExists(atPath: directory.path)
            {
                reads.append(
                    readScreenTimeAppUsageDevice(
                        directory: directory,
                        device: currentMacDevice,
                        interval: interval,
                        now: now
                    )
                )
            }

            if let remoteRoot = paths.biomeRemoteScreenTimeAppUsageDirectory,
               fileManager.fileExists(atPath: remoteRoot.path)
            {
                do {
                    let directories = try fileManager.contentsOfDirectory(
                        at: remoteRoot,
                        includingPropertiesForKeys: [.isDirectoryKey],
                        options: [.skipsHiddenFiles]
                    )
                    let remoteDirectories = directories.filter {
                        (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                    }
                    if remoteDirectories.count > 32 {
                        reads.append(
                            SourceRead(
                                values: [],
                                latestUpdate: latestModificationDate(remoteRoot),
                                permissionDenied: false,
                                warning: "ScreenTime.AppUsage exposes too many remote devices to scan safely"
                            )
                        )
                    } else {
                        for directory in remoteDirectories.sorted(by: { $0.path < $1.path }) {
                            let id = directory.lastPathComponent
                            let device = catalog[id]?.device
                                ?? Self.makeRemoteDevice(id: id, hardwareIdentifier: nil, platform: nil)
                            reads.append(
                                readScreenTimeAppUsageDevice(
                                    directory: directory,
                                    device: device,
                                    interval: interval,
                                    now: now
                                )
                            )
                        }
                    }
                } catch {
                    let denied = Self.looksLikePermissionFailure(error)
                    reads.append(
                        SourceRead(
                            values: [],
                            latestUpdate: nil,
                            permissionDenied: denied,
                            warning: denied ? nil : "ScreenTime.AppUsage remote devices: \(error)"
                        )
                    )
                }
            }

            let warnings = reads.compactMap(\.warning)
            return SourceRead(
                values: reads.flatMap(\.values),
                latestUpdate: reads.compactMap(\.latestUpdate).max(),
                permissionDenied: reads.contains(where: \.permissionDenied),
                warning: warnings.isEmpty ? nil : warnings.joined(separator: "; ")
            )
        }

        private func readScreenTimeAppUsageDevice(
            directory: URL,
            device: AppleScreenTimeDevice,
            interval: DateInterval,
            now: Date
        ) -> SourceRead<UsageInterval> {
            do {
                let files = try regularFiles(recursivelyIn: directory).filter { file in
                    !file.pathComponents.contains { $0.caseInsensitiveCompare("tombstone") == .orderedSame }
                }
                let maximumFiles = 512
                let maximumRelevantEvents = 250_000
                guard files.count <= maximumFiles else {
                    return SourceRead(
                        values: [],
                        latestUpdate: latestModificationDate(directory),
                        permissionDenied: false,
                        warning: "ScreenTime.AppUsage has too many source segments to scan safely"
                    )
                }

                var eventsInsideInterval: [AppleBiomeScreenTimeAppUsageEvent] = []
                var latestBeforeInterval: [String: AppleBiomeScreenTimeAppUsageEvent] = [:]
                var earliestAfterInterval: [String: AppleBiomeScreenTimeAppUsageEvent] = [:]
                var latestModification: Date?
                var latestEvent: Date?
                var malformedCount = 0
                var exceededRelevantEventBudget = false

                func retainedEventCount() -> Int {
                    eventsInsideInterval.count
                        + latestBeforeInterval.count
                        + earliestAfterInterval.count
                }

                func retainRelevantEvents(_ events: [AppleBiomeScreenTimeAppUsageEvent]) {
                    for event in events {
                        latestEvent = maxDate(latestEvent, event.timestamp)
                        let key = event.canonicalBundleIdentifier.lowercased()
                        if event.timestamp < interval.start {
                            if let existing = latestBeforeInterval[key] {
                                if event.timestamp > existing.timestamp {
                                    latestBeforeInterval[key] = event
                                }
                            } else if retainedEventCount() < maximumRelevantEvents {
                                latestBeforeInterval[key] = event
                            } else {
                                exceededRelevantEventBudget = true
                            }
                        } else if event.timestamp <= interval.end {
                            if retainedEventCount() < maximumRelevantEvents {
                                eventsInsideInterval.append(event)
                            } else {
                                exceededRelevantEventBudget = true
                            }
                        } else if let existing = earliestAfterInterval[key] {
                            if event.timestamp < existing.timestamp {
                                earliestAfterInterval[key] = event
                            }
                        } else if retainedEventCount() < maximumRelevantEvents {
                            earliestAfterInterval[key] = event
                        } else {
                            exceededRelevantEventBudget = true
                        }
                    }
                }

                for file in files {
                    let fingerprint = try fileFingerprint(file)
                    latestModification = maxDate(latestModification, fingerprint.modifiedAt)
                    let key = file.standardizedFileURL.path
                    if let cached = biomeFileCache.screenTimeAppUsageEvents(
                        for: key,
                        fingerprint: fingerprint
                    ) {
                        retainRelevantEvents(cached)
                        continue
                    }

                    do {
                        let data = try Data(contentsOf: file, options: [.mappedIfSafe])
                        let events = try AppleBiomeSEGBDecoder.decodeScreenTimeAppUsage(data)
                        biomeFileCache.insert(
                            path: key,
                            fingerprint: fingerprint,
                            screenTimeAppUsageEvents: events,
                            retainedBytes: Self.estimatedRetainedBytes(
                                sourceBytes: fingerprint.size,
                                screenTimeAppUsageEvents: events
                            )
                        )
                        retainRelevantEvents(events)
                    } catch {
                        malformedCount += 1
                    }
                }

                let existing = Set(files.map { $0.standardizedFileURL.path })
                biomeFileCache.retainFiles(existing, under: directory.standardizedFileURL.path)

                if exceededRelevantEventBudget {
                    return SourceRead(
                        values: [],
                        latestUpdate: maxDate(latestModification, latestEvent),
                        permissionDenied: false,
                        warning: "ScreenTime.AppUsage exceeded Goalong's bounded daily event budget"
                    )
                }

                let allEvents = Array(latestBeforeInterval.values)
                    + eventsInsideInterval
                    + Array(earliestAfterInterval.values)
                let isToday = calendar.isDateInToday(interval.start)
                let stitched = AppleBiomeScreenTimeAppUsageIntervalBuilder.intervals(
                    from: allEvents,
                    closeOpenIntervalAt: isToday ? min(now, interval.end) : nil,
                    maximumOpenIntervalAge: isToday ? 20 * 60 : nil
                )
                let values = stitched.compactMap { row -> UsageInterval? in
                    let start = max(row.start, interval.start)
                    let end = min(row.end, interval.end)
                    guard end > start else { return nil }
                    return UsageInterval(
                        device: device,
                        bundleIdentifier: row.bundleIdentifier,
                        displayName: Self.applicationDisplayName(row.bundleIdentifier),
                        start: start,
                        end: end,
                        source: .screenTimeAppUsage
                    )
                }
                let warning = malformedCount > 0
                    ? "Skipped \(malformedCount) unrecognized Apple ScreenTime.AppUsage file\(malformedCount == 1 ? "" : "s")"
                    : nil
                return SourceRead(
                    values: values,
                    latestUpdate: maxDate(latestModification, latestEvent),
                    permissionDenied: false,
                    warning: warning
                )
            } catch {
                let denied = Self.looksLikePermissionFailure(error)
                return SourceRead(
                    values: [],
                    latestUpdate: nil,
                    permissionDenied: denied,
                    warning: denied ? nil : "ScreenTime.AppUsage: \(error)"
                )
            }
        }

        private func readBiomeIntervals(
            interval: DateInterval,
            now: Date,
            catalog: [String: DeviceCatalogEntry]
        ) -> SourceRead<UsageInterval> {
            defer {
                biomeFileCache.removeMissingFiles { [fileManager] path in
                    fileManager.fileExists(atPath: path)
                }
            }
            var values: [UsageInterval] = []
            var latestUpdate: Date?
            var permissionDenied = false
            var warnings: [String] = []

            let local = readBiomeDevice(
                directory: paths.biomeLocalDirectory,
                device: currentMacDevice,
                interval: interval,
                now: now
            )
            values.append(contentsOf: local.values)
            latestUpdate = maxDate(latestUpdate, local.latestUpdate)
            permissionDenied = permissionDenied || local.permissionDenied
            if let warning = local.warning { warnings.append(warning) }

            if fileManager.fileExists(atPath: paths.biomeRemoteDirectory.path) {
                do {
                    let remoteDirectories = try fileManager.contentsOfDirectory(
                        at: paths.biomeRemoteDirectory,
                        includingPropertiesForKeys: [.isDirectoryKey],
                        options: [.skipsHiddenFiles]
                    )
                    for directory in remoteDirectories {
                        let resourceValues = try? directory.resourceValues(forKeys: [.isDirectoryKey])
                        guard resourceValues?.isDirectory == true else { continue }
                        let id = directory.lastPathComponent
                        let device = catalog[id]?.device
                            ?? Self.makeRemoteDevice(id: id, hardwareIdentifier: nil, platform: nil)
                        let read = readBiomeDevice(
                            directory: directory,
                            device: device,
                            interval: interval,
                            now: now
                        )
                        values.append(contentsOf: read.values)
                        latestUpdate = maxDate(latestUpdate, read.latestUpdate)
                        permissionDenied = permissionDenied || read.permissionDenied
                        if let warning = read.warning { warnings.append(warning) }
                    }
                } catch {
                    permissionDenied = permissionDenied || Self.looksLikePermissionFailure(error)
                    if !Self.looksLikePermissionFailure(error) {
                        warnings.append("Biome remote devices: \(error)")
                    }
                }
            }

            return SourceRead(
                values: values,
                latestUpdate: latestUpdate,
                permissionDenied: permissionDenied,
                warning: warnings.isEmpty ? nil : warnings.joined(separator: "; ")
            )
        }

        private func readBiomeDevice(
            directory: URL,
            device: AppleScreenTimeDevice,
            interval: DateInterval,
            now: Date
        ) -> SourceRead<UsageInterval> {
            guard fileManager.fileExists(atPath: directory.path) else {
                return SourceRead(values: [], latestUpdate: nil, permissionDenied: false, warning: nil)
            }

            do {
                let files = try regularFiles(recursivelyIn: directory)
                var allEvents: [AppleBiomeFocusEvent] = []
                var latestModification: Date?
                var malformedCount = 0

                for file in files {
                    let fingerprint = try fileFingerprint(file)
                    latestModification = maxDate(latestModification, fingerprint.modifiedAt)
                    let key = file.standardizedFileURL.path
                    if let cachedEvents = biomeFileCache.events(for: key, fingerprint: fingerprint) {
                        allEvents.append(contentsOf: cachedEvents)
                        continue
                    }

                    do {
                        let data = try Data(contentsOf: file, options: [.mappedIfSafe])
                        let events = try AppleBiomeSEGBDecoder.decode(data)
                        biomeFileCache.insert(
                            path: key,
                            fingerprint: fingerprint,
                            events: events,
                            retainedBytes: Self.estimatedRetainedBytes(
                                sourceBytes: fingerprint.size,
                                events: events
                            )
                        )
                        allEvents.append(contentsOf: events)
                    } catch AppleBiomeFormatError.unsupportedFormat {
                        malformedCount += 1
                    } catch {
                        malformedCount += 1
                    }
                }

                let existing = Set(files.map { $0.standardizedFileURL.path })
                biomeFileCache.retainFiles(existing, under: directory.standardizedFileURL.path)

                let latestEvent = allEvents.map(\.timestamp).max()
                let canCloseLiveInterval = calendar.isDateInToday(interval.start)
                    && latestEvent.map { now.timeIntervalSince($0) <= 20 * 60 } == true
                let stitched = AppleBiomeIntervalBuilder.intervals(
                    from: allEvents,
                    closeOpenIntervalAt: canCloseLiveInterval ? min(now, interval.end) : nil
                )
                let values = stitched.compactMap { row -> UsageInterval? in
                    let start = max(row.start, interval.start)
                    let end = min(row.end, interval.end)
                    guard end > start else { return nil }
                    return UsageInterval(
                        device: device,
                        bundleIdentifier: row.bundleIdentifier,
                        displayName: Self.applicationDisplayName(row.bundleIdentifier),
                        start: start,
                        end: end,
                        source: .biome
                    )
                }

                let warning = malformedCount > 0
                    ? "Skipped \(malformedCount) unrecognized Apple Biome file\(malformedCount == 1 ? "" : "s")"
                    : nil
                return SourceRead(
                    values: values,
                    latestUpdate: maxDate(latestModification, latestEvent),
                    permissionDenied: false,
                    warning: warning
                )
            } catch {
                let denied = Self.looksLikePermissionFailure(error)
                return SourceRead(
                    values: [],
                    latestUpdate: nil,
                    permissionDenied: denied,
                    warning: denied ? nil : "Biome \(device.displayName): \(error)"
                )
            }
        }

        private func regularFiles(recursivelyIn directory: URL) throws -> [URL] {
            guard let enumerator = fileManager.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else {
                throw CocoaError(.fileReadNoPermission)
            }

            var files: [URL] = []
            for case let file as URL in enumerator {
                let values = try file.resourceValues(forKeys: [.isRegularFileKey])
                if values.isRegularFile == true { files.append(file) }
            }
            return files.sorted { $0.path < $1.path }
        }

        // MARK: - Apple device identity

        /// Reads only the bounded, non-secret device fields needed to turn an Apple hardware
        /// model into the friendly name already chosen by the user. The source database remains
        /// read-only and the result is kept only in memory while the database fingerprint matches.
        func readAppleAccountDeviceCatalog() -> [AppleAccountDeviceMetadata] {
            let url = paths.appleAccountDeviceDatabase
            guard fileManager.fileExists(atPath: url.path) else {
                accountDeviceCatalogCache = nil
                return []
            }

            do {
                let fingerprint = try sqliteFingerprint(url)
                if let cached = accountDeviceCatalogCache,
                   cached.fingerprint == fingerprint
                {
                    return cached.devices
                }

                let database = try SQLiteReadConnection(path: url.path)
                let required = Set(["name", "model", "os", "trusted", "last_updated_date"])
                guard try database.tableColumns("device_list").isSuperset(of: required) else {
                    accountDeviceCatalogCache = nil
                    return []
                }

                let devices: [AppleAccountDeviceMetadata] = try database.query(
                    """
                    SELECT
                      COALESCE(name, ''),
                      COALESCE(model, ''),
                      COALESCE(os, ''),
                      last_updated_date
                    FROM device_list
                    WHERE trusted = 1
                    ORDER BY last_updated_date DESC
                    LIMIT 64
                    """
                ) { statement in
                    let name = SQLiteReadConnection.string(statement, column: 0)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty else { return nil }
                    let model = SQLiteReadConnection.string(statement, column: 1)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let operatingSystem = SQLiteReadConnection.string(statement, column: 2)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let updated = SQLiteReadConnection.double(statement, column: 3)
                        .map(Date.init(timeIntervalSince1970:))
                    let device = AppleAccountDeviceMetadata(
                        name: name,
                        model: model.isEmpty ? nil : model,
                        operatingSystem: operatingSystem.isEmpty ? nil : operatingSystem,
                        lastUpdatedAt: updated
                    )
                    return device.kind == .unknown ? nil : device
                }
                accountDeviceCatalogCache = AppleAccountDeviceCatalogCache(
                    fingerprint: fingerprint,
                    devices: devices
                )
                return devices
            } catch {
                // Naming is an optional enrichment. Never let a missing, protected or changed
                // Apple account database hide otherwise valid Screen Time usage.
                accountDeviceCatalogCache = nil
                return []
            }
        }

        // MARK: - Biome device catalog

        private struct DeviceCatalogEntry {
            let device: AppleScreenTimeDevice
            let hardwareIdentifier: String?
            let platform: Int?
        }

        private func readDeviceCatalog() -> SourceReadDictionary<DeviceCatalogEntry> {
            var entries: [String: DeviceCatalogEntry] = [:]
            var denied = false
            var warning: String?

            if fileManager.fileExists(atPath: paths.biomeSyncDatabase.path) {
                do {
                    let database = try SQLiteReadConnection(path: paths.biomeSyncDatabase.path)
                    let hasHardwareID = try database.tableColumns("DevicePeer").contains("hardware_id")
                    let sql = hasHardwareID
                        ? "SELECT DISTINCT device_identifier, COALESCE(hardware_id, ''), platform FROM DevicePeer WHERE device_identifier IS NOT NULL"
                        : "SELECT DISTINCT device_identifier, '', platform FROM DevicePeer WHERE device_identifier IS NOT NULL"
                    let rows: [(String, String, Int?)] = try database.query(sql) { statement in
                        let id = SQLiteReadConnection.string(statement, column: 0)
                        guard !id.isEmpty else { return nil }
                        let hardware = SQLiteReadConnection.string(statement, column: 1)
                        let platform = SQLiteReadConnection.int(statement, column: 2)
                        return (id, hardware, platform)
                    }
                    for (id, descriptors) in Dictionary(grouping: rows, by: { $0.0 }) {
                        let resolved = Self.preferredRemoteDevice(
                            id: id,
                            descriptors: descriptors.map {
                                AppleBiomeDeviceDescriptor(
                                    hardwareIdentifier: $0.1.isEmpty ? nil : $0.1,
                                    platform: $0.2
                                )
                            }
                        )
                        entries[id] = DeviceCatalogEntry(
                            device: resolved,
                            hardwareIdentifier: Self.hardwareIdentifier(from: resolved),
                            platform: descriptors.compactMap(\.2).sorted().first
                        )
                    }
                } catch {
                    denied = Self.looksLikePermissionFailure(error)
                    if !denied { warning = "Biome device catalog: \(error)" }
                }
            }

            // The stream directory is authoritative even when sync.db changes schema.
            if fileManager.fileExists(atPath: paths.biomeRemoteDirectory.path) {
                do {
                    let directories = try fileManager.contentsOfDirectory(
                        at: paths.biomeRemoteDirectory,
                        includingPropertiesForKeys: [.isDirectoryKey],
                        options: [.skipsHiddenFiles]
                    )
                    for directory in directories {
                        let values = try? directory.resourceValues(forKeys: [.isDirectoryKey])
                        guard values?.isDirectory == true else { continue }
                        let id = directory.lastPathComponent
                        guard entries[id] == nil else { continue }
                        entries[id] = DeviceCatalogEntry(
                            device: Self.makeRemoteDevice(id: id, hardwareIdentifier: nil, platform: nil),
                            hardwareIdentifier: nil,
                            platform: nil
                        )
                    }
                } catch {
                    denied = denied || Self.looksLikePermissionFailure(error)
                    if warning == nil, !Self.looksLikePermissionFailure(error) {
                        warning = "Biome remote directory: \(error)"
                    }
                }
            }

            return SourceReadDictionary(
                devices: entries,
                permissionDenied: denied,
                warning: warning
            )
        }

        // MARK: - Merge and report construction

        private enum UsageSource: Int {
            case biome = 1
            case knowledgeC = 2
            case screenTimeAppUsage = 3
        }

        private struct UsageInterval {
            let device: AppleScreenTimeDevice
            let bundleIdentifier: String
            let displayName: String?
            let start: Date
            let end: Date
            let source: UsageSource

            init(
                device: AppleScreenTimeDevice,
                bundleIdentifier: String,
                displayName: String?,
                start: Date,
                end: Date,
                source: UsageSource
            ) {
                self.device = device
                self.bundleIdentifier = bundleIdentifier
                self.displayName = displayName
                self.start = start
                self.end = end
                self.source = source
            }

            var duration: TimeInterval { end.timeIntervalSince(start) }

            func replacing(start: Date, end: Date) -> UsageInterval {
                UsageInterval(
                    device: device,
                    bundleIdentifier: bundleIdentifier,
                    displayName: displayName,
                    start: start,
                    end: end,
                    source: source
                )
            }
        }

        private func mergeIntervals(
            preferred: [UsageInterval],
            supplemental: [UsageInterval]
        ) -> [UsageInterval] {
            let preferredNormalized = normalizeIntervals(preferred)
            var accepted = preferredNormalized

            for candidate in supplemental.sorted(by: intervalOrder) {
                var fragments = [candidate]
                // The caller supplies the more authoritative Apple source first. Supplemental
                // rows fill only physical coverage gaps, so a lower-priority source cannot add
                // conflicting attribution for time the preferred source already explains.
                for existing in preferredNormalized where existing.device.id == candidate.device.id {
                    fragments = fragments.flatMap { subtract($0, occupiedBy: existing) }
                    if fragments.isEmpty { break }
                }
                accepted.append(contentsOf: fragments)
            }
            return mergeAdjacent(normalizeIntervals(accepted))
        }

        private func normalizeIntervals(_ intervals: [UsageInterval]) -> [UsageInterval] {
            var accepted: [UsageInterval] = []
            let ordered = intervals.sorted {
                if $0.source.rawValue != $1.source.rawValue {
                    return $0.source.rawValue > $1.source.rawValue
                }
                return intervalOrder($0, $1)
            }

            for candidate in ordered where candidate.duration > 0 {
                var fragments = [candidate]
                for existing in accepted
                    where existing.device.id == candidate.device.id
                        && sameApplication(existing, candidate)
                {
                    fragments = fragments.flatMap { subtract($0, occupiedBy: existing) }
                    if fragments.isEmpty { break }
                }
                accepted.append(contentsOf: fragments)
            }
            return accepted.sorted(by: intervalOrder)
        }

        private func subtract(_ candidate: UsageInterval, occupiedBy existing: UsageInterval) -> [UsageInterval] {
            guard candidate.device.id == existing.device.id,
                  candidate.start < existing.end,
                  existing.start < candidate.end
            else { return [candidate] }

            var output: [UsageInterval] = []
            if candidate.start < existing.start {
                output.append(candidate.replacing(start: candidate.start, end: existing.start))
            }
            if existing.end < candidate.end {
                output.append(candidate.replacing(start: existing.end, end: candidate.end))
            }
            return output.filter { $0.duration > 0 }
        }

        private func mergeAdjacent(_ intervals: [UsageInterval]) -> [UsageInterval] {
            var output: [UsageInterval] = []
            for interval in intervals.sorted(by: intervalOrder) {
                if let last = output.last,
                   last.device.id == interval.device.id,
                   last.bundleIdentifier == interval.bundleIdentifier,
                   last.source == interval.source,
                   interval.start.timeIntervalSince(last.end) <= 1,
                   interval.start >= last.end.addingTimeInterval(-1)
                {
                    output[output.count - 1] = last.replacing(
                        start: last.start,
                        end: max(last.end, interval.end)
                    )
                } else {
                    output.append(interval)
                }
            }
            return output
        }

        private func intervalOrder(_ lhs: UsageInterval, _ rhs: UsageInterval) -> Bool {
            if lhs.device.id != rhs.device.id { return lhs.device.id < rhs.device.id }
            if lhs.start != rhs.start { return lhs.start < rhs.start }
            if lhs.end != rhs.end { return lhs.end < rhs.end }
            return lhs.bundleIdentifier < rhs.bundleIdentifier
        }

        private func makeReports(from intervals: [UsageInterval]) -> [AppleScreenTimeDeviceReport] {
            Dictionary(grouping: intervals, by: { $0.device.id })
                .values
                .compactMap { deviceRows -> AppleScreenTimeDeviceReport? in
                    guard let first = deviceRows.first else { return nil }
                    let device = deviceRows.dropFirst().reduce(first.device) { current, row in
                        Self.moreSpecificDevice(current, row.device)
                    }
                    let segments = makeTimelineSegments(from: deviceRows)
                    return AppleScreenTimeDeviceReport(
                        device: device,
                        lastUpdatedAt: deviceRows.map(\.end).max() ?? Date.distantPast,
                        segments: segments
                    )
                }
                .sorted {
                    if $0.device.id == currentMacDevice.id { return true }
                    if $1.device.id == currentMacDevice.id { return false }
                    if $0.device.kind.rawValue != $1.device.kind.rawValue {
                        return $0.device.kind.rawValue < $1.device.kind.rawValue
                    }
                    return $0.device.displayName.localizedCaseInsensitiveCompare($1.device.displayName) == .orderedAscending
                }
        }

        /// Apple may retain concurrent usage rows for helpers and the application they operate.
        /// Keep every application's duration while representing physical screen-on coverage once.
        private func makeTimelineSegments(from intervals: [UsageInterval]) -> [AppleScreenTimeSegment] {
            guard !intervals.isEmpty else { return [] }

            var starting: [Date: [UsageInterval]] = [:]
            var ending: [Date: [UsageInterval]] = [:]
            var boundarySet = Set<Date>()
            for interval in intervals where interval.duration > 0 {
                starting[interval.start, default: []].append(interval)
                ending[interval.end, default: []].append(interval)
                boundarySet.insert(interval.start)
                boundarySet.insert(interval.end)
            }

            let boundaries = boundarySet.sorted()
            guard boundaries.count > 1 else { return [] }

            var active: [String: UsageInterval] = [:]
            var segments: [AppleScreenTimeSegment] = []
            segments.reserveCapacity(boundaries.count - 1)

            for index in 0 ..< boundaries.count - 1 {
                let start = boundaries[index]
                let end = boundaries[index + 1]

                for interval in ending[start] ?? [] {
                    active.removeValue(forKey: applicationKey(interval))
                }
                for interval in starting[start] ?? [] {
                    active[applicationKey(interval)] = interval
                }

                let duration = end.timeIntervalSince(start)
                guard duration > 0, !active.isEmpty else { continue }
                let applications = active.values
                    .sorted {
                        applicationKey($0) < applicationKey($1)
                    }
                    .map { interval in
                        AppleScreenTimeApplicationUsage(
                            bundleIdentifier: interval.bundleIdentifier,
                            displayName: interval.displayName,
                            duration: duration
                        )
                    }

                if let previous = segments.last,
                   previous.end == start,
                   previous.applications.map(applicationKey) == applications.map(applicationKey)
                {
                    let combinedApplications = zip(previous.applications, applications).map { old, new in
                        AppleScreenTimeApplicationUsage(
                            bundleIdentifier: old.bundleIdentifier ?? new.bundleIdentifier,
                            displayName: old.displayName ?? new.displayName,
                            duration: old.duration + new.duration
                        )
                    }
                    segments[segments.count - 1] = AppleScreenTimeSegment(
                        start: previous.start,
                        end: end,
                        totalScreenOnDuration: previous.totalScreenOnDuration + duration,
                        applications: combinedApplications
                    )
                } else {
                    segments.append(
                        AppleScreenTimeSegment(
                            start: start,
                            end: end,
                            totalScreenOnDuration: duration,
                            applications: applications
                        )
                    )
                }
            }
            return segments
        }

        private func sameApplication(_ lhs: UsageInterval, _ rhs: UsageInterval) -> Bool {
            applicationKey(lhs) == applicationKey(rhs)
        }

        private func applicationKey(_ interval: UsageInterval) -> String {
            return interval.bundleIdentifier.lowercased()
        }

        private func applicationKey(_ application: AppleScreenTimeApplicationUsage) -> String {
            if let bundleIdentifier = application.bundleIdentifier {
                return "bundle:\(bundleIdentifier.lowercased())"
            }
            return "name:\((application.displayName ?? "unknown").lowercased())"
        }

        private func mergeDeviceLists(_ groups: [AppleScreenTimeDevice]...) -> [AppleScreenTimeDevice] {
            var byID: [String: AppleScreenTimeDevice] = [currentMacDevice.id: currentMacDevice]
            for group in groups {
                for device in group where Self.appearsInAppleSettingsScreenTime(device.kind) {
                    byID[device.id] = device
                }
            }
            return byID.values.sorted {
                if $0.id == currentMacDevice.id { return true }
                if $1.id == currentMacDevice.id { return false }
                if $0.kind.rawValue != $1.kind.rawValue {
                    return $0.kind.rawValue < $1.kind.rawValue
                }
                return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
        }

        private static func appearsInAppleSettingsScreenTime(
            _ kind: AppleScreenTimeDeviceKind
        ) -> Bool {
            switch kind {
            case .mac, .iPhone, .iPad, .iPod:
                return true
            case .appleWatch, .appleTV, .homePod, .visionPro, .unknown:
                return false
            }
        }


        private func sourceLabels(
            devices: [AppleScreenTimeDevice],
            knowledgeDeviceIDs: Set<String>,
            biomeDeviceIDs: Set<String>
        ) -> [String: String] {
            Dictionary(uniqueKeysWithValues: devices.map { device in
                let hasKnowledge = knowledgeDeviceIDs.contains(device.id)
                let hasBiome = biomeDeviceIDs.contains(device.id)
                let label: String
                switch (hasKnowledge, hasBiome) {
                case (true, true): label = "Apple knowledgeC + Biome iCloud"
                case (true, false): label = "Apple knowledgeC"
                case (false, true): label = device.id == currentMacDevice.id
                    ? "Apple Biome local"
                    : "Apple Biome · iCloud sync"
                case (false, false): label = "Discovered in Apple iCloud sync"
                }
                return (device.id, label)
            })
        }

        private func sourceLabel(for intervals: [UsageInterval]) -> String {
            var components: [String] = []
            if intervals.contains(where: { $0.source == .screenTimeAppUsage }) {
                components.append("ScreenTime.AppUsage")
            }
            if intervals.contains(where: { $0.source == .knowledgeC }) {
                components.append("knowledgeC")
            }
            if intervals.contains(where: { $0.source == .biome }) {
                components.append("Biome local")
            }
            return components.isEmpty
                ? "Apple system usage stores"
                : "Apple " + components.joined(separator: " + ")
        }

        private func sourceAPI(for intervals: [UsageInterval]) -> String {
            var components: [String] = []
            if intervals.contains(where: { $0.source == .screenTimeAppUsage }) {
                components.append("ScreenTime.AppUsage")
            }
            if intervals.contains(where: { $0.source == .knowledgeC }) {
                components.append("knowledgeC /app/usage")
            }
            if intervals.contains(where: { $0.source == .biome }) {
                components.append("Biome App.InFocus local/iCloud sync")
            }
            return "Apple system Screen Time stores: "
                + (components.isEmpty ? "none" : components.joined(separator: " + "))
        }

        // MARK: - Status and helpers

        private func makeStatus(
            hasData: Bool,
            permissionDenied: Bool,
            remoteDeviceCount: Int,
            warnings: [String],
            privateAggregateStore: Bool = false
        ) -> AppleSystemScreenTimeStatus {
            if permissionDenied, !hasData {
                return AppleSystemScreenTimeStatus(
                    kind: .fullDiskAccessRequired,
                    title: "Full Disk Access required",
                    message:
                        "Apple protects its Screen Time aggregate, ScreenTime.AppUsage, knowledgeC and Biome stores. Grant Goalong History Full Disk Access once, then reopen or refresh the app."
                )
            }
            if hasData, permissionDenied || !warnings.isEmpty {
                return AppleSystemScreenTimeStatus(
                    kind: .partial,
                    title: "Apple Screen Time partially available",
                    message: warnings.first.map {
                        "Apple’s private ScreenTimeAgent aggregate is unavailable. The readable fallback is shown; \($0)"
                    } ?? "Apple’s private ScreenTimeAgent aggregate is unavailable. This is a partial reconstruction from readable Apple usage streams and can differ from Settings."
                )
            }
            if hasData, remoteDeviceCount == 0 {
                return AppleSystemScreenTimeStatus(
                    kind: .localOnly,
                    title: privateAggregateStore
                        ? "Apple Screen Time aggregate for this Mac"
                        : "Apple activity data for this Mac",
                    message: privateAggregateStore
                        ? "Goalong is reading an Apple-owned private aggregate in place. Apple does not guarantee exact parity with the values rendered by Settings, and no synchronized remote device is present for this day."
                        : "No remote Apple device stream is present yet. Enable Screen Time → Share Across Devices on the same Apple Account to populate the All devices view automatically. Totals are reconstructed from Apple stores readable on this Mac and can differ from Settings."
                )
            }
            if hasData {
                return AppleSystemScreenTimeStatus(
                    kind: .ready,
                    title: privateAggregateStore
                        ? "Apple Screen Time aggregate connected"
                        : "Apple activity sources connected",
                    message: privateAggregateStore
                        ? "Goalong reads Apple-owned per-device aggregate blocks in place without copying them. This private format has not been certified as exactly identical to Settings."
                        : "The view is reconstructed from Apple’s readable ScreenTime.AppUsage, knowledgeC and iCloud-synced Biome streams, never Goalong’s recorder. macOS may protect the private DeviceActivity summary used by Settings, so exact Settings parity is not guaranteed."
                )
            }
            return AppleSystemScreenTimeStatus(
                kind: .noAppleData,
                title: "No Apple Screen Time data found",
                message:
                    "Turn on Screen Time and Share Across Devices for the same Apple Account. Apple may need a few minutes to create or synchronize the first App.InFocus records."
            )
        }

        static func applicationDisplayName(_ bundleIdentifier: String) -> String? {
            let builtIns: [String: String] = [
                "ai.goalong.localhistory": "Goalong History",
                "com.apple.springboard": "Home & Lock Screen",
                "com.apple.mobilesafari": "Safari",
                "com.apple.mobilesms": "Messages",
                "com.apple.mobilemail": "Mail",
                "com.apple.maps": "Maps",
                "com.apple.camera": "Camera",
                "com.apple.preferences": "Settings",
                "com.apple.appstore": "App Store",
                "com.apple.youtube": "YouTube",
                "com.google.ios.youtube": "YouTube",
                "com.apple.mobileslideshow": "Photos",
                "com.burbn.instagram": "Instagram",
                "com.apple.mobiletimer": "Clock",
                "com.apple.mobilecal": "Calendar",
                "com.apple.mobilephone": "Phone",
                "com.apple.facetime": "FaceTime",
                "com.apple.mobilenotes": "Notes",
                "com.apple.podcasts": "Podcasts",
                "com.apple.weather": "Weather",
                "com.spotify.client": "Spotify",
                "com.openai.codex": "ChatGPT",
                "com.openai.sky.cuaservice": "Codex Computer Use",
                "com.openai.sky.cuaservice.cli": "Codex Computer Use Helper",
                "net.whatsapp.whatsapp": "WhatsApp",
            ]
            if let value = builtIns[bundleIdentifier.lowercased()] { return value }

            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier),
               let bundle = Bundle(url: url)
            {
                let display = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                let name = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
                return display ?? name
            }
            return nil
        }

        static func preferredRemoteDevice(
            id: String,
            descriptors: [AppleBiomeDeviceDescriptor]
        ) -> AppleScreenTimeDevice {
            let cleaned = descriptors.map { descriptor in
                let hardware = descriptor.hardwareIdentifier?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return AppleBiomeDeviceDescriptor(
                    hardwareIdentifier: hardware?.isEmpty == false ? hardware : nil,
                    platform: descriptor.platform
                )
            }
            let knownKinds = Set(cleaned.compactMap { descriptor -> AppleScreenTimeDeviceKind? in
                let kind = deviceKind(model: descriptor.hardwareIdentifier)
                return kind == .unknown ? nil : kind
            })

            if knownKinds.count > 1 {
                return makeRemoteDevice(id: id, hardwareIdentifier: nil, platform: nil)
            }
            if let knownKind = knownKinds.first {
                let matching = cleaned.filter {
                    deviceKind(model: $0.hardwareIdentifier) == knownKind
                }
                if let best = matching.sorted(by: descriptorOrder).first {
                    return makeRemoteDevice(
                        id: id,
                        hardwareIdentifier: best.hardwareIdentifier,
                        platform: best.platform
                    )
                }
            }
            let best = cleaned.sorted(by: descriptorOrder).first
            return makeRemoteDevice(
                id: id,
                hardwareIdentifier: best?.hardwareIdentifier,
                platform: best?.platform
            )
        }

        private static func descriptorOrder(
            _ lhs: AppleBiomeDeviceDescriptor,
            _ rhs: AppleBiomeDeviceDescriptor
        ) -> Bool {
            let leftHardware = lhs.hardwareIdentifier ?? ""
            let rightHardware = rhs.hardwareIdentifier ?? ""
            if leftHardware.isEmpty != rightHardware.isEmpty { return !leftHardware.isEmpty }
            if (lhs.platform == nil) != (rhs.platform == nil) { return lhs.platform != nil }
            if leftHardware != rightHardware {
                return leftHardware.localizedCaseInsensitiveCompare(rightHardware) == .orderedAscending
            }
            return (lhs.platform ?? Int.max) < (rhs.platform ?? Int.max)
        }

        private static func moreSpecificDevice(
            _ lhs: AppleScreenTimeDevice,
            _ rhs: AppleScreenTimeDevice
        ) -> AppleScreenTimeDevice {
            func score(_ device: AppleScreenTimeDevice) -> Int {
                var value = device.kind == .unknown ? 0 : 100
                let base = device.displayName.components(separatedBy: " · ").first?.lowercased() ?? ""
                if base != "apple device", base != "iphone or ipad" { value += 20 }
                return value
            }
            let left = score(lhs)
            let right = score(rhs)
            if left != right { return left > right ? lhs : rhs }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) != .orderedDescending
                ? lhs
                : rhs
        }

        private static func hardwareIdentifier(from device: AppleScreenTimeDevice) -> String? {
            guard device.kind != .unknown else { return nil }
            let value = device.displayName.components(separatedBy: " · ").first?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return value?.isEmpty == false ? value : nil
        }

        private static func makeRemoteDevice(
            id: String,
            hardwareIdentifier: String?,
            platform: Int?
        ) -> AppleScreenTimeDevice {
            let hardware = hardwareIdentifier?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let modelKind = deviceKind(model: hardware)
            let platformKind = deviceKind(platform: platform)
            let resolvedKind = modelKind == .unknown ? platformKind : modelKind
            let shortID = id.count > 8 ? String(id.prefix(8)) : id
            let name: String
            if let hardware, !hardware.isEmpty {
                name = "\(hardware) · \(shortID)"
            } else if resolvedKind != .unknown {
                name = "\(resolvedKind.displayName) · \(shortID)"
            } else {
                name = "Apple device · \(shortID)"
            }
            return AppleScreenTimeDevice(id: id, name: name, kind: resolvedKind)
        }

        private static func deviceKind(model: String?) -> AppleScreenTimeDeviceKind {
            let normalized = model?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() ?? ""
            if normalized.hasPrefix("iphone") { return .iPhone }
            if normalized.hasPrefix("ipad") { return .iPad }
            if normalized.hasPrefix("ipod") { return .iPod }
            if normalized.hasPrefix("watch") || normalized.contains("apple watch") { return .appleWatch }
            if normalized.hasPrefix("appletv") || normalized.contains("apple tv") { return .appleTV }
            if normalized.hasPrefix("homepod") || normalized.hasPrefix("audioaccessory") { return .homePod }
            if normalized.hasPrefix("realitydevice") || normalized.contains("vision pro") { return .visionPro }
            if normalized.hasPrefix("mac") { return .mac }
            return .unknown
        }

        static func deviceKind(platform: Int?) -> AppleScreenTimeDeviceKind {
            // Values are BMDevicePlatform, verified against the locally installed
            // BiomeFoundation framework. Unknown future values remain generic.
            switch platform {
            case 1: return .iPad
            case 2: return .iPhone
            case 3, 4: return .mac
            case 5: return .appleTV
            case 6: return .appleWatch
            case 7: return .homePod
            case 8: return .visionPro
            default: return .unknown
            }
        }

        private static func looksLikePermissionFailure(_ error: Error) -> Bool {
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain,
               [NSFileReadNoPermissionError, NSFileReadNoSuchFileError].contains(nsError.code)
            {
                return nsError.code == NSFileReadNoPermissionError
            }
            if nsError.domain == NSPOSIXErrorDomain,
               [Int(EACCES), Int(EPERM)].contains(nsError.code)
            {
                return true
            }
            let message = String(describing: error).lowercased()
            return message.contains("not authorized")
                || message.contains("authorization denied")
                || message.contains("permission denied")
                || message.contains("operation not permitted")
        }

        private func latestModificationDate(_ url: URL) -> Date? {
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]) else {
                return nil
            }
            return values.contentModificationDate
        }

        private func maxDate(_ lhs: Date?, _ rhs: Date?) -> Date? {
            switch (lhs, rhs) {
            case (.some(let left), .some(let right)): return max(left, right)
            case (.some(let value), .none), (.none, .some(let value)): return value
            case (.none, .none): return nil
            }
        }

        private struct SourceRead<Value> {
            let values: [Value]
            let latestUpdate: Date?
            let permissionDenied: Bool
            let warning: String?
        }

        private struct SourceReadDictionary<Value> {
            let devices: [String: Value]
            let permissionDenied: Bool
            let warning: String?
        }

        private static func estimatedRetainedBytes(
            sourceBytes: Int,
            events: [AppleBiomeFocusEvent]
        ) -> Int {
            let decodedBytes = events.reduce(into: 0) { result, event in
                let addition = MemoryLayout<AppleBiomeFocusEvent>.stride
                    + event.bundleIdentifier.utf8.count + 32
                result = result > Int.max - addition ? Int.max : result + addition
            }
            return max(max(1, sourceBytes), decodedBytes)
        }

        private static func estimatedRetainedBytes(
            sourceBytes: Int,
            screenTimeAppUsageEvents events: [AppleBiomeScreenTimeAppUsageEvent]
        ) -> Int {
            let decodedBytes = events.reduce(into: 0) { result, event in
                let addition = MemoryLayout<AppleBiomeScreenTimeAppUsageEvent>.stride
                    + event.bundleIdentifier.utf8.count
                    + (event.parentBundleIdentifier?.utf8.count ?? 0)
                    + 48
                result = result > Int.max - addition ? Int.max : result + addition
            }
            return max(max(1, sourceBytes), decodedBytes)
        }

        private func fileFingerprint(_ url: URL) throws -> AppleBiomeFileFingerprint {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return AppleBiomeFileFingerprint(
                size: values.fileSize ?? 0,
                modifiedAt: values.contentModificationDate ?? .distantPast
            )
        }

        private func sqliteFingerprint(_ url: URL) throws -> AppleBiomeFileFingerprint {
            let primary = try fileFingerprint(url)
            let wal = URL(fileURLWithPath: url.path + "-wal")
            guard fileManager.fileExists(atPath: wal.path),
                  let walFingerprint = try? fileFingerprint(wal)
            else { return primary }
            let size = primary.size > Int.max - walFingerprint.size
                ? Int.max
                : primary.size + walFingerprint.size
            return AppleBiomeFileFingerprint(
                size: size,
                modifiedAt: max(primary.modifiedAt, walFingerprint.modifiedAt)
            )
        }
    }

    private final class SQLiteReadConnection {
        private var database: OpaquePointer?

        init(path: String) throws {
            var authorizedStatus = stat()
            guard Darwin.lstat(path, &authorizedStatus) == 0,
                  authorizedStatus.st_mode & S_IFMT == S_IFREG,
                  let resolvedCString = Darwin.realpath(path, nil)
            else {
                throw SQLiteReadError(code: SQLITE_CANTOPEN, message: "SQLite source is not a regular file")
            }
            defer { Darwin.free(resolvedCString) }
            let resolvedPath = String(cString: resolvedCString)
            var resolvedStatus = stat()
            guard Darwin.lstat(resolvedPath, &resolvedStatus) == 0,
                  resolvedStatus.st_mode & S_IFMT == S_IFREG,
                  resolvedStatus.st_dev == authorizedStatus.st_dev,
                  resolvedStatus.st_ino == authorizedStatus.st_ino
            else {
                throw SQLiteReadError(code: SQLITE_CANTOPEN, message: "SQLite source changed while resolving its path")
            }

            let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_NOFOLLOW
            let result = sqlite3_open_v2(resolvedPath, &database, flags, nil)
            guard result == SQLITE_OK, let database,
                  sqlite3_db_readonly(database, "main") == 1
            else {
                let message = database.map { String(cString: sqlite3_errmsg($0)) }
                    ?? "SQLite could not open the file"
                if let database { sqlite3_close(database) }
                database = nil
                throw SQLiteReadError(code: result, message: message)
            }
            do {
                try executeConnectionPragma("PRAGMA temp_store=MEMORY")
                try executeConnectionPragma("PRAGMA mmap_size=0")
                try executeConnectionPragma("PRAGMA query_only=ON")
                guard try integerConnectionPragma("PRAGMA temp_store") == 2,
                      try integerConnectionPragma("PRAGMA mmap_size") == 0,
                      try integerConnectionPragma("PRAGMA query_only") == 1,
                      sqlite3_db_readonly(database, "main") == 1
                else {
                    throw SQLiteReadError(
                        code: SQLITE_READONLY,
                        message: "SQLite could not be locked to read-only operation"
                    )
                }
                guard sqlite3_set_authorizer(
                    database,
                    { _, action, _, _, _, _ in
                        switch action {
                        case SQLITE_SELECT, SQLITE_READ, SQLITE_FUNCTION, SQLITE_PRAGMA,
                            SQLITE_RECURSIVE:
                            return SQLITE_OK
                        default:
                            return SQLITE_DENY
                        }
                    },
                    nil
                ) == SQLITE_OK else {
                    throw SQLiteReadError(
                        code: SQLITE_AUTH,
                        message: "SQLite read-only authorizer could not be installed"
                    )
                }
                sqlite3_busy_timeout(database, 500)
            } catch {
                sqlite3_close(database)
                self.database = nil
                throw error
            }
        }

        deinit {
            if let database { sqlite3_close(database) }
        }

        func tableColumns(_ table: String) throws -> Set<String> {
            let safe = table.replacingOccurrences(of: "\"", with: "\"\"")
            let rows: [String] = try query("PRAGMA table_info(\"\(safe)\")") { statement in
                let name = Self.string(statement, column: 1)
                return name.isEmpty ? nil : name
            }
            return Set(rows)
        }

        private func executeConnectionPragma(_ sql: String) throws {
            guard let database else {
                throw SQLiteReadError(code: SQLITE_MISUSE, message: "Database closed")
            }
            var statement: OpaquePointer?
            let prepare = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
            guard prepare == SQLITE_OK, let statement else {
                throw SQLiteReadError(code: prepare, message: String(cString: sqlite3_errmsg(database)))
            }
            defer { sqlite3_finalize(statement) }
            let step = sqlite3_step(statement)
            guard step == SQLITE_DONE || step == SQLITE_ROW else {
                throw SQLiteReadError(code: step, message: String(cString: sqlite3_errmsg(database)))
            }
        }

        private func integerConnectionPragma(_ sql: String) throws -> Int {
            let values: [Int] = try query(sql) { statement in
                guard sqlite3_column_type(statement, 0) != SQLITE_NULL else { return nil }
                return Int(sqlite3_column_int64(statement, 0))
            }
            guard let value = values.first else {
                throw SQLiteReadError(code: SQLITE_ERROR, message: "SQLite pragma returned no value")
            }
            return value
        }

        func query<T>(
            _ sql: String,
            bind: ((OpaquePointer) -> Void)? = nil,
            row: (OpaquePointer) throws -> T?
        ) throws -> [T] {
            guard let database else { throw SQLiteReadError(code: SQLITE_MISUSE, message: "Database closed") }
            var statement: OpaquePointer?
            let prepare = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
            guard prepare == SQLITE_OK, let statement else {
                throw SQLiteReadError(code: prepare, message: String(cString: sqlite3_errmsg(database)))
            }
            defer { sqlite3_finalize(statement) }
            bind?(statement)

            var output: [T] = []
            while true {
                let step = sqlite3_step(statement)
                if step == SQLITE_ROW {
                    if let value = try row(statement) { output.append(value) }
                } else if step == SQLITE_DONE {
                    return output
                } else {
                    throw SQLiteReadError(code: step, message: String(cString: sqlite3_errmsg(database)))
                }
            }
        }

        static func string(_ statement: OpaquePointer, column: Int32) -> String {
            guard sqlite3_column_type(statement, column) != SQLITE_NULL,
                  let value = sqlite3_column_text(statement, column)
            else { return "" }
            return String(cString: value)
        }

        static func double(_ statement: OpaquePointer, column: Int32) -> Double? {
            guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
            return sqlite3_column_double(statement, column)
        }

        static func int(_ statement: OpaquePointer, column: Int32) -> Int? {
            guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
            return Int(sqlite3_column_int64(statement, column))
        }
    }

    private extension AppleScreenTimeImportVerification {
        /// Apple system databases are read directly and are not an imported companion file.
        /// The existing serialized value remains `unsigned` because Apple does not sign these
        /// private local records for third-party verification.
        static var appleSystemStore: AppleScreenTimeImportVerification { .unsigned }
    }

    private struct SQLiteReadError: Error, CustomStringConvertible {
        let code: Int32
        let message: String
        var description: String { "SQLite \(code): \(message)" }
    }
#endif
