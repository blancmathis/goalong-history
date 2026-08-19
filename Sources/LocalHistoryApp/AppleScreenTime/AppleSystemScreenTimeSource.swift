#if os(macOS)
    import AppKit
    import AppleScreenTime
    import Darwin
    import Foundation
    import SQLite3

    enum AppleSystemScreenTimeStatusKind: String, Equatable {
        case ready
        case localOnly
        case fullDiskAccessRequired
        case noAppleData
        case partial
    }

    struct AppleSystemScreenTimeStatus: Equatable {
        let kind: AppleSystemScreenTimeStatusKind
        let title: String
        let message: String

        static let loading = AppleSystemScreenTimeStatus(
            kind: .noAppleData,
            title: "Reading Apple Screen Time",
            message: "LocalHistory is checking Apple’s local Screen Time and iCloud-synced device stores."
        )
    }

    struct AppleSystemScreenTimeCollection {
        let storedExport: AppleScreenTimeStoredExport?
        let availableDevices: [AppleScreenTimeDevice]
        let status: AppleSystemScreenTimeStatus
        let deviceSourceLabels: [String: String]
        let latestAppleUpdate: Date?
        let knowledgeIntervalCount: Int
        let biomeIntervalCount: Int
    }

    struct AppleSystemScreenTimePaths {
        let knowledgeDatabase: URL
        let biomeSyncDatabase: URL
        let biomeLocalDirectory: URL
        let biomeRemoteDirectory: URL

        static let `default`: AppleSystemScreenTimePaths = {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let library = home.appendingPathComponent("Library", isDirectory: true)
            let biome = library.appendingPathComponent("Biome", isDirectory: true)
            let appInFocus = biome
                .appendingPathComponent("streams", isDirectory: true)
                .appendingPathComponent("restricted", isDirectory: true)
                .appendingPathComponent("App.InFocus", isDirectory: true)

            return AppleSystemScreenTimePaths(
                knowledgeDatabase: library
                    .appendingPathComponent("Application Support", isDirectory: true)
                    .appendingPathComponent("Knowledge", isDirectory: true)
                    .appendingPathComponent("knowledgeC.db", isDirectory: false),
                biomeSyncDatabase: biome
                    .appendingPathComponent("sync", isDirectory: true)
                    .appendingPathComponent("sync.db", isDirectory: false),
                biomeLocalDirectory: appInFocus.appendingPathComponent("local", isDirectory: true),
                biomeRemoteDirectory: appInFocus.appendingPathComponent("remote", isDirectory: true)
            )
        }()
    }

    /// Reads Apple-generated Screen Time data already present on the Mac.
    ///
    /// - `knowledgeC.db` provides Apple `/app/usage` intervals for the Mac and any device
    ///   rows Apple has synchronized into the database.
    /// - Biome `App.InFocus` provides automatic iCloud-synced focus transitions for iPhone,
    ///   iPad and other devices when “Share Across Devices” is enabled.
    ///
    /// These are private on-disk Apple formats, not LocalHistory’s recorder. The source is
    /// deliberately isolated so an Apple schema change cannot affect normal activity capture.
    final class AppleSystemScreenTimeSource {
        let currentMacDevice: AppleScreenTimeDevice

        private let paths: AppleSystemScreenTimePaths
        private let fileManager: FileManager
        private let calendar: Calendar
        private let nowProvider: () -> Date
        private var biomeFileCache: [String: CachedBiomeFile] = [:]

        init(
            deviceID: String,
            paths: AppleSystemScreenTimePaths = .default,
            fileManager: FileManager = .default,
            calendar: Calendar = .current,
            nowProvider: @escaping () -> Date = Date.init
        ) {
            self.paths = paths
            self.fileManager = fileManager
            self.calendar = calendar
            self.nowProvider = nowProvider
            self.currentMacDevice = AppleScreenTimeDevice(
                id: "apple-system-current-mac:\(deviceID)",
                name: Host.current().localizedName ?? ProcessInfo.processInfo.hostName,
                kind: .mac
            )
        }

        func collect(for day: Date) -> AppleSystemScreenTimeCollection {
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
            let requestedInterval = DateInterval(start: dayInterval.start, end: max(dayInterval.start, effectiveEnd))
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

            let merged = mergeIntervals(
                preferred: knowledgeRead.values,
                supplemental: biomeRead.values
            )
            let discoveredDevices = mergeDeviceLists(
                catalogRead.devices.values.map(\.device),
                merged.map(\.device)
            )
            let reports = makeReports(from: merged)
            let latestUpdate = [
                knowledgeRead.latestUpdate,
                biomeRead.latestUpdate,
                reports.map(\.lastUpdatedAt).max(),
            ].compactMap { $0 }.max()

            let denied = catalogRead.permissionDenied
                || knowledgeRead.permissionDenied
                || biomeRead.permissionDenied
            let warnings = [catalogRead.warning, knowledgeRead.warning, biomeRead.warning]
                .compactMap { $0 }
            let remoteDeviceCount = discoveredDevices.filter { $0.id != currentMacDevice.id }.count
            let status = makeStatus(
                hasData: !reports.isEmpty,
                permissionDenied: denied,
                remoteDeviceCount: remoteDeviceCount,
                warnings: warnings
            )

            guard !reports.isEmpty else {
                return AppleSystemScreenTimeCollection(
                    storedExport: nil,
                    availableDevices: discoveredDevices,
                    status: status,
                    deviceSourceLabels: sourceLabels(
                        devices: discoveredDevices,
                        knowledgeDeviceIDs: Set(knowledgeRead.values.map(\.device.id)),
                        biomeDeviceIDs: Set(biomeRead.values.map(\.device.id))
                    ),
                    latestAppleUpdate: latestUpdate,
                    knowledgeIntervalCount: knowledgeRead.values.count,
                    biomeIntervalCount: biomeRead.values.count
                )
            }

            let info = Bundle.main.infoDictionary
            let provenance = AppleScreenTimeProvenance(
                api: "Apple system Screen Time stores: knowledgeC /app/usage + Biome App.InFocus iCloud sync",
                collectorBundleIdentifier: Bundle.main.bundleIdentifier ?? "ai.goalong.localhistory",
                collectorVersion: info?["CFBundleShortVersionString"] as? String ?? "unknown",
                collectorPlatform: ProcessInfo.processInfo.operatingSystemVersionString,
                authorization: .unknown,
                fetchPolicy: .live,
                euCustomerRequirementAcknowledged: false
            )
            let envelope = AppleScreenTimeExportEnvelope(
                requestedStart: dayInterval.start,
                requestedEnd: dayInterval.end,
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
                deviceSourceLabels: sourceLabels(
                    devices: discoveredDevices,
                    knowledgeDeviceIDs: Set(knowledgeRead.values.map(\.device.id)),
                    biomeDeviceIDs: Set(biomeRead.values.map(\.device.id))
                ),
                latestAppleUpdate: latestUpdate,
                knowledgeIntervalCount: knowledgeRead.values.count,
                biomeIntervalCount: biomeRead.values.count
            )
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
                        device = known
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
            let canonical = """
                SELECT
                  COALESCE(ZOBJECT.ZVALUESTRING, ''),
                  ZOBJECT.ZSTARTDATE,
                  ZOBJECT.ZENDDATE,
                  COALESCE(ZSOURCE.ZDEVICEID, ''),
                  COALESCE(ZSYNCPEER.ZMODEL, '')
                FROM ZOBJECT
                  LEFT JOIN ZSTRUCTUREDMETADATA
                    ON ZOBJECT.ZSTRUCTUREDMETADATA = ZSTRUCTUREDMETADATA.Z_PK
                  LEFT JOIN ZSOURCE
                    ON ZOBJECT.ZSOURCE = ZSOURCE.Z_PK
                  LEFT JOIN ZSYNCPEER
                    ON ZSOURCE.ZDEVICEID = ZSYNCPEER.ZDEVICEID
                WHERE ZSTRUCTUREDMETADATA.ZSTREAMNAME = '/app/usage'
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

        // MARK: - Biome

        private func readBiomeIntervals(
            interval: DateInterval,
            now: Date,
            catalog: [String: DeviceCatalogEntry]
        ) -> SourceRead<UsageInterval> {
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
                    if let cached = biomeFileCache[key], cached.fingerprint == fingerprint {
                        allEvents.append(contentsOf: cached.events)
                        continue
                    }

                    do {
                        let data = try Data(contentsOf: file, options: [.mappedIfSafe])
                        let events = try AppleBiomeSEGBDecoder.decode(data)
                        biomeFileCache[key] = CachedBiomeFile(fingerprint: fingerprint, events: events)
                        allEvents.append(contentsOf: events)
                    } catch AppleBiomeFormatError.unsupportedFormat {
                        malformedCount += 1
                    } catch {
                        malformedCount += 1
                    }
                }

                let existing = Set(files.map { $0.standardizedFileURL.path })
                biomeFileCache = biomeFileCache.filter { existing.contains($0.key) || !$0.key.hasPrefix(directory.path) }

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
                    for (id, hardware, platform) in rows {
                        let device = Self.makeRemoteDevice(
                            id: id,
                            hardwareIdentifier: hardware,
                            platform: platform
                        )
                        entries[id] = DeviceCatalogEntry(
                            device: device,
                            hardwareIdentifier: hardware.isEmpty ? nil : hardware,
                            platform: platform
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
        }

        private struct UsageInterval {
            let device: AppleScreenTimeDevice
            let bundleIdentifier: String
            let displayName: String?
            let start: Date
            let end: Date
            let source: UsageSource

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
                for existing in accepted where existing.device.id == candidate.device.id {
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
                    let segments = deviceRows.sorted(by: intervalOrder).map { row in
                        AppleScreenTimeSegment(
                            start: row.start,
                            end: row.end,
                            totalScreenOnDuration: row.duration,
                            applications: [
                                AppleScreenTimeApplicationUsage(
                                    bundleIdentifier: row.bundleIdentifier,
                                    displayName: row.displayName,
                                    duration: row.duration
                                )
                            ]
                        )
                    }
                    return AppleScreenTimeDeviceReport(
                        device: first.device,
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

        private func mergeDeviceLists(_ groups: [AppleScreenTimeDevice]...) -> [AppleScreenTimeDevice] {
            var byID: [String: AppleScreenTimeDevice] = [currentMacDevice.id: currentMacDevice]
            for group in groups {
                for device in group { byID[device.id] = device }
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

        // MARK: - Status and helpers

        private func makeStatus(
            hasData: Bool,
            permissionDenied: Bool,
            remoteDeviceCount: Int,
            warnings: [String]
        ) -> AppleSystemScreenTimeStatus {
            if permissionDenied, !hasData {
                return AppleSystemScreenTimeStatus(
                    kind: .fullDiskAccessRequired,
                    title: "Full Disk Access required",
                    message:
                        "Apple protects Screen Time’s knowledgeC and Biome stores. Grant LocalHistory Full Disk Access once, then reopen or refresh the app."
                )
            }
            if hasData, permissionDenied || !warnings.isEmpty {
                return AppleSystemScreenTimeStatus(
                    kind: .partial,
                    title: "Apple Screen Time partially available",
                    message: warnings.first
                        ?? "Some Apple Screen Time stores are still protected, but the readable device data is shown."
                )
            }
            if hasData, remoteDeviceCount == 0 {
                return AppleSystemScreenTimeStatus(
                    kind: .localOnly,
                    title: "Official Apple data for this Mac",
                    message:
                        "No iPhone or iPad stream is present yet. Enable Screen Time → Share Across Devices on the same Apple Account to populate the All devices view automatically."
                )
            }
            if hasData {
                return AppleSystemScreenTimeStatus(
                    kind: .ready,
                    title: "Official Apple Screen Time connected",
                    message:
                        "The view is built from Apple’s local usage database and iCloud-synced Biome device streams, not from LocalHistory’s activity recorder."
                )
            }
            return AppleSystemScreenTimeStatus(
                kind: .noAppleData,
                title: "No Apple Screen Time data found",
                message:
                    "Turn on Screen Time and Share Across Devices for the same Apple Account. Apple may need a few minutes to create or synchronize the first App.InFocus records."
            )
        }

        private static func applicationDisplayName(_ bundleIdentifier: String) -> String? {
            let builtIns: [String: String] = [
                "com.apple.springboard": "Home & Lock Screen",
                "com.apple.mobilesafari": "Safari",
                "com.apple.MobileSMS": "Messages",
                "com.apple.mobilemail": "Mail",
                "com.apple.Maps": "Maps",
                "com.apple.camera": "Camera",
                "com.apple.Preferences": "Settings",
                "com.apple.AppStore": "App Store",
                "com.apple.youtube": "YouTube",
            ]
            if let value = builtIns[bundleIdentifier] { return value }

            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier),
               let bundle = Bundle(url: url)
            {
                let display = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                let name = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
                return display ?? name
            }
            return nil
        }

        private static func makeRemoteDevice(
            id: String,
            hardwareIdentifier: String?,
            platform: Int?
        ) -> AppleScreenTimeDevice {
            let hardware = hardwareIdentifier?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let kind = deviceKind(model: hardware)
            let resolvedKind: AppleScreenTimeDeviceKind = {
                if kind != .unknown { return kind }
                // Apple Biome currently uses platform 2 for iOS/iPadOS peers. Without a
                // hardware identifier, keep the device generic rather than falsely naming it.
                return .unknown
            }()
            let shortID = id.count > 8 ? String(id.prefix(8)) : id
            let name: String
            if let hardware, !hardware.isEmpty {
                name = "\(hardware) · \(shortID)"
            } else if platform == 2 {
                name = "iPhone or iPad · \(shortID)"
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
            if normalized.hasPrefix("mac") { return .mac }
            return .unknown
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

        private struct BiomeFileFingerprint: Equatable {
            let size: Int
            let modifiedAt: Date
        }

        private struct CachedBiomeFile {
            let fingerprint: BiomeFileFingerprint
            let events: [AppleBiomeFocusEvent]
        }

        private func fileFingerprint(_ url: URL) throws -> BiomeFileFingerprint {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return BiomeFileFingerprint(
                size: values.fileSize ?? 0,
                modifiedAt: values.contentModificationDate ?? .distantPast
            )
        }
    }

    private final class SQLiteReadConnection {
        private var database: OpaquePointer?

        init(path: String) throws {
            let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
            let result = sqlite3_open_v2(path, &database, flags, nil)
            guard result == SQLITE_OK, database != nil else {
                let message = database.map { String(cString: sqlite3_errmsg($0)) }
                    ?? "SQLite could not open the file"
                if let database { sqlite3_close(database) }
                database = nil
                throw SQLiteReadError(code: result, message: message)
            }
            sqlite3_busy_timeout(database, 500)
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
