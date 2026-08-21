#if os(macOS)
    import Foundation
    import LocalHistoryCore

    /// Persists independent retention windows without retroactively deleting any
    /// existing class during migration. Cleanup is whole-day and never erases the
    /// current day or cryptographic proofs unless their own policy explicitly expires.
    final class HistoryRetentionStore {
        private let fileManager = FileManager.default
        private(set) var policy: HistoryRetentionPolicy

        init(legacyRetentionDays: Int) {
            if let data = try? Data(contentsOf: AppPaths.retentionPolicyFile),
                let decoded = try? Self.decoder.decode(
                    HistoryRetentionPolicy.self,
                    from: data
                )
            {
                policy = decoded
            } else {
                policy = .migratingLegacy(retentionDays: legacyRetentionDays)
                try? save(policy)
            }
        }

        @discardableResult
        func save(_ value: HistoryRetentionPolicy) throws -> HistoryRetentionPolicy {
            try AppPaths.prepare()
            let data = try Self.encoder.encode(value)
            try data.write(to: AppPaths.retentionPolicyFile, options: .atomic)
            try? fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: AppPaths.retentionPolicyFile.path
            )
            policy = value
            return value
        }

        /// Keeps the existing Settings value effective for the detailed layer
        /// while memories and cryptographic proofs remain independently retained.
        func updateDetailedRetention(fromLegacyDays days: Int) throws {
            let clamped = min(max(0, days), 3_650)
            let duration: RetentionDuration = clamped == 0
                ? .indefinite
                : RetentionDuration(days: clamped)
            var updated = policy
            updated.detailedEvents = duration
            updated.semanticSnapshots = duration
            updated.analysisCaches = duration
            _ = try save(updated)
            let activation = Data("explicit-settings-save\n".utf8)
            try activation.write(
                to: AppPaths.retentionPolicyActivationFile,
                options: .atomic
            )
            try? fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: AppPaths.retentionPolicyActivationFile.path
            )
        }

        func applyCleanup(now: Date = Date()) {
            guard fileManager.fileExists(
                atPath: AppPaths.retentionPolicyActivationFile.path
            ) else {
                Diagnostics.write(
                    "Retention policy migrated non-destructively; cleanup remains disabled until settings are explicitly saved"
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
                do {
                    try fileManager.removeItem(
                        at: URL(fileURLWithPath: decision.artifact.localPath)
                    )
                } catch {
                    Diagnostics.write(
                        "Retention cleanup could not remove \(decision.artifact.localPath): \(error)"
                    )
                }
            }
        }

        private func storedArtifacts() -> [HistoryStoredArtifact] {
            var output: [HistoryStoredArtifact] = []
            var definitions: [(URL, HistoryDataClass)] = [
                (AppPaths.eventsDirectory, .detailedEvents),
                (AppPaths.semanticDirectory, .semanticSnapshots),
                (AppPaths.memoriesDirectory, .memories),
                (ActivityAnalysisPaths.analysisDirectory, .analysisCaches),
                (AppPaths.sealsDirectory, .minuteSeals),
                (AppPaths.receiptsDirectory, .anchorReceipts),
            ]
            definitions.append(
                contentsOf: ComputerHistoryStore.retentionDirectories(
                    rootDirectory: AppPaths.applicationSupportDirectory
                ).map { ($0, .memories) }
            )

            for (directory, dataClass) in definitions {
                guard let files = try? fileManager.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                ) else { continue }
                for file in files {
                    guard let day = Self.day(from: file.lastPathComponent) else {
                        continue
                    }
                    let start = Calendar.current.startOfDay(for: day)
                    let end = Calendar.current.date(
                        byAdding: .day,
                        value: 1,
                        to: start
                    )!.addingTimeInterval(-0.001)
                    output.append(
                        HistoryStoredArtifact(
                            id: "\(dataClass.rawValue):\(file.lastPathComponent)",
                            dataClass: dataClass,
                            start: start,
                            end: end,
                            localPath: file.path
                        )
                    )
                }
            }
            return output
        }

        private static func day(from name: String) -> Date? {
            guard let range = name.range(
                of: #"^\d{4}-\d{2}-\d{2}"#,
                options: .regularExpression
            ) else { return nil }
            return dayFormatter.date(from: String(name[range]))
        }

        private static let dayFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = "yyyy-MM-dd"
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
