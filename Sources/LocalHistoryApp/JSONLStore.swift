#if os(macOS)
    import Darwin
    import Foundation
    import LocalHistoryCore

    struct JSONLAppendOutcome {
        let didSynchronize: Bool
        let synchronizationError: Error?
    }

    struct JSONLStoreMetrics: Equatable {
        let appendedLineCount: Int
        let synchronizationCount: Int
    }

    struct JSONLDeletionMetrics: Equatable {
        var filesConsidered = 0
        var filesSkippedBeforeCutoff = 0
        var filesOpened = 0
        var filesUnchanged = 0
        var filesReplaced = 0
        var filesRemoved = 0
        var sourceBytesRead: Int64 = 0
        var rowsVisited = 0
        var rowsDeleted = 0
        var malformedRowsPreserved = 0
        var malformedRowsDiscarded = 0
        var oversizedRows = 0
        var oversizedRowsDiscarded = 0
        var peakBufferedBytes = 0
    }

    struct JSONLTargetedDeletionOutcome: Equatable {
        let eventCount: Int
        let semanticSnapshotIDs: Set<String>
    }

    final class JSONLStore {
        private enum DeletionRule {
            case since(Date)
            case exactEventIDs(Set<String>)

            var requiresExactClassification: Bool {
                if case .exactEventIDs = self { return true }
                return false
            }

            func matches(_ event: HistoryEvent) -> Bool {
                switch self {
                case .since(let cutoff):
                    return event.timestamp >= cutoff
                case .exactEventIDs(let IDs):
                    return IDs.contains(event.id)
                }
            }
        }

        private struct DirectoryHandle {
            let descriptor: Int32
            let status: stat
        }

        static let deletionReadChunkBytes = 64 * 1_024
        static let maximumEventLineBytes = 2 * 1_024 * 1_024
        static let deletionMemoryBoundBytes =
            deletionReadChunkBytes + maximumEventLineBytes
        static let maximumScavengedDeletionTemporaries = 64
        static let maximumScavengerEntriesInspected = 4_096

        private static let maximumSourceTimeZoneDistance: TimeInterval = 26 * 60 * 60
        private static let staleDeletionTemporaryAge: TimeInterval = 24 * 60 * 60
        private static let commitLockName = ".jsonl-commit.lock"

        private let queue = DispatchQueue(label: "ai.goalong.localhistory.jsonl-store")
        private let encoder: JSONEncoder
        private let decoder: JSONDecoder
        private let eventsDirectory: URL
        private let beforeDeletionCommit: (() -> Void)?
        private let beforeDeleteAllUnlink: ((URL) -> Void)?
        private let eventFilePermissionSetter: (Int32, mode_t) -> Int32

        private var currentFileURL: URL?
        private var currentHandle: FileHandle?
        private var writesSinceSync = 0
        private var appendedLineCount = 0
        private var synchronizationCount = 0
        private var requiresRestartRecovery = false
        private var latestDeletionMetrics = JSONLDeletionMetrics()

        /// `HistoryRetentionStore` is the only automatic purge authority. The
        /// legacy argument label remains source-compatible, but constructing the
        /// append store never interprets it as deletion permission.
        init(
            retentionDays _: Int,
            eventsDirectory: URL = AppPaths.eventsDirectory,
            prepareApplicationStorage: Bool = true,
            beforeDeletionCommit: (() -> Void)? = nil,
            scavengerNow: Date = Date(),
            beforeDeleteAllUnlink: ((URL) -> Void)? = nil,
            beforeScavengerUnlink: ((URL) -> Void)? = nil,
            eventFilePermissionSetter: @escaping (Int32, mode_t) -> Int32 = {
                Darwin.fchmod($0, $1)
            }
        ) throws {
            self.eventsDirectory = Self.normalizedDirectoryURL(eventsDirectory)
            self.beforeDeletionCommit = beforeDeletionCommit
            self.beforeDeleteAllUnlink = beforeDeleteAllUnlink
            self.eventFilePermissionSetter = eventFilePermissionSetter

            encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]

            decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601

            if prepareApplicationStorage {
                try AppPaths.prepare()
            }

            let directory = try Self.openVerifiedDirectory(at: self.eventsDirectory)
            defer { _ = Darwin.close(directory.descriptor) }
            try Self.withExclusiveCommitLock(
                in: directory.descriptor,
                directoryURL: self.eventsDirectory
            ) {
                try Self.requireCurrentDirectory(
                    directory,
                    at: self.eventsDirectory
                )
                try Self.scavengeStaleDeletionTemporaries(
                    in: directory,
                    directoryURL: self.eventsDirectory,
                    now: scavengerNow,
                    beforeUnlink: beforeScavengerUnlink
                )
            }
        }

        func append(_ event: HistoryEvent) {
            queue.async { [weak self] in
                guard let self else { return }
                do {
                    let outcome = try self.appendOnQueue(event)
                    if let error = outcome.synchronizationError {
                        Diagnostics.write("Failed to synchronize appended event: \(error)")
                    }
                } catch {
                    Diagnostics.write("Failed to append event: \(error)")
                }
            }
        }

        /// Appends one complete line and waits for the store queue. A thrown error means
        /// the caller must not advance its integrity cursor or publish the event to seals.
        /// A synchronization error is returned separately because the complete line was
        /// already written and must keep its sequence in the live chain.
        func appendAndWait(_ event: HistoryEvent) throws -> JSONLAppendOutcome {
            try queue.sync {
                try appendOnQueue(event)
            }
        }

        func flush() {
            do {
                try flushAndWait()
            } catch {
                Diagnostics.write("Failed to flush event journal: \(error)")
            }
        }

        func flushAndWait() throws {
            try queue.sync {
                try synchronizeCurrentHandle()
            }
        }

        func close() {
            do {
                try closeAndWait()
            } catch {
                Diagnostics.write("Failed to close event journal: \(error)")
            }
        }

        func closeAndWait() throws {
            try queue.sync {
                try closeCurrentHandle()
            }
        }

        var metrics: JSONLStoreMetrics {
            queue.sync {
                JSONLStoreMetrics(
                    appendedLineCount: appendedLineCount,
                    synchronizationCount: synchronizationCount
                )
            }
        }

        var deletionMetrics: JSONLDeletionMetrics {
            queue.sync { latestDeletionMetrics }
        }

        /// Reads only the bounded tail of each event file. This is used at startup to
        /// recover a state checkpoint that lagged a successfully appended event.
        func latestPersistedEvent() throws -> HistoryEvent? {
            try queue.sync {
                let directory = try Self.openVerifiedDirectory(at: eventsDirectory)
                defer { _ = Darwin.close(directory.descriptor) }
                return try Self.withSharedCommitLock(
                    in: directory.descriptor,
                    directoryURL: eventsDirectory
                ) {
                    try Self.requireCurrentDirectory(directory, at: eventsDirectory)
                    var latest: HistoryEvent?
                    for fileName in try Self.eventFileNames(in: directory.descriptor) {
                        guard
                            let candidate = try Self.lastDecodableEvent(
                                named: fileName,
                                in: directory.descriptor,
                                directoryURL: eventsDirectory,
                                decoder: decoder
                            )
                        else {
                            continue
                        }
                        guard let sequence = candidate.integrity?.sequence else { continue }
                        if latest?.integrity?.sequence ?? 0 < sequence {
                            latest = candidate
                        }
                    }
                    return latest
                }
            }
        }

        func deleteEvents(since cutoff: Date, completion: @escaping (Result<Int, Error>) -> Void) {
            queue.async { [weak self] in
                guard let self else { return }
                do {
                    try self.closeCurrentHandle()
                    let directory = try Self.openVerifiedDirectory(at: self.eventsDirectory)
                    defer { _ = Darwin.close(directory.descriptor) }
                    let deleted = try self.rewriteFilesKeepingEvents(
                        before: cutoff,
                        directory: directory
                    )
                    DispatchQueue.main.async { completion(.success(deleted)) }
                } catch {
                    DispatchQueue.main.async { completion(.failure(error)) }
                }
            }
        }

        /// Deletes only explicitly resolved source-event identifiers. The caller
        /// provides the source interval solely to bound which day journals are
        /// streamed; timestamps never broaden the deletion predicate.
        func deleteEvents(
            withIDs eventIDs: Set<String>,
            from start: Date,
            through end: Date,
            completion: @escaping (Result<JSONLTargetedDeletionOutcome, Error>) -> Void
        ) {
            queue.async { [weak self] in
                guard let self else { return }
                do {
                    guard !eventIDs.isEmpty else {
                        DispatchQueue.main.async {
                            completion(
                                .success(
                                    JSONLTargetedDeletionOutcome(
                                        eventCount: 0,
                                        semanticSnapshotIDs: []
                                    )
                                )
                            )
                        }
                        return
                    }
                    guard start <= end else {
                        throw JSONLStoreError.invalidTargetedDeletionInterval
                    }
                    guard eventIDs.count <= 32_768 else {
                        throw JSONLStoreError.targetedDeletionExceedsLimit(eventIDs.count, 32_768)
                    }
                    try self.closeCurrentHandle()
                    let directory = try Self.openVerifiedDirectory(at: self.eventsDirectory)
                    defer { _ = Darwin.close(directory.descriptor) }
                    let outcome = try self.rewriteFilesKeepingEvents(
                        withIDs: eventIDs,
                        from: start,
                        through: end,
                        directory: directory
                    )
                    DispatchQueue.main.async { completion(.success(outcome)) }
                } catch {
                    DispatchQueue.main.async { completion(.failure(error)) }
                }
            }
        }

        func deleteAll(completion: @escaping (Result<Int, Error>) -> Void) {
            queue.async { [weak self] in
                guard let self else { return }
                do {
                    try self.closeCurrentHandle()
                    let directory = try Self.openVerifiedDirectory(at: self.eventsDirectory)
                    defer { _ = Darwin.close(directory.descriptor) }
                    let deleted = try Self.deleteAllEventFiles(
                        in: directory,
                        directoryURL: self.eventsDirectory,
                        beforeUnlink: self.beforeDeleteAllUnlink
                    )
                    DispatchQueue.main.async { completion(.success(deleted)) }
                } catch {
                    DispatchQueue.main.async { completion(.failure(error)) }
                }
            }
        }

        private func appendOnQueue(_ event: HistoryEvent) throws -> JSONLAppendOutcome {
            guard !requiresRestartRecovery else {
                throw JSONLStoreError.writeOutcomeRequiresRestartRecovery
            }
            let destination = eventsDirectory.appendingPathComponent(
                AppPaths.localDayString(for: event.timestamp) + ".jsonl"
            )
            var data = try encoder.encode(event)
            data.append(0x0A)
            guard data.count <= Self.maximumEventLineBytes else {
                throw JSONLStoreError.eventRowExceedsMaximum(
                    destination,
                    data.count,
                    Self.maximumEventLineBytes
                )
            }
            let directory = try Self.openVerifiedDirectory(at: eventsDirectory)
            defer { _ = Darwin.close(directory.descriptor) }
            let shouldSynchronize = try Self.withExclusiveCommitLock(
                in: directory.descriptor,
                directoryURL: eventsDirectory
            ) {
                try Self.requireCurrentDirectory(directory, at: eventsDirectory)
                try ensureHandle(
                    for: destination,
                    named: destination.lastPathComponent,
                    in: directory.descriptor
                )
                guard let currentHandle else {
                    throw JSONLStoreError.missingEventHandle(destination)
                }

                do {
                    try currentHandle.write(contentsOf: data)
                } catch {
                    // A failed write may have left a partial row. Reopening on the next
                    // attempt inserts a newline separator before new data, preserving the
                    // corrupt fragment without letting it consume the following valid row.
                    try? currentHandle.close()
                    self.currentHandle = nil
                    currentFileURL = nil
                    writesSinceSync = 0
                    requiresRestartRecovery = true
                    throw error
                }

                appendedLineCount += 1
                writesSinceSync += 1
                return writesSinceSync >= 20
            }

            guard shouldSynchronize else {
                return JSONLAppendOutcome(didSynchronize: false, synchronizationError: nil)
            }

            do {
                try synchronizeCurrentHandle()
                return JSONLAppendOutcome(didSynchronize: true, synchronizationError: nil)
            } catch {
                // The full row has been accepted by write(2), so reusing its sequence
                // would create a duplicate. Keep retrying the durability barrier on each
                // subsequent append/flush and expose the error to the recorder.
                return JSONLAppendOutcome(didSynchronize: false, synchronizationError: error)
            }
        }

        private func ensureHandle(
            for url: URL,
            named fileName: String,
            in directoryDescriptor: Int32
        ) throws {
            if currentFileURL == url,
                let currentHandle,
                try Self.descriptorTargetsCurrentPath(
                    currentHandle.fileDescriptor,
                    named: fileName,
                    in: directoryDescriptor
                )
            {
                return
            }
            try closeCurrentHandle()

            let opened = try Self.openEventFileForAppend(
                named: fileName,
                in: directoryDescriptor,
                fileURL: url,
                permissionSetter: eventFilePermissionSetter
            )
            if opened.didCreate {
                try Self.synchronize(
                    descriptor: directoryDescriptor,
                    fileURL: eventsDirectory
                )
            }
            currentFileURL = url
            currentHandle = opened.handle
        }

        private func synchronizeCurrentHandle() throws {
            guard let handle = currentHandle, writesSinceSync > 0 else { return }
            try handle.synchronize()
            synchronizationCount += 1
            writesSinceSync = 0
        }

        private func closeCurrentHandle() throws {
            if let handle = currentHandle {
                do {
                    try synchronizeCurrentHandle()
                    try handle.close()
                } catch {
                    try? handle.close()
                    currentHandle = nil
                    currentFileURL = nil
                    throw error
                }
            }
            currentHandle = nil
            currentFileURL = nil
            writesSinceSync = 0
        }

        private static func deleteAllEventFiles(
            in directory: DirectoryHandle,
            directoryURL: URL,
            beforeUnlink: ((URL) -> Void)?
        ) throws -> Int {
            try withExclusiveCommitLock(
                in: directory.descriptor,
                directoryURL: directoryURL
            ) {
                try requireCurrentDirectory(directory, at: directoryURL)
                let fileNames = try eventFileNames(in: directory.descriptor)
                let snapshots = try fileNames.map { fileName in
                    try safeRegularStatus(
                        named: fileName,
                        in: directory.descriptor,
                        fileURL: directoryURL.appendingPathComponent(fileName)
                    )
                }

                for (fileName, snapshot) in zip(fileNames, snapshots) {
                    let fileURL = directoryURL.appendingPathComponent(fileName)
                    beforeUnlink?(fileURL)
                    try requireCurrentDirectory(directory, at: directoryURL)
                    let current = try safeRegularStatus(
                        named: fileName,
                        in: directory.descriptor,
                        fileURL: fileURL
                    )
                    guard sameSourceSnapshot(snapshot, current) else {
                        throw JSONLStoreError.sourceChangedDuringDeletion(fileURL)
                    }
                    let result = fileName.withCString {
                        Darwin.unlinkat(directory.descriptor, $0, 0)
                    }
                    guard result == 0 else {
                        throw JSONLStoreError.sourceChangedDuringDeletion(fileURL)
                    }
                }
                if !fileNames.isEmpty {
                    try synchronize(descriptor: directory.descriptor, fileURL: directoryURL)
                }
                return fileNames.count
            }
        }

        private static func eventFileNames(in directoryDescriptor: Int32) throws -> [String] {
            var fileNames: [String] = []
            for fileName in try directoryEntryNames(in: directoryDescriptor) {
                guard isKnownEventFileName(fileName),
                    let status = try? entryStatus(
                        named: fileName,
                        in: directoryDescriptor
                    )
                else {
                    continue
                }
                guard (status.st_mode & S_IFMT) == S_IFREG else {
                    // Preserve legacy symlinks and non-regular entries without ever
                    // following or mutating them.
                    continue
                }
                guard status.st_nlink == 1 else {
                    throw JSONLStoreError.unsafeEventFile(
                        URL(fileURLWithPath: fileName)
                    )
                }
                fileNames.append(fileName)
            }
            return fileNames.sorted()
        }

        private func rewriteFilesKeepingEvents(
            before cutoff: Date,
            directory: DirectoryHandle
        ) throws -> Int {
            var metrics = JSONLDeletionMetrics()
            var semanticSnapshotIDs = Set<String>()
            defer { latestDeletionMetrics = metrics }
            let earliestPotentialFileDay = AppPaths.localDayString(
                for: cutoff.addingTimeInterval(-Self.maximumSourceTimeZoneDistance)
            )

            for fileName in try Self.eventFileNames(in: directory.descriptor) {
                metrics.filesConsidered += 1
                let fileDay = String(fileName.prefix(10))
                guard fileDay >= earliestPotentialFileDay else {
                    metrics.filesSkippedBeforeCutoff += 1
                    continue
                }
                try rewriteFileKeepingEvents(
                    named: fileName,
                    rule: .since(cutoff),
                    directory: directory,
                    metrics: &metrics,
                    semanticSnapshotIDs: &semanticSnapshotIDs
                )
            }

            return metrics.rowsDeleted
        }

        private func rewriteFilesKeepingEvents(
            withIDs eventIDs: Set<String>,
            from start: Date,
            through end: Date,
            directory: DirectoryHandle
        ) throws -> JSONLTargetedDeletionOutcome {
            var metrics = JSONLDeletionMetrics()
            defer { latestDeletionMetrics = metrics }
            let earliestPotentialFileDay = AppPaths.localDayString(
                for: start.addingTimeInterval(-Self.maximumSourceTimeZoneDistance)
            )
            let latestPotentialFileDay = AppPaths.localDayString(
                for: end.addingTimeInterval(Self.maximumSourceTimeZoneDistance)
            )
            var semanticSnapshotIDs = Set<String>()
            let fileNames = try Self.eventFileNames(in: directory.descriptor)
            let candidateFileNames = fileNames.filter { fileName in
                let fileDay = String(fileName.prefix(10))
                return fileDay >= earliestPotentialFileDay
                    && fileDay <= latestPotentialFileDay
            }
            metrics.filesConsidered = fileNames.count
            let preflight = try preflightTargetedEventFiles(
                candidateFileNames,
                eventIDs: eventIDs,
                directory: directory
            )
            metrics.sourceBytesRead += preflight.bytesRead
            metrics.rowsVisited += preflight.rowsVisited
            metrics.peakBufferedBytes = max(
                metrics.peakBufferedBytes,
                preflight.peakBufferedBytes
            )

            for fileName in preflight.matchingFileNames.sorted() {
                try rewriteFileKeepingEvents(
                    named: fileName,
                    rule: .exactEventIDs(eventIDs),
                    directory: directory,
                    metrics: &metrics,
                    semanticSnapshotIDs: &semanticSnapshotIDs
                )
            }

            return JSONLTargetedDeletionOutcome(
                eventCount: metrics.rowsDeleted,
                semanticSnapshotIDs: semanticSnapshotIDs
            )
        }

        private func preflightTargetedEventFiles(
            _ fileNames: [String],
            eventIDs: Set<String>,
            directory: DirectoryHandle
        ) throws -> (
            matchingFileNames: Set<String>,
            bytesRead: Int64,
            rowsVisited: Int,
            peakBufferedBytes: Int
        ) {
            let reader = HistoryJSONLinesStreamReader(
                chunkSize: Self.deletionReadChunkBytes,
                maximumLineBytes: Self.maximumEventLineBytes
            )
            var foundIDs = Set<String>()
            var matchingFileNames = Set<String>()
            var bytesRead: Int64 = 0
            var rowsVisited = 0
            var peakBufferedBytes = 0

            for fileName in fileNames {
                let fileURL = eventsDirectory.appendingPathComponent(fileName)
                var classificationFailed = false
                let readMetrics = try reader.read(
                    file: fileURL,
                    directoryDescriptor: directory.descriptor,
                    relativeName: fileName,
                    onLine: { raw, _ in
                        guard let event = try? decoder.decode(HistoryEvent.self, from: raw) else {
                            classificationFailed = true
                            return
                        }
                        if eventIDs.contains(event.id) {
                            foundIDs.insert(event.id)
                            matchingFileNames.insert(fileName)
                        }
                    },
                    onOversizedLine: { _, _ in
                        classificationFailed = true
                    }
                )
                guard !classificationFailed,
                    !readMetrics.sourceChangedDuringRead
                else {
                    throw JSONLStoreError.unclassifiableTargetedDeletionRow(fileURL)
                }
                bytesRead += readMetrics.bytesRead
                rowsVisited += readMetrics.rowsVisited
                peakBufferedBytes = max(
                    peakBufferedBytes,
                    readMetrics.peakBufferedBytes
                )
            }
            guard foundIDs == eventIDs else {
                throw JSONLStoreError.targetedEventsUnavailable(
                    eventIDs.count - foundIDs.count
                )
            }
            return (matchingFileNames, bytesRead, rowsVisited, peakBufferedBytes)
        }

        private func rewriteFileKeepingEvents(
            named fileName: String,
            rule: DeletionRule,
            directory: DirectoryHandle,
            metrics: inout JSONLDeletionMetrics,
            semanticSnapshotIDs: inout Set<String>
        ) throws {
            let sourceDescriptor = fileName.withCString {
                Darwin.openat(
                    directory.descriptor,
                    $0,
                    O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW
                )
            }
            guard sourceDescriptor >= 0 else {
                throw JSONLStoreError.sourceUnavailableDuringDeletion(
                    eventsDirectory.appendingPathComponent(fileName)
                )
            }
            defer { _ = Darwin.close(sourceDescriptor) }

            var initialStatus = stat()
            guard Darwin.fstat(sourceDescriptor, &initialStatus) == 0,
                (initialStatus.st_mode & S_IFMT) == S_IFREG,
                initialStatus.st_nlink == 1,
                initialStatus.st_size >= 0
            else {
                throw JSONLStoreError.unsafeEventFile(
                    eventsDirectory.appendingPathComponent(fileName)
                )
            }
            metrics.filesOpened += 1

            let temporaryName = ".\(fileName).delete-\(UUID().uuidString).tmp"
            let temporaryDescriptor = temporaryName.withCString {
                Darwin.openat(
                    directory.descriptor,
                    $0,
                    O_WRONLY | O_CLOEXEC | O_NOFOLLOW | O_CREAT | O_EXCL,
                    mode_t(0o600)
                )
            }
            guard temporaryDescriptor >= 0 else {
                throw JSONLStoreError.couldNotCreateDeletionTemporaryFile(
                    eventsDirectory.appendingPathComponent(temporaryName)
                )
            }
            var initialTemporaryStatus = stat()
            guard flock(temporaryDescriptor, LOCK_EX | LOCK_NB) == 0,
                Darwin.fstat(temporaryDescriptor, &initialTemporaryStatus) == 0,
                Self.isSafeRegularFile(initialTemporaryStatus),
                try Self.descriptorTargetsCurrentPath(
                    temporaryDescriptor,
                    named: temporaryName,
                    in: directory.descriptor
                )
            else {
                _ = Darwin.close(temporaryDescriptor)
                throw JSONLStoreError.couldNotSecureDeletionTemporaryFile(
                    eventsDirectory.appendingPathComponent(temporaryName)
                )
            }
            var temporaryInstalled = false
            defer {
                if !temporaryInstalled {
                    try? Self.removeDeletionTemporaryIfStillOwned(
                        named: temporaryName,
                        descriptor: temporaryDescriptor,
                        in: directory,
                        directoryURL: eventsDirectory
                    )
                }
                _ = Darwin.close(temporaryDescriptor)
            }

            var fileDeletedRows = 0
            var outputBytes: Int64 = 0
            var lineBuffer = Data()
            var readBuffer = [UInt8](repeating: 0, count: Self.deletionReadChunkBytes)
            var offset: Int64 = 0
            var discardingOversizedLine = false

            func notePeakBuffer() {
                metrics.peakBufferedBytes = max(
                    metrics.peakBufferedBytes,
                    lineBuffer.count + readBuffer.count
                )
            }

            func writeBufferedLine(hasNewline: Bool) throws {
                metrics.rowsVisited += 1
                if let event = try? decoder.decode(HistoryEvent.self, from: lineBuffer) {
                    if rule.matches(event) {
                        metrics.rowsDeleted += 1
                        fileDeletedRows += 1
                        if case .exactEventIDs = rule,
                            let snapshotID = event.semanticContext?.snapshotID
                        {
                            semanticSnapshotIDs.insert(snapshotID)
                        }
                    } else {
                        try Self.writeAll(
                            lineBuffer,
                            to: temporaryDescriptor,
                            fileURL: eventsDirectory.appendingPathComponent(temporaryName)
                        )
                        outputBytes += Int64(lineBuffer.count)
                        if hasNewline {
                            try Self.writeNewline(
                                to: temporaryDescriptor,
                                fileURL: eventsDirectory.appendingPathComponent(temporaryName)
                            )
                            outputBytes += 1
                        }
                    }
                } else {
                    guard !rule.requiresExactClassification else {
                        throw JSONLStoreError.unclassifiableTargetedDeletionRow(
                            eventsDirectory.appendingPathComponent(fileName)
                        )
                    }
                    // An explicit privacy deletion cannot safely classify an
                    // undecodable row by timestamp. Discard it instead of preserving
                    // details that may have been captured after the cutoff.
                    metrics.rowsDeleted += 1
                    metrics.malformedRowsDiscarded += 1
                    fileDeletedRows += 1
                }
                lineBuffer.removeAll(keepingCapacity: true)
            }

            func finishDiscardingOversizedLine() throws {
                metrics.rowsVisited += 1
                guard !rule.requiresExactClassification else {
                    throw JSONLStoreError.unclassifiableTargetedDeletionRow(
                        eventsDirectory.appendingPathComponent(fileName)
                    )
                }
                metrics.rowsDeleted += 1
                metrics.oversizedRows += 1
                metrics.oversizedRowsDiscarded += 1
                fileDeletedRows += 1
                discardingOversizedLine = false
                lineBuffer.removeAll(keepingCapacity: true)
            }

            while offset < Int64(initialStatus.st_size) {
                let requested = min(
                    readBuffer.count,
                    Int(Int64(initialStatus.st_size) - offset)
                )
                let bytesRead = readBuffer.withUnsafeMutableBytes { buffer -> Int in
                    guard let baseAddress = buffer.baseAddress else { return 0 }
                    return Darwin.pread(
                        sourceDescriptor,
                        baseAddress,
                        requested,
                        off_t(offset)
                    )
                }
                if bytesRead < 0, errno == EINTR { continue }
                guard bytesRead >= 0 else {
                    throw JSONLStoreError.couldNotReadEventFile(
                        eventsDirectory.appendingPathComponent(fileName)
                    )
                }
                guard bytesRead > 0 else { break }
                offset += Int64(bytesRead)
                metrics.sourceBytesRead += Int64(bytesRead)

                var cursor = 0
                while cursor < bytesRead {
                    let newlineIndex = readBuffer[cursor..<bytesRead].firstIndex(of: 0x0A)
                    let segmentEnd = newlineIndex ?? bytesRead
                    let segmentLength = segmentEnd - cursor
                    if !discardingOversizedLine,
                        lineBuffer.count + segmentLength > Self.maximumEventLineBytes
                    {
                        // The timestamp cannot be decoded within the strict memory bound.
                        // An explicit privacy deletion therefore discards the unknown row
                        // and continues at the next delimiter instead of retaining details
                        // that may be newer than the cutoff.
                        discardingOversizedLine = true
                        lineBuffer.removeAll(keepingCapacity: true)
                    } else if !discardingOversizedLine, segmentLength > 0 {
                        readBuffer.withUnsafeBytes { buffer in
                            guard let baseAddress = buffer.baseAddress else { return }
                            lineBuffer.append(
                                baseAddress.advanced(by: cursor).assumingMemoryBound(to: UInt8.self),
                                count: segmentLength
                            )
                        }
                        notePeakBuffer()
                    }
                    if let newlineIndex {
                        if discardingOversizedLine {
                            try finishDiscardingOversizedLine()
                        } else {
                            try writeBufferedLine(hasNewline: true)
                        }
                        cursor = newlineIndex + 1
                    } else {
                        cursor = bytesRead
                    }
                }
            }
            if discardingOversizedLine {
                try finishDiscardingOversizedLine()
            } else if !lineBuffer.isEmpty {
                try writeBufferedLine(hasNewline: false)
            }

            guard fileDeletedRows > 0 else {
                metrics.filesUnchanged += 1
                return
            }

            if outputBytes > 0 {
                guard Darwin.fchmod(temporaryDescriptor, mode_t(0o600)) == 0 else {
                    throw JSONLStoreError.couldNotSecureDeletionTemporaryFile(
                        eventsDirectory.appendingPathComponent(temporaryName)
                    )
                }
                try Self.synchronize(
                    descriptor: temporaryDescriptor,
                    fileURL: eventsDirectory.appendingPathComponent(temporaryName)
                )
                guard Darwin.fstat(temporaryDescriptor, &initialTemporaryStatus) == 0,
                    Self.isSafeRegularFile(initialTemporaryStatus)
                else {
                    throw JSONLStoreError.couldNotSecureDeletionTemporaryFile(
                        eventsDirectory.appendingPathComponent(temporaryName)
                    )
                }
            }

            try Self.withExclusiveCommitLock(
                in: directory.descriptor,
                directoryURL: eventsDirectory
            ) {
                beforeDeletionCommit?()
                try Self.requireCurrentDirectory(directory, at: eventsDirectory)
                try Self.requireUnchangedSource(
                    named: fileName,
                    in: directory.descriptor,
                    descriptor: sourceDescriptor,
                    initialStatus: initialStatus,
                    sourceURL: eventsDirectory.appendingPathComponent(fileName)
                )
                try Self.requireUnchangedSource(
                    named: temporaryName,
                    in: directory.descriptor,
                    descriptor: temporaryDescriptor,
                    initialStatus: initialTemporaryStatus,
                    sourceURL: eventsDirectory.appendingPathComponent(temporaryName)
                )

                if outputBytes == 0 {
                    let unlinkResult = fileName.withCString {
                        Darwin.unlinkat(directory.descriptor, $0, 0)
                    }
                    guard unlinkResult == 0 else {
                        throw JSONLStoreError.sourceChangedDuringDeletion(
                            eventsDirectory.appendingPathComponent(fileName)
                        )
                    }
                    metrics.filesRemoved += 1
                    let temporaryUnlinkResult = temporaryName.withCString {
                        Darwin.unlinkat(directory.descriptor, $0, 0)
                    }
                    guard temporaryUnlinkResult == 0 else {
                        throw JSONLStoreError.couldNotScavengeDeletionTemporary(
                            eventsDirectory.appendingPathComponent(temporaryName)
                        )
                    }
                    temporaryInstalled = true
                } else {
                    let renameResult = temporaryName.withCString { temporaryCString in
                        fileName.withCString { fileCString in
                            Darwin.renameat(
                                directory.descriptor,
                                temporaryCString,
                                directory.descriptor,
                                fileCString
                            )
                        }
                    }
                    guard renameResult == 0 else {
                        throw JSONLStoreError.sourceChangedDuringDeletion(
                            eventsDirectory.appendingPathComponent(fileName)
                        )
                    }
                    temporaryInstalled = true
                    metrics.filesReplaced += 1
                }
                try Self.synchronize(
                    descriptor: directory.descriptor,
                    fileURL: eventsDirectory
                )
            }
        }

        private static func requireUnchangedSource(
            named fileName: String,
            in directoryDescriptor: Int32,
            descriptor sourceDescriptor: Int32,
            initialStatus: stat,
            sourceURL: URL
        ) throws {
            var descriptorStatus = stat()
            var pathStatus = stat()
            let pathResult = fileName.withCString {
                Darwin.fstatat(
                    directoryDescriptor,
                    $0,
                    &pathStatus,
                    AT_SYMLINK_NOFOLLOW
                )
            }
            guard Darwin.fstat(sourceDescriptor, &descriptorStatus) == 0,
                pathResult == 0,
                sameSourceSnapshot(initialStatus, descriptorStatus),
                sameSourceSnapshot(initialStatus, pathStatus)
            else {
                throw JSONLStoreError.sourceChangedDuringDeletion(sourceURL)
            }
        }

        private static func sameSourceSnapshot(_ lhs: stat, _ rhs: stat) -> Bool {
            lhs.st_dev == rhs.st_dev
                && lhs.st_ino == rhs.st_ino
                && lhs.st_size == rhs.st_size
                && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
                && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
                && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
                && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
                && (rhs.st_mode & S_IFMT) == S_IFREG
                && lhs.st_nlink == 1
                && rhs.st_nlink == 1
        }

        private static func writeAll(
            _ data: Data,
            to descriptor: Int32,
            fileURL: URL
        ) throws {
            var written = 0
            try data.withUnsafeBytes { buffer in
                guard let baseAddress = buffer.baseAddress else { return }
                while written < data.count {
                    let result = Darwin.write(
                        descriptor,
                        baseAddress.advanced(by: written),
                        data.count - written
                    )
                    if result > 0 {
                        written += result
                    } else if result < 0, errno == EINTR {
                        continue
                    } else {
                        throw JSONLStoreError.couldNotWriteDeletionTemporaryFile(fileURL)
                    }
                }
            }
        }

        private static func writeNewline(to descriptor: Int32, fileURL: URL) throws {
            var newline: UInt8 = 0x0A
            while true {
                let result = Darwin.write(descriptor, &newline, 1)
                if result == 1 { return }
                if result < 0, errno == EINTR { continue }
                throw JSONLStoreError.couldNotWriteDeletionTemporaryFile(fileURL)
            }
        }

        private static func synchronize(descriptor: Int32, fileURL: URL) throws {
            while Darwin.fsync(descriptor) != 0 {
                if errno == EINTR { continue }
                throw JSONLStoreError.couldNotSynchronizeDeletion(fileURL)
            }
        }

        private static func openVerifiedDirectory(at directoryURL: URL) throws -> DirectoryHandle {
            let components = directoryURL.pathComponents
            guard directoryURL.isFileURL,
                components.first == "/",
                !components.contains("."),
                !components.contains("..")
            else {
                throw JSONLStoreError.unsafeEventsDirectory(directoryURL)
            }

            let flags = O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            var descriptor = Darwin.open("/", flags)
            guard descriptor >= 0 else {
                throw JSONLStoreError.unsafeEventsDirectory(directoryURL)
            }

            for component in components.dropFirst() where component != "/" {
                let nextDescriptor = component.withCString {
                    Darwin.openat(descriptor, $0, flags)
                }
                _ = Darwin.close(descriptor)
                guard nextDescriptor >= 0 else {
                    throw JSONLStoreError.unsafeEventsDirectory(directoryURL)
                }
                descriptor = nextDescriptor
            }

            var status = stat()
            guard Darwin.fstat(descriptor, &status) == 0,
                (status.st_mode & S_IFMT) == S_IFDIR
            else {
                _ = Darwin.close(descriptor)
                throw JSONLStoreError.unsafeEventsDirectory(directoryURL)
            }
            return DirectoryHandle(descriptor: descriptor, status: status)
        }

        private static func normalizedDirectoryURL(_ directoryURL: URL) -> URL {
            let path = directoryURL.path
            // macOS publishes these root aliases itself. Normalize only those fixed
            // system aliases; every caller-controlled descendant is still traversed
            // component-by-component with O_NOFOLLOW.
            for (alias, target) in [("/var", "/private/var"), ("/tmp", "/private/tmp")] {
                if path == alias {
                    return URL(fileURLWithPath: target, isDirectory: true)
                }
                if path.hasPrefix(alias + "/") {
                    return URL(
                        fileURLWithPath: target + String(path.dropFirst(alias.count)),
                        isDirectory: true
                    )
                }
            }
            return directoryURL
        }

        private static func requireCurrentDirectory(
            _ directory: DirectoryHandle,
            at directoryURL: URL
        ) throws {
            let current = try openVerifiedDirectory(at: directoryURL)
            defer { _ = Darwin.close(current.descriptor) }
            guard current.status.st_dev == directory.status.st_dev,
                current.status.st_ino == directory.status.st_ino
            else {
                throw JSONLStoreError.unsafeEventsDirectory(directoryURL)
            }
        }

        private static func withExclusiveCommitLock<T>(
            in directoryDescriptor: Int32,
            directoryURL: URL,
            _ body: () throws -> T
        ) throws -> T {
            try withCommitLock(
                operation: LOCK_EX,
                in: directoryDescriptor,
                directoryURL: directoryURL,
                body
            )
        }

        private static func withSharedCommitLock<T>(
            in directoryDescriptor: Int32,
            directoryURL: URL,
            _ body: () throws -> T
        ) throws -> T {
            try withCommitLock(
                operation: LOCK_SH,
                in: directoryDescriptor,
                directoryURL: directoryURL,
                body
            )
        }

        private static func withCommitLock<T>(
            operation: Int32,
            in directoryDescriptor: Int32,
            directoryURL: URL,
            _ body: () throws -> T
        ) throws -> T {
            let commonFlags = O_RDWR | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW
            let lockDescriptor = commitLockName.withCString {
                Darwin.openat(
                    directoryDescriptor,
                    $0,
                    commonFlags | O_CREAT,
                    mode_t(0o600)
                )
            }
            guard lockDescriptor >= 0 else {
                throw JSONLStoreError.unsafeCommitLock(directoryURL)
            }
            defer { _ = Darwin.close(lockDescriptor) }

            var lockStatus = stat()
            guard Darwin.fstat(lockDescriptor, &lockStatus) == 0,
                isSafeRegularFile(lockStatus)
            else {
                throw JSONLStoreError.unsafeCommitLock(directoryURL)
            }
            guard Darwin.fchmod(lockDescriptor, mode_t(0o600)) == 0,
                Darwin.fstat(lockDescriptor, &lockStatus) == 0,
                isSafeRegularFile(lockStatus),
                lockStatus.st_mode & mode_t(0o777) == mode_t(0o600)
            else {
                throw JSONLStoreError.unsafeCommitLock(directoryURL)
            }
            while flock(lockDescriptor, operation) != 0 {
                if errno == EINTR { continue }
                throw JSONLStoreError.couldNotLockEventsDirectory(directoryURL)
            }
            defer { _ = flock(lockDescriptor, LOCK_UN) }

            guard
                try descriptorTargetsCurrentPath(
                    lockDescriptor,
                    named: commitLockName,
                    in: directoryDescriptor
                )
            else {
                throw JSONLStoreError.unsafeCommitLock(directoryURL)
            }
            return try body()
        }

        private static func directoryEntryNames(
            in directoryDescriptor: Int32,
            maximumCount: Int? = nil
        ) throws -> [String] {
            let duplicate = Darwin.dup(directoryDescriptor)
            guard duplicate >= 0 else {
                throw JSONLStoreError.couldNotListEventsDirectory
            }
            guard let directory = Darwin.fdopendir(duplicate) else {
                _ = Darwin.close(duplicate)
                throw JSONLStoreError.couldNotListEventsDirectory
            }
            defer { _ = Darwin.closedir(directory) }

            var names: [String] = []
            while maximumCount.map({ names.count < $0 }) ?? true {
                errno = 0
                guard let entry = Darwin.readdir(directory) else {
                    guard errno == 0 else {
                        throw JSONLStoreError.couldNotListEventsDirectory
                    }
                    break
                }
                let name = withUnsafePointer(to: entry.pointee.d_name) { pointer in
                    pointer.withMemoryRebound(
                        to: CChar.self,
                        capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)
                    ) {
                        String(cString: $0)
                    }
                }
                if name != ".", name != ".." {
                    names.append(name)
                }
            }
            return names
        }

        private static func entryStatus(
            named fileName: String,
            in directoryDescriptor: Int32
        ) throws -> stat {
            var status = stat()
            let result = fileName.withCString {
                Darwin.fstatat(
                    directoryDescriptor,
                    $0,
                    &status,
                    AT_SYMLINK_NOFOLLOW
                )
            }
            guard result == 0 else {
                throw JSONLStoreError.sourceUnavailableDuringDeletion(
                    URL(fileURLWithPath: fileName)
                )
            }
            return status
        }

        private static func safeRegularStatus(
            named fileName: String,
            in directoryDescriptor: Int32,
            fileURL: URL
        ) throws -> stat {
            let status = try entryStatus(named: fileName, in: directoryDescriptor)
            guard isSafeRegularFile(status) else {
                throw JSONLStoreError.unsafeEventFile(fileURL)
            }
            return status
        }

        private static func isSafeRegularFile(_ status: stat) -> Bool {
            (status.st_mode & S_IFMT) == S_IFREG && status.st_nlink == 1
        }

        private static func descriptorTargetsCurrentPath(
            _ descriptor: Int32,
            named fileName: String,
            in directoryDescriptor: Int32
        ) throws -> Bool {
            var descriptorStatus = stat()
            guard Darwin.fstat(descriptor, &descriptorStatus) == 0,
                isSafeRegularFile(descriptorStatus)
            else {
                return false
            }
            guard
                let pathStatus = try? entryStatus(
                    named: fileName,
                    in: directoryDescriptor
                )
            else {
                return false
            }
            return isSafeRegularFile(pathStatus)
                && descriptorStatus.st_dev == pathStatus.st_dev
                && descriptorStatus.st_ino == pathStatus.st_ino
        }

        private static func scavengeStaleDeletionTemporaries(
            in directory: DirectoryHandle,
            directoryURL: URL,
            now: Date,
            beforeUnlink: ((URL) -> Void)?
        ) throws {
            let names = try directoryEntryNames(
                in: directory.descriptor,
                maximumCount: maximumScavengerEntriesInspected
            )
            var removed = 0
            for fileName in names where removed < maximumScavengedDeletionTemporaries {
                guard isDeletionTemporaryFileName(fileName) else {
                    continue
                }
                if try scavengeDeletionTemporaryIfStale(
                    named: fileName,
                    in: directory,
                    directoryURL: directoryURL,
                    now: now,
                    beforeUnlink: beforeUnlink
                ) {
                    removed += 1
                }
            }
            if removed > 0 {
                try synchronize(descriptor: directory.descriptor, fileURL: directoryURL)
            }
        }

        private static func scavengeDeletionTemporaryIfStale(
            named fileName: String,
            in directory: DirectoryHandle,
            directoryURL: URL,
            now: Date,
            beforeUnlink: ((URL) -> Void)?
        ) throws -> Bool {
            let fileURL = directoryURL.appendingPathComponent(fileName)
            let descriptor = fileName.withCString {
                Darwin.openat(
                    directory.descriptor,
                    $0,
                    O_RDWR | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW
                )
            }
            guard descriptor >= 0 else { return false }
            defer { _ = Darwin.close(descriptor) }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                if errno == EWOULDBLOCK || errno == EAGAIN { return false }
                throw JSONLStoreError.couldNotLockDeletionTemporary(fileURL)
            }
            defer { _ = flock(descriptor, LOCK_UN) }

            var status = stat()
            guard Darwin.fstat(descriptor, &status) == 0,
                isSafeRegularFile(status)
            else {
                return false
            }
            let modifiedAt =
                TimeInterval(status.st_mtimespec.tv_sec)
                + TimeInterval(status.st_mtimespec.tv_nsec) / 1_000_000_000
            let changedAt =
                TimeInterval(status.st_ctimespec.tv_sec)
                + TimeInterval(status.st_ctimespec.tv_nsec) / 1_000_000_000
            guard
                now.timeIntervalSince1970 - max(modifiedAt, changedAt)
                    >= staleDeletionTemporaryAge
            else {
                return false
            }
            beforeUnlink?(fileURL)
            try requireCurrentDirectory(directory, at: directoryURL)
            try requireUnchangedSource(
                named: fileName,
                in: directory.descriptor,
                descriptor: descriptor,
                initialStatus: status,
                sourceURL: fileURL
            )
            guard
                fileName.withCString({
                    Darwin.unlinkat(directory.descriptor, $0, 0)
                }) == 0
            else {
                throw JSONLStoreError.couldNotScavengeDeletionTemporary(fileURL)
            }
            return true
        }

        private static func removeDeletionTemporaryIfStillOwned(
            named fileName: String,
            descriptor: Int32,
            in directory: DirectoryHandle,
            directoryURL: URL
        ) throws {
            try withExclusiveCommitLock(
                in: directory.descriptor,
                directoryURL: directoryURL
            ) {
                try requireCurrentDirectory(directory, at: directoryURL)
                guard
                    try descriptorTargetsCurrentPath(
                        descriptor,
                        named: fileName,
                        in: directory.descriptor
                    )
                else {
                    return
                }
                guard
                    fileName.withCString({
                        Darwin.unlinkat(directory.descriptor, $0, 0)
                    }) == 0
                else {
                    throw JSONLStoreError.couldNotScavengeDeletionTemporary(
                        directoryURL.appendingPathComponent(fileName)
                    )
                }
                try synchronize(descriptor: directory.descriptor, fileURL: directoryURL)
            }
        }

        private static func isDeletionTemporaryFileName(_ fileName: String) -> Bool {
            guard fileName.first == ".", fileName.hasSuffix(".tmp") else { return false }
            let body = String(fileName.dropFirst().dropLast(4))
            let marker = ".jsonl.delete-"
            guard let markerRange = body.range(of: marker),
                markerRange.lowerBound == body.index(body.startIndex, offsetBy: 10)
            else {
                return false
            }
            let day = String(body[..<markerRange.lowerBound]) + ".jsonl"
            let identifier = String(body[markerRange.upperBound...])
            return isKnownEventFileName(day) && UUID(uuidString: identifier) != nil
        }

        private static func openEventFileForAppend(
            named fileName: String,
            in directoryDescriptor: Int32,
            fileURL: URL,
            permissionSetter: (Int32, mode_t) -> Int32
        ) throws -> (handle: FileHandle, didCreate: Bool) {
            let commonFlags = O_RDWR | O_APPEND | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW
            var didCreate = false
            var descriptor = fileName.withCString {
                Darwin.openat(directoryDescriptor, $0, commonFlags)
            }
            if descriptor < 0, errno == ENOENT {
                descriptor = fileName.withCString {
                    Darwin.openat(
                        directoryDescriptor,
                        $0,
                        commonFlags | O_CREAT | O_EXCL,
                        mode_t(0o600)
                    )
                }
                if descriptor >= 0 {
                    didCreate = true
                }
                if descriptor < 0, errno == EEXIST {
                    descriptor = fileName.withCString {
                        Darwin.openat(directoryDescriptor, $0, commonFlags)
                    }
                }
            }
            guard descriptor >= 0 else {
                throw JSONLStoreError.unsafeEventFile(fileURL)
            }

            var info = stat()
            guard fstat(descriptor, &info) == 0,
                isSafeRegularFile(info),
                try descriptorTargetsCurrentPath(
                    descriptor,
                    named: fileName,
                    in: directoryDescriptor
                )
            else {
                _ = Darwin.close(descriptor)
                throw JSONLStoreError.unsafeEventFile(fileURL)
            }
            guard permissionSetter(descriptor, mode_t(0o600)) == 0,
                Darwin.fstat(descriptor, &info) == 0,
                isSafeRegularFile(info),
                info.st_mode & mode_t(0o777) == mode_t(0o600),
                try descriptorTargetsCurrentPath(
                    descriptor,
                    named: fileName,
                    in: directoryDescriptor
                )
            else {
                _ = Darwin.close(descriptor)
                throw JSONLStoreError.unsafeEventFile(fileURL)
            }

            if info.st_size > 0 {
                var finalByte: UInt8 = 0
                let readCount = pread(descriptor, &finalByte, 1, info.st_size - 1)
                guard readCount == 1 else {
                    _ = Darwin.close(descriptor)
                    throw JSONLStoreError.couldNotInspectEventTail(fileURL)
                }
                if finalByte != 0x0A {
                    var newline: UInt8 = 0x0A
                    guard write(descriptor, &newline, 1) == 1 else {
                        _ = Darwin.close(descriptor)
                        throw JSONLStoreError.couldNotSeparateIncompleteEventTail(fileURL)
                    }
                    Diagnostics.write(
                        "Preserved an incomplete event-journal tail as its own malformed row before appending new events"
                    )
                }
            }
            return (
                FileHandle(fileDescriptor: descriptor, closeOnDealloc: true),
                didCreate
            )
        }

        private static func lastDecodableEvent(
            named fileName: String,
            in directoryDescriptor: Int32,
            directoryURL: URL,
            decoder: JSONDecoder,
            maximumTailBytes: Int = 8 * 1_024 * 1_024
        ) throws -> HistoryEvent? {
            let fileURL = directoryURL.appendingPathComponent(fileName)
            let descriptor = fileName.withCString {
                Darwin.openat(
                    directoryDescriptor,
                    $0,
                    O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW
                )
            }
            guard descriptor >= 0 else { throw JSONLStoreError.unsafeEventFile(fileURL) }
            defer { _ = Darwin.close(descriptor) }

            var info = stat()
            guard fstat(descriptor, &info) == 0,
                isSafeRegularFile(info),
                try descriptorTargetsCurrentPath(
                    descriptor,
                    named: fileName,
                    in: directoryDescriptor
                )
            else { throw JSONLStoreError.unsafeEventFile(fileURL) }
            guard info.st_size > 0 else { return nil }

            let byteCount = min(Int64(maximumTailBytes), Int64(info.st_size))
            let offset = Int64(info.st_size) - byteCount
            var data = Data(count: Int(byteCount))
            let bytesRead = data.withUnsafeMutableBytes { buffer -> Int in
                guard let baseAddress = buffer.baseAddress else { return 0 }
                return pread(descriptor, baseAddress, Int(byteCount), off_t(offset))
            }
            guard bytesRead >= 0 else {
                throw JSONLStoreError.couldNotInspectEventTail(fileURL)
            }
            if bytesRead < data.count { data.removeSubrange(bytesRead..<data.count) }

            let rows = data.split(separator: 0x0A, omittingEmptySubsequences: true)
            for (index, row) in rows.enumerated().reversed() {
                // A bounded tail can begin in the middle of a large row. Never accept
                // that leading fragment as recovery evidence.
                if offset > 0, index == 0 { continue }
                if let event = try? decoder.decode(HistoryEvent.self, from: Data(row)) {
                    return event
                }
            }
            return nil
        }

        private static func isKnownEventFileName(_ name: String) -> Bool {
            guard name.count == 16, name.hasSuffix(".jsonl") else { return false }
            return dayFormatter.date(from: String(name.prefix(10))) != nil
        }

        private enum JSONLStoreError: LocalizedError {
            case unsafeEventsDirectory(URL)
            case unsafeEventFile(URL)
            case missingEventHandle(URL)
            case couldNotInspectEventTail(URL)
            case couldNotSeparateIncompleteEventTail(URL)
            case eventRowExceedsMaximum(URL, Int, Int)
            case sourceUnavailableDuringDeletion(URL)
            case sourceChangedDuringDeletion(URL)
            case unsafeCommitLock(URL)
            case couldNotLockEventsDirectory(URL)
            case couldNotLockDeletionTemporary(URL)
            case couldNotListEventsDirectory
            case couldNotScavengeDeletionTemporary(URL)
            case couldNotCreateDeletionTemporaryFile(URL)
            case couldNotSecureDeletionTemporaryFile(URL)
            case couldNotReadEventFile(URL)
            case couldNotWriteDeletionTemporaryFile(URL)
            case couldNotSynchronizeDeletion(URL)
            case invalidTargetedDeletionInterval
            case targetedDeletionExceedsLimit(Int, Int)
            case unclassifiableTargetedDeletionRow(URL)
            case targetedEventsUnavailable(Int)
            case writeOutcomeRequiresRestartRecovery

            var errorDescription: String? {
                switch self {
                case .unsafeEventsDirectory(let url):
                    return "The events directory is unavailable or unsafe at \(url.path)."
                case .unsafeEventFile(let url):
                    return "Refusing to modify a linked or non-regular event file at \(url.path)."
                case .missingEventHandle(let url):
                    return "The event journal handle disappeared before writing \(url.path)."
                case .couldNotInspectEventTail(let url):
                    return "Could not inspect the event journal tail at \(url.path)."
                case .couldNotSeparateIncompleteEventTail(let url):
                    return "Could not isolate the incomplete event journal tail at \(url.path)."
                case .eventRowExceedsMaximum(let url, let actualBytes, let maximumBytes):
                    return
                        "Refusing a \(actualBytes)-byte event row at \(url.path); the bounded maximum is \(maximumBytes) bytes."
                case .sourceUnavailableDuringDeletion(let url):
                    return "The event source became unavailable while deleting details at \(url.path)."
                case .sourceChangedDuringDeletion(let url):
                    return
                        "The event source changed while deleting details; its original file was not replaced at \(url.path)."
                case .unsafeCommitLock(let url):
                    return "The event commit lock is unavailable or unsafe at \(url.path)."
                case .couldNotLockEventsDirectory(let url):
                    return "Could not lock the events directory at \(url.path)."
                case .couldNotLockDeletionTemporary(let url):
                    return "Could not lock the deletion temporary file at \(url.path)."
                case .couldNotListEventsDirectory:
                    return "Could not enumerate the pinned events directory."
                case .couldNotScavengeDeletionTemporary(let url):
                    return "Could not remove the stale deletion temporary file at \(url.path)."
                case .couldNotCreateDeletionTemporaryFile(let url):
                    return "Could not create the secure deletion temporary file at \(url.path)."
                case .couldNotSecureDeletionTemporaryFile(let url):
                    return "Could not secure the deletion temporary file at \(url.path)."
                case .couldNotReadEventFile(let url):
                    return "Could not stream the event file while deleting details at \(url.path)."
                case .couldNotWriteDeletionTemporaryFile(let url):
                    return "Could not write the bounded deletion temporary file at \(url.path)."
                case .couldNotSynchronizeDeletion(let url):
                    return "Could not durably synchronize deletion at \(url.path)."
                case .invalidTargetedDeletionInterval:
                    return "The targeted deletion interval is invalid."
                case .targetedDeletionExceedsLimit(let actual, let maximum):
                    return
                        "Refusing to retain \(actual) targeted event identifiers; the bounded maximum is \(maximum)."
                case .unclassifiableTargetedDeletionRow(let url):
                    return
                        "The selected event journal contains an undecodable row at \(url.path); no exact targeted deletion was committed."
                case .targetedEventsUnavailable(let missingCount):
                    return
                        "The current source is missing \(missingCount) selected event identifier(s); no exact targeted deletion was committed."
                case .writeOutcomeRequiresRestartRecovery:
                    return
                        "A previous event write had an unknown partial outcome; restart is required before appending another sequence."
                }
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
    }
#endif
