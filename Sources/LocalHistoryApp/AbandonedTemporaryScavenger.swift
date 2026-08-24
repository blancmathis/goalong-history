#if os(macOS)
    import Darwin
    import Foundation

    /// Removes only old, hidden atomic-write artifacts whose names are owned by Goalong.
    /// It never opens transcript/event bodies and never traverses user-source directories.
    struct AbandonedTemporaryScavenger {
        struct Limits: Equatable {
            static let production = Limits()

            var minimumAge: TimeInterval = 24 * 60 * 60
            var maximumDirectoryEntries = 4_096
            var maximumDeletedFiles = 128
            var maximumElapsedSeconds: TimeInterval = 0.10
            var maximumDiagnostics = 8

            fileprivate func validated() -> Limits {
                Limits(
                    minimumAge: max(24 * 60 * 60, minimumAge),
                    maximumDirectoryEntries: min(max(1, maximumDirectoryEntries), 20_000),
                    maximumDeletedFiles: min(max(1, maximumDeletedFiles), 512),
                    maximumElapsedSeconds: min(max(0.001, maximumElapsedSeconds), 1),
                    maximumDiagnostics: min(max(0, maximumDiagnostics), 32)
                )
            }
        }

        struct Report: Equatable {
            var deletedFiles = 0
            var deletedBytes: Int64 = 0
            var preservedYoungFiles = 0
            var preservedUnsafeFiles = 0
            var visitedEntries = 0
            var reachedEntryBudget = false
            var reachedDeletionBudget = false
            var reachedTimeBudget = false
            var diagnostics: [String] = []
        }

        private enum DirectoryKind {
            case analysis
            case memories
            case computerHistory
            case codexMemory
            case agentActivityMetadata
            case chatGPTHistory
            case chatGPTRecaps

            func owns(_ name: String) -> Bool {
                switch self {
                case .analysis:
                    return Self.atomicDestination(in: name).map {
                        $0 == "runtime-input-cache.json"
                            || Self.hasDayPrefix($0, suffix: ".analysis.json")
                            || Self.hasDayPrefix($0, suffix: ".agent.md")
                    } ?? false
                case .memories:
                    return Self.atomicDestination(in: name).map {
                        Self.hasDayPrefix($0, suffix: ".memory.json")
                            || Self.hasDayPrefix($0, suffix: ".memory.md")
                    } ?? false
                case .computerHistory:
                    return Self.atomicDestination(in: name).map {
                        Self.hasDayPrefix($0, suffix: ".computer-history.json")
                    } ?? false
                case .codexMemory:
                    return Self.atomicDestination(in: name).map {
                        Self.hasDayPrefix($0, suffix: "-goalong-computer-history.md")
                    } ?? false
                case .agentActivityMetadata:
                    for destination in ["configuration.json", "index.json"] {
                        let prefix = ".\(destination).migration-"
                        guard name.hasPrefix(prefix) else { continue }
                        let identifier = String(name.dropFirst(prefix.count))
                        return Self.isCanonicalUUID(identifier)
                    }
                    return false
                case .chatGPTHistory:
                    return Self.atomicDestination(in: name) == "normalized-conversations.json"
                case .chatGPTRecaps:
                    return Self.atomicDestination(in: name).map {
                        Self.hasDayPrefix($0, suffix: ".chatgpt-recap.json")
                            || Self.hasDayPrefix($0, suffix: ".chatgpt-recap.md")
                    } ?? false
                }
            }

            private static func atomicDestination(in name: String) -> String? {
                guard name.first == ".", name.hasSuffix(".tmp") else { return nil }
                let withoutDot = String(name.dropFirst())
                guard withoutDot.count > 41 else { return nil }
                let identifierStart = withoutDot.index(withoutDot.endIndex, offsetBy: -40)
                let separator = withoutDot.index(before: identifierStart)
                guard withoutDot[separator] == "." else { return nil }
                let identifier = String(
                    withoutDot[
                        identifierStart..<withoutDot.index(withoutDot.endIndex, offsetBy: -4)])
                guard isCanonicalUUID(identifier) else { return nil }
                return String(withoutDot[..<separator])
            }

            private static func isCanonicalUUID(_ value: String) -> Bool {
                value.utf8.count == 36 && UUID(uuidString: value) != nil
            }

            private static func hasDayPrefix(_ value: String, suffix: String) -> Bool {
                guard value.hasSuffix(suffix) else { return false }
                let day = String(value.dropLast(suffix.count))
                guard day.utf8.count == 10 else { return false }
                let bytes = Array(day.utf8)
                guard bytes[4] == 45, bytes[7] == 45,
                    bytes.enumerated().allSatisfy({ index, byte in
                        index == 4 || index == 7 || (48...57).contains(byte)
                    })
                else { return false }

                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = TimeZone(secondsFromGMT: 0)!
                let formatter = DateFormatter()
                formatter.calendar = calendar
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = calendar.timeZone
                formatter.dateFormat = "yyyy-MM-dd"
                formatter.isLenient = false
                guard let date = formatter.date(from: day) else { return false }
                return formatter.string(from: date) == day
            }
        }

        private struct DirectorySpec {
            let url: URL
            let kind: DirectoryKind
            let diagnosticName: String
        }

        private struct Identity: Equatable {
            let device: dev_t
            let inode: ino_t
        }

        private struct FileIdentity: Equatable {
            let directoryIdentity: Identity
            let device: dev_t
            let inode: ino_t
            let size: off_t
            let linkCount: nlink_t
            let modifiedSeconds: time_t
            let modifiedNanoseconds: Int
            let changedSeconds: time_t
            let changedNanoseconds: Int

            init(directoryIdentity: Identity, status: stat) {
                self.directoryIdentity = directoryIdentity
                device = status.st_dev
                inode = status.st_ino
                size = status.st_size
                linkCount = status.st_nlink
                modifiedSeconds = status.st_mtimespec.tv_sec
                modifiedNanoseconds = status.st_mtimespec.tv_nsec
                changedSeconds = status.st_ctimespec.tv_sec
                changedNanoseconds = status.st_ctimespec.tv_nsec
            }
        }

        private struct Candidate {
            let name: String
            let identity: FileIdentity
        }

        private let rootDirectory: URL
        private let codexMemoryDirectory: URL?
        private let limits: Limits
        private let monotonicClock: () -> TimeInterval
        private let beforeUnlink: ((URL) -> Void)?

        init(
            rootDirectory: URL,
            codexMemoryDirectory: URL? = nil,
            limits: Limits = .production,
            monotonicClock: @escaping () -> TimeInterval = {
                ProcessInfo.processInfo.systemUptime
            },
            beforeUnlink: ((URL) -> Void)? = nil
        ) {
            self.rootDirectory = rootDirectory.standardizedFileURL
            self.codexMemoryDirectory = codexMemoryDirectory?.standardizedFileURL
            self.limits = limits.validated()
            self.monotonicClock = monotonicClock
            self.beforeUnlink = beforeUnlink
        }

        func scavenge(now: Date = Date()) -> Report {
            let specifications = directorySpecifications()
            let startedAt = monotonicClock()
            var report = Report()

            for specification in specifications {
                guard !timeExpired(startedAt: startedAt, report: &report) else { break }
                guard
                    scan(
                        specification,
                        now: now,
                        startedAt: startedAt,
                        report: &report
                    )
                else { break }
            }
            return report
        }

        private func directorySpecifications() -> [DirectorySpec] {
            var result = [
                DirectorySpec(
                    url: rootDirectory.appendingPathComponent("analysis", isDirectory: true),
                    kind: .analysis,
                    diagnosticName: "analysis"
                ),
                DirectorySpec(
                    url: rootDirectory.appendingPathComponent("memories", isDirectory: true),
                    kind: .memories,
                    diagnosticName: "memories"
                ),
                DirectorySpec(
                    url: rootDirectory.appendingPathComponent("computer-history", isDirectory: true),
                    kind: .computerHistory,
                    diagnosticName: "computer-history"
                ),
                DirectorySpec(
                    url: rootDirectory.appendingPathComponent("agent-activity-v2", isDirectory: true),
                    kind: .agentActivityMetadata,
                    diagnosticName: "agent-activity-v2"
                ),
                DirectorySpec(
                    url: rootDirectory.appendingPathComponent("chatgpt/history", isDirectory: true),
                    kind: .chatGPTHistory,
                    diagnosticName: "ChatGPT history"
                ),
                DirectorySpec(
                    url: rootDirectory.appendingPathComponent("chatgpt/recaps", isDirectory: true),
                    kind: .chatGPTRecaps,
                    diagnosticName: "ChatGPT recaps"
                ),
            ]
            if let codexMemoryDirectory {
                result.append(
                    DirectorySpec(
                        url: codexMemoryDirectory,
                        kind: .codexMemory,
                        diagnosticName: "Codex memory mirror"
                    )
                )
            }
            return result
        }

        private func scan(
            _ specification: DirectorySpec,
            now: Date,
            startedAt: TimeInterval,
            report: inout Report
        ) -> Bool {
            var pathStatus = stat()
            guard lstat(specification.url.path, &pathStatus) == 0 else {
                if errno != ENOENT {
                    addDiagnostic("Could not inspect \(specification.diagnosticName); preserved it.", to: &report)
                }
                return true
            }
            guard Self.isDirectory(pathStatus) else {
                report.preservedUnsafeFiles += 1
                addDiagnostic("Refused unsafe \(specification.diagnosticName) directory.", to: &report)
                return true
            }

            let descriptor = specification.url.path.withCString {
                Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard descriptor >= 0 else {
                report.preservedUnsafeFiles += 1
                addDiagnostic("Could not open \(specification.diagnosticName) safely; preserved it.", to: &report)
                return true
            }
            defer { Darwin.close(descriptor) }

            var openedStatus = stat()
            guard Darwin.fstat(descriptor, &openedStatus) == 0,
                Self.isDirectory(openedStatus),
                Self.identity(pathStatus) == Self.identity(openedStatus)
            else {
                report.preservedUnsafeFiles += 1
                addDiagnostic("\(specification.diagnosticName) changed while opening; preserved it.", to: &report)
                return true
            }
            let directoryIdentity = Self.identity(openedStatus)

            let duplicate = Darwin.dup(descriptor)
            guard duplicate >= 0, let stream = Darwin.fdopendir(duplicate) else {
                if duplicate >= 0 { Darwin.close(duplicate) }
                addDiagnostic("Could not enumerate \(specification.diagnosticName); preserved it.", to: &report)
                return true
            }
            defer { Darwin.closedir(stream) }

            var candidates: [Candidate] = []
            var unsafeMatchCount = 0
            var incomplete = false
            while let entry = Darwin.readdir(stream) {
                if timeExpired(startedAt: startedAt, report: &report) {
                    incomplete = true
                    break
                }
                guard report.visitedEntries < limits.maximumDirectoryEntries else {
                    report.reachedEntryBudget = true
                    incomplete = true
                    break
                }
                report.visitedEntries += 1

                let name = Self.entryName(entry)
                guard name != ".", name != "..", specification.kind.owns(name) else { continue }

                var status = stat()
                let statusResult = name.withCString {
                    Darwin.fstatat(descriptor, $0, &status, AT_SYMLINK_NOFOLLOW)
                }
                guard statusResult == 0,
                    Self.isRegularFile(status),
                    status.st_dev == directoryIdentity.device,
                    status.st_nlink == 1
                else {
                    unsafeMatchCount += 1
                    continue
                }

                let lastMutation = max(
                    TimeInterval(status.st_mtimespec.tv_sec)
                        + TimeInterval(status.st_mtimespec.tv_nsec) / 1_000_000_000,
                    TimeInterval(status.st_ctimespec.tv_sec)
                        + TimeInterval(status.st_ctimespec.tv_nsec) / 1_000_000_000
                )
                guard now.timeIntervalSince1970 - lastMutation >= limits.minimumAge else {
                    report.preservedYoungFiles += 1
                    continue
                }
                guard report.deletedFiles + candidates.count < limits.maximumDeletedFiles else {
                    report.reachedDeletionBudget = true
                    continue
                }
                candidates.append(
                    Candidate(
                        name: name,
                        identity: FileIdentity(directoryIdentity: directoryIdentity, status: status)
                    )
                )
            }

            if incomplete { return false }
            if unsafeMatchCount > 0 {
                report.preservedUnsafeFiles += unsafeMatchCount + candidates.count
                addDiagnostic(
                    "Unsafe owned-looking file in \(specification.diagnosticName); preserved that directory.",
                    to: &report)
                return true
            }

            guard
                revalidateDirectory(
                    specification.url,
                    expected: directoryIdentity,
                    descriptor: descriptor
                ), candidates.allSatisfy({ revalidate($0, descriptor: descriptor) })
            else {
                report.preservedUnsafeFiles += candidates.count
                addDiagnostic("\(specification.diagnosticName) changed during cleanup; preserved it.", to: &report)
                return true
            }

            for candidate in candidates {
                guard !timeExpired(startedAt: startedAt, report: &report) else { return false }
                beforeUnlink?(specification.url.appendingPathComponent(candidate.name))
                guard
                    revalidateDirectory(
                        specification.url,
                        expected: directoryIdentity,
                        descriptor: descriptor
                    ), revalidate(candidate, descriptor: descriptor)
                else {
                    report.preservedUnsafeFiles += 1
                    addDiagnostic("\(specification.diagnosticName) changed before deletion; preserved it.", to: &report)
                    return true
                }
                guard candidate.name.withCString({ Darwin.unlinkat(descriptor, $0, 0) }) == 0 else {
                    report.preservedUnsafeFiles += 1
                    addDiagnostic(
                        "Could not remove an owned temporary in \(specification.diagnosticName).", to: &report)
                    return true
                }
                report.deletedFiles += 1
                report.deletedBytes += Int64(max(0, candidate.identity.size))
            }
            if !candidates.isEmpty { _ = Darwin.fsync(descriptor) }
            return true
        }

        private func timeExpired(startedAt: TimeInterval, report: inout Report) -> Bool {
            guard monotonicClock() - startedAt < limits.maximumElapsedSeconds else {
                report.reachedTimeBudget = true
                return true
            }
            return false
        }

        private func revalidateDirectory(
            _ url: URL,
            expected: Identity,
            descriptor: Int32
        ) -> Bool {
            var pathStatus = stat()
            var openedStatus = stat()
            return lstat(url.path, &pathStatus) == 0
                && Darwin.fstat(descriptor, &openedStatus) == 0
                && Self.isDirectory(pathStatus)
                && Self.isDirectory(openedStatus)
                && Self.identity(pathStatus) == expected
                && Self.identity(openedStatus) == expected
        }

        private func revalidate(_ candidate: Candidate, descriptor: Int32) -> Bool {
            var status = stat()
            let result = candidate.name.withCString {
                Darwin.fstatat(descriptor, $0, &status, AT_SYMLINK_NOFOLLOW)
            }
            return result == 0
                && Self.isRegularFile(status)
                && FileIdentity(
                    directoryIdentity: candidate.identity.directoryIdentity,
                    status: status
                ) == candidate.identity
        }

        private func addDiagnostic(_ message: String, to report: inout Report) {
            guard report.diagnostics.count < limits.maximumDiagnostics else { return }
            report.diagnostics.append(message)
        }

        private static func identity(_ status: stat) -> Identity {
            Identity(device: status.st_dev, inode: status.st_ino)
        }

        private static func isDirectory(_ status: stat) -> Bool {
            (status.st_mode & S_IFMT) == S_IFDIR
        }

        private static func isRegularFile(_ status: stat) -> Bool {
            (status.st_mode & S_IFMT) == S_IFREG
        }

        private static func entryName(_ entry: UnsafeMutablePointer<dirent>) -> String {
            withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
        }
    }

    /// Exact atomic writer used by derived stores that opt into abandoned-temp recovery.
    /// The parent must already exist and must remain the same regular directory until rename.
    enum GoalongOwnedAtomicFileWriter {
        static func write(_ data: Data, to destination: URL) throws {
            let directory = destination.deletingLastPathComponent()
            var pathStatus = stat()
            guard lstat(directory.path, &pathStatus) == 0,
                (pathStatus.st_mode & S_IFMT) == S_IFDIR
            else { throw POSIXError(.ENOTDIR) }
            let directoryIdentity = (pathStatus.st_dev, pathStatus.st_ino)
            let directoryDescriptor = directory.path.withCString {
                Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard directoryDescriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            defer { Darwin.close(directoryDescriptor) }

            var openedStatus = stat()
            guard Darwin.fstat(directoryDescriptor, &openedStatus) == 0,
                (openedStatus.st_mode & S_IFMT) == S_IFDIR,
                openedStatus.st_dev == directoryIdentity.0,
                openedStatus.st_ino == directoryIdentity.1
            else { throw POSIXError(.ESTALE) }

            let destinationName = destination.lastPathComponent
            var existingIdentity: (dev_t, ino_t)?
            var destinationStatus = stat()
            let destinationResult = destinationName.withCString {
                Darwin.fstatat(directoryDescriptor, $0, &destinationStatus, AT_SYMLINK_NOFOLLOW)
            }
            if destinationResult == 0 {
                guard (destinationStatus.st_mode & S_IFMT) == S_IFREG,
                    destinationStatus.st_nlink == 1,
                    destinationStatus.st_dev == openedStatus.st_dev
                else {
                    throw POSIXError(.ELOOP)
                }
                existingIdentity = (destinationStatus.st_dev, destinationStatus.st_ino)
            } else if errno != ENOENT {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }

            let temporaryName = ".\(destinationName).\(UUID().uuidString).tmp"
            let temporaryDescriptor = temporaryName.withCString {
                Darwin.openat(
                    directoryDescriptor,
                    $0,
                    O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                    mode_t(0o600)
                )
            }
            guard temporaryDescriptor >= 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            var removeTemporary = true
            defer {
                Darwin.close(temporaryDescriptor)
                if removeTemporary {
                    _ = temporaryName.withCString { Darwin.unlinkat(directoryDescriptor, $0, 0) }
                }
            }

            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let count = Darwin.write(
                        temporaryDescriptor,
                        bytes.baseAddress?.advanced(by: offset),
                        bytes.count - offset
                    )
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else {
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                    offset += count
                }
            }
            guard Darwin.fchmod(temporaryDescriptor, mode_t(0o600)) == 0,
                Darwin.fsync(temporaryDescriptor) == 0
            else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

            var currentDirectoryStatus = stat()
            guard lstat(directory.path, &currentDirectoryStatus) == 0,
                currentDirectoryStatus.st_dev == directoryIdentity.0,
                currentDirectoryStatus.st_ino == directoryIdentity.1
            else { throw POSIXError(.ESTALE) }

            var currentDestinationStatus = stat()
            let currentResult = destinationName.withCString {
                Darwin.fstatat(directoryDescriptor, $0, &currentDestinationStatus, AT_SYMLINK_NOFOLLOW)
            }
            if let existingIdentity {
                guard currentResult == 0,
                    currentDestinationStatus.st_dev == existingIdentity.0,
                    currentDestinationStatus.st_ino == existingIdentity.1
                else { throw POSIXError(.ESTALE) }
            } else if currentResult == 0 || errno != ENOENT {
                throw POSIXError(.ESTALE)
            }

            let renameResult = temporaryName.withCString { temporary in
                destinationName.withCString { final in
                    Darwin.renameat(directoryDescriptor, temporary, directoryDescriptor, final)
                }
            }
            guard renameResult == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            removeTemporary = false
            _ = Darwin.fsync(directoryDescriptor)
        }
    }
#endif
