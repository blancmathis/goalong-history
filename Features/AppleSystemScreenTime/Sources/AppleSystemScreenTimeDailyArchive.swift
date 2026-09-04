#if os(macOS)
    import AppleScreenTime
    import Foundation

    public enum AppleSystemScreenTimeDailyArchiveError: Error, CustomStringConvertible {
        case invalidDay
        case invalidRecord
        case unsafeDirectory
        case recordTooLarge(Int)

        public var description: String {
            switch self {
            case .invalidDay:
                return "The Screen Time calendar day could not be resolved."
            case .invalidRecord:
                return "The stored Screen Time day is invalid."
            case .unsafeDirectory:
                return "The Screen Time daily archive must use regular local directories, not files or symbolic links."
            case .recordTooLarge(let bytes):
                return "The stored Screen Time day exceeded the 16 MiB safety limit (\(bytes) bytes)."
            }
        }
    }

    public enum AppleSystemScreenTimeDailyArchiveState: String, Codable, Equatable, Sendable {
        case active
        case completed
    }

    public struct AppleSystemScreenTimeDailyArchiveRecord: Codable, Equatable, Sendable {
        public let schemaVersion: Int
        public let dayStart: Date
        public let dayEnd: Date
        public let timeZoneIdentifier: String
        public let state: AppleSystemScreenTimeDailyArchiveState
        public let storedAt: Date
        public let collection: AppleSystemScreenTimeCollection

        public init(
            schemaVersion: Int = 1,
            dayStart: Date,
            dayEnd: Date,
            timeZoneIdentifier: String,
            state: AppleSystemScreenTimeDailyArchiveState,
            storedAt: Date,
            collection: AppleSystemScreenTimeCollection
        ) {
            self.schemaVersion = schemaVersion
            self.dayStart = dayStart
            self.dayEnd = dayEnd
            self.timeZoneIdentifier = timeZoneIdentifier
            self.state = state
            self.storedAt = storedAt
            self.collection = collection
        }
    }

    /// Keeps exactly one compact normalized record for each Screen Time day.
    ///
    /// The active day's file is atomically replaced only when its Apple-derived payload changes.
    /// Completed days are closed without reopening Apple-owned history and are never refreshed.
    public final class AppleSystemScreenTimeDailyArchive: @unchecked Sendable {
        public static let maximumRecordBytes = 16 * 1_024 * 1_024

        public let rootDirectory: URL
        public let daysDirectory: URL

        private let fileManager: FileManager
        private let calendar: Calendar
        private let queue = DispatchQueue(label: "ai.goalong.apple-screen-time.daily-archive")

        public init(
            rootDirectory: URL,
            fileManager: FileManager = .default,
            calendar: Calendar = .current,
            createIfMissing: Bool = true
        ) throws {
            self.rootDirectory = rootDirectory
            self.daysDirectory = rootDirectory.appendingPathComponent("days", isDirectory: true)
            self.fileManager = fileManager
            self.calendar = calendar
            if createIfMissing {
                try prepareDirectory()
            } else {
                try validateDirectoryIfPresent(rootDirectory)
                try validateDirectoryIfPresent(daysDirectory)
            }
        }

        @discardableResult
        public func storeActiveDay(
            _ collection: AppleSystemScreenTimeCollection,
            for day: Date,
            storedAt: Date = Date()
        ) throws -> AppleSystemScreenTimeDailyArchiveRecord? {
            try queue.sync {
                guard let storedExport = collection.storedExport else {
                    return try loadRecordLocked(for: day)
                }
                try AppleScreenTimeValidator.validate(storedExport.envelope)
                let interval = try dayInterval(for: day)
                let url = fileURL(for: interval.start)
                // A malformed active-day record from an older build must not block a valid
                // Apple refresh. It is replaced only after the new payload validates.
                if let existing = try? loadRecordLocked(at: url),
                    Self.hasEquivalentPayload(existing.collection, collection)
                {
                    return existing
                }

                let record = AppleSystemScreenTimeDailyArchiveRecord(
                    dayStart: interval.start,
                    dayEnd: interval.end,
                    timeZoneIdentifier: calendar.timeZone.identifier,
                    state: .active,
                    storedAt: storedAt,
                    collection: collection.replacingStorageState(.liveCurrentDayStored)
                )
                try write(record, to: url)
                return record
            }
        }

        public func completedCollection(for day: Date, now: Date = Date()) -> AppleSystemScreenTimeCollection? {
            queue.sync {
                guard let interval = try? dayInterval(for: day), interval.end <= calendar.startOfDay(for: now),
                    var record = try? loadRecordLocked(at: fileURL(for: interval.start))
                else { return nil }

                if record.state == .active {
                    let current = record
                    let completed = AppleSystemScreenTimeDailyArchiveRecord(
                        dayStart: current.dayStart,
                        dayEnd: current.dayEnd,
                        timeZoneIdentifier: current.timeZoneIdentifier,
                        state: .completed,
                        storedAt: current.storedAt,
                        collection: current.collection.replacingStorageState(.completedDayStored)
                    )
                    do {
                        try write(completed, to: fileURL(for: interval.start))
                        record = completed
                    } catch {
                        return current.collection.replacingStorageState(.completedDayStored)
                    }
                }
                return record.collection.replacingStorageState(.completedDayStored)
            }
        }

        public func activeCollection(for day: Date) -> AppleSystemScreenTimeCollection? {
            queue.sync {
                guard let record = try? loadRecordLocked(for: day) else { return nil }
                return record.collection.replacingStorageState(.activeDayStoredFallback)
            }
        }

        /// Reads an existing Goalong day without touching Apple-owned stores or mutating the archive.
        public func storedCollection(for day: Date, now: Date = Date()) -> AppleSystemScreenTimeCollection? {
            queue.sync {
                guard let interval = try? dayInterval(for: day),
                    let record = try? loadRecordLocked(at: fileURL(for: interval.start))
                else { return nil }
                let state: AppleSystemScreenTimeStorageState =
                    interval.end <= calendar.startOfDay(for: now)
                    ? .completedDayStored
                    : .activeDayStoredFallback
                return record.collection.replacingStorageState(state)
            }
        }

        @discardableResult
        public func finalizeCompletedDays(now: Date = Date()) -> Int {
            queue.sync {
                let today = calendar.startOfDay(for: now)
                guard
                    let files = try? fileManager.contentsOfDirectory(
                        at: daysDirectory,
                        includingPropertiesForKeys: nil,
                        options: [.skipsHiddenFiles]
                    )
                else { return 0 }

                var finalized = 0
                for file in files where file.pathExtension == "json" {
                    guard let record = try? loadRecordLocked(at: file),
                        record.state == .active,
                        record.dayEnd <= today
                    else { continue }
                    let completed = AppleSystemScreenTimeDailyArchiveRecord(
                        dayStart: record.dayStart,
                        dayEnd: record.dayEnd,
                        timeZoneIdentifier: record.timeZoneIdentifier,
                        state: .completed,
                        storedAt: record.storedAt,
                        collection: record.collection.replacingStorageState(.completedDayStored)
                    )
                    if (try? write(completed, to: file)) != nil {
                        finalized += 1
                    }
                }
                return finalized
            }
        }

        public func storedDayStrings() -> [String] {
            queue.sync {
                guard
                    let files = try? fileManager.contentsOfDirectory(
                        at: daysDirectory,
                        includingPropertiesForKeys: nil,
                        options: [.skipsHiddenFiles]
                    )
                else { return [] }
                return
                    files
                    .filter {
                        guard $0.pathExtension == "json",
                            let values = try? $0.resourceValues(
                                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
                            )
                        else { return false }
                        return values.isRegularFile == true && values.isSymbolicLink != true
                    }
                    .map { $0.deletingPathExtension().lastPathComponent }
                    .filter(Self.isDayString)
                    .sorted()
            }
        }

        private func loadRecordLocked(for day: Date) throws -> AppleSystemScreenTimeDailyArchiveRecord? {
            let interval = try dayInterval(for: day)
            return try loadRecordLocked(at: fileURL(for: interval.start))
        }

        private func loadRecordLocked(at url: URL) throws -> AppleSystemScreenTimeDailyArchiveRecord? {
            guard fileManager.fileExists(atPath: url.path) else { return nil }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw AppleSystemScreenTimeDailyArchiveError.invalidRecord
            }
            let size = values.fileSize ?? 0
            guard size <= Self.maximumRecordBytes else {
                throw AppleSystemScreenTimeDailyArchiveError.recordTooLarge(size)
            }
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            let record = try AppleScreenTimeJSON.decode(
                AppleSystemScreenTimeDailyArchiveRecord.self,
                from: data
            )
            guard record.schemaVersion == 1,
                record.dayStart < record.dayEnd,
                record.collection.storedExport != nil
            else {
                throw AppleSystemScreenTimeDailyArchiveError.invalidRecord
            }
            if let stored = record.collection.storedExport {
                try AppleScreenTimeValidator.validate(stored.envelope)
            }
            return record
        }

        private func write(_ record: AppleSystemScreenTimeDailyArchiveRecord, to url: URL) throws {
            try prepareDirectory()
            guard let storedExport = record.collection.storedExport else {
                throw AppleSystemScreenTimeDailyArchiveError.invalidRecord
            }
            try AppleScreenTimeValidator.validate(storedExport.envelope)
            let data = try AppleScreenTimeJSON.encode(record, prettyPrinted: false)
            guard data.count <= Self.maximumRecordBytes else {
                throw AppleSystemScreenTimeDailyArchiveError.recordTooLarge(data.count)
            }
            try data.write(to: url, options: [.atomic])
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }

        private func prepareDirectory() throws {
            try validateDirectoryIfPresent(rootDirectory)
            try validateDirectoryIfPresent(daysDirectory)
            try fileManager.createDirectory(
                at: daysDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try validateDirectoryIfPresent(rootDirectory)
            try validateDirectoryIfPresent(daysDirectory)
            try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: daysDirectory.path)
        }

        private func validateDirectoryIfPresent(_ url: URL) throws {
            guard fileManager.fileExists(atPath: url.path) else { return }
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw AppleSystemScreenTimeDailyArchiveError.unsafeDirectory
            }
        }

        private func dayInterval(for day: Date) throws -> DateInterval {
            guard let interval = calendar.dateInterval(of: .day, for: day) else {
                throw AppleSystemScreenTimeDailyArchiveError.invalidDay
            }
            return interval
        }

        private func fileURL(for dayStart: Date) -> URL {
            daysDirectory.appendingPathComponent(Self.dayString(dayStart, calendar: calendar) + ".json")
        }

        private static func dayString(_ date: Date, calendar: Calendar) -> String {
            let components = calendar.dateComponents([.year, .month, .day], from: date)
            return String(
                format: "%04d-%02d-%02d",
                components.year ?? 0,
                components.month ?? 0,
                components.day ?? 0
            )
        }

        private static func isDayString(_ value: String) -> Bool {
            value.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
        }

        private static func hasEquivalentPayload(
            _ lhs: AppleSystemScreenTimeCollection,
            _ rhs: AppleSystemScreenTimeCollection
        ) -> Bool {
            lhs.availableDevices == rhs.availableDevices
                && lhs.status == rhs.status
                && lhs.deviceSourceLabels == rhs.deviceSourceLabels
                && lhs.latestAppleUpdate == rhs.latestAppleUpdate
                && lhs.knowledgeIntervalCount == rhs.knowledgeIntervalCount
                && lhs.biomeIntervalCount == rhs.biomeIntervalCount
                && lhs.screenTimeAppUsageIntervalCount == rhs.screenTimeAppUsageIntervalCount
                && equivalentStoredExport(lhs.storedExport, rhs.storedExport)
        }

        private static func equivalentStoredExport(
            _ lhs: AppleScreenTimeStoredExport?,
            _ rhs: AppleScreenTimeStoredExport?
        ) -> Bool {
            guard let lhs, let rhs else { return lhs == nil && rhs == nil }
            let left = lhs.envelope
            let right = rhs.envelope
            return lhs.verification == rhs.verification
                && left.requestedStart == right.requestedStart
                && left.requestedEnd == right.requestedEnd
                && left.requestedScope == right.requestedScope
                && left.provenance == right.provenance
                && left.reports == right.reports
        }
    }

    /// Routes current-day reads to Apple and completed-day reads exclusively to Goalong's archive.
    public final class AppleSystemScreenTimeRepository: @unchecked Sendable {
        public let currentMacDevice: AppleScreenTimeDevice

        private let archive: AppleSystemScreenTimeDailyArchive
        private let calendar: Calendar
        private let nowProvider: () -> Date
        private let liveCollectionProvider: (Date) -> AppleSystemScreenTimeCollection
        private let queue = DispatchQueue(label: "ai.goalong.apple-screen-time.repository")
        private var lastFinalizationDay: Date?

        public convenience init(
            rootDirectory: URL,
            deviceID: String,
            calendar: Calendar = .current,
            nowProvider: @escaping () -> Date = Date.init
        ) throws {
            let source = AppleSystemScreenTimeSource(
                deviceID: deviceID,
                calendar: calendar,
                nowProvider: nowProvider
            )
            try self.init(
                rootDirectory: rootDirectory,
                currentMacDevice: source.currentMacDevice,
                calendar: calendar,
                nowProvider: nowProvider,
                liveCollectionProvider: { source.collect(for: $0) }
            )
        }

        public init(
            rootDirectory: URL,
            currentMacDevice: AppleScreenTimeDevice,
            calendar: Calendar = .current,
            nowProvider: @escaping () -> Date = Date.init,
            liveCollectionProvider: @escaping (Date) -> AppleSystemScreenTimeCollection
        ) throws {
            self.currentMacDevice = currentMacDevice
            self.calendar = calendar
            self.nowProvider = nowProvider
            self.liveCollectionProvider = liveCollectionProvider
            self.archive = try AppleSystemScreenTimeDailyArchive(
                rootDirectory: rootDirectory,
                calendar: calendar
            )
        }

        public func collect(for day: Date) -> AppleSystemScreenTimeCollection {
            queue.sync {
                let now = nowProvider()
                let today = calendar.startOfDay(for: now)
                let requestedDay = calendar.startOfDay(for: day)
                if lastFinalizationDay != today {
                    _ = archive.finalizeCompletedDays(now: now)
                    lastFinalizationDay = today
                }

                if requestedDay < today {
                    return archive.completedCollection(for: requestedDay, now: now)
                        ?? missingCompletedDayCollection(requestedDay)
                }
                guard requestedDay == today else {
                    return missingCompletedDayCollection(requestedDay)
                }

                let live = AppleScreenTimeDeviceNormalizer.normalize(
                    liveCollectionProvider(requestedDay),
                    currentMac: currentMacDevice
                )
                if live.storedExport != nil {
                    do {
                        _ = try archive.storeActiveDay(live, for: requestedDay, storedAt: now)
                        return live.replacingStorageState(.liveCurrentDayStored)
                    } catch {
                        return AppleSystemScreenTimeCollection(
                            storedExport: live.storedExport,
                            availableDevices: live.availableDevices,
                            status: AppleSystemScreenTimeStatus(
                                kind: .partial,
                                title: "Screen Time read, local day could not be saved",
                                message:
                                    "Apple data is visible now, but Goalong could not update today's local day record: \(error)"
                            ),
                            deviceSourceLabels: live.deviceSourceLabels,
                            latestAppleUpdate: live.latestAppleUpdate,
                            knowledgeIntervalCount: live.knowledgeIntervalCount,
                            biomeIntervalCount: live.biomeIntervalCount,
                            screenTimeAppUsageIntervalCount: live.screenTimeAppUsageIntervalCount,
                            storageState: .directAppleRead
                        )
                    }
                }

                if let stored = archive.activeCollection(for: requestedDay) {
                    return AppleSystemScreenTimeCollection(
                        storedExport: stored.storedExport,
                        availableDevices: stored.availableDevices,
                        status: AppleSystemScreenTimeStatus(
                            kind: .partial,
                            title: "Showing today's last stored Screen Time",
                            message:
                                "The current Apple read returned no usable data. Goalong kept the last successful update for today. \(live.status.message)"
                        ),
                        deviceSourceLabels: stored.deviceSourceLabels,
                        latestAppleUpdate: stored.latestAppleUpdate,
                        knowledgeIntervalCount: stored.knowledgeIntervalCount,
                        biomeIntervalCount: stored.biomeIntervalCount,
                        screenTimeAppUsageIntervalCount: stored.screenTimeAppUsageIntervalCount,
                        storageState: .activeDayStoredFallback
                    )
                }
                return live.replacingStorageState(.directAppleRead)
            }
        }

        public func storedDayStrings() -> [String] {
            archive.storedDayStrings()
        }

        private func missingCompletedDayCollection(_ day: Date) -> AppleSystemScreenTimeCollection {
            AppleSystemScreenTimeCollection(
                storedExport: nil,
                availableDevices: [],
                status: AppleSystemScreenTimeStatus(
                    kind: .noAppleData,
                    title: "No stored Screen Time for this completed day",
                    message:
                        "Goalong never reopens Apple history after a day ends. This day was not captured while it was active."
                ),
                deviceSourceLabels: [:],
                latestAppleUpdate: nil,
                knowledgeIntervalCount: 0,
                biomeIntervalCount: 0,
                screenTimeAppUsageIntervalCount: 0,
                storageState: .missingCompletedDay
            )
        }

    }
#endif
