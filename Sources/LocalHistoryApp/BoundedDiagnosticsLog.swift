#if os(macOS)
    import Darwin
    import Foundation

    struct BoundedDiagnosticsIngressSnapshot: Equatable {
        let capacity: Int
        let maximumPendingBytes: Int
        let maximumMessageBytes: Int
        let pendingCount: Int
        let pendingBytes: Int
        let maximumObservedCount: Int
        let maximumObservedBytes: Int
        let totalDroppedCount: Int
        let drainScheduled: Bool
        let scheduledDrainCount: Int
    }

    /// A fixed-size handoff in front of the filesystem logger. Producers retain at
    /// most one scheduled closure and a bounded ring, even if flock/fsync is slow.
    final class BoundedDiagnosticsIngress {
        typealias Scheduler = (@escaping () -> Void) -> Void
        typealias Sink = (Date, String) -> Void

        static let defaultCapacity = 128
        static let defaultMaximumPendingBytes = 128 * 1_024
        static let defaultMaximumMessageBytes = 2 * 1_024

        private struct Entry {
            let timestamp: Date
            let message: String
            let byteCount: Int
        }

        private let capacity: Int
        private let maximumPendingBytes: Int
        private let maximumMessageBytes: Int
        private let scheduler: Scheduler
        private let sink: Sink
        private let lock = NSLock()

        private var slots: [Entry?]
        private var head = 0
        private var count = 0
        private var pendingBytes = 0
        private var drainScheduled = false
        private var scheduledDrainCount = 0
        private var maximumObservedCount = 0
        private var maximumObservedBytes = 0
        private var totalDroppedCount = 0
        private var omittedCount = 0
        private var firstOmittedAt: Date?
        private var lastOmittedAt: Date?

        init(
            capacity: Int = BoundedDiagnosticsIngress.defaultCapacity,
            maximumPendingBytes: Int = BoundedDiagnosticsIngress.defaultMaximumPendingBytes,
            maximumMessageBytes: Int = BoundedDiagnosticsIngress.defaultMaximumMessageBytes,
            scheduler: @escaping Scheduler,
            sink: @escaping Sink
        ) {
            precondition(capacity > 0)
            precondition(maximumPendingBytes >= maximumMessageBytes)
            precondition(maximumMessageBytes >= 128)
            self.capacity = capacity
            self.maximumPendingBytes = maximumPendingBytes
            self.maximumMessageBytes = maximumMessageBytes
            self.scheduler = scheduler
            self.sink = sink
            slots = [Entry?](repeating: nil, count: capacity)
        }

        func submit(_ message: String, at timestamp: Date = Date()) {
            let boundedMessage = Self.boundedMessage(
                message,
                maximumBytes: maximumMessageBytes
            )
            let byteCount = boundedMessage.utf8.count
            var shouldSchedule = false

            lock.lock()
            if omittedCount > 0
                || count >= capacity
                || pendingBytes > maximumPendingBytes - byteCount
            {
                totalDroppedCount += 1
                omittedCount += 1
                firstOmittedAt = firstOmittedAt ?? timestamp
                lastOmittedAt = timestamp
            } else {
                let insertionIndex = (head + count) % capacity
                slots[insertionIndex] = Entry(
                    timestamp: timestamp,
                    message: boundedMessage,
                    byteCount: byteCount
                )
                count += 1
                pendingBytes += byteCount
                maximumObservedCount = max(maximumObservedCount, count)
                maximumObservedBytes = max(maximumObservedBytes, pendingBytes)
            }
            if !drainScheduled {
                drainScheduled = true
                scheduledDrainCount += 1
                shouldSchedule = true
            }
            lock.unlock()

            if shouldSchedule {
                scheduler { [weak self] in self?.drain() }
            }
        }

        var snapshot: BoundedDiagnosticsIngressSnapshot {
            lock.lock()
            defer { lock.unlock() }
            return BoundedDiagnosticsIngressSnapshot(
                capacity: capacity,
                maximumPendingBytes: maximumPendingBytes,
                maximumMessageBytes: maximumMessageBytes,
                pendingCount: count,
                pendingBytes: pendingBytes,
                maximumObservedCount: maximumObservedCount,
                maximumObservedBytes: maximumObservedBytes,
                totalDroppedCount: totalDroppedCount,
                drainScheduled: drainScheduled,
                scheduledDrainCount: scheduledDrainCount
            )
        }

        private func drain() {
            while true {
                let output: (Date, String)?
                lock.lock()
                if count > 0, let entry = slots[head] {
                    slots[head] = nil
                    head = (head + 1) % capacity
                    count -= 1
                    pendingBytes -= entry.byteCount
                    output = (entry.timestamp, entry.message)
                } else if omittedCount > 0,
                    let firstOmittedAt,
                    let lastOmittedAt
                {
                    let count = omittedCount
                    omittedCount = 0
                    self.firstOmittedAt = nil
                    self.lastOmittedAt = nil
                    output = (
                        lastOmittedAt,
                        "[\(count) diagnostics omitted during overload; first_epoch=\(firstOmittedAt.timeIntervalSince1970); last_epoch=\(lastOmittedAt.timeIntervalSince1970)]"
                    )
                } else {
                    drainScheduled = false
                    output = nil
                }
                lock.unlock()

                guard let output else { return }
                autoreleasepool {
                    sink(output.0, output.1)
                }
            }
        }

        private static func boundedMessage(_ message: String, maximumBytes: Int) -> String {
            let probe = message.utf8.prefix(maximumBytes + 1)
            guard probe.count > maximumBytes else { return message }
            let marker = " [diagnostic message truncated]"
            let prefixLimit = max(0, maximumBytes - marker.utf8.count)
            var prefix = String(decoding: message.utf8.prefix(prefixLimit), as: UTF8.self)
            while prefix.utf8.count > prefixLimit, !prefix.isEmpty {
                prefix.removeLast()
            }
            return prefix + marker
        }
    }

    /// Keeps one active diagnostics segment and one backup, each capped independently.
    /// A directory lock serializes cooperating app processes while `threadLock` covers
    /// concurrent callers sharing an instance.
    enum BoundedDiagnosticsRotationCheckpoint: Equatable {
        case backupRenamed
        case directorySynchronized
        case activeLogTruncated
    }

    final class BoundedDiagnosticsLog {
        static let defaultMaximumFileBytes: Int64 = 1 * 1_024 * 1_024

        private static let logFileName = "diagnostics.log"
        private static let backupFileName = "diagnostics.log.1"
        private static let temporaryBackupFileName = ".diagnostics.log.rotation.tmp"
        private static let omittedTailMarker = Data("[older diagnostics omitted]\n".utf8)
        private static let truncatedEntryMarker = Data("\n[diagnostic entry truncated]\n".utf8)

        private let directoryURL: URL
        private let maximumFileBytes: Int64
        private let rotationObserver: ((BoundedDiagnosticsRotationCheckpoint) throws -> Void)?
        private let threadLock = NSLock()

        init(
            directoryURL: URL,
            maximumFileBytes: Int64 = BoundedDiagnosticsLog.defaultMaximumFileBytes,
            rotationObserver: ((BoundedDiagnosticsRotationCheckpoint) throws -> Void)? = nil
        ) {
            precondition(maximumFileBytes >= 128)
            self.directoryURL = directoryURL.standardizedFileURL
            self.maximumFileBytes = maximumFileBytes
            self.rotationObserver = rotationObserver
        }

        func append(_ text: String) throws {
            let entry = boundedEntryData(for: text)

            threadLock.lock()
            defer { threadLock.unlock() }

            let directoryDescriptor = try openSecureDirectory()
            defer { _ = Darwin.close(directoryDescriptor) }
            try acquireExclusiveLock(on: directoryDescriptor)
            defer { _ = flock(directoryDescriptor, LOCK_UN) }

            try normalizeBackupIfNeeded(in: directoryDescriptor)

            let logDescriptor = try openSecureRegularFile(
                named: Self.logFileName,
                in: directoryDescriptor,
                flags: O_RDWR | O_APPEND,
                createIfMissing: true
            )
            defer { _ = Darwin.close(logDescriptor) }

            let status = try regularFileStatus(
                descriptor: logDescriptor,
                name: Self.logFileName
            )
            let currentBytes = Int64(status.st_size)
            let entryBytes = Int64(entry.count)
            if currentBytes > maximumFileBytes
                || currentBytes > maximumFileBytes - entryBytes
            {
                try rotate(
                    logDescriptor: logDescriptor,
                    currentBytes: currentBytes,
                    directoryDescriptor: directoryDescriptor
                )
            }

            _ = try regularFileStatus(
                descriptor: logDescriptor,
                name: Self.logFileName
            )
            try writeAll(entry, to: logDescriptor, name: Self.logFileName)
            let finalStatus = try regularFileStatus(
                descriptor: logDescriptor,
                name: Self.logFileName
            )
            guard Int64(finalStatus.st_size) <= maximumFileBytes else {
                throw DiagnosticsLogError.fileExceededLimit(
                    directoryURL.appendingPathComponent(Self.logFileName),
                    maximumFileBytes
                )
            }
        }

        private func boundedEntryData(for text: String) -> Data {
            let probeLimit = Int(maximumFileBytes) + 1
            let data = Data(text.utf8.prefix(probeLimit))
            guard Int64(data.count) > maximumFileBytes else { return data }

            let marker = Self.truncatedEntryMarker
            let prefixLimit = Int(maximumFileBytes) - marker.count
            var prefix = Data(data.prefix(prefixLimit))
            while !prefix.isEmpty, String(data: prefix, encoding: .utf8) == nil {
                prefix.removeLast()
            }
            prefix.append(marker)
            return prefix
        }

        private func openSecureDirectory() throws -> Int32 {
            let parentURL = directoryURL.deletingLastPathComponent()
            let directoryName = directoryURL.lastPathComponent
            guard !directoryName.isEmpty, directoryName != ".", directoryName != ".." else {
                throw DiagnosticsLogError.unsafeDirectory(directoryURL)
            }

            let parentDescriptor = parentURL.path.withCString {
                Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            }
            guard parentDescriptor >= 0 else {
                throw posixError(operation: "open parent directory", at: parentURL)
            }
            defer { _ = Darwin.close(parentDescriptor) }

            var existingStatus = stat()
            let lookupResult = directoryName.withCString {
                Darwin.fstatat(parentDescriptor, $0, &existingStatus, AT_SYMLINK_NOFOLLOW)
            }
            if lookupResult == 0 {
                guard existingStatus.st_mode & S_IFMT == S_IFDIR else {
                    throw DiagnosticsLogError.unsafeDirectory(directoryURL)
                }
            } else if errno == ENOENT {
                let creationResult = directoryName.withCString {
                    Darwin.mkdirat(parentDescriptor, $0, mode_t(0o700))
                }
                guard creationResult == 0 || errno == EEXIST else {
                    throw posixError(operation: "create diagnostics directory", at: directoryURL)
                }
            } else {
                throw posixError(operation: "inspect diagnostics directory", at: directoryURL)
            }

            let directoryDescriptor = directoryName.withCString {
                Darwin.openat(
                    parentDescriptor,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                )
            }
            guard directoryDescriptor >= 0 else {
                throw DiagnosticsLogError.unsafeDirectory(directoryURL)
            }

            var openedStatus = stat()
            guard Darwin.fstat(directoryDescriptor, &openedStatus) == 0,
                openedStatus.st_mode & S_IFMT == S_IFDIR,
                Darwin.fchmod(directoryDescriptor, mode_t(0o700)) == 0,
                Darwin.fstat(directoryDescriptor, &openedStatus) == 0,
                openedStatus.st_mode & S_IFMT == S_IFDIR,
                openedStatus.st_mode & mode_t(0o777) == mode_t(0o700)
            else {
                _ = Darwin.close(directoryDescriptor)
                throw DiagnosticsLogError.unsafeDirectory(directoryURL)
            }
            return directoryDescriptor
        }

        private func openSecureRegularFile(
            named name: String,
            in directoryDescriptor: Int32,
            flags: Int32,
            createIfMissing: Bool
        ) throws -> Int32 {
            for _ in 0..<4 {
                var descriptor = name.withCString {
                    Darwin.openat(
                        directoryDescriptor,
                        $0,
                        flags | O_CLOEXEC | O_NOFOLLOW
                    )
                }
                if descriptor < 0, errno == ENOENT, createIfMissing {
                    descriptor = name.withCString {
                        Darwin.openat(
                            directoryDescriptor,
                            $0,
                            flags | O_CLOEXEC | O_NOFOLLOW | O_CREAT | O_EXCL,
                            mode_t(0o600)
                        )
                    }
                    if descriptor < 0, errno == EEXIST { continue }
                }
                guard descriptor >= 0 else {
                    throw DiagnosticsLogError.unsafeEntry(
                        directoryURL.appendingPathComponent(name)
                    )
                }

                do {
                    _ = try secureRegularFile(descriptor: descriptor, name: name)
                    return descriptor
                } catch {
                    _ = Darwin.close(descriptor)
                    throw error
                }
            }
            throw DiagnosticsLogError.unsafeEntry(directoryURL.appendingPathComponent(name))
        }

        private func secureExistingRegularFileIfPresent(
            named name: String,
            in directoryDescriptor: Int32
        ) throws {
            var status = stat()
            let result = name.withCString {
                Darwin.fstatat(directoryDescriptor, $0, &status, AT_SYMLINK_NOFOLLOW)
            }
            if result < 0, errno == ENOENT { return }
            guard result == 0, status.st_mode & S_IFMT == S_IFREG else {
                throw DiagnosticsLogError.unsafeEntry(
                    directoryURL.appendingPathComponent(name)
                )
            }

            let descriptor = try openSecureRegularFile(
                named: name,
                in: directoryDescriptor,
                flags: O_RDWR,
                createIfMissing: false
            )
            _ = Darwin.close(descriptor)
        }

        private func normalizeBackupIfNeeded(in directoryDescriptor: Int32) throws {
            var status = stat()
            let lookupResult = Self.backupFileName.withCString {
                Darwin.fstatat(directoryDescriptor, $0, &status, AT_SYMLINK_NOFOLLOW)
            }
            if lookupResult < 0, errno == ENOENT { return }
            guard lookupResult == 0, status.st_mode & S_IFMT == S_IFREG else {
                throw DiagnosticsLogError.unsafeEntry(
                    directoryURL.appendingPathComponent(Self.backupFileName)
                )
            }

            let descriptor = try openSecureRegularFile(
                named: Self.backupFileName,
                in: directoryDescriptor,
                flags: O_RDONLY,
                createIfMissing: false
            )
            defer { _ = Darwin.close(descriptor) }

            let openedStatus = try regularFileStatus(
                descriptor: descriptor,
                name: Self.backupFileName
            )
            guard Int64(openedStatus.st_size) > maximumFileBytes else { return }

            let backupData = try boundedTail(
                from: descriptor,
                currentBytes: Int64(openedStatus.st_size),
                name: Self.backupFileName
            )
            try installBackup(
                backupData,
                in: directoryDescriptor,
                reportRotationCheckpoints: false
            )
        }

        @discardableResult
        private func secureRegularFile(descriptor: Int32, name: String) throws -> stat {
            var status = try regularFileStatus(descriptor: descriptor, name: name)
            guard Darwin.fchmod(descriptor, mode_t(0o600)) == 0 else {
                throw posixError(
                    operation: "secure diagnostics file",
                    at: directoryURL.appendingPathComponent(name)
                )
            }
            status = try regularFileStatus(descriptor: descriptor, name: name)
            guard status.st_mode & mode_t(0o777) == mode_t(0o600) else {
                throw DiagnosticsLogError.unsafeEntry(
                    directoryURL.appendingPathComponent(name)
                )
            }
            return status
        }

        private func regularFileStatus(descriptor: Int32, name: String) throws -> stat {
            var status = stat()
            guard Darwin.fstat(descriptor, &status) == 0,
                status.st_mode & S_IFMT == S_IFREG,
                status.st_size >= 0,
                status.st_nlink == 1
            else {
                throw DiagnosticsLogError.unsafeEntry(
                    directoryURL.appendingPathComponent(name)
                )
            }
            return status
        }

        private func acquireExclusiveLock(on descriptor: Int32) throws {
            while flock(descriptor, LOCK_EX) != 0 {
                guard errno == EINTR else {
                    throw posixError(
                        operation: "lock diagnostics log",
                        at: directoryURL
                    )
                }
            }
        }

        private func rotate(
            logDescriptor: Int32,
            currentBytes: Int64,
            directoryDescriptor: Int32
        ) throws {
            let backupData = try boundedTail(
                from: logDescriptor,
                currentBytes: currentBytes,
                name: Self.logFileName
            )
            try installBackup(
                backupData,
                in: directoryDescriptor,
                reportRotationCheckpoints: true
            )
            _ = try regularFileStatus(
                descriptor: logDescriptor,
                name: Self.logFileName
            )
            guard Darwin.ftruncate(logDescriptor, 0) == 0 else {
                throw posixError(
                    operation: "truncate rotated diagnostics log",
                    at: directoryURL.appendingPathComponent(Self.logFileName)
                )
            }
            try rotationObserver?(.activeLogTruncated)
        }

        private func boundedTail(
            from descriptor: Int32,
            currentBytes: Int64,
            name: String
        ) throws -> Data {
            guard currentBytes > 0 else { return Data() }

            let wasTruncated = currentBytes > maximumFileBytes
            let payloadLimit =
                wasTruncated
                ? Int(maximumFileBytes) - Self.omittedTailMarker.count
                : Int(maximumFileBytes)
            let bytesToRead = min(currentBytes, Int64(payloadLimit))
            let startOffset = currentBytes - bytesToRead
            var data = Data(count: Int(bytesToRead))
            var totalRead = 0

            while totalRead < data.count {
                let remainingBytes = data.count - totalRead
                let bytesRead = data.withUnsafeMutableBytes { buffer -> Int in
                    guard let baseAddress = buffer.baseAddress else { return 0 }
                    return Darwin.pread(
                        descriptor,
                        baseAddress.advanced(by: totalRead),
                        remainingBytes,
                        off_t(startOffset + Int64(totalRead))
                    )
                }
                if bytesRead < 0, errno == EINTR { continue }
                guard bytesRead >= 0 else {
                    throw posixError(
                        operation: "read bounded diagnostics tail",
                        at: directoryURL.appendingPathComponent(name)
                    )
                }
                guard bytesRead > 0 else { break }
                totalRead += bytesRead
            }
            if totalRead < data.count {
                data.removeSubrange(totalRead..<data.count)
            }

            guard wasTruncated else { return data }
            while let firstByte = data.first, firstByte & 0xC0 == 0x80 {
                data.removeFirst()
            }
            var bounded = Self.omittedTailMarker
            bounded.append(data)
            return bounded
        }

        private func installBackup(
            _ data: Data,
            in directoryDescriptor: Int32,
            reportRotationCheckpoints: Bool
        ) throws {
            try removeStaleTemporaryBackupIfPresent(in: directoryDescriptor)
            let temporaryDescriptor = try openSecureRegularFile(
                named: Self.temporaryBackupFileName,
                in: directoryDescriptor,
                flags: O_RDWR,
                createIfMissing: true
            )
            var temporaryIsInstalled = false
            defer {
                _ = Darwin.close(temporaryDescriptor)
                if !temporaryIsInstalled {
                    _ = Self.temporaryBackupFileName.withCString {
                        Darwin.unlinkat(directoryDescriptor, $0, 0)
                    }
                }
            }

            _ = try regularFileStatus(
                descriptor: temporaryDescriptor,
                name: Self.temporaryBackupFileName
            )
            guard Darwin.ftruncate(temporaryDescriptor, 0) == 0 else {
                throw posixError(
                    operation: "truncate diagnostics backup",
                    at: directoryURL.appendingPathComponent(Self.temporaryBackupFileName)
                )
            }
            try writeAll(data, to: temporaryDescriptor, name: Self.temporaryBackupFileName)
            try synchronize(descriptor: temporaryDescriptor, name: Self.temporaryBackupFileName)

            _ = try regularFileStatus(
                descriptor: temporaryDescriptor,
                name: Self.temporaryBackupFileName
            )
            try secureExistingRegularFileIfPresent(
                named: Self.backupFileName,
                in: directoryDescriptor
            )

            let renameResult = Self.temporaryBackupFileName.withCString { temporaryName in
                Self.backupFileName.withCString { backupName in
                    Darwin.renameat(
                        directoryDescriptor,
                        temporaryName,
                        directoryDescriptor,
                        backupName
                    )
                }
            }
            guard renameResult == 0 else {
                throw posixError(
                    operation: "install diagnostics backup",
                    at: directoryURL.appendingPathComponent(Self.backupFileName)
                )
            }
            temporaryIsInstalled = true
            if reportRotationCheckpoints {
                try rotationObserver?(.backupRenamed)
            }
            try synchronizeDirectory(directoryDescriptor)
            if reportRotationCheckpoints {
                try rotationObserver?(.directorySynchronized)
            }
        }

        private func removeStaleTemporaryBackupIfPresent(
            in directoryDescriptor: Int32
        ) throws {
            var status = stat()
            let lookupResult = Self.temporaryBackupFileName.withCString {
                Darwin.fstatat(directoryDescriptor, $0, &status, AT_SYMLINK_NOFOLLOW)
            }
            if lookupResult < 0, errno == ENOENT { return }
            guard lookupResult == 0, status.st_mode & S_IFMT == S_IFREG else {
                throw DiagnosticsLogError.unsafeEntry(
                    directoryURL.appendingPathComponent(Self.temporaryBackupFileName)
                )
            }

            let descriptor = try openSecureRegularFile(
                named: Self.temporaryBackupFileName,
                in: directoryDescriptor,
                flags: O_RDWR,
                createIfMissing: false
            )
            _ = Darwin.close(descriptor)
            let removalResult = Self.temporaryBackupFileName.withCString {
                Darwin.unlinkat(directoryDescriptor, $0, 0)
            }
            guard removalResult == 0 else {
                throw posixError(
                    operation: "remove stale diagnostics backup",
                    at: directoryURL.appendingPathComponent(Self.temporaryBackupFileName)
                )
            }
        }

        private func writeAll(_ data: Data, to descriptor: Int32, name: String) throws {
            var totalWritten = 0
            while totalWritten < data.count {
                let bytesWritten = data.withUnsafeBytes { buffer -> Int in
                    guard let baseAddress = buffer.baseAddress else { return 0 }
                    return Darwin.write(
                        descriptor,
                        baseAddress.advanced(by: totalWritten),
                        data.count - totalWritten
                    )
                }
                if bytesWritten < 0, errno == EINTR { continue }
                guard bytesWritten > 0 else {
                    throw posixError(
                        operation: "write diagnostics file",
                        at: directoryURL.appendingPathComponent(name)
                    )
                }
                totalWritten += bytesWritten
            }
        }

        private func synchronize(descriptor: Int32, name: String) throws {
            while Darwin.fsync(descriptor) != 0 {
                guard errno == EINTR else {
                    throw posixError(
                        operation: "synchronize diagnostics file",
                        at: directoryURL.appendingPathComponent(name)
                    )
                }
            }
        }

        private func synchronizeDirectory(_ descriptor: Int32) throws {
            while Darwin.fsync(descriptor) != 0 {
                guard errno == EINTR else {
                    throw posixError(
                        operation: "synchronize diagnostics directory",
                        at: directoryURL
                    )
                }
            }
        }

        private func posixError(operation: String, at url: URL) -> NSError {
            let code = errno
            return NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(code),
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Could not \(operation) at \(url.path): \(String(cString: strerror(code)))"
                ]
            )
        }
    }

    private enum DiagnosticsLogError: LocalizedError {
        case unsafeDirectory(URL)
        case unsafeEntry(URL)
        case fileExceededLimit(URL, Int64)

        var errorDescription: String? {
            switch self {
            case .unsafeDirectory(let URL):
                return "Diagnostics directory is not a real private directory: \(URL.path)"
            case .unsafeEntry(let URL):
                return "Diagnostics path is not a private regular file: \(URL.path)"
            case .fileExceededLimit(let URL, let maximumBytes):
                return "Diagnostics file exceeded its \(maximumBytes)-byte limit: \(URL.path)"
            }
        }
    }
#endif
