#if os(macOS)
    import Darwin
    import Foundation

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
                guard let key = dayKey(URL), cutoffKey.map({ key >= $0 }) ?? true else {
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

        private static func posixError(
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

        var total: Int {
            activityAnalysisFiles + activityMemoryFiles + computerHistoryFiles
        }
    }

    /// A fully preflighted snapshot of all feature-owned derived deletion targets.
    /// Preparing this plan does not modify storage; execution revalidates it before
    /// unlinking anything.
    struct DerivedHistoryDeletionPlan {
        fileprivate let analysisPlans: [OwnedFileDeletionPlan]
        fileprivate let memoryPlans: [OwnedFileDeletionPlan]
        fileprivate let computerHistoryPlans: [OwnedFileDeletionPlan]

        var expectedResult: DerivedHistoryDeletionResult {
            DerivedHistoryDeletionResult(
                activityAnalysisFiles: analysisPlans.reduce(0) { $0 + $1.targets.count },
                activityMemoryFiles: memoryPlans.reduce(0) { $0 + $1.targets.count },
                computerHistoryFiles: computerHistoryPlans.reduce(0) { $0 + $1.targets.count }
            )
        }

        fileprivate var allPlans: [OwnedFileDeletionPlan] {
            analysisPlans + memoryPlans + computerHistoryPlans
        }

        fileprivate func validate() throws {
            try OwnedFileDeletionPlan.validate(allPlans)
        }

        func execute() throws -> DerivedHistoryDeletionResult {
            _ = try OwnedFileDeletionPlan.execute(allPlans)
            return expectedResult
        }
    }

    /// Implements the explicit clear-history contract for regenerable analysis and
    /// long-lived derived memories. It only unlinks exact, day-keyed files owned by these
    /// features and never traverses directories or follows symbolic links.
    final class DerivedHistoryCleaner {
        private let rootDirectory: URL
        private let computerHistoryStore: ComputerHistoryStore

        init(
            rootDirectory: URL = AppPaths.applicationSupportDirectory,
            codexMemoryDirectory: URL? = nil
        ) {
            self.rootDirectory = rootDirectory
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
            let analysisDirectory = rootDirectory.appendingPathComponent(
                "analysis",
                isDirectory: true
            )
            let memoryDirectory = rootDirectory.appendingPathComponent(
                "memories",
                isDirectory: true
            )
            let trustedAncestor = OwnedFileDeletionPlan.trustedAncestor(
                for: [analysisDirectory, memoryDirectory]
                    + computerHistoryStore.memoryDeletionDirectories
            )
            let analysisPlan = try deletionPlan(
                in: analysisDirectory,
                trustedAncestor: trustedAncestor,
                suffixes: [".analysis.json", ".agent.md"],
                cutoffKey: cutoffKey
            )
            let memoryPlan = try deletionPlan(
                in: memoryDirectory,
                trustedAncestor: trustedAncestor,
                suffixes: [".memory.json", ".memory.md"],
                cutoffKey: cutoffKey
            )
            let computerHistoryPlans = try computerHistoryStore.deletionPlans(
                since: cutoff,
                trustedAncestor: trustedAncestor
            )

            let analysisPlans = [analysisPlan].compactMap { $0 }
            let memoryPlans = [memoryPlan].compactMap { $0 }
            let plan = DerivedHistoryDeletionPlan(
                analysisPlans: analysisPlans,
                memoryPlans: memoryPlans,
                computerHistoryPlans: computerHistoryPlans
            )
            // Sequential category discovery is followed by one whole-plan validation,
            // immediately before the caller is permitted to begin deleting raw stores.
            try plan.validate()
            return plan
        }

        private func deletionPlan(
            in directory: URL,
            trustedAncestor: URL,
            suffixes: [String],
            cutoffKey: String?
        ) throws -> OwnedFileDeletionPlan? {
            try OwnedFileDeletionPlan.prepare(
                directory: directory,
                trustedAncestor: trustedAncestor,
                cutoffKey: cutoffKey,
                dayKey: { [self] URL in dayKey(URL, suffixes: suffixes) }
            )
        }

        private func dayKey(_ URL: URL, suffixes: [String]) -> String? {
            let name = URL.lastPathComponent
            guard let suffix = suffixes.first(where: name.hasSuffix) else { return nil }
            let rawDay = String(name.dropLast(suffix.count))
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
