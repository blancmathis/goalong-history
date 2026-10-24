#if os(macOS)
    import Darwin
    import Foundation
    import LocalHistoryCore
    import Security

    /// A no-follow deletion plan for exact, feature-owned regular files.
    ///
    /// Planning validates the directory itself with `lstat`, records its device/inode,
    /// then validates every matching child before any caller is allowed to unlink a file.
    /// Execution revalidates those identities and unlinks relative to an open directory
    /// descriptor, so replacing the directory path cannot redirect deletion elsewhere.
    struct OwnedFileDeletionPlan {
        struct DirectoryIdentity: Equatable {
            let device: dev_t
            let inode: ino_t

            init(_ status: stat) {
                device = status.st_dev
                inode = status.st_ino
            }
        }

        struct Target {
            let name: String
            let URL: URL
            let identity: DirectoryIdentity
        }

        struct ValidatedPathComponent {
            let name: String
            let URL: URL
            let identity: DirectoryIdentity
        }

        let trustedAncestor: URL
        let trustedAncestorIdentity: DirectoryIdentity
        let directory: URL
        let directoryIdentity: DirectoryIdentity
        let validatedPathComponents: [ValidatedPathComponent]
        let targets: [Target]

        /// Chooses a lexical ancestor shared by all managed roots, then steps one level
        /// upward so the common component itself is still validated. In production this
        /// normally trusts `/Users` and validates the user's home plus every descendant;
        /// tests and custom roots get the analogous nearest shared parent.
        static func trustedAncestor(for directories: [URL]) -> URL {
            let componentSets = directories.map { $0.standardizedFileURL.pathComponents }
            guard var common = componentSets.first else {
                return URL(fileURLWithPath: "/", isDirectory: true)
            }
            for components in componentSets.dropFirst() {
                let sharedCount = zip(common, components).prefix { $0 == $1 }.count
                common = Array(common.prefix(sharedCount))
            }

            guard common.count > 1 else {
                return URL(fileURLWithPath: "/", isDirectory: true)
            }
            let commonURL = URL(
                fileURLWithPath: NSString.path(withComponents: common),
                isDirectory: true
            )
            return commonURL.deletingLastPathComponent().standardizedFileURL
        }

        static func prepare(
            directory: URL,
            trustedAncestor: URL,
            cutoffKey: String?,
            matchingDayKeys: Set<String>? = nil,
            dayKey: (URL) -> String?
        ) throws -> OwnedFileDeletionPlan? {
            let normalizedDirectory = directory.standardizedFileURL
            let normalizedAncestor = trustedAncestor.standardizedFileURL
            guard let opened = try openDirectoryChain(
                directory: normalizedDirectory,
                trustedAncestor: normalizedAncestor
            ) else { return nil }
            defer { Darwin.close(opened.descriptor) }

            var targets: [Target] = []
            for name in try directoryEntries(descriptor: opened.descriptor).sorted() {
                let URL = normalizedDirectory.appendingPathComponent(name, isDirectory: false)
                guard let key = dayKey(URL),
                    cutoffKey.map({ key >= $0 }) ?? true,
                    matchingDayKeys.map({ $0.contains(key) }) ?? true
                else {
                    continue
                }
                var status = stat()
                let result = name.withCString {
                    Darwin.fstatat(opened.descriptor, $0, &status, AT_SYMLINK_NOFOLLOW)
                }
                guard result == 0,
                    isRegularFile(status),
                    status.st_dev == opened.directoryIdentity.device
                else {
                    throw SafetyError.unsafeOwnedPath(URL)
                }
                targets.append(
                    Target(
                        name: name,
                        URL: URL,
                        identity: DirectoryIdentity(status)
                    )
                )
            }

            let plan = OwnedFileDeletionPlan(
                trustedAncestor: normalizedAncestor,
                trustedAncestorIdentity: opened.trustedAncestorIdentity,
                directory: normalizedDirectory,
                directoryIdentity: opened.directoryIdentity,
                validatedPathComponents: opened.validatedPathComponents,
                targets: targets
            )
            // Enumeration is not trusted until the complete lexical path still resolves
            // through the exact no-follow directory chain captured above.
            try validatePath(plan)
            return plan
        }

        static func execute(_ plans: [OwnedFileDeletionPlan]) throws -> Int {
            // Revalidate every category and target before the first unlink. The caller
            // may hold a plan while other stores are cleared, so a later-category
            // mutation must fail before an earlier category is partially removed.
            try validate(plans)

            var deleted = 0
            for plan in plans {
                deleted += try execute(plan)
            }
            return deleted
        }

        static func validate(_ plans: [OwnedFileDeletionPlan]) throws {
            for plan in plans {
                try validate(plan)
            }
        }

        private static func execute(_ plan: OwnedFileDeletionPlan) throws -> Int {
            guard let opened = try openDirectoryChain(
                directory: plan.directory,
                trustedAncestor: plan.trustedAncestor,
                expectedTrustedAncestorIdentity: plan.trustedAncestorIdentity,
                expectedPathComponents: plan.validatedPathComponents
            ) else {
                throw SafetyError.directoryChanged(plan.directory)
            }
            defer { Darwin.close(opened.descriptor) }

            guard opened.directoryIdentity == plan.directoryIdentity else {
                throw SafetyError.directoryChanged(plan.directory)
            }
            var deleted = 0
            for target in plan.targets {
                // Revalidate the whole ancestor chain before every file. `unlinkat` then
                // remains confined to the descriptor opened for the validated directory.
                try validatePath(plan)
                try requireTargetIdentity(
                    target,
                    directoryIdentity: plan.directoryIdentity,
                    descriptor: opened.descriptor
                )
                guard target.name.withCString({ Darwin.unlinkat(opened.descriptor, $0, 0) }) == 0 else {
                    throw posixError(operation: "unlinkat", URL: target.URL)
                }
                deleted += 1
            }
            return deleted
        }

        private static func requireTargetIdentity(
            _ target: Target,
            directoryIdentity: DirectoryIdentity,
            descriptor: Int32
        ) throws {
            var status = stat()
            let result = target.name.withCString {
                Darwin.fstatat(descriptor, $0, &status, AT_SYMLINK_NOFOLLOW)
            }
            guard result == 0 else {
                throw SafetyError.ownedPathChanged(target.URL)
            }
            guard isRegularFile(status),
                status.st_dev == directoryIdentity.device,
                DirectoryIdentity(status) == target.identity
            else {
                throw SafetyError.ownedPathChanged(target.URL)
            }
        }

        private static func validatePath(_ plan: OwnedFileDeletionPlan) throws {
            guard let opened = try openDirectoryChain(
                directory: plan.directory,
                trustedAncestor: plan.trustedAncestor,
                expectedTrustedAncestorIdentity: plan.trustedAncestorIdentity,
                expectedPathComponents: plan.validatedPathComponents
            ) else {
                throw SafetyError.directoryChanged(plan.directory)
            }
            Darwin.close(opened.descriptor)
            guard opened.directoryIdentity == plan.directoryIdentity else {
                throw SafetyError.directoryChanged(plan.directory)
            }
        }

        private static func validate(_ plan: OwnedFileDeletionPlan) throws {
            guard let opened = try openDirectoryChain(
                directory: plan.directory,
                trustedAncestor: plan.trustedAncestor,
                expectedTrustedAncestorIdentity: plan.trustedAncestorIdentity,
                expectedPathComponents: plan.validatedPathComponents
            ) else {
                throw SafetyError.directoryChanged(plan.directory)
            }
            defer { Darwin.close(opened.descriptor) }

            guard opened.directoryIdentity == plan.directoryIdentity else {
                throw SafetyError.directoryChanged(plan.directory)
            }
            for target in plan.targets {
                try requireTargetIdentity(
                    target,
                    directoryIdentity: plan.directoryIdentity,
                    descriptor: opened.descriptor
                )
            }
        }

        private struct OpenedDirectory {
            let descriptor: Int32
            let trustedAncestorIdentity: DirectoryIdentity
            let directoryIdentity: DirectoryIdentity
            let validatedPathComponents: [ValidatedPathComponent]
        }

        private static func openDirectoryChain(
            directory: URL,
            trustedAncestor: URL,
            expectedTrustedAncestorIdentity: DirectoryIdentity? = nil,
            expectedPathComponents: [ValidatedPathComponent]? = nil
        ) throws -> OpenedDirectory? {
            let ancestorComponents = trustedAncestor.pathComponents
            let directoryComponents = directory.pathComponents
            guard directoryComponents.count >= ancestorComponents.count,
                Array(directoryComponents.prefix(ancestorComponents.count)) == ancestorComponents
            else {
                throw SafetyError.pathEscapesTrustedAncestor(directory, trustedAncestor)
            }

            guard let trustedStatus = try statusIfPresent(at: trustedAncestor) else { return nil }
            guard isDirectory(trustedStatus) else {
                throw SafetyError.unsafeDirectory(trustedAncestor)
            }
            let trustedIdentity = DirectoryIdentity(trustedStatus)
            if let expectedTrustedAncestorIdentity,
                trustedIdentity != expectedTrustedAncestorIdentity
            {
                throw SafetyError.directoryChanged(trustedAncestor)
            }

            var currentDescriptor = trustedAncestor.path.withCString {
                Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard currentDescriptor >= 0 else {
                throw posixError(operation: "open", URL: trustedAncestor)
            }

            var openedStatus = stat()
            guard Darwin.fstat(currentDescriptor, &openedStatus) == 0 else {
                let error = posixError(operation: "fstat", URL: trustedAncestor)
                Darwin.close(currentDescriptor)
                throw error
            }
            guard isDirectory(openedStatus), DirectoryIdentity(openedStatus) == trustedIdentity else {
                Darwin.close(currentDescriptor)
                throw SafetyError.directoryChanged(trustedAncestor)
            }

            let remainingNames = Array(directoryComponents.dropFirst(ancestorComponents.count))
            if let expectedPathComponents,
                expectedPathComponents.map(\.name) != remainingNames
            {
                Darwin.close(currentDescriptor)
                throw SafetyError.directoryChanged(directory)
            }

            var validated: [ValidatedPathComponent] = []
            var currentURL = trustedAncestor
            do {
                for (index, name) in remainingNames.enumerated() {
                    currentURL.appendPathComponent(name, isDirectory: true)
                    var status = stat()
                    let result = name.withCString {
                        Darwin.fstatat(currentDescriptor, $0, &status, AT_SYMLINK_NOFOLLOW)
                    }
                    if result != 0 {
                        let code = errno
                        if code == ENOENT, expectedPathComponents == nil {
                            Darwin.close(currentDescriptor)
                            return nil
                        }
                        throw SafetyError.directoryChanged(currentURL)
                    }
                    guard isDirectory(status) else {
                        throw SafetyError.unsafeDirectory(currentURL)
                    }
                    let identity = DirectoryIdentity(status)
                    if let expectedPathComponents,
                        expectedPathComponents[index].identity != identity
                    {
                        throw SafetyError.directoryChanged(currentURL)
                    }

                    let nextDescriptor = name.withCString {
                        Darwin.openat(
                            currentDescriptor,
                            $0,
                            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                        )
                    }
                    guard nextDescriptor >= 0 else {
                        throw SafetyError.directoryChanged(currentURL)
                    }
                    var nextStatus = stat()
                    guard Darwin.fstat(nextDescriptor, &nextStatus) == 0,
                        isDirectory(nextStatus),
                        DirectoryIdentity(nextStatus) == identity
                    else {
                        Darwin.close(nextDescriptor)
                        throw SafetyError.directoryChanged(currentURL)
                    }

                    validated.append(
                        ValidatedPathComponent(name: name, URL: currentURL, identity: identity)
                    )
                    Darwin.close(currentDescriptor)
                    currentDescriptor = nextDescriptor
                }

                let directoryIdentity = validated.last?.identity ?? trustedIdentity
                return OpenedDirectory(
                    descriptor: currentDescriptor,
                    trustedAncestorIdentity: trustedIdentity,
                    directoryIdentity: directoryIdentity,
                    validatedPathComponents: validated
                )
            } catch {
                Darwin.close(currentDescriptor)
                throw error
            }
        }

        private static func directoryEntries(descriptor: Int32) throws -> [String] {
            let duplicate = Darwin.dup(descriptor)
            guard duplicate >= 0 else {
                throw posixError(
                    operation: "dup",
                    URL: URL(fileURLWithPath: "/dev/fd/\(descriptor)")
                )
            }
            guard let stream = Darwin.fdopendir(duplicate) else {
                let error = posixError(
                    operation: "fdopendir",
                    URL: URL(fileURLWithPath: "/dev/fd/\(descriptor)")
                )
                Darwin.close(duplicate)
                throw error
            }
            defer { Darwin.closedir(stream) }

            var names: [String] = []
            while true {
                errno = 0
                guard let entry = Darwin.readdir(stream) else {
                    let code = errno
                    if code != 0 {
                        throw posixError(
                            operation: "readdir",
                            URL: URL(fileURLWithPath: "/dev/fd/\(descriptor)"),
                            code: code
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
                names.append(name)
            }
            return names
        }

        private static func statusIfPresent(at URL: URL) throws -> stat? {
            var status = stat()
            let result = URL.path.withCString { Darwin.lstat($0, &status) }
            guard result != 0 else { return status }
            let code = errno
            guard code == ENOENT else {
                throw posixError(operation: "lstat", URL: URL, code: code)
            }
            return nil
        }

        private static func isDirectory(_ status: stat) -> Bool {
            (status.st_mode & S_IFMT) == S_IFDIR
        }

        private static func isRegularFile(_ status: stat) -> Bool {
            (status.st_mode & S_IFMT) == S_IFREG
        }

        fileprivate static func posixError(
            operation: String,
            URL: URL,
            code: Int32 = errno
        ) -> NSError {
            NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(code),
                userInfo: [
                    NSFilePathErrorKey: URL.path,
                    NSLocalizedDescriptionKey: "\(operation) failed for \(URL.path): "
                        + String(cString: strerror(code)),
                ]
            )
        }

        enum SafetyError: LocalizedError {
            case unsafeDirectory(URL)
            case unsafeOwnedPath(URL)
            case directoryChanged(URL)
            case ownedPathChanged(URL)
            case pathEscapesTrustedAncestor(URL, URL)

            var errorDescription: String? {
                switch self {
                case let .unsafeDirectory(URL):
                    return "Refusing to use a non-directory or symbolic-link deletion root: \(URL.path)"
                case let .unsafeOwnedPath(URL):
                    return "Refusing to delete a non-regular or cross-device owned path: \(URL.path)"
                case let .directoryChanged(URL):
                    return "Deletion root changed after validation: \(URL.path)"
                case let .ownedPathChanged(URL):
                    return "Owned path changed after validation: \(URL.path)"
                case let .pathEscapesTrustedAncestor(URL, ancestor):
                    return "Deletion path \(URL.path) is outside trusted ancestor \(ancestor.path)"
                }
            }
        }
    }

    struct DerivedHistoryDeletionResult: Equatable {
        let activityAnalysisFiles: Int
        let activityMemoryFiles: Int
        let computerHistoryFiles: Int
        var activitySummaryFiles: Int = 0

        var total: Int {
            activityAnalysisFiles + activityMemoryFiles + computerHistoryFiles + activitySummaryFiles
        }
    }

    /// A fully preflighted snapshot of all feature-owned derived deletion targets.
    /// Preparing this plan does not modify storage; execution revalidates it before
    /// unlinking anything.
    struct DerivedHistoryDeletionPlan {
        fileprivate let analysisPlans: [OwnedFileDeletionPlan]
        fileprivate let memoryPlans: [OwnedFileDeletionPlan]
        fileprivate let computerHistoryPlans: [OwnedFileDeletionPlan]
        fileprivate var activitySummaryPlans: [OwnedFileDeletionPlan] = []
        /// Orphan `.activity-<UUID>` temporaries left by an interrupted summary write.
        /// Only planned on a full clear and never counted as user-visible deletions.
        fileprivate var activityTemporaryPlans: [OwnedFileDeletionPlan] = []
        fileprivate var clearSummaryDirectory = false
        /// Proof packages (`chatgpt/proofs/<executionID>/`) holding the canonical recap text,
        /// plus the proof chain head on a full clear. Never counted as user-visible deletions.
        fileprivate var proofPlans: [OwnedFileDeletionPlan] = []
        fileprivate var proofDirectoryPlans: [OwnedFileDeletionPlan] = []
        fileprivate var evidenceStore: AnalysisEvidenceCapsuleStore?
        fileprivate var evidenceExecutionIDs: [String] = []

        var expectedResult: DerivedHistoryDeletionResult {
            DerivedHistoryDeletionResult(
                activityAnalysisFiles: analysisPlans.reduce(0) { $0 + $1.targets.count },
                activityMemoryFiles: memoryPlans.reduce(0) { $0 + $1.targets.count },
                computerHistoryFiles: computerHistoryPlans.reduce(0) { $0 + $1.targets.count },
                activitySummaryFiles: activitySummaryPlans.reduce(0) { $0 + $1.targets.count }
            )
        }

        fileprivate var allPlans: [OwnedFileDeletionPlan] {
            analysisPlans + memoryPlans + computerHistoryPlans + activitySummaryPlans
                + activityTemporaryPlans + proofPlans
        }

        fileprivate func validate() throws {
            try OwnedFileDeletionPlan.validate(allPlans)
        }

        /// Raw events are already gone but the semantic clear failed: still remove the derived
        /// views so no derived data of the deleted period survives. Errors are only logged;
        /// the caller reports the semantic failure (a retry is idempotent).
        @discardableResult
        func executeAfterSemanticFailure() -> DerivedHistoryDeletionResult? {
            do {
                return try execute()
            } catch {
                Diagnostics.write(
                    "Derived history clear failed after a semantic clear failure: \(error)"
                )
                return nil
            }
        }

        func execute() throws -> DerivedHistoryDeletionResult {
            // Key-first cryptographic erasure of the encrypted response capsules, after the
            // whole plan is revalidated so an unsafe target still aborts before any deletion.
            // A keychain error never stops the run: every file is still deleted, then the first
            // error is thrown so the user learns that the erase is incomplete.
            var keychainError: Error?
            if let evidenceStore, !evidenceExecutionIDs.isEmpty {
                try OwnedFileDeletionPlan.validate(allPlans)
                for executionID in evidenceExecutionIDs {
                    do { try evidenceStore.destroy(executionID: executionID) } catch {
                        Diagnostics.write("Evidence key erase failed for \(executionID): \(error)")
                        if keychainError == nil { keychainError = error }
                    }
                }
            }
            _ = try OwnedFileDeletionPlan.execute(allPlans)
            for plan in proofDirectoryPlans { try Self.removeEmptyDirectory(plan) }
            if clearSummaryDirectory, let plan = activitySummaryPlans.first ?? activityTemporaryPlans.first {
                try Self.removeEmptyDirectory(plan)
            }
            if let keychainError { throw keychainError }
            return expectedResult
        }

        private static func removeEmptyDirectory(_ plan: OwnedFileDeletionPlan) throws {
            var status = stat()
            guard lstat(plan.directory.path, &status) == 0 else {
                if errno == ENOENT { return }
                throw OwnedFileDeletionPlan.posixError(operation: "lstat", URL: plan.directory)
            }
            guard OwnedFileDeletionPlan.DirectoryIdentity(status) == plan.directoryIdentity else {
                throw OwnedFileDeletionPlan.SafetyError.directoryChanged(plan.directory)
            }
            if rmdir(plan.directory.path) != 0 {
                let code = errno
                // Every planned file is already gone. A foreign entry (for example
                // .DS_Store) only keeps the empty folder; it never fails the clear.
                guard code == ENOTEMPTY || code == EEXIST else {
                    throw OwnedFileDeletionPlan.posixError(operation: "rmdir", URL: plan.directory, code: code)
                }
            }
        }
    }

    /// Implements the explicit clear-history contract for regenerable analysis and
    /// long-lived derived memories. It only unlinks exact, day-keyed files owned by these
    /// features and never traverses directories or follows symbolic links.
    final class DerivedHistoryCleaner {
        private let rootDirectory: URL
        private let computerHistoryStore: ComputerHistoryStore
        private let deleteEvidenceKeyItem: (CFDictionary) -> OSStatus

        init(
            rootDirectory: URL = AppPaths.applicationSupportDirectory,
            codexMemoryDirectory: URL? = nil,
            deleteEvidenceKeyItem: @escaping (CFDictionary) -> OSStatus = { SecItemDelete($0) }
        ) {
            self.rootDirectory = rootDirectory
            self.deleteEvidenceKeyItem = deleteEvidenceKeyItem
            computerHistoryStore = ComputerHistoryStore(
                rootDirectory: rootDirectory,
                codexMemoryDirectory: codexMemoryDirectory
            )
        }

        func delete(since cutoff: Date?) throws -> DerivedHistoryDeletionResult {
            try prepareDeletion(since: cutoff).execute()
        }

        /// Validates every derived deletion root and matching target without modifying
        /// storage. Clear-history orchestration must call this before deleting raw or
        /// semantic history so an unsafe derived target cannot cause a partial clear.
        func prepareDeletion(since cutoff: Date?) throws -> DerivedHistoryDeletionPlan {
            let cutoffKey = cutoff.map(dayString)
            return try prepareDeletion(cutoffKey: cutoffKey, matchingDayKeys: nil)
        }

        func prepareDeletion(days: Set<Date>) throws -> DerivedHistoryDeletionPlan {
            let dayKeys = Set(days.map(dayString))
            return try prepareDeletion(cutoffKey: nil, matchingDayKeys: dayKeys)
        }

        private func prepareDeletion(
            cutoffKey: String?,
            matchingDayKeys: Set<String>?
        ) throws -> DerivedHistoryDeletionPlan {
            let analysisDirectory = rootDirectory.appendingPathComponent(
                "analysis",
                isDirectory: true
            )
            let memoryDirectory = rootDirectory.appendingPathComponent(
                "memories",
                isDirectory: true
            )
            // ChatGPT recaps quote the day's activity: a history clear must erase them too.
            let chatGPTRecapsDirectory = rootDirectory
                .appendingPathComponent("chatgpt", isDirectory: true)
                .appendingPathComponent("recaps", isDirectory: true)
            // The proof of a recap keeps its canonical text (markdown, five lines, scores) and an
            // encrypted copy of the model response: a history clear erases them with the recap.
            let proofsDirectory = rootDirectory
                .appendingPathComponent("chatgpt", isDirectory: true)
                .appendingPathComponent("proofs", isDirectory: true)
            let evidenceDirectory = proofsDirectory
                .appendingPathComponent("private-evidence", isDirectory: true)
            let trustedAncestor = OwnedFileDeletionPlan.trustedAncestor(
                for: [analysisDirectory, memoryDirectory, chatGPTRecapsDirectory, proofsDirectory]
                    + computerHistoryStore.memoryDeletionDirectories
            )
            let analysisPlan = try deletionPlan(
                in: analysisDirectory,
                trustedAncestor: trustedAncestor,
                suffixes: [".analysis.json", ".agent.md"],
                cutoffKey: cutoffKey,
                matchingDayKeys: matchingDayKeys
            )
            let memoryPlan = try deletionPlan(
                in: memoryDirectory,
                trustedAncestor: trustedAncestor,
                suffixes: [".memory.json", ".memory.md"],
                cutoffKey: cutoffKey,
                matchingDayKeys: matchingDayKeys
            )
            let isFullClear = cutoffKey == nil && matchingDayKeys == nil
            let summaryDirectory = rootDirectory.appendingPathComponent("activity-days")
            let summaryPlan = try deletionPlan(
                in: summaryDirectory,
                trustedAncestor: trustedAncestor,
                suffixes: [".json", GoalongActivityCheckpointStore.suffix, GoalongActivityDayStore.purgeMarkerSuffix],
                cutoffKey: cutoffKey, matchingDayKeys: matchingDayKeys)
            // A targeted clear must not touch temporaries: a concurrent writer may own them.
            let summaryTemporaryPlan = isFullClear
                ? try OwnedFileDeletionPlan.prepare(
                    directory: summaryDirectory,
                    trustedAncestor: trustedAncestor,
                    cutoffKey: nil,
                    dayKey: { URL in Self.isActivityTemporaryName(URL.lastPathComponent) ? URL.lastPathComponent : nil })
                : nil
            let computerHistoryPlans = try computerHistoryStore.deletionPlans(
                cutoffKey: cutoffKey,
                matchingDayKeys: matchingDayKeys,
                trustedAncestor: trustedAncestor
            )

            let developerPlan = try deletionPlan(in: rootDirectory.appendingPathComponent("developer"),
                trustedAncestor: trustedAncestor, suffixes: [".jsonl"], cutoffKey: cutoffKey, matchingDayKeys: matchingDayKeys)
            let chatGPTRecapPlan = try deletionPlan(in: chatGPTRecapsDirectory,
                trustedAncestor: trustedAncestor, suffixes: [".chatgpt-recap.json", ".chatgpt-recap.md"],
                cutoffKey: cutoffKey, matchingDayKeys: matchingDayKeys)
            let analysisPlans = [analysisPlan, developerPlan, chatGPTRecapPlan].compactMap { $0 }
            // The day note is user-written content for a whole day, not activity of a
            // period: only a full history clear removes it. Calls and developer counts
            // have no per-record rewrite, so a partial clear erases their whole day file.
            let notesPlan = isFullClear
                ? try deletionPlan(in: rootDirectory.appendingPathComponent("notes"), trustedAncestor: trustedAncestor,
                    suffixes: [".json"], cutoffKey: nil, matchingDayKeys: nil)
                : nil
            let callsPlan = try deletionPlan(in: rootDirectory.appendingPathComponent("calls"), trustedAncestor: trustedAncestor,
                suffixes: [".jsonl"], cutoffKey: cutoffKey, matchingDayKeys: matchingDayKeys)
            let memoryPlans = [memoryPlan, notesPlan, callsPlan].compactMap { $0 }
            var plan = DerivedHistoryDeletionPlan(
                analysisPlans: analysisPlans,
                memoryPlans: memoryPlans,
                computerHistoryPlans: computerHistoryPlans,
                activitySummaryPlans: [summaryPlan].compactMap { $0 },
                activityTemporaryPlans: [summaryTemporaryPlan].compactMap { $0 },
                clearSummaryDirectory: isFullClear
            )
            // A partial clear may leave chain-head.json pointing at an erased run:
            // AnalysisProofStore.loadChainHead then returns nil and the next proof restarts the chain.
            var executionIDs = Set(
                (chatGPTRecapPlan?.targets ?? []).compactMap { recapExecutionID(at: $0.URL) }
            )
            var stagingNames: Set<String> = []
            if isFullClear {
                for name in Self.uuidNamedEntries(in: proofsDirectory) { executionIDs.insert(name) }
                for name in Self.uuidNamedEntries(in: evidenceDirectory, suffix: ".capsule") {
                    executionIDs.insert(name)
                }
                // Interrupted proof writes leave `.<uuid>.tmp` staging folders with the same files.
                for name in Self.stagingEntries(in: proofsDirectory) { stagingNames.insert(name) }
                plan.proofPlans = try deletionPlan(
                    in: proofsDirectory, trustedAncestor: trustedAncestor, suffixes: [],
                    cutoffKey: nil, matchingDayKeys: nil, nameKey: { $0 == "chain-head.json" ? $0 : nil }
                ).map { [$0] } ?? []
            } else {
                // Orphans: proofs no recap references any more (a regenerated recap replaced its proof,
                // the recap write failed, or a clear cancelled the run after its proof). They still hold
                // the day's recap text (result.json) and its encrypted response: erase them with their day.
                // The barrier is drained before this preflight, so no generation is writing them now.
                let earliestKey = cutoffKey ?? matchingDayKeys?.min()
                func isErased(_ date: (key: String, exact: Bool)) -> Bool {
                    // A day read from the package is exact. A modification date is the generation
                    // time, never before the analysed day: erase from the earliest erased day on.
                    guard date.exact else { return earliestKey.map { date.key >= $0 } ?? false }
                    return (cutoffKey.map { date.key >= $0 } ?? true)
                        && (matchingDayKeys.map { $0.contains(date.key) } ?? true)
                }
                let recapNames = (try? FileManager.default.contentsOfDirectory(atPath: chatGPTRecapsDirectory.path)) ?? []
                let referenced = Set(recapNames.compactMap {
                    recapExecutionID(at: chatGPTRecapsDirectory.appendingPathComponent($0))?.lowercased()
                })
                let packages = Self.uuidNamedEntries(in: proofsDirectory)
                for name in packages where !referenced.contains(name.lowercased())
                    && isErased(proofDate(in: proofsDirectory.appendingPathComponent(name, isDirectory: true)))
                {
                    executionIDs.insert(name)
                }
                for name in Self.stagingEntries(in: proofsDirectory)
                    where isErased(proofDate(in: proofsDirectory.appendingPathComponent(name, isDirectory: true)))
                {
                    stagingNames.insert(name)
                    executionIDs.insert(String(name.dropFirst().dropLast(4)))
                }
                // A capsule written before its package (the run stopped in between) has only its date.
                let packageIDs = Set(packages.map { $0.lowercased() })
                for name in Self.uuidNamedEntries(in: evidenceDirectory, suffix: ".capsule")
                    where !packageIDs.contains(name.lowercased()) && !referenced.contains(name.lowercased())
                {
                    let capsule = evidenceDirectory.appendingPathComponent(name + ".capsule")
                    if let key = modificationDayKey(of: capsule), isErased((key, false)) {
                        executionIDs.insert(name)
                    }
                }
            }
            for executionID in executionIDs.sorted() + stagingNames.sorted() {
                let directory = proofsDirectory.appendingPathComponent(executionID, isDirectory: true)
                let known: Set<String> = [
                    "definition.jws", "context-manifest.json", "provider-request.json",
                    "provider-response.json", "result.json", "device-public-key.x963",
                    "run.jws", "manifest.json",
                ]
                if let proof = try OwnedFileDeletionPlan.prepare(
                    directory: directory, trustedAncestor: trustedAncestor, cutoffKey: nil,
                    dayKey: { known.contains($0.lastPathComponent) ? $0.lastPathComponent : nil }
                ) {
                    plan.proofPlans.append(proof)
                    plan.proofDirectoryPlans.append(proof)
                }
            }
            plan.evidenceExecutionIDs = executionIDs.sorted()
            plan.evidenceStore = AnalysisEvidenceCapsuleStore(
                directory: evidenceDirectory, deleteKeyItem: deleteEvidenceKeyItem)
            // Sequential category discovery is followed by one whole-plan validation,
            // immediately before the caller is permitted to begin deleting raw stores.
            try plan.validate()
            return plan
        }

        /// Execution id of the proof a recap JSON references, only when it is a valid UUID.
        /// Bounded stable read; symbolic links and unreadable or foreign files yield nil.
        private func recapExecutionID(at URL: URL) -> String? {
            struct Reference: Decodable { struct Proof: Decodable { let executionID: String }; let proof: Proof? }
            guard URL.lastPathComponent.hasSuffix(".chatgpt-recap.json"),
                let data = try? ChatGPTHistoryStore.readStableSource(
                    at: URL, maximumBytes: Int64(ChatGPTRecapPersistence.maximumLegacyJSONBytes)),
                let id = (try? JSONDecoder().decode(Reference.self, from: data))?.proof?.executionID,
                UUID(uuidString: id) != nil
            else { return nil }
            return id
        }

        /// Day of a proof package: the `day` of its context manifest, else its folder's modification day.
        private func proofDate(in directory: URL) -> (key: String, exact: Bool) {
            struct Manifest: Decodable { let day: String }
            if let data = try? ChatGPTHistoryStore.readStableSource(
                at: directory.appendingPathComponent("context-manifest.json"), maximumBytes: 1_024 * 1_024),
                let day = (try? JSONDecoder().decode(Manifest.self, from: data))?.day,
                let key = validDayKey(day)
            {
                return (key, true)
            }
            // No folder date means nothing to read: the earliest possible key erases it with any clear.
            return (modificationDayKey(of: directory) ?? "0000-00-00", false)
        }

        /// Local day of the modification time of `URL` itself (symbolic links are not followed).
        private func modificationDayKey(of URL: URL) -> String? {
            var status = stat()
            guard lstat(URL.path, &status) == 0 else { return nil }
            return dayString(Date(timeIntervalSince1970: TimeInterval(status.st_mtimespec.tv_sec)))
        }

        /// Names in `directory` that are UUIDs (optionally followed by `suffix`). Names only.
        private static func uuidNamedEntries(in directory: URL, suffix: String = "") -> [String] {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            return names.compactMap { name in
                guard name.hasSuffix(suffix) else { return nil }
                let stem = String(name.dropLast(suffix.count))
                return UUID(uuidString: stem) != nil ? stem : nil
            }
        }

        /// `.<uuid>.tmp` folder names in `directory` (staging folders of `AnalysisProofStore`).
        private static func stagingEntries(in directory: URL) -> [String] {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            return names.filter { name in
                name.hasPrefix(".") && name.hasSuffix(".tmp")
                    && UUID(uuidString: String(name.dropFirst().dropLast(4))) != nil
            }
        }

        /// Exactly `GoalongActivityDayStore.temporaryPrefix` + an uppercase UUID.
        static func isActivityTemporaryName(_ name: String) -> Bool {
            let prefix = GoalongActivityDayStore.temporaryPrefix
            guard name.hasPrefix(prefix) else { return false }
            let rest = name.dropFirst(prefix.count)
            return rest.count == 36 && UUID(uuidString: String(rest))?.uuidString == String(rest)
        }

        private func deletionPlan(
            in directory: URL,
            trustedAncestor: URL,
            suffixes: [String],
            cutoffKey: String?,
            matchingDayKeys: Set<String>?,
            nameKey: ((String) -> String?)? = nil
        ) throws -> OwnedFileDeletionPlan? {
            try OwnedFileDeletionPlan.prepare(
                directory: directory,
                trustedAncestor: trustedAncestor,
                cutoffKey: cutoffKey,
                matchingDayKeys: matchingDayKeys,
                dayKey: { [self] URL in
                    if let nameKey { return nameKey(URL.lastPathComponent) }
                    return dayKey(URL, suffixes: suffixes)
                }
            )
        }

        private func dayKey(_ URL: URL, suffixes: [String]) -> String? {
            let name = URL.lastPathComponent
            guard let suffix = suffixes.first(where: name.hasSuffix) else { return nil }
            return validDayKey(String(name.dropLast(suffix.count)))
        }

        /// `rawDay` when it is a real local `yyyy-MM-dd` day, else nil.
        private func validDayKey(_ rawDay: String) -> String? {
            let fields = rawDay.split(separator: "-", omittingEmptySubsequences: false)
            guard fields.count == 3,
                fields[0].count == 4,
                fields[1].count == 2,
                fields[2].count == 2,
                fields.allSatisfy({ $0.allSatisfy(\.isNumber) }),
                let year = Int(fields[0]),
                let month = Int(fields[1]),
                let day = Int(fields[2])
            else { return nil }

            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .current
            guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)),
                dayString(date) == rawDay
            else { return nil }
            return rawDay
        }

        private func dayString(_ date: Date) -> String {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .current
            let components = calendar.dateComponents(
                [.year, .month, .day],
                from: calendar.startOfDay(for: date)
            )
            return String(
                format: "%04d-%02d-%02d",
                locale: Locale(identifier: "en_US_POSIX"),
                components.year ?? 0,
                components.month ?? 0,
                components.day ?? 0
            )
        }

    }
#endif
