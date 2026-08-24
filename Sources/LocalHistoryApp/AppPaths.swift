#if os(macOS)
    import AgentActivity
    import Darwin
    import Foundation
    import LocalHistoryCore

    enum AppPaths {
        final class ProcessPreparationGate {
            private let lock = NSLock()
            private var isPrepared = false

            func perform(_ operation: () throws -> Void) throws {
                lock.lock()
                defer { lock.unlock() }
                guard !isPrepared else { return }
                try operation()
                isPrepared = true
            }
        }

        private static let applicationStoragePreparationGate = ProcessPreparationGate()
        private static let agentActivityPreparationLock = NSLock()
        private static let agentActivityDirectoryName = "agent-activity-v2"
        private static let legacyAgentActivityDirectoryName = "agent-activity"
        private static let legacyAgentActivityQuarantinePrefix = ".agent-activity-legacy-quarantine-v2-"
        private static let retiredFixedLegacyQuarantineName = ".agent-activity-legacy-quarantine-v2"
        private static let agentActivitySentinelCandidatePrefix = ".agent-activity-v2-sentinel-"
        private static let maximumMigratedConfigurationBytes: Int64 = 1 * 1_024 * 1_024
        private static let maximumMigratedIndexBytes: Int64 = 64 * 1_024 * 1_024
        private static let legacyVaultDirectoryNames: Set<String> = [
            "blobs", "hook-inbox", "manifests", "materialized", "signals",
        ]
        private static let legacyVaultRegularFileNames: Set<String> = [
            "configuration.json", "index.json", "state.json",
        ]
        private static let migratedIndexTopLevelKeys: Set<String> = [
            "schemaVersion", "entries", "lastFullDiscoveryByFolder",
            "lastFullDiscoveryAttemptByFolder", "fullDiscoveryFailureCountByFolder",
            "rootStatusByFolder", "lastHandledSignalByProvider", "updatedAt",
        ]
        private static let migratedIndexEntryKeys: Set<String> = [
            "id", "stableConversationID", "watchedFolderID", "watchedFolderName",
            "provider", "reference", "relativePath", "sourceCreatedAt",
            "sourceModifiedAt", "conversationStartedAt", "conversationEndedAt",
            "firstIndexedAt", "lastObservedAt", "byteCount", "sha256",
            "sourceDevice", "sourceInode", "sourceChangedSeconds", "sourceChangedNanoseconds",
            "sourceContainerByteCount", "sourceContainerModifiedSeconds",
            "sourceContainerModifiedNanoseconds",
            "startOffset", "endOffset", "availability", "statusDetail",
        ]
        private static let migratedIndexReferenceKeys: Set<String> = ["kind", "path", "locator"]
        private static let legacySentinelContents = Data(
            "Goalong History Agent Activity v2 safety barrier. Legacy storage is disabled.\n".utf8
        )

        private struct FileIdentity: Equatable {
            var device: UInt64
            var inode: UInt64
            var type: FileAttributeType
        }

        private struct OwnedRemovalEntry {
            var name: String
            var identity: FileIdentity
            var children: [OwnedRemovalEntry]?
        }

        private static let ownedRemovalTestHookLock = NSLock()
        private static var ownedRemovalTestHook: ((URL) throws -> Void)?

        /// Installs a deterministic race seam used only by deletion-boundary tests.
        /// Production callers never set it.
        static func setOwnedRemovalTestHook(_ hook: ((URL) throws -> Void)?) {
            ownedRemovalTestHookLock.lock()
            ownedRemovalTestHook = hook
            ownedRemovalTestHookLock.unlock()
        }

        static let applicationSupportDirectory: URL = {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            return base.appendingPathComponent("LocalHistory", isDirectory: true)
        }()

        static let eventsDirectory = applicationSupportDirectory.appendingPathComponent("events", isDirectory: true)
        static let sealsDirectory = applicationSupportDirectory.appendingPathComponent("seals", isDirectory: true)
        static let receiptsDirectory = applicationSupportDirectory.appendingPathComponent("receipts", isDirectory: true)
        static let sharesDirectory = applicationSupportDirectory.appendingPathComponent("shares", isDirectory: true)
        static let semanticDirectory = applicationSupportDirectory.appendingPathComponent("semantic", isDirectory: true)
        static let memoriesDirectory = applicationSupportDirectory.appendingPathComponent("memories", isDirectory: true)
        static let screenTimeDirectory = applicationSupportDirectory.appendingPathComponent(
            "apple-screen-time", isDirectory: true)
        static let agentActivityDirectory = applicationSupportDirectory.appendingPathComponent(
            agentActivityDirectoryName, isDirectory: true)
        static let chatGPTDirectory = applicationSupportDirectory.appendingPathComponent(
            "chatgpt", isDirectory: true)
        static let chatGPTHistoryDirectory = chatGPTDirectory.appendingPathComponent(
            "history", isDirectory: true)
        static let chatGPTRecapsDirectory = chatGPTDirectory.appendingPathComponent(
            "recaps", isDirectory: true)
        static let chatGPTRunsDirectory = chatGPTDirectory.appendingPathComponent(
            "runs", isDirectory: true)
        static let chatGPTCodexHomeDirectory = chatGPTDirectory.appendingPathComponent(
            "codex-home", isDirectory: true)
        static let integrityStateFile = applicationSupportDirectory.appendingPathComponent(
            "integrity-state.json", isDirectory: false)
        static let configFile = applicationSupportDirectory.appendingPathComponent("config.json", isDirectory: false)
        static let sharingRulesFile = applicationSupportDirectory.appendingPathComponent(
            "sharing-rules.json", isDirectory: false)
        static let softwareSigningKeyFile = applicationSupportDirectory.appendingPathComponent(
            "device-signing-key-v2.bin", isDirectory: false)
        static let diagnosticsFile = applicationSupportDirectory.appendingPathComponent(
            "diagnostics.log", isDirectory: false)
        static let captureHealthFile = applicationSupportDirectory.appendingPathComponent(
            "capture-health.json", isDirectory: false)
        static let retentionPolicyFile = applicationSupportDirectory.appendingPathComponent(
            "retention-policy.json", isDirectory: false)
        static let retentionPolicyActivationFile = applicationSupportDirectory.appendingPathComponent(
            "retention-policy-activated", isDirectory: false)

        static func prepare() throws {
            try applicationStoragePreparationGate.perform {
                try prepareApplicationStorage(
                    applicationSupportDirectory: applicationSupportDirectory,
                    fileManager: .default
                )
            }
        }

        /// Prepares only the bounded wake-up signal path used by short-lived provider hooks.
        /// It never opens Agent Activity configuration/index files or runs legacy migration.
        /// Existing unsafe storage fails closed so hook input cannot recreate a transcript vault.
        static func prepareAgentActivityHookStorage() throws -> URL {
            try prepareAgentActivityHookStorage(
                applicationSupportDirectory: applicationSupportDirectory,
                fileManager: .default
            )
        }

        @discardableResult
        static func prepareAgentActivityHookStorage(
            applicationSupportDirectory: URL,
            fileManager: FileManager = .default
        ) throws -> URL {
            var preparedDirectory: URL?
            try withLockedAgentActivitySupportDirectory(
                applicationSupportDirectory,
                fileManager: fileManager
            ) { supportDirectory in
                let legacyBarrier = supportDirectory.appendingPathComponent(
                    legacyAgentActivityDirectoryName,
                    isDirectory: false
                )
                let v2Directory = supportDirectory.appendingPathComponent(
                    agentActivityDirectoryName,
                    isDirectory: true
                )
                let signalsDirectory = v2Directory.appendingPathComponent(
                    "signals",
                    isDirectory: true
                )

                let legacyType = try itemType(at: legacyBarrier, fileManager: fileManager)
                let hasValidLegacyBarrier: Bool
                if legacyType == nil {
                    hasValidLegacyBarrier = true
                } else if legacyType == .typeRegular {
                    hasValidLegacyBarrier =
                        try readRegularFileNoFollow(
                            at: legacyBarrier,
                            maximumBytes: 256
                        ) == legacySentinelContents
                } else {
                    hasValidLegacyBarrier = false
                }
                guard hasValidLegacyBarrier else {
                    throw AppPathsError.invalidLegacyBarrier(legacyBarrier)
                }

                let v2Type = try itemType(at: v2Directory, fileManager: fileManager)
                guard v2Type == nil || v2Type == .typeDirectory else {
                    throw AppPathsError.unsafeHookStorage(v2Directory)
                }
                let signalsType = try itemType(at: signalsDirectory, fileManager: fileManager)
                guard signalsType == nil || signalsType == .typeDirectory else {
                    throw AppPathsError.unsafeHookStorage(signalsDirectory)
                }

                // These names identify the retired full-content vault. Do not let a hook
                // operate alongside one, even though the hook itself only writes a signal.
                if v2Type == .typeDirectory {
                    for forbiddenName in ["blobs", "hook-inbox", "manifests", "materialized"] {
                        let forbiddenItem = v2Directory.appendingPathComponent(
                            forbiddenName,
                            isDirectory: true
                        )
                        guard try itemType(at: forbiddenItem, fileManager: fileManager) == nil else {
                            throw AppPathsError.unsafeHookStorage(forbiddenItem)
                        }
                    }
                }

                if legacyType == nil {
                    try createLegacySentinel(at: legacyBarrier, fileManager: fileManager)
                } else {
                    try setAndVerifyPOSIXPermissions(
                        0o600,
                        for: legacyBarrier,
                        expectedType: .typeRegular,
                        fileManager: fileManager
                    )
                }
                try ensureSecureDirectory(v2Directory, fileManager: fileManager)
                try ensureSecureDirectory(signalsDirectory, fileManager: fileManager)
                try secureExistingAgentSignalFiles(
                    in: signalsDirectory,
                    fileManager: fileManager
                )
                guard
                    try readRegularFileNoFollow(at: legacyBarrier, maximumBytes: 256)
                        == legacySentinelContents
                else {
                    throw AppPathsError.invalidLegacyBarrier(legacyBarrier)
                }
                preparedDirectory = v2Directory
            }
            guard let preparedDirectory else {
                throw AppPathsError.unsafeHookStorage(applicationSupportDirectory)
            }
            return preparedDirectory
        }

        /// Prepares the stores that make up Goalong History. The independent stores are
        /// created first, but Agent Activity migration remains fail-closed: the application
        /// must not continue while a legacy transcript vault is still reachable.
        static func prepareApplicationStorage(
            applicationSupportDirectory: URL,
            fileManager: FileManager = .default,
            agentActivityPreparation: ((URL, FileManager) throws -> Void)? = nil
        ) throws {
            try ensureSecureDirectory(applicationSupportDirectory, fileManager: fileManager)
            for directory in standardStorageDirectories(in: applicationSupportDirectory) {
                try ensureSecureDirectory(directory, fileManager: fileManager)
            }

            let preparation =
                agentActivityPreparation ?? { root, manager in
                    try prepareAgentActivityStorage(
                        applicationSupportDirectory: root,
                        fileManager: manager
                    )
                }
            do {
                try preparation(applicationSupportDirectory, fileManager)
            } catch {
                if case AppPathsError.agentActivityPreparationFailed = error {
                    throw error
                }
                let preparationError = error
                do {
                    try containAgentActivityPreparationFailure(
                        applicationSupportDirectory: applicationSupportDirectory,
                        fileManager: fileManager
                    )
                } catch let containmentError {
                    let failure = AppPathsError.agentActivityPreparationFailed(
                        preparation: preparationError.localizedDescription,
                        containment: containmentError.localizedDescription
                    )
                    reportAgentActivityPreparationError(failure.localizedDescription)
                    throw failure
                }
                let failure = AppPathsError.agentActivityPreparationFailed(
                    preparation: preparationError.localizedDescription,
                    containment: nil
                )
                reportAgentActivityPreparationError(failure.localizedDescription)
                throw failure
            }
        }

        private static func standardStorageDirectories(in root: URL) -> [URL] {
            let chatGPT = root.appendingPathComponent("chatgpt", isDirectory: true)
            return [
                root.appendingPathComponent("events", isDirectory: true),
                root.appendingPathComponent("seals", isDirectory: true),
                root.appendingPathComponent("receipts", isDirectory: true),
                root.appendingPathComponent("shares", isDirectory: true),
                root.appendingPathComponent("semantic", isDirectory: true),
                root.appendingPathComponent("memories", isDirectory: true),
                root.appendingPathComponent("apple-screen-time", isDirectory: true),
                chatGPT,
                chatGPT.appendingPathComponent("history", isDirectory: true),
                chatGPT.appendingPathComponent("recaps", isDirectory: true),
                chatGPT.appendingPathComponent("runs", isDirectory: true),
                chatGPT.appendingPathComponent("codex-home", isDirectory: true),
            ]
        }

        /// Moves only the bounded Agent Activity index/configuration into the v2 root, then
        /// replaces the legacy root with a regular-file barrier. A legacy build therefore
        /// cannot recreate its content-addressed transcript vault at `agent-activity/blobs`.
        static func prepareAgentActivityStorage(
            applicationSupportDirectory: URL,
            fileManager: FileManager = .default
        ) throws {
            do {
                try withLockedAgentActivitySupportDirectory(
                    applicationSupportDirectory,
                    fileManager: fileManager
                ) { supportDirectory in
                    try prepareAgentActivityStorageLocked(
                        supportDirectory: supportDirectory,
                        fileManager: fileManager
                    )
                }
            } catch {
                let preparationError = error
                do {
                    try containAgentActivityPreparationFailure(
                        applicationSupportDirectory: applicationSupportDirectory,
                        fileManager: fileManager
                    )
                } catch let containmentError {
                    let failure = AppPathsError.agentActivityPreparationFailed(
                        preparation: preparationError.localizedDescription,
                        containment: containmentError.localizedDescription
                    )
                    reportAgentActivityPreparationError(failure.localizedDescription)
                    throw failure
                }
                let failure = AppPathsError.agentActivityPreparationFailed(
                    preparation: preparationError.localizedDescription,
                    containment: nil
                )
                reportAgentActivityPreparationError(failure.localizedDescription)
                throw failure
            }
        }

        private static func withLockedAgentActivitySupportDirectory(
            _ applicationSupportDirectory: URL,
            fileManager: FileManager,
            operation: (URL) throws -> Void
        ) throws {
            agentActivityPreparationLock.lock()
            defer { agentActivityPreparationLock.unlock() }

            let supportDirectory = applicationSupportDirectory.standardizedFileURL
            try ensureSecureDirectory(supportDirectory, fileManager: fileManager)
            let supportDescriptor = supportDirectory.path.withCString {
                open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            }
            guard supportDescriptor >= 0 else {
                throw posixError(path: supportDirectory.path)
            }
            defer { _ = close(supportDescriptor) }
            guard flock(supportDescriptor, LOCK_EX) == 0 else {
                throw posixError(path: supportDirectory.path)
            }
            defer { _ = flock(supportDescriptor, LOCK_UN) }

            try operation(supportDirectory)
        }

        private static func prepareAgentActivityStorageLocked(
            supportDirectory: URL,
            fileManager: FileManager
        ) throws {

            let legacyDirectory = supportDirectory.appendingPathComponent(
                legacyAgentActivityDirectoryName,
                isDirectory: true
            )
            let v2Directory = supportDirectory.appendingPathComponent(
                agentActivityDirectoryName,
                isDirectory: true
            )

            try ensureSecureDirectory(v2Directory, fileManager: fileManager)
            try ensureSecureDirectory(
                v2Directory.appendingPathComponent("signals", isDirectory: true),
                fileManager: fileManager
            )

            let legacyType = try itemType(at: legacyDirectory, fileManager: fileManager)
            let removableLegacyIdentity: FileIdentity?
            if legacyType == .typeDirectory {
                // Preflight the active legacy vault before migration can ever rename or
                // delete it. Unknown files are preserved by fail-closed containment.
                removableLegacyIdentity = try recognizableLegacyQuarantineIdentity(
                    at: legacyDirectory,
                    fileManager: fileManager,
                    allowEmpty: true
                )
                try migrateValidatedConfiguration(
                    from: legacyDirectory.appendingPathComponent("configuration.json", isDirectory: false),
                    to: v2Directory.appendingPathComponent("configuration.json", isDirectory: false),
                    fileManager: fileManager
                )
                try migrateValidatedIndex(
                    from: legacyDirectory.appendingPathComponent("index.json", isDirectory: false),
                    to: v2Directory.appendingPathComponent("index.json", isDirectory: false),
                    fileManager: fileManager
                )
            } else {
                removableLegacyIdentity = nil
            }

            try validatePreparedAgentActivityStore(
                at: v2Directory,
                fileManager: fileManager
            )

            if legacyType == .typeRegular {
                // This is either our existing barrier or another non-directory blocker.
                // Preserve its bytes and only tighten its permissions.
                try setAndVerifyPOSIXPermissions(
                    0o600,
                    for: legacyDirectory,
                    expectedType: .typeRegular,
                    fileManager: fileManager
                )
            } else if legacyType != nil {
                try replaceLegacyItemWithSentinel(
                    legacyDirectory: legacyDirectory,
                    fileManager: fileManager,
                    removeOwnedQuarantinesAfterInstallation: true,
                    expectedRemovableIdentity: removableLegacyIdentity
                )
            } else {
                try createLegacySentinel(at: legacyDirectory, fileManager: fileManager)
            }

            try setAndVerifyPOSIXPermissions(
                0o700,
                for: v2Directory,
                expectedType: .typeDirectory,
                fileManager: fileManager
            )
            guard
                try readRegularFileNoFollow(at: legacyDirectory, maximumBytes: 256)
                    == legacySentinelContents
            else {
                throw AppPathsError.invalidLegacyBarrier(legacyDirectory)
            }
            try removeRecognizableLegacyQuarantines(
                supportDirectory: supportDirectory,
                legacyBarrier: legacyDirectory,
                v2Directory: v2Directory,
                fileManager: fileManager
            )
        }

        /// Reconciles both the retired fixed quarantine and UUID quarantines left by an
        /// interrupted migration. Every candidate is preflighted before any deletion. A
        /// lookalike is preserved and blocks startup instead of being guessed as ours.
        private static func removeRecognizableLegacyQuarantines(
            supportDirectory: URL,
            legacyBarrier: URL,
            v2Directory: URL,
            fileManager: FileManager
        ) throws {
            guard
                try readRegularFileNoFollow(at: legacyBarrier, maximumBytes: 256)
                    == legacySentinelContents
            else { throw AppPathsError.invalidLegacyBarrier(legacyBarrier) }
            try validatePreparedAgentActivityStore(at: v2Directory, fileManager: fileManager)

            let supportItems = try fileManager.contentsOfDirectory(
                at: supportDirectory,
                includingPropertiesForKeys: nil,
                options: []
            )
            var candidates: [URL] = []
            for item in supportItems {
                let name = item.lastPathComponent
                if name == retiredFixedLegacyQuarantineName {
                    candidates.append(item)
                    continue
                }
                guard name.hasPrefix(legacyAgentActivityQuarantinePrefix) else { continue }
                let suffix = String(name.dropFirst(legacyAgentActivityQuarantinePrefix.count))
                guard UUID(uuidString: suffix) != nil else {
                    throw AppPathsError.unrecognizedLegacyQuarantine(item)
                }
                candidates.append(item)
            }

            let identities = try candidates.map { quarantine in
                try recognizableLegacyQuarantineIdentity(
                    at: quarantine,
                    fileManager: fileManager
                )
            }
            for (quarantine, identity) in zip(candidates, identities) {
                try removeOwnedQuarantine(
                    quarantine,
                    expectedIdentity: identity,
                    fileManager: fileManager
                )
            }
        }

        private static func recognizableLegacyQuarantineIdentity(
            at quarantine: URL,
            fileManager: FileManager,
            allowEmpty: Bool = false
        ) throws -> FileIdentity {
            guard let quarantineIdentity = try fileIdentity(at: quarantine),
                quarantineIdentity.type == .typeDirectory
            else { throw AppPathsError.unrecognizedLegacyQuarantine(quarantine) }

            let topLevel = try fileManager.contentsOfDirectory(
                at: quarantine,
                includingPropertiesForKeys: nil,
                options: []
            )
            let names = Set(topLevel.map(\.lastPathComponent))
            let hasLegacySignature =
                !names.isDisjoint(with: ["blobs", "manifests", "materialized"])
                || (names.contains("configuration.json") && names.contains("index.json"))
            guard hasLegacySignature || (allowEmpty && names.isEmpty),
                names.allSatisfy(isRecognizableLegacyVaultName)
            else { throw AppPathsError.unrecognizedLegacyQuarantine(quarantine) }

            for child in topLevel {
                guard let identity = try fileIdentity(at: child),
                    identity.device == quarantineIdentity.device
                else { throw AppPathsError.unrecognizedLegacyQuarantine(quarantine) }
                if legacyVaultDirectoryNames.contains(child.lastPathComponent) {
                    guard identity.type == .typeDirectory else {
                        throw AppPathsError.unrecognizedLegacyQuarantine(quarantine)
                    }
                } else {
                    guard identity.type == .typeRegular else {
                        throw AppPathsError.unrecognizedLegacyQuarantine(quarantine)
                    }
                }
            }

            var enumerationFailed = false
            guard
                let enumerator = fileManager.enumerator(
                    at: quarantine,
                    includingPropertiesForKeys: nil,
                    options: [],
                    errorHandler: { _, _ in
                        enumerationFailed = true
                        return false
                    }
                )
            else { throw AppPathsError.unrecognizedLegacyQuarantine(quarantine) }
            var nodeCount = 0
            while let child = enumerator.nextObject() as? URL {
                nodeCount += 1
                guard nodeCount <= 100_000,
                    let identity = try fileIdentity(at: child),
                    identity.device == quarantineIdentity.device,
                    identity.type == .typeDirectory || identity.type == .typeRegular
                else { throw AppPathsError.unrecognizedLegacyQuarantine(quarantine) }
            }
            guard !enumerationFailed,
                try fileIdentity(at: quarantine) == quarantineIdentity
            else { throw AppPathsError.unrecognizedLegacyQuarantine(quarantine) }
            return quarantineIdentity
        }

        private static func isRecognizableLegacyVaultName(_ name: String) -> Bool {
            legacyVaultDirectoryNames.contains(name)
                || legacyVaultRegularFileNames.contains(name)
                || (name.hasPrefix("configuration.") && name.hasSuffix(".json"))
                || (name.hasPrefix("index.") && name.hasSuffix(".json"))
        }

        private static func containAgentActivityPreparationFailure(
            applicationSupportDirectory: URL,
            fileManager: FileManager
        ) throws {
            try withLockedAgentActivitySupportDirectory(
                applicationSupportDirectory,
                fileManager: fileManager
            ) { supportDirectory in
                let v2Directory = supportDirectory.appendingPathComponent(
                    agentActivityDirectoryName,
                    isDirectory: true
                )
                if let v2Type = try itemType(at: v2Directory, fileManager: fileManager),
                    v2Type != .typeDirectory
                {
                    let invalidRootQuarantine = try uniqueOwnedQuarantine(
                        beside: v2Directory,
                        prefix: ".agent-activity-v2-invalid-root-",
                        fileManager: fileManager
                    )
                    try fileManager.moveItem(at: v2Directory, to: invalidRootQuarantine)
                    guard let quarantineIdentity = try fileIdentity(at: invalidRootQuarantine),
                        quarantineIdentity.type == v2Type
                    else {
                        throw AppPathsError.couldNotCreateMigrationFile(invalidRootQuarantine)
                    }
                    try ensureSecureDirectory(v2Directory, fileManager: fileManager)
                    try removeOwnedQuarantine(
                        invalidRootQuarantine,
                        expectedIdentity: quarantineIdentity,
                        fileManager: fileManager
                    )
                } else {
                    try ensureSecureDirectory(v2Directory, fileManager: fileManager)
                }
                try ensureSecureDirectory(
                    v2Directory.appendingPathComponent("signals", isDirectory: true),
                    fileManager: fileManager
                )

                let legacyDirectory = supportDirectory.appendingPathComponent(
                    legacyAgentActivityDirectoryName,
                    isDirectory: true
                )
                switch try itemType(at: legacyDirectory, fileManager: fileManager) {
                case .typeRegular:
                    try setAndVerifyPOSIXPermissions(
                        0o600,
                        for: legacyDirectory,
                        expectedType: .typeRegular,
                        fileManager: fileManager
                    )
                case nil:
                    try createLegacySentinel(at: legacyDirectory, fileManager: fileManager)
                default:
                    // Preserve an unreadable or partially migrated legacy item by rename, while
                    // still installing the barrier. It is deliberately not auto-deleted later.
                    try replaceLegacyItemWithSentinel(
                        legacyDirectory: legacyDirectory,
                        fileManager: fileManager,
                        removeOwnedQuarantinesAfterInstallation: false
                    )
                }
            }
        }

        private static func reportAgentActivityPreparationError(_ detail: String) {
            let message = "Goalong History Agent Activity preparation error: \(detail)\n"
            try? FileHandle.standardError.write(contentsOf: Data(message.utf8))
        }

        private static func ensureSecureDirectory(_ directory: URL, fileManager: FileManager) throws {
            if let type = try itemType(at: directory, fileManager: fileManager) {
                guard type == .typeDirectory else {
                    throw AppPathsError.expectedDirectory(directory)
                }
            } else {
                try fileManager.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            }
            try setAndVerifyPOSIXPermissions(
                0o700,
                for: directory,
                expectedType: .typeDirectory,
                fileManager: fileManager
            )
        }

        private static func secureExistingAgentSignalFiles(
            in directory: URL,
            fileManager: FileManager
        ) throws {
            let names = Set(AgentProvider.allCases.map { "\($0.rawValue).json" })
                .union([".writer.lock"])
            for name in names {
                let file = directory.appendingPathComponent(name, isDirectory: false)
                guard let type = try itemType(at: file, fileManager: fileManager) else { continue }
                guard type == .typeRegular else {
                    throw AppPathsError.unsafeHookStorage(file)
                }
                try setAndVerifyPOSIXPermissions(
                    0o600,
                    for: file,
                    expectedType: .typeRegular,
                    fileManager: fileManager
                )
            }
        }

        private static func migrateValidatedConfiguration(
            from source: URL,
            to destination: URL,
            fileManager: FileManager
        ) throws {
            let sourceData = try normalizedConfigurationData(at: source)
            let destinationType = try itemType(at: destination, fileManager: fileManager)
            if let normalizedDestination = try normalizedConfigurationData(at: destination) {
                let current = try readRegularFileNoFollow(
                    at: destination,
                    maximumBytes: maximumMigratedConfigurationBytes
                )
                guard current != normalizedDestination else { return }
                try installMigratedMetadata(
                    normalizedDestination,
                    at: destination,
                    replacingInvalidDestination: true,
                    fileManager: fileManager
                )
                return
            }
            guard let sourceData else {
                if destinationType != nil {
                    try discardInvalidMetadata(at: destination, fileManager: fileManager)
                }
                return
            }
            try installMigratedMetadata(
                sourceData,
                at: destination,
                replacingInvalidDestination: destinationType != nil,
                fileManager: fileManager
            )
        }

        private static func normalizedConfigurationData(at source: URL) throws -> Data? {
            guard
                let data = try readRegularFileNoFollow(
                    at: source,
                    maximumBytes: maximumMigratedConfigurationBytes
                )
            else { return nil }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let configuration = try? decoder.decode(AgentActivityConfiguration.self, from: data),
                (1...2).contains(configuration.schemaVersion)
            else { return nil }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let normalized = try encoder.encode(configuration.validated())
            guard Int64(normalized.count) <= maximumMigratedConfigurationBytes else { return nil }
            return normalized
        }

        private static func validatePreparedAgentActivityStore(
            at rootDirectory: URL,
            fileManager: FileManager
        ) throws {
            try setAndVerifyPOSIXPermissions(
                0o700,
                for: rootDirectory,
                expectedType: .typeDirectory,
                fileManager: fileManager
            )
            let signalsDirectory = rootDirectory.appendingPathComponent("signals", isDirectory: true)
            try setAndVerifyPOSIXPermissions(
                0o700,
                for: signalsDirectory,
                expectedType: .typeDirectory,
                fileManager: fileManager
            )
            try secureExistingAgentSignalFiles(
                in: signalsDirectory,
                fileManager: fileManager
            )
            for name in ["configuration.json", "index.json"] {
                let metadata = rootDirectory.appendingPathComponent(name, isDirectory: false)
                guard let type = try itemType(at: metadata, fileManager: fileManager) else { continue }
                guard type == .typeRegular else {
                    throw AppPathsError.invalidMigratedMetadata(metadata)
                }
                try setAndVerifyPOSIXPermissions(
                    0o600,
                    for: metadata,
                    expectedType: .typeRegular,
                    fileManager: fileManager
                )
            }
            let store = try AgentActivityStore(
                rootDirectory: rootDirectory,
                fileManager: fileManager
            )
            guard store.configurationIsValid(),
                store.indexIsValid(maximumEntries: 50_000)
            else { throw AppPathsError.invalidMigratedMetadata(rootDirectory) }
        }

        private static func migrateValidatedIndex(
            from source: URL,
            to destination: URL,
            fileManager: FileManager
        ) throws {
            let sourceData = try normalizedIndexData(at: source)
            let destinationType = try itemType(at: destination, fileManager: fileManager)
            if let normalizedDestination = try normalizedIndexData(at: destination) {
                let current = try readRegularFileNoFollow(
                    at: destination,
                    maximumBytes: maximumMigratedIndexBytes
                )
                guard current != normalizedDestination else { return }
                try installMigratedMetadata(
                    normalizedDestination,
                    at: destination,
                    replacingInvalidDestination: true,
                    fileManager: fileManager
                )
                return
            }
            guard let sourceData else {
                if destinationType != nil {
                    try discardInvalidMetadata(at: destination, fileManager: fileManager)
                }
                return
            }
            try installMigratedMetadata(
                sourceData,
                at: destination,
                replacingInvalidDestination: destinationType != nil,
                fileManager: fileManager
            )
        }

        private static func normalizedIndexData(at source: URL) throws -> Data? {
            guard
                let data = try readRegularFileNoFollow(
                    at: source,
                    maximumBytes: maximumMigratedIndexBytes
                ),
                migratedIndexJSONContainsOnlyMetadataKeys(data)
            else { return nil }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard var index = try? decoder.decode(AgentActivityIndex.self, from: data)
            else { return nil }
            // Diagnostics can contain paths, database errors, or provider-controlled text.
            // They are regenerated as one of the closed availability codes only.
            for offset in index.entries.indices {
                switch index.entries[offset].availability {
                case .available:
                    index.entries[offset].statusDetail = nil
                case .missing:
                    index.entries[offset].statusDetail = "source_missing"
                case .inaccessible:
                    index.entries[offset].statusDetail = "source_inaccessible"
                }
            }
            guard isValidMigratedIndex(index) else { return nil }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let normalized = try encoder.encode(index)
            guard Int64(normalized.count) <= maximumMigratedIndexBytes else { return nil }
            return normalized
        }

        private static func migratedIndexJSONContainsOnlyMetadataKeys(_ data: Data) -> Bool {
            guard let object = try? JSONSerialization.jsonObject(with: data),
                let dictionary = object as? [String: Any],
                Set(dictionary.keys).isSubset(of: migratedIndexTopLevelKeys),
                let entries = dictionary["entries"] as? [Any]
            else { return false }

            return entries.allSatisfy { rawEntry in
                guard let entry = rawEntry as? [String: Any],
                    Set(entry.keys).isSubset(of: migratedIndexEntryKeys),
                    let reference = entry["reference"] as? [String: Any],
                    Set(reference.keys).isSubset(of: migratedIndexReferenceKeys)
                else { return false }
                return true
            }
        }

        private static func installMigratedMetadata(
            _ data: Data,
            at destination: URL,
            replacingInvalidDestination: Bool = false,
            fileManager: FileManager
        ) throws {
            let temporary = destination.deletingLastPathComponent().appendingPathComponent(
                ".\(destination.lastPathComponent).migration-\(UUID().uuidString)",
                isDirectory: false
            )
            do {
                try data.write(to: temporary, options: [.withoutOverwriting])
            } catch {
                throw AppPathsError.couldNotCreateMigrationFile(temporary)
            }
            guard let temporaryIdentity = try fileIdentity(at: temporary),
                temporaryIdentity.type == .typeRegular
            else {
                throw AppPathsError.couldNotCreateMigrationFile(temporary)
            }
            defer {
                try? removeOwnedItem(
                    at: temporary,
                    expectedIdentity: temporaryIdentity
                )
            }
            try setAndVerifyPOSIXPermissions(
                0o600,
                for: temporary,
                expectedType: .typeRegular,
                fileManager: fileManager
            )

            var invalidQuarantine: (URL, FileIdentity)?
            if replacingInvalidDestination,
                let destinationType = try itemType(at: destination, fileManager: fileManager)
            {
                let quarantine = try uniqueOwnedQuarantine(
                    beside: destination,
                    prefix: ".\(destination.lastPathComponent).invalid-v2-",
                    fileManager: fileManager
                )
                try fileManager.moveItem(at: destination, to: quarantine)
                guard let quarantineIdentity = try fileIdentity(at: quarantine),
                    quarantineIdentity.type == destinationType
                else {
                    throw AppPathsError.couldNotCreateMigrationFile(quarantine)
                }
                invalidQuarantine = (quarantine, quarantineIdentity)
            } else if try itemType(at: destination, fileManager: fileManager) != nil {
                return
            }

            do {
                try fileManager.moveItem(at: temporary, to: destination)
                try setAndVerifyPOSIXPermissions(
                    0o600,
                    for: destination,
                    expectedType: .typeRegular,
                    fileManager: fileManager
                )
            } catch {
                if let quarantined = invalidQuarantine,
                    try itemType(at: destination, fileManager: fileManager) == nil
                {
                    try? fileManager.moveItem(at: quarantined.0, to: destination)
                }
                throw error
            }
            if let quarantined = invalidQuarantine {
                try removeOwnedQuarantine(
                    quarantined.0,
                    expectedIdentity: quarantined.1,
                    fileManager: fileManager
                )
            }
        }

        private static func discardInvalidMetadata(
            at destination: URL,
            fileManager: FileManager
        ) throws {
            guard let destinationType = try itemType(at: destination, fileManager: fileManager) else {
                return
            }
            let quarantine = try uniqueOwnedQuarantine(
                beside: destination,
                prefix: ".\(destination.lastPathComponent).invalid-v2-",
                fileManager: fileManager
            )
            try fileManager.moveItem(at: destination, to: quarantine)
            guard let quarantineIdentity = try fileIdentity(at: quarantine),
                quarantineIdentity.type == destinationType
            else {
                throw AppPathsError.couldNotCreateMigrationFile(quarantine)
            }
            try removeOwnedQuarantine(
                quarantine,
                expectedIdentity: quarantineIdentity,
                fileManager: fileManager
            )
        }

        private static func isValidMigratedIndex(_ index: AgentActivityIndex) -> Bool {
            guard index.schemaVersion == 2,
                index.entries.count <= 50_000,
                index.lastFullDiscoveryByFolder.count <= 10_000,
                index.lastFullDiscoveryAttemptByFolder.count <= 10_000,
                index.fullDiscoveryFailureCountByFolder.count <= 10_000,
                index.rootStatusByFolder.count <= AgentActivityConfiguration.maximumWatchedFolders,
                index.lastHandledSignalByProvider.count <= AgentProvider.allCases.count,
                cursorMapIsValid(index.lastFullDiscoveryByFolder),
                cursorMapIsValid(index.lastFullDiscoveryAttemptByFolder),
                index.fullDiscoveryFailureCountByFolder.allSatisfy({
                    isOpaqueIdentifier($0.key, maximumBytes: 1_024)
                        && (0...30).contains($0.value)
                }),
                index.rootStatusByFolder.allSatisfy({
                    isOpaqueIdentifier($0.key, maximumBytes: 256)
                }),
                index.lastHandledSignalByProvider.keys.allSatisfy({
                    AgentProvider(rawValue: $0) != nil
                }),
                Set(index.entries.map(\.id)).count == index.entries.count,
                Set(
                    index.entries.map {
                        "\($0.reference.kind.rawValue)\u{0}\($0.reference.path)\u{0}\($0.reference.locator ?? "")"
                    }
                ).count
                    == index.entries.count
            else { return false }
            return index.entries.allSatisfy { entry in
                AgentStableConversationIdentifier.isPersisted(entry.stableConversationID)
                    && entry.id
                        == AgentStableConversationIdentifier.entryID(
                            provider: entry.provider,
                            persistedIdentifier: entry.stableConversationID
                        )
                    && isOpaqueIdentifier(entry.watchedFolderID, maximumBytes: 256)
                    && entry.watchedFolderName == entry.provider.displayName
                    && isValidatedAbsoluteSourcePath(entry.reference.path)
                    && isValidatedOpaqueRelativePath(entry.relativePath)
                    && referenceLocatorIsValid(entry.reference)
                    && isValidStatusCode(entry.statusDetail, availability: entry.availability)
                    && entry.byteCount >= 0
                    && (entry.sha256.isEmpty || isSHA256Hex(entry.sha256))
                    && (entry.availability != .available || isSHA256Hex(entry.sha256))
                    && sourceIdentityIsValid(entry)
                    && sourceContainerIdentityIsValid(entry)
                    && offsetsAreValid(entry)
            }
        }

        private static func sourceIdentityIsValid(_ entry: AgentSourceIndexEntry) -> Bool {
            let fields = [
                entry.sourceDevice != nil,
                entry.sourceInode != nil,
                entry.sourceChangedSeconds != nil,
                entry.sourceChangedNanoseconds != nil,
            ]
            guard fields.allSatisfy({ $0 }) || fields.allSatisfy({ !$0 }) else { return false }
            guard let nanoseconds = entry.sourceChangedNanoseconds else { return true }
            return (0..<1_000_000_000).contains(nanoseconds)
        }

        private static func sourceContainerIdentityIsValid(_ entry: AgentSourceIndexEntry) -> Bool {
            let fields = [
                entry.sourceContainerByteCount != nil,
                entry.sourceContainerModifiedSeconds != nil,
                entry.sourceContainerModifiedNanoseconds != nil,
            ]
            guard fields.allSatisfy({ $0 }) || fields.allSatisfy({ !$0 }) else { return false }
            guard let byteCount = entry.sourceContainerByteCount,
                let nanoseconds = entry.sourceContainerModifiedNanoseconds
            else { return true }
            return byteCount >= 0 && (0..<1_000_000_000).contains(nanoseconds)
        }

        private static func cursorMapIsValid(
            _ values: [String: Date],
            maximumKeyBytes: Int = 1_024
        ) -> Bool {
            values.allSatisfy { isOpaqueIdentifier($0.key, maximumBytes: maximumKeyBytes) }
        }

        private static func isOpaqueIdentifier(_ value: String, maximumBytes: Int) -> Bool {
            !value.isEmpty && value.utf8.count <= maximumBytes
                && value.unicodeScalars.allSatisfy { scalar in
                    scalar.value >= 0x21 && scalar.value != 0x7F
                }
        }

        private static func isValidatedAbsoluteSourcePath(_ path: String) -> Bool {
            guard path.hasPrefix("/"), path.utf8.count <= 4_096,
                !path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
            else { return false }
            return URL(fileURLWithPath: path).standardizedFileURL.path == path
        }

        private static func isValidatedOpaqueRelativePath(_ path: String) -> Bool {
            guard !path.isEmpty, !path.hasPrefix("/"), path.utf8.count <= 1_024,
                !path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
            else { return false }
            let components = path.split(separator: "/", omittingEmptySubsequences: false)
            return !components.isEmpty
                && components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
        }

        private static func referenceLocatorIsValid(_ reference: AgentSourceReference) -> Bool {
            switch reference.kind {
            case .file:
                return reference.locator == nil
            case .sqliteConversation:
                guard let locator = reference.locator,
                    isOpaqueIdentifier(locator, maximumBytes: 256)
                else { return false }
                return locator.unicodeScalars.allSatisfy { scalar in
                    scalar.isASCII
                        && (CharacterSet.alphanumerics.contains(scalar)
                            || "-._:".unicodeScalars.contains(scalar))
                }
            }
        }

        private static func isValidStatusCode(
            _ value: String?,
            availability: AgentSourceAvailability
        ) -> Bool {
            switch availability {
            case .available:
                return value == nil
            case .missing:
                return value == "source_missing"
            case .inaccessible:
                return value == "source_inaccessible"
            }
        }

        private static func isSHA256Hex(_ value: String) -> Bool {
            value.utf8.count == 64
                && value.unicodeScalars.allSatisfy {
                    (48...57).contains($0.value) || (97...102).contains($0.value)
                }
        }

        private static func offsetsAreValid(_ entry: AgentSourceIndexEntry) -> Bool {
            switch (entry.startOffset, entry.endOffset) {
            case (nil, nil):
                return true
            case (let start?, let end?):
                return start >= 0 && end >= start && end <= entry.byteCount
            default:
                return false
            }
        }

        private static func readRegularFileNoFollow(
            at url: URL,
            maximumBytes: Int64
        ) throws -> Data? {
            let descriptor = url.path.withCString { open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
            guard descriptor >= 0 else {
                if errno == ENOENT || errno == ELOOP { return nil }
                throw posixError(path: url.path)
            }
            defer { _ = close(descriptor) }

            var status = stat()
            guard fstat(descriptor, &status) == 0 else {
                throw posixError(path: url.path)
            }
            guard status.st_mode & S_IFMT == S_IFREG,
                status.st_size >= 0,
                status.st_size <= maximumBytes
            else {
                return nil
            }

            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
            var data = Data()
            data.reserveCapacity(Int(status.st_size))
            while data.count <= maximumBytes {
                let remaining = Int(maximumBytes) - data.count + 1
                guard let chunk = try handle.read(upToCount: min(16 * 1_024, remaining)),
                    !chunk.isEmpty
                else {
                    return data
                }
                data.append(chunk)
            }
            return nil
        }

        private static func replaceLegacyItemWithSentinel(
            legacyDirectory: URL,
            fileManager: FileManager,
            removeOwnedQuarantinesAfterInstallation: Bool,
            expectedRemovableIdentity: FileIdentity? = nil
        ) throws {
            guard let originalType = try itemType(at: legacyDirectory, fileManager: fileManager) else {
                try createLegacySentinel(at: legacyDirectory, fileManager: fileManager)
                return
            }
            let originalRemovableIdentity: FileIdentity?
            if removeOwnedQuarantinesAfterInstallation {
                let identity: FileIdentity
                if let expectedRemovableIdentity {
                    identity = expectedRemovableIdentity
                } else {
                    identity = try recognizableLegacyQuarantineIdentity(
                        at: legacyDirectory,
                        fileManager: fileManager,
                        allowEmpty: true
                    )
                }
                guard identity.type == .typeDirectory else {
                    throw AppPathsError.unrecognizedLegacyQuarantine(legacyDirectory)
                }
                let currentIdentity = try fileIdentity(at: legacyDirectory)
                guard currentIdentity == identity else {
                    throw AppPathsError.unrecognizedLegacyQuarantine(legacyDirectory)
                }
                originalRemovableIdentity = identity
            } else {
                originalRemovableIdentity = nil
            }
            let sentinelCandidate = legacyDirectory.deletingLastPathComponent().appendingPathComponent(
                "\(agentActivitySentinelCandidatePrefix)\(UUID().uuidString)",
                isDirectory: false
            )
            try createLegacySentinel(at: sentinelCandidate, fileManager: fileManager)
            guard let sentinelCandidateIdentity = try fileIdentity(at: sentinelCandidate),
                sentinelCandidateIdentity.type == .typeRegular
            else {
                throw AppPathsError.couldNotCreateSentinel(sentinelCandidate)
            }
            defer {
                try? removeOwnedItem(
                    at: sentinelCandidate,
                    expectedIdentity: sentinelCandidateIdentity
                )
            }

            let quarantineDirectory = try uniqueOwnedQuarantine(
                beside: legacyDirectory,
                prefix: legacyAgentActivityQuarantinePrefix,
                fileManager: fileManager
            )
            try fileManager.moveItem(at: legacyDirectory, to: quarantineDirectory)
            guard let quarantineIdentity = try fileIdentity(at: quarantineDirectory),
                quarantineIdentity.type == originalType,
                originalRemovableIdentity.map({ $0 == quarantineIdentity }) ?? true
            else {
                throw AppPathsError.couldNotCreateMigrationFile(quarantineDirectory)
            }
            var ownedQuarantines = [(quarantineDirectory, quarantineIdentity)]
            var installed = false
            var lastInstallationError: Error?
            for _ in 0..<8 {
                do {
                    try fileManager.moveItem(at: sentinelCandidate, to: legacyDirectory)
                    installed = true
                    break
                } catch {
                    lastInstallationError = error
                    guard let contendedType = try itemType(at: legacyDirectory, fileManager: fileManager) else {
                        continue
                    }
                    if contendedType == .typeRegular,
                        try readRegularFileNoFollow(at: legacyDirectory, maximumBytes: 256)
                            == legacySentinelContents
                    {
                        installed = true
                        break
                    }

                    let expectedContendedIdentity: FileIdentity?
                    if removeOwnedQuarantinesAfterInstallation {
                        let identity = try recognizableLegacyQuarantineIdentity(
                            at: legacyDirectory,
                            fileManager: fileManager,
                            allowEmpty: true
                        )
                        guard identity.type == .typeDirectory else {
                            throw AppPathsError.unrecognizedLegacyQuarantine(legacyDirectory)
                        }
                        let currentIdentity = try fileIdentity(at: legacyDirectory)
                        guard currentIdentity == identity else {
                            throw AppPathsError.unrecognizedLegacyQuarantine(legacyDirectory)
                        }
                        expectedContendedIdentity = identity
                    } else {
                        expectedContendedIdentity = nil
                    }

                    let contendedQuarantine = try uniqueOwnedQuarantine(
                        beside: legacyDirectory,
                        prefix: legacyAgentActivityQuarantinePrefix,
                        fileManager: fileManager
                    )
                    try fileManager.moveItem(at: legacyDirectory, to: contendedQuarantine)
                    guard let contendedIdentity = try fileIdentity(at: contendedQuarantine),
                        contendedIdentity.type == contendedType,
                        expectedContendedIdentity.map({ $0 == contendedIdentity }) ?? true
                    else {
                        throw AppPathsError.couldNotCreateMigrationFile(contendedQuarantine)
                    }
                    ownedQuarantines.append((contendedQuarantine, contendedIdentity))
                    if contendedType == .typeDirectory {
                        let v2Directory = legacyDirectory.deletingLastPathComponent().appendingPathComponent(
                            agentActivityDirectoryName,
                            isDirectory: true
                        )
                        try migrateValidatedConfiguration(
                            from: contendedQuarantine.appendingPathComponent("configuration.json"),
                            to: v2Directory.appendingPathComponent("configuration.json"),
                            fileManager: fileManager
                        )
                        try migrateValidatedIndex(
                            from: contendedQuarantine.appendingPathComponent("index.json"),
                            to: v2Directory.appendingPathComponent("index.json"),
                            fileManager: fileManager
                        )
                    }
                }
            }
            guard installed else {
                throw lastInstallationError ?? AppPathsError.couldNotCreateSentinel(legacyDirectory)
            }
            try setAndVerifyPOSIXPermissions(
                0o600,
                for: legacyDirectory,
                expectedType: .typeRegular,
                fileManager: fileManager
            )
            guard
                try readRegularFileNoFollow(at: legacyDirectory, maximumBytes: 256)
                    == legacySentinelContents
            else {
                throw AppPathsError.invalidLegacyBarrier(legacyDirectory)
            }
            if removeOwnedQuarantinesAfterInstallation {
                let v2Directory = legacyDirectory.deletingLastPathComponent().appendingPathComponent(
                    agentActivityDirectoryName,
                    isDirectory: true
                )
                try validatePreparedAgentActivityStore(at: v2Directory, fileManager: fileManager)
                for (quarantine, identity) in ownedQuarantines {
                    try removeOwnedQuarantine(
                        quarantine,
                        expectedIdentity: identity,
                        fileManager: fileManager
                    )
                }
            }
        }

        private static func uniqueOwnedQuarantine(
            beside item: URL,
            prefix: String,
            fileManager: FileManager
        ) throws -> URL {
            for _ in 0..<8 {
                let candidate = item.deletingLastPathComponent().appendingPathComponent(
                    "\(prefix)\(UUID().uuidString)",
                    isDirectory: false
                )
                if try itemType(at: candidate, fileManager: fileManager) == nil {
                    return candidate
                }
            }
            throw AppPathsError.couldNotCreateMigrationFile(item)
        }

        private static func removeOwnedQuarantine(
            _ quarantine: URL,
            expectedIdentity: FileIdentity,
            fileManager _: FileManager
        ) throws {
            try removeOwnedItem(at: quarantine, expectedIdentity: expectedIdentity)
        }

        /// Removes only the exact inode that was previously recorded. Directory contents
        /// are snapshotted and revalidated through pinned descriptors, then traversed with
        /// `openat`/`O_NOFOLLOW` and removed with `unlinkat`. A name replaced after validation
        /// is deliberately preserved and turns the migration into a fail-closed error.
        private static func removeOwnedItem(
            at item: URL,
            expectedIdentity: FileIdentity
        ) throws {
            let normalizedItem = item.standardizedFileURL
            let parent = normalizedItem.deletingLastPathComponent().standardizedFileURL
            let name = normalizedItem.lastPathComponent
            guard !name.isEmpty, name != ".", name != "..",
                parent.appendingPathComponent(name).standardizedFileURL == normalizedItem,
                let parentIdentity = try fileIdentity(at: parent),
                parentIdentity.type == .typeDirectory
            else {
                throw AppPathsError.couldNotCreateMigrationFile(item)
            }

            let parentDescriptor = parent.path.withCString {
                Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            }
            guard parentDescriptor >= 0 else { throw posixError(path: parent.path) }
            defer { _ = Darwin.close(parentDescriptor) }
            try requireDirectoryIdentity(
                parentIdentity,
                descriptor: parentDescriptor,
                path: parent
            )

            var currentStatus = stat()
            let initialResult = name.withCString {
                Darwin.fstatat(parentDescriptor, $0, &currentStatus, AT_SYMLINK_NOFOLLOW)
            }
            if initialResult != 0 {
                let initialError = errno
                guard initialError == ENOENT else {
                    throw posixError(path: normalizedItem.path, code: initialError)
                }
                try invokeOwnedRemovalTestHook(for: normalizedItem)
                try requireDirectoryIdentity(
                    parentIdentity,
                    descriptor: parentDescriptor,
                    path: parent
                )
                let finalResult = name.withCString {
                    Darwin.fstatat(parentDescriptor, $0, &currentStatus, AT_SYMLINK_NOFOLLOW)
                }
                if finalResult != 0, errno == ENOENT { return }
                throw AppPathsError.couldNotCreateMigrationFile(normalizedItem)
            }

            guard fileIdentity(for: currentStatus) == expectedIdentity,
                expectedIdentity.device == parentIdentity.device
            else {
                throw AppPathsError.couldNotCreateMigrationFile(normalizedItem)
            }

            var ownedDirectoryDescriptor: Int32 = -1
            var ownedEntries: [OwnedRemovalEntry] = []
            if expectedIdentity.type == .typeDirectory {
                ownedDirectoryDescriptor = name.withCString {
                    Darwin.openat(
                        parentDescriptor,
                        $0,
                        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                    )
                }
                guard ownedDirectoryDescriptor >= 0 else {
                    throw AppPathsError.couldNotCreateMigrationFile(normalizedItem)
                }
                var openedStatus = stat()
                guard Darwin.fstat(ownedDirectoryDescriptor, &openedStatus) == 0,
                    fileIdentity(for: openedStatus) == expectedIdentity
                else {
                    _ = Darwin.close(ownedDirectoryDescriptor)
                    throw AppPathsError.couldNotCreateMigrationFile(normalizedItem)
                }
                var nodeCount = 0
                do {
                    ownedEntries = try snapshotOwnedDirectory(
                        descriptor: ownedDirectoryDescriptor,
                        directory: normalizedItem,
                        expectedDevice: expectedIdentity.device,
                        nodeCount: &nodeCount
                    )
                    try validateOwnedDirectorySnapshot(
                        ownedEntries,
                        descriptor: ownedDirectoryDescriptor,
                        directory: normalizedItem,
                        expectedDevice: expectedIdentity.device
                    )
                } catch {
                    _ = Darwin.close(ownedDirectoryDescriptor)
                    throw error
                }
            }
            defer {
                if ownedDirectoryDescriptor >= 0 {
                    _ = Darwin.close(ownedDirectoryDescriptor)
                }
            }

            try invokeOwnedRemovalTestHook(for: normalizedItem)
            try requireDirectoryIdentity(
                parentIdentity,
                descriptor: parentDescriptor,
                path: parent
            )
            guard try relativeIdentity(
                named: name,
                in: parentDescriptor
            ) == expectedIdentity else {
                throw AppPathsError.couldNotCreateMigrationFile(normalizedItem)
            }

            if expectedIdentity.type == .typeDirectory {
                var pinnedStatus = stat()
                guard Darwin.fstat(ownedDirectoryDescriptor, &pinnedStatus) == 0,
                    fileIdentity(for: pinnedStatus) == expectedIdentity
                else {
                    throw AppPathsError.couldNotCreateMigrationFile(normalizedItem)
                }
                try deleteOwnedDirectorySnapshot(
                    ownedEntries,
                    descriptor: ownedDirectoryDescriptor,
                    directory: normalizedItem,
                    expectedDevice: expectedIdentity.device
                )
                guard try directoryEntryNames(descriptor: ownedDirectoryDescriptor).isEmpty,
                    try relativeIdentity(named: name, in: parentDescriptor) == expectedIdentity,
                    Darwin.fstat(ownedDirectoryDescriptor, &pinnedStatus) == 0,
                    fileIdentity(for: pinnedStatus) == expectedIdentity,
                    name.withCString({ Darwin.unlinkat(parentDescriptor, $0, AT_REMOVEDIR) }) == 0
                else {
                    throw AppPathsError.couldNotCreateMigrationFile(normalizedItem)
                }
            } else {
                guard name.withCString({ Darwin.unlinkat(parentDescriptor, $0, 0) }) == 0 else {
                    throw AppPathsError.couldNotCreateMigrationFile(normalizedItem)
                }
            }

            var postRemovalStatus = stat()
            let postRemovalResult = name.withCString {
                Darwin.fstatat(parentDescriptor, $0, &postRemovalStatus, AT_SYMLINK_NOFOLLOW)
            }
            guard postRemovalResult != 0, errno == ENOENT else {
                throw AppPathsError.couldNotCreateMigrationFile(normalizedItem)
            }
        }

        private static func snapshotOwnedDirectory(
            descriptor: Int32,
            directory: URL,
            expectedDevice: UInt64,
            nodeCount: inout Int,
            depth: Int = 0
        ) throws -> [OwnedRemovalEntry] {
            guard depth <= 256 else {
                throw AppPathsError.couldNotCreateMigrationFile(directory)
            }
            let names = try directoryEntryNames(
                descriptor: descriptor,
                maximumCount: 100_000 - nodeCount
            ).sorted()
            var entries: [OwnedRemovalEntry] = []
            entries.reserveCapacity(names.count)
            for name in names {
                nodeCount += 1
                guard nodeCount <= 100_000,
                    let identity = try relativeIdentity(named: name, in: descriptor),
                    identity.device == expectedDevice,
                    identity.type == .typeDirectory || identity.type == .typeRegular
                else {
                    throw AppPathsError.couldNotCreateMigrationFile(
                        directory.appendingPathComponent(name)
                    )
                }

                var children: [OwnedRemovalEntry]?
                if identity.type == .typeDirectory {
                    let childDescriptor = name.withCString {
                        Darwin.openat(
                            descriptor,
                            $0,
                            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                        )
                    }
                    guard childDescriptor >= 0 else {
                        throw AppPathsError.couldNotCreateMigrationFile(
                            directory.appendingPathComponent(name)
                        )
                    }
                    var openedStatus = stat()
                    guard Darwin.fstat(childDescriptor, &openedStatus) == 0,
                        fileIdentity(for: openedStatus) == identity
                    else {
                        _ = Darwin.close(childDescriptor)
                        throw AppPathsError.couldNotCreateMigrationFile(
                            directory.appendingPathComponent(name)
                        )
                    }
                    do {
                        children = try snapshotOwnedDirectory(
                            descriptor: childDescriptor,
                            directory: directory.appendingPathComponent(name, isDirectory: true),
                            expectedDevice: expectedDevice,
                            nodeCount: &nodeCount,
                            depth: depth + 1
                        )
                    } catch {
                        _ = Darwin.close(childDescriptor)
                        throw error
                    }
                    _ = Darwin.close(childDescriptor)
                }
                entries.append(
                    OwnedRemovalEntry(name: name, identity: identity, children: children)
                )
            }
            return entries
        }

        private static func validateOwnedDirectorySnapshot(
            _ entries: [OwnedRemovalEntry],
            descriptor: Int32,
            directory: URL,
            expectedDevice: UInt64
        ) throws {
            guard try directoryEntryNames(descriptor: descriptor).sorted() == entries.map(\.name)
            else { throw AppPathsError.couldNotCreateMigrationFile(directory) }

            for entry in entries {
                guard try relativeIdentity(named: entry.name, in: descriptor) == entry.identity,
                    entry.identity.device == expectedDevice
                else {
                    throw AppPathsError.couldNotCreateMigrationFile(
                        directory.appendingPathComponent(entry.name)
                    )
                }
                guard let children = entry.children else { continue }
                let childURL = directory.appendingPathComponent(entry.name, isDirectory: true)
                let childDescriptor = entry.name.withCString {
                    Darwin.openat(
                        descriptor,
                        $0,
                        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                    )
                }
                guard childDescriptor >= 0 else {
                    throw AppPathsError.couldNotCreateMigrationFile(childURL)
                }
                defer { _ = Darwin.close(childDescriptor) }
                var openedStatus = stat()
                guard Darwin.fstat(childDescriptor, &openedStatus) == 0,
                    fileIdentity(for: openedStatus) == entry.identity
                else { throw AppPathsError.couldNotCreateMigrationFile(childURL) }
                try validateOwnedDirectorySnapshot(
                    children,
                    descriptor: childDescriptor,
                    directory: childURL,
                    expectedDevice: expectedDevice
                )
            }
        }

        private static func deleteOwnedDirectorySnapshot(
            _ entries: [OwnedRemovalEntry],
            descriptor: Int32,
            directory: URL,
            expectedDevice: UInt64
        ) throws {
            guard try directoryEntryNames(descriptor: descriptor).sorted() == entries.map(\.name)
            else { throw AppPathsError.couldNotCreateMigrationFile(directory) }

            for entry in entries {
                let childURL = directory.appendingPathComponent(
                    entry.name,
                    isDirectory: entry.identity.type == .typeDirectory
                )
                guard try relativeIdentity(named: entry.name, in: descriptor) == entry.identity,
                    entry.identity.device == expectedDevice
                else { throw AppPathsError.couldNotCreateMigrationFile(childURL) }

                if let children = entry.children {
                    let childDescriptor = entry.name.withCString {
                        Darwin.openat(
                            descriptor,
                            $0,
                            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                        )
                    }
                    guard childDescriptor >= 0 else {
                        throw AppPathsError.couldNotCreateMigrationFile(childURL)
                    }
                    var openedStatus = stat()
                    guard Darwin.fstat(childDescriptor, &openedStatus) == 0,
                        fileIdentity(for: openedStatus) == entry.identity
                    else {
                        _ = Darwin.close(childDescriptor)
                        throw AppPathsError.couldNotCreateMigrationFile(childURL)
                    }
                    do {
                        try deleteOwnedDirectorySnapshot(
                            children,
                            descriptor: childDescriptor,
                            directory: childURL,
                            expectedDevice: expectedDevice
                        )
                        guard try directoryEntryNames(descriptor: childDescriptor).isEmpty,
                            try relativeIdentity(named: entry.name, in: descriptor) == entry.identity,
                            Darwin.fstat(childDescriptor, &openedStatus) == 0,
                            fileIdentity(for: openedStatus) == entry.identity,
                            entry.name.withCString({
                                Darwin.unlinkat(descriptor, $0, AT_REMOVEDIR)
                            }) == 0
                        else {
                            throw AppPathsError.couldNotCreateMigrationFile(childURL)
                        }
                    } catch {
                        _ = Darwin.close(childDescriptor)
                        throw error
                    }
                    _ = Darwin.close(childDescriptor)
                } else {
                    guard entry.name.withCString({ Darwin.unlinkat(descriptor, $0, 0) }) == 0 else {
                        throw AppPathsError.couldNotCreateMigrationFile(childURL)
                    }
                }
            }
        }

        private static func directoryEntryNames(
            descriptor: Int32,
            maximumCount: Int = 100_000
        ) throws -> [String] {
            guard maximumCount >= 0 else {
                throw AppPathsError.couldNotCreateMigrationFile(
                    URL(fileURLWithPath: "/dev/fd/\(descriptor)")
                )
            }
            let enumerationDescriptor = ".".withCString {
                Darwin.openat(
                    descriptor,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                )
            }
            guard enumerationDescriptor >= 0 else {
                throw AppPathsError.couldNotCreateMigrationFile(
                    URL(fileURLWithPath: "/dev/fd/\(descriptor)")
                )
            }
            guard let stream = Darwin.fdopendir(enumerationDescriptor) else {
                _ = Darwin.close(enumerationDescriptor)
                throw AppPathsError.couldNotCreateMigrationFile(
                    URL(fileURLWithPath: "/dev/fd/\(descriptor)")
                )
            }
            defer { Darwin.closedir(stream) }

            var names: [String] = []
            while true {
                errno = 0
                guard let entry = Darwin.readdir(stream) else {
                    guard errno == 0 else {
                        throw AppPathsError.couldNotCreateMigrationFile(
                            URL(fileURLWithPath: "/dev/fd/\(descriptor)")
                        )
                    }
                    break
                }
                let name = withUnsafePointer(to: entry.pointee.d_name) { pointer in
                    pointer.withMemoryRebound(
                        to: CChar.self,
                        capacity: Int(MAXNAMLEN) + 1
                    ) { String(cString: $0) }
                }
                guard name != ".", name != ".." else { continue }
                guard names.count < maximumCount else {
                    throw AppPathsError.couldNotCreateMigrationFile(
                        URL(fileURLWithPath: "/dev/fd/\(descriptor)")
                    )
                }
                names.append(name)
            }
            return names
        }

        private static func relativeIdentity(
            named name: String,
            in directoryDescriptor: Int32
        ) throws -> FileIdentity? {
            var status = stat()
            let result = name.withCString {
                Darwin.fstatat(directoryDescriptor, $0, &status, AT_SYMLINK_NOFOLLOW)
            }
            guard result == 0 else {
                let code = errno
                if code == ENOENT || code == ENOTDIR { return nil }
                throw posixError(path: name, code: code)
            }
            return fileIdentity(for: status)
        }

        private static func requireDirectoryIdentity(
            _ expectedIdentity: FileIdentity,
            descriptor: Int32,
            path: URL
        ) throws {
            var openedStatus = stat()
            guard try fileIdentity(at: path) == expectedIdentity,
                Darwin.fstat(descriptor, &openedStatus) == 0,
                fileIdentity(for: openedStatus) == expectedIdentity,
                expectedIdentity.type == .typeDirectory
            else { throw AppPathsError.couldNotCreateMigrationFile(path) }
        }

        private static func invokeOwnedRemovalTestHook(for item: URL) throws {
            ownedRemovalTestHookLock.lock()
            let hook = ownedRemovalTestHook
            ownedRemovalTestHookLock.unlock()
            try hook?(item)
        }

        private static func createLegacySentinel(at url: URL, fileManager: FileManager) throws {
            do {
                try legacySentinelContents.write(to: url, options: [.withoutOverwriting])
            } catch {
                throw AppPathsError.couldNotCreateSentinel(url)
            }
            try setAndVerifyPOSIXPermissions(
                0o600,
                for: url,
                expectedType: .typeRegular,
                fileManager: fileManager
            )
        }

        private static func setAndVerifyPOSIXPermissions(
            _ permissions: Int,
            for url: URL,
            expectedType: FileAttributeType,
            fileManager _: FileManager
        ) throws {
            let directoryFlag = expectedType == .typeDirectory ? O_DIRECTORY : 0
            let descriptor = url.path.withCString {
                open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | directoryFlag)
            }
            guard descriptor >= 0 else { throw posixError(path: url.path) }
            defer { _ = close(descriptor) }

            var status = stat()
            guard fstat(descriptor, &status) == 0,
                fileAttributeType(for: status.st_mode) == expectedType,
                fchmod(descriptor, mode_t(permissions)) == 0,
                fstat(descriptor, &status) == 0,
                fileAttributeType(for: status.st_mode) == expectedType,
                Int(status.st_mode & mode_t(0o777)) == permissions
            else {
                throw AppPathsError.unsafePermissions(url)
            }
        }

        private static func itemType(at url: URL, fileManager _: FileManager) throws -> FileAttributeType? {
            try fileIdentity(at: url)?.type
        }

        private static func fileIdentity(at url: URL) throws -> FileIdentity? {
            var status = stat()
            let result = url.path.withCString { lstat($0, &status) }
            guard result == 0 else {
                if errno == ENOENT || errno == ENOTDIR { return nil }
                throw posixError(path: url.path)
            }
            return fileIdentity(for: status)
        }

        private static func fileIdentity(for status: stat) -> FileIdentity {
            FileIdentity(
                device: UInt64(status.st_dev),
                inode: UInt64(status.st_ino),
                type: fileAttributeType(for: status.st_mode)
            )
        }

        private static func fileAttributeType(for mode: mode_t) -> FileAttributeType {
            switch mode & S_IFMT {
            case S_IFDIR:
                return .typeDirectory
            case S_IFREG:
                return .typeRegular
            case S_IFLNK:
                return .typeSymbolicLink
            case S_IFCHR:
                return .typeCharacterSpecial
            case S_IFBLK:
                return .typeBlockSpecial
            case S_IFSOCK:
                return .typeSocket
            default:
                return .typeUnknown
            }
        }

        private static func posixError(path: String, code: Int32 = errno) -> NSError {
            return NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(code),
                userInfo: [NSFilePathErrorKey: path]
            )
        }

        static func localDayString(for date: Date = Date()) -> String {
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter.string(from: date)
        }

        static func eventFileURL(for date: Date = Date()) -> URL {
            eventsDirectory.appendingPathComponent(localDayString(for: date) + ".jsonl")
        }

        static func semanticFileURL(for date: Date = Date()) -> URL {
            semanticDirectory.appendingPathComponent(localDayString(for: date) + ".semantic.jsonl")
        }

        static func sealFileURL(for date: Date = Date()) -> URL {
            sealsDirectory.appendingPathComponent(localDayString(for: date) + ".seals.jsonl")
        }

        static func receiptFileURL(for date: Date = Date()) -> URL {
            receiptsDirectory.appendingPathComponent(localDayString(for: date) + ".receipts.jsonl")
        }

        static func defaultShareFileURL(for date: Date = Date()) -> URL {
            sharesDirectory.appendingPathComponent(localDayString(for: date) + ".share.json")
        }
    }

    private enum AppPathsError: LocalizedError {
        case expectedDirectory(URL)
        case couldNotCreateSentinel(URL)
        case couldNotCreateMigrationFile(URL)
        case invalidLegacyBarrier(URL)
        case invalidMigratedMetadata(URL)
        case unrecognizedLegacyQuarantine(URL)
        case agentActivityPreparationFailed(preparation: String, containment: String?)
        case unsafeHookStorage(URL)
        case unsafePermissions(URL)

        var errorDescription: String? {
            switch self {
            case .expectedDirectory(let url):
                return "Expected a real directory at \(url.path)"
            case .couldNotCreateSentinel(let url):
                return "Could not create the Agent Activity legacy-storage barrier at \(url.path)"
            case .couldNotCreateMigrationFile(let url):
                return "Could not create the Agent Activity metadata migration file at \(url.path)"
            case .invalidLegacyBarrier(let url):
                return "Agent Activity legacy storage is not blocked by the verified barrier at \(url.path)"
            case .invalidMigratedMetadata(let url):
                return "Agent Activity v2 metadata does not satisfy the current store contract at \(url.path)"
            case .unrecognizedLegacyQuarantine(let url):
                return "Unrecognized Agent Activity legacy quarantine was preserved at \(url.path)"
            case .agentActivityPreparationFailed(let preparation, let containment):
                if let containment {
                    return "Agent Activity preparation failed: \(preparation); containment failed: \(containment)"
                }
                return "Agent Activity preparation failed after containment: \(preparation)"
            case .unsafeHookStorage(let url):
                return "Agent Activity hook storage is unsafe at \(url.path)"
            case .unsafePermissions(let url):
                return "Could not secure Agent Activity storage permissions at \(url.path)"
            }
        }
    }

    final class ConfigManager {
        private(set) var config: RecorderConfig

        init() {
            do {
                try AppPaths.prepare()
                if FileManager.default.fileExists(atPath: AppPaths.configFile.path) {
                    config = try RecorderConfig.load(from: AppPaths.configFile)
                    try? FileManager.default.setAttributes(
                        [.posixPermissions: 0o600], ofItemAtPath: AppPaths.configFile.path)
                } else {
                    config = .default
                    try config.write(to: AppPaths.configFile)
                    try? FileManager.default.setAttributes(
                        [.posixPermissions: 0o600], ofItemAtPath: AppPaths.configFile.path)
                }
            } catch {
                config = .default
                Diagnostics.write("Failed to load config; using defaults: \(error)")
            }
        }

        func reload() {
            do {
                config = try RecorderConfig.load(from: AppPaths.configFile)
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: AppPaths.configFile.path)
                Diagnostics.write("Configuration reloaded")
            } catch {
                Diagnostics.write("Configuration reload failed: \(error)")
            }
        }

        @discardableResult
        func save(_ newConfig: RecorderConfig) throws -> RecorderConfig {
            let validated = newConfig.validated()
            try validated.write(to: AppPaths.configFile)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: AppPaths.configFile.path)
            config = validated
            Diagnostics.write("Configuration saved from the dashboard")
            return validated
        }
    }

    enum Diagnostics {
        private static let ingress: BoundedDiagnosticsIngress = {
            let queue = DispatchQueue(
                label: "ai.goalong.localhistory.diagnostics",
                qos: .utility
            )
            let log = BoundedDiagnosticsLog(
                directoryURL: AppPaths.applicationSupportDirectory
            )
            let formatter = ISO8601DateFormatter()
            return BoundedDiagnosticsIngress(
                scheduler: { work in queue.async(execute: work) },
                sink: { timestamp, message in
                    let line = "[\(formatter.string(from: timestamp))] \(message)\n"
                    do {
                        try log.append(line)
                    } catch {
                        if let data = "Goalong History diagnostic failure: \(error)\n".data(using: .utf8) {
                            try? FileHandle.standardError.write(contentsOf: data)
                        }
                    }
                }
            )
        }()

        static func write(_ message: String) {
            ingress.submit(message, at: Date())
        }
    }
#endif
