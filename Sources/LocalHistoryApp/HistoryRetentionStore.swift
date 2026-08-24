#if os(macOS)
    import Darwin
    import Foundation
    import LocalHistoryCore

    struct HistoryRetentionArtifactDirectory {
        let directory: URL
        let dataClass: HistoryDataClass
        let allowedSuffixes: Set<String>

        init(directory: URL, dataClass: HistoryDataClass, allowedSuffixes: Set<String>) {
            self.directory = directory
            self.dataClass = dataClass
            self.allowedSuffixes = allowedSuffixes
        }

        func recognizes(_ fileName: String) -> Bool {
            guard fileName.count > 10 else { return false }
            let dayEnd = fileName.index(fileName.startIndex, offsetBy: 10)
            return allowedSuffixes.contains(String(fileName[dayEnd...]))
        }
    }

    struct HistoryRetentionStorage {
        let policyFile: URL
        let activationFile: URL
        let artifactDirectories: [HistoryRetentionArtifactDirectory]
        let prepare: () throws -> Void

        static var live: HistoryRetentionStorage {
            let computerHistoryDirectories = ComputerHistoryStore.retentionDirectories(
                rootDirectory: AppPaths.applicationSupportDirectory
            )
            var artifacts = [
                HistoryRetentionArtifactDirectory(
                    directory: AppPaths.eventsDirectory,
                    dataClass: .detailedEvents,
                    allowedSuffixes: [".jsonl"]
                ),
                HistoryRetentionArtifactDirectory(
                    directory: AppPaths.semanticDirectory,
                    dataClass: .semanticSnapshots,
                    allowedSuffixes: [".semantic.jsonl"]
                ),
                HistoryRetentionArtifactDirectory(
                    directory: AppPaths.memoriesDirectory,
                    dataClass: .memories,
                    allowedSuffixes: [".memory.json", ".memory.md"]
                ),
                HistoryRetentionArtifactDirectory(
                    directory: ActivityAnalysisPaths.analysisDirectory,
                    dataClass: .analysisCaches,
                    allowedSuffixes: [".analysis.json", ".agent.md"]
                ),
                HistoryRetentionArtifactDirectory(
                    directory: AppPaths.sealsDirectory,
                    dataClass: .minuteSeals,
                    allowedSuffixes: [".seals.jsonl"]
                ),
                HistoryRetentionArtifactDirectory(
                    directory: AppPaths.receiptsDirectory,
                    dataClass: .anchorReceipts,
                    allowedSuffixes: [".receipts.jsonl"]
                ),
            ]
            artifacts.append(
                contentsOf: computerHistoryDirectories.map {
                    HistoryRetentionArtifactDirectory(
                        directory: $0,
                        dataClass: .memories,
                        allowedSuffixes: [
                            ".computer-history.json",
                            ".computer-history.md",
                            "-goalong-computer-history.md",
                        ]
                    )
                }
            )
            return HistoryRetentionStorage(
                policyFile: AppPaths.retentionPolicyFile,
                activationFile: AppPaths.retentionPolicyActivationFile,
                artifactDirectories: artifacts,
                prepare: { try AppPaths.prepare() }
            )
        }
    }

    private enum HistoryRetentionStoreError: LocalizedError {
        case unsupportedPolicy
        case oversizedMetadata(URL)
        case unsafeMetadataPath(URL)

        var errorDescription: String? {
            switch self {
            case .unsupportedPolicy:
                return "The retention policy is not supported for automatic cleanup."
            case let .oversizedMetadata(url):
                return "Retention metadata is unexpectedly large at \(url.path)."
            case let .unsafeMetadataPath(url):
                return "Retention metadata must be a regular file, not a link or directory: \(url.path)."
            }
        }
    }

    /// The sole automatic-retention authority. Migration never activates cleanup:
    /// the persisted policy and its activation record must both be valid and equal.
    final class HistoryRetentionStore {
        private static let maximumMetadataBytes: Int64 = 64 * 1_024

        private let fileManager: FileManager
        private let storage: HistoryRetentionStorage
        private let diagnose: (String) -> Void
        private var cleanupMayRun: Bool
        private(set) var policy: HistoryRetentionPolicy

        convenience init(legacyRetentionDays: Int) {
            self.init(
                legacyRetentionDays: legacyRetentionDays,
                storage: .live,
                fileManager: .default,
                diagnostics: { Diagnostics.write($0) }
            )
        }

        init(
            legacyRetentionDays: Int,
            storage: HistoryRetentionStorage,
            fileManager: FileManager = .default,
            diagnostics: @escaping (String) -> Void = { _ in }
        ) {
            self.fileManager = fileManager
            self.storage = storage
            diagnose = diagnostics
            cleanupMayRun = false
            policy = .migratingLegacy(retentionDays: legacyRetentionDays)

            if let data = Self.readBoundedRegularFile(at: storage.policyFile),
                let decoded = try? Self.decoder.decode(
                    HistoryRetentionPolicy.self,
                    from: data
                ),
                decoded.isSupportedForAutomaticCleanup
            {
                policy = decoded
                cleanupMayRun = true
                return
            }

            // Persist a first-run migration only when neither metadata path exists.
            // A stale activation marker or an invalid/symlinked policy must not be
            // overwritten into a state that could authorize deletion on next launch.
            guard !Self.itemExists(at: storage.policyFile),
                !Self.itemExists(at: storage.activationFile)
            else {
                diagnose(
                    "Retention policy unavailable or unsupported; using an in-memory non-destructive migration with cleanup disabled"
                )
                return
            }
            do {
                try storage.prepare()
                try writeMetadata(Self.encoder.encode(policy), to: storage.policyFile)
            } catch {
                diagnose("Could not persist non-destructive retention migration: \(error)")
            }
        }

        @discardableResult
        func save(_ value: HistoryRetentionPolicy) throws -> HistoryRetentionPolicy {
            guard value.isSupportedForAutomaticCleanup else {
                throw HistoryRetentionStoreError.unsupportedPolicy
            }
            try storage.prepare()
            try invalidateMatchingActivationIfPresent()
            try writeMetadata(Self.encoder.encode(value), to: storage.policyFile)
            policy = value
            cleanupMayRun = false
            return value
        }

        /// Keeps the Settings value effective for the detailed layer. Zero,
        /// negative and otherwise invalid values conservatively mean "keep".
        func updateDetailedRetention(fromLegacyDays days: Int) throws {
            let duration = RetentionDuration(days: days)
            var updated = policy
            updated.detailedEvents = duration
            updated.semanticSnapshots = duration
            updated.analysisCaches = duration
            _ = try save(updated)

            let activation = ActivationRecord(policy: updated)
            try writeMetadata(Self.encoder.encode(activation), to: storage.activationFile)
            cleanupMayRun = true
        }

        func applyCleanup(now: Date = Date()) {
            guard cleanupMayRun, activationMatchesCurrentPolicy() else {
                diagnose(
                    "Retention cleanup disabled until a supported policy is explicitly saved"
                )
                return
            }

            let artifacts = storedArtifacts()
            let decisions = RetentionPlanner.decisions(
                for: artifacts,
                policy: policy,
                now: now
            )
            let today = Calendar.current.startOfDay(for: now)
            for decision in decisions where decision.shouldDelete {
                guard decision.artifact.end < today else { continue }
                let file = URL(fileURLWithPath: decision.artifact.localPath)
                guard isManagedRegularArtifact(file) else {
                    diagnose(
                        "Retention cleanup preserved an unknown, linked, or changed artifact at \(file.path)"
                    )
                    continue
                }
                do {
                    try Self.unlinkRegularFile(at: file)
                } catch {
                    diagnose(
                        "Retention cleanup could not remove \(decision.artifact.localPath): \(error)"
                    )
                }
            }
        }

        private func activationMatchesCurrentPolicy() -> Bool {
            guard let data = Self.readBoundedRegularFile(at: storage.activationFile),
                let activation = try? Self.decoder.decode(ActivationRecord.self, from: data)
            else { return false }
            return activation.schemaVersion == ActivationRecord.currentSchemaVersion
                && activation.policy.isSupportedForAutomaticCleanup
                && activation.policy == policy
        }

        private func invalidateMatchingActivationIfPresent() throws {
            guard let data = Self.readBoundedRegularFile(at: storage.activationFile),
                (try? Self.decoder.decode(ActivationRecord.self, from: data)) != nil
            else { return }
            try Self.unlinkRegularFile(at: storage.activationFile)
        }

        private func writeMetadata(_ data: Data, to destination: URL) throws {
            guard data.count <= Self.maximumMetadataBytes else {
                throw HistoryRetentionStoreError.oversizedMetadata(destination)
            }
            if Self.itemExists(at: destination),
                Self.regularFileSize(at: destination) == nil
            {
                throw HistoryRetentionStoreError.unsafeMetadataPath(destination)
            }
            try data.write(to: destination, options: .atomic)
            try? fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: destination.path
            )
        }

        private func storedArtifacts() -> [HistoryStoredArtifact] {
            var output: [HistoryStoredArtifact] = []
            for definition in storage.artifactDirectories {
                guard let files = try? fileManager.contentsOfDirectory(
                    at: definition.directory,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                ) else { continue }

                for file in files {
                    let name = file.lastPathComponent
                    guard definition.recognizes(name),
                        Self.regularFileSize(at: file) != nil,
                        let day = Self.day(from: name)
                    else { continue }
                    let start = Calendar.current.startOfDay(for: day)
                    guard let nextDay = Calendar.current.date(
                        byAdding: .day,
                        value: 1,
                        to: start
                    ) else { continue }
                    output.append(
                        HistoryStoredArtifact(
                            id: "\(definition.dataClass.rawValue):\(file.path)",
                            dataClass: definition.dataClass,
                            start: start,
                            end: nextDay.addingTimeInterval(-0.001),
                            localPath: file.path
                        )
                    )
                }
            }
            return output
        }

        private func isManagedRegularArtifact(_ file: URL) -> Bool {
            guard Self.regularFileSize(at: file) != nil else { return false }
            let parent = file.deletingLastPathComponent().standardizedFileURL
            return storage.artifactDirectories.contains { definition in
                definition.directory.standardizedFileURL == parent
                    && definition.recognizes(file.lastPathComponent)
                    && Self.day(from: file.lastPathComponent) != nil
            }
        }

        private static func day(from name: String) -> Date? {
            guard name.count > 10 else { return nil }
            let end = name.index(name.startIndex, offsetBy: 10)
            let dayString = String(name[..<end])
            guard dayString.range(
                of: #"^\d{4}-\d{2}-\d{2}$"#,
                options: .regularExpression
            ) != nil else { return nil }
            return dayFormatter.date(from: dayString)
        }

        private static func itemExists(at url: URL) -> Bool {
            var info = stat()
            return url.path.withCString { lstat($0, &info) } == 0
        }

        private static func regularFileSize(at url: URL) -> Int64? {
            var info = stat()
            guard url.path.withCString({ lstat($0, &info) }) == 0,
                (info.st_mode & S_IFMT) == S_IFREG
            else { return nil }
            return info.st_size
        }

        private static func readBoundedRegularFile(at url: URL) -> Data? {
            let descriptor = url.path.withCString {
                open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            }
            guard descriptor >= 0 else { return nil }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            var info = stat()
            guard fstat(descriptor, &info) == 0,
                (info.st_mode & S_IFMT) == S_IFREG,
                info.st_size >= 0,
                info.st_size <= maximumMetadataBytes,
                let data = try? handle.read(
                    upToCount: Int(maximumMetadataBytes) + 1
                ),
                data.count <= maximumMetadataBytes
            else { return nil }
            return data
        }

        private static func unlinkRegularFile(at url: URL) throws {
            guard regularFileSize(at: url) != nil else {
                throw HistoryRetentionStoreError.unsafeMetadataPath(url)
            }
            let result = url.path.withCString { unlink($0) }
            guard result == 0 else {
                throw NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(errno),
                    userInfo: [NSFilePathErrorKey: url.path]
                )
            }
        }

        private struct ActivationRecord: Codable {
            static let currentSchemaVersion = 1

            let schemaVersion: Int
            let policy: HistoryRetentionPolicy

            init(policy: HistoryRetentionPolicy) {
                schemaVersion = Self.currentSchemaVersion
                self.policy = policy
            }
        }

        private static let dayFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.isLenient = false
            return formatter
        }()

        private static let encoder: JSONEncoder = {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [
                .prettyPrinted,
                .sortedKeys,
                .withoutEscapingSlashes,
            ]
            return encoder
        }()

        private static let decoder: JSONDecoder = {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return decoder
        }()
    }
#endif
