#if os(macOS)
    import Carbon
    import Darwin
    import Foundation
    import LocalHistoryCore

    struct SemanticContextDeletionMetrics: Equatable {
        var bytesRead: Int64 = 0
        var rowsVisited = 0
        var peakBufferedBytes = 0
    }

    final class SemanticContextStore {
        static let deletionReadChunkBytes = 64 * 1_024
        static let maximumSemanticLineBytes = 2 * 1_024 * 1_024

        private let queue = DispatchQueue(
            label: "ai.goalong.localhistory.semantic-context",
            qos: .utility
        )
        private let semanticDirectory: URL
        private let secureInputEnabled: () -> Bool
        private var latestDeletionMetrics = SemanticContextDeletionMetrics()
        private var recentReferencesByIdentity: [String: SemanticContextReference] = [:]
        private var recentIdentityOrder: [String] = []
        private static let maximumRecentIdentities = 256

        init(
            semanticDirectory: URL = AppPaths.semanticDirectory,
            secureInputEnabled: @escaping () -> Bool = { IsSecureEventInputEnabled() }
        ) {
            self.semanticDirectory = semanticDirectory.standardizedFileURL
            self.secureInputEnabled = secureInputEnabled
        }

        var deletionMetrics: SemanticContextDeletionMetrics {
            queue.sync { latestDeletionMetrics }
        }

        func append(
            capture: AXRichContextCapture,
            context: ContextSnapshot,
            timestamp: Date = Date(),
            deduplicationScope: String? = nil,
            validateBeforeAppend: () -> Bool = { true }
        ) throws -> SemanticContextReference {
            let text = capture.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty,
                !secureInputEnabled(),
                context.suppressionReason == nil,
                context.focusedElement?.isSecure != true
            else {
                throw SemanticContextStoreError.suppressedOrEmpty
            }

            let resolvedSource = source(from: capture.source)
            let contentHash = SHA256Digest.hashHex(text)
            let identity = deduplicationScope.map {
                SHA256Digest.hashHex(
                    [
                        AppPaths.localDayString(for: timestamp),
                        $0,
                        context.fingerprint,
                        resolvedSource.rawValue,
                        contentHash,
                        String(capture.redacted),
                        String(capture.truncated),
                    ].joined(separator: "\u{0}")
                )
            }
            let file = semanticDirectory.appendingPathComponent(
                AppPaths.localDayString(for: timestamp) + ".semantic.jsonl"
            )

            return try queue.sync {
                guard validateBeforeAppend() else { throw SemanticContextStoreError.suppressedOrEmpty }
                if let identity,
                    let existing = recentReferencesByIdentity[identity]
                {
                    // The event still receives its own observation timestamp and is
                    // recorded normally; only the identical plaintext payload is
                    // interned within this concrete interaction.
                    return SemanticContextReference(
                        snapshotID: existing.snapshotID,
                        capturedAt: timestamp,
                        source: existing.source,
                        contentSHA256: existing.contentSHA256,
                        characterCount: existing.characterCount,
                        redacted: existing.redacted,
                        truncated: existing.truncated
                    )
                }
                let payload = SemanticContextPayload(
                    id: UUID().uuidString,
                    capturedAt: timestamp,
                    application: context.app,
                    window: context.window,
                    url: context.url,
                    focusedRole: context.focusedElement?.role,
                    source: resolvedSource,
                    text: text,
                    contentSHA256: contentHash,
                    redacted: capture.redacted,
                    truncated: capture.truncated
                )
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                var data = try encoder.encode(payload)
                data.append(0x0A)
                try AppPaths.prepare()
                if !FileManager.default.fileExists(atPath: file.path) {
                    FileManager.default.createFile(
                        atPath: file.path,
                        contents: nil,
                        attributes: [.posixPermissions: 0o600]
                    )
                }
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: file.path
                )
                let handle = try FileHandle(forUpdating: file)
                defer { try? handle.close() }
                let end = try handle.seekToEnd()
                guard validateBeforeAppend() else { throw SemanticContextStoreError.suppressedOrEmpty }
                let offset = try repairTornTail(of: handle, end: end)
                do {
                    try handle.write(contentsOf: data)
                } catch {
                    // A failed (for example disk-full) append leaves no fragment behind.
                    try? handle.truncate(atOffset: offset)
                    throw error
                }
                if let identity {
                    remember(payload.reference, identity: identity)
                }
                return payload.reference
            }
        }

        /// A crash or a full disk can leave the file without its final newline. A tail that
        /// decodes is a complete row and only gets its newline; an undecodable fragment is
        /// cut so the next row starts on its own line. Returns the offset of the next append.
        private func repairTornTail(of handle: FileHandle, end: UInt64) throws -> UInt64 {
            guard end > 0 else { return 0 }
            var last: UInt8 = 0
            guard Darwin.pread(handle.fileDescriptor, &last, 1, off_t(end - 1)) == 1 else {
                throw CocoaError(.fileReadUnknown)
            }
            guard last != 0x0A else { return end }
            let window = Int(min(end, UInt64(Self.maximumSemanticLineBytes + 1)))
            let start = end - UInt64(window)
            var tail = [UInt8](repeating: 0, count: window)
            var filled = 0
            while filled < window {
                let count = tail.withUnsafeMutableBytes {
                    Darwin.pread(
                        handle.fileDescriptor,
                        $0.baseAddress!.advanced(by: filled),
                        window - filled,
                        off_t(start) + off_t(filled)
                    )
                }
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw CocoaError(.fileReadUnknown) }
                filled += count
            }
            let fragmentStart: UInt64
            if let newline = tail.lastIndex(of: 0x0A) {
                fragmentStart = start + UInt64(newline + 1)
            } else if start == 0 {
                fragmentStart = 0
            } else {
                // The fragment is longer than any valid row: keep it apart, never decode it.
                try handle.write(contentsOf: Data([0x0A]))
                return end + 1
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let fragment = Data(tail[Int(fragmentStart - start)...])
            if (try? decoder.decode(SemanticContextPayload.self, from: fragment)) != nil {
                try handle.write(contentsOf: Data([0x0A]))
                return end + 1
            }
            try handle.truncate(atOffset: fragmentStart)
            try handle.seek(toOffset: fragmentStart)
            Diagnostics.write("Semantic append removed a torn \(end - fragmentStart)-byte tail.")
            return fragmentStart
        }

        func resetDeduplicationCache() {
            queue.sync {
                recentReferencesByIdentity.removeAll(keepingCapacity: false)
                recentIdentityOrder.removeAll(keepingCapacity: false)
            }
        }

        /// Deletes every payload captured at or after `cutoff`. Only day files from the
        /// day before the cutoff onward are read (one day of margin for a time-zone
        /// change), each file is streamed, and an unreadable row in those files is
        /// removed too: an explicit privacy clear never keeps plaintext it cannot classify.
        /// One failing file does not stop the others; the first error is reported at the end.
        func deleteEvents(
            since cutoff: Date,
            completion: @escaping (Result<Int, Error>) -> Void
        ) {
            queue.async {
                var deleted = 0
                var unreadable = 0
                var metrics = SemanticContextDeletionMetrics()
                var firstError: Error?
                do {
                    let firstKey = AppPaths.localDayString(for: cutoff.addingTimeInterval(-86_400))
                    for file in try self.semanticFiles()
                    where String(file.lastPathComponent.prefix(10)) >= firstKey {
                        do {
                            let outcome = try self.rewrite(
                                file: file,
                                metrics: &metrics,
                                deletingUnreadableRows: true,
                                shouldDelete: { $0.capturedAt >= cutoff }
                            )
                            deleted += outcome.deleted
                            unreadable += outcome.unreadable
                        } catch {
                            if firstError == nil { firstError = error }
                        }
                    }
                } catch {
                    firstError = error
                }
                self.recentReferencesByIdentity.removeAll(keepingCapacity: false)
                self.recentIdentityOrder.removeAll(keepingCapacity: false)
                self.latestDeletionMetrics = metrics
                if unreadable > 0 {
                    Diagnostics.write("Semantic clear removed \(unreadable) unreadable row(s).")
                }
                let result: Result<Int, Error> = firstError.map { .failure($0) } ?? .success(deleted)
                DispatchQueue.main.async { completion(result) }
            }
        }

        func deleteAll(completion: @escaping (Result<Int, Error>) -> Void) {
            queue.async {
                do {
                    let files = try self.semanticFiles()
                    for file in files { try FileManager.default.removeItem(at: file) }
                    self.recentReferencesByIdentity.removeAll(keepingCapacity: false)
                    self.recentIdentityOrder.removeAll(keepingCapacity: false)
                    DispatchQueue.main.async { completion(.success(files.count)) }
                } catch {
                    DispatchQueue.main.async { completion(.failure(error)) }
                }
            }
        }

        /// Deletes only semantic payloads referenced by exact source events. The
        /// operation is user-triggered, streams retained rows into a sibling
        /// temporary, and refuses malformed or linked inputs rather than widening
        /// the deletion scope.
        func deleteSnapshots(
            withIDs snapshotIDs: Set<String>,
            on days: Set<Date>? = nil,
            completion: @escaping (Result<Int, Error>) -> Void
        ) {
            queue.async {
                do {
                    guard snapshotIDs.count <= 32_768 else {
                        throw SemanticContextStoreError.targetedDeletionExceedsLimit(
                            snapshotIDs.count,
                            32_768
                        )
                    }
                    guard !snapshotIDs.isEmpty else {
                        DispatchQueue.main.async { completion(.success(0)) }
                        return
                    }
                    var deleted = 0
                    var metrics = SemanticContextDeletionMetrics()
                    for file in try self.semanticFiles(matching: days) {
                        deleted += try self.rewrite(
                            file: file,
                            metrics: &metrics,
                            shouldDelete: { snapshotIDs.contains($0.id) }
                        ).deleted
                    }
                    self.removeRecentReferences(withSnapshotIDs: snapshotIDs)
                    self.latestDeletionMetrics = metrics
                    DispatchQueue.main.async { completion(.success(deleted)) }
                } catch {
                    DispatchQueue.main.async { completion(.failure(error)) }
                }
            }
        }

        func preflightSnapshotDeletion(
            withIDs snapshotIDs: Set<String>,
            on days: Set<Date>
        ) throws {
            guard snapshotIDs.count <= 32_768 else {
                throw SemanticContextStoreError.targetedDeletionExceedsLimit(
                    snapshotIDs.count,
                    32_768
                )
            }
            guard !snapshotIDs.isEmpty else { return }
            try queue.sync {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let reader = HistoryJSONLinesStreamReader(
                    chunkSize: Self.deletionReadChunkBytes,
                    maximumLineBytes: Self.maximumSemanticLineBytes
                )
                for file in try semanticFiles(matching: days) {
                    var classificationFailed = false
                    let readMetrics = try reader.read(
                        file: file,
                        onLine: { raw, _ in
                            if (try? decoder.decode(
                                SemanticContextPayload.self,
                                from: raw
                            )) == nil {
                                classificationFailed = true
                            }
                        },
                        onOversizedLine: { _, _ in
                            classificationFailed = true
                        }
                    )
                    guard !classificationFailed,
                        !readMetrics.sourceChangedDuringRead
                    else {
                        throw SemanticContextStoreError
                            .unclassifiableTargetedDeletionRow(file)
                    }
                }
            }
        }

        private func semanticFiles(matching days: Set<Date>? = nil) throws -> [URL] {
            var directoryStatus = stat()
            guard lstat(semanticDirectory.path, &directoryStatus) == 0 else {
                if errno == ENOENT { return [] }
                throw SemanticContextStoreError.unsafeDirectory(semanticDirectory)
            }
            guard (directoryStatus.st_mode & S_IFMT) == S_IFDIR else {
                throw SemanticContextStoreError.unsafeDirectory(semanticDirectory)
            }
            let matchingDayKeys = days.map { Set($0.map(AppPaths.localDayString)) }
            let files = try FileManager.default.contentsOfDirectory(
                at: semanticDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ).filter {
                guard $0.lastPathComponent.hasSuffix(".semantic.jsonl") else {
                    return false
                }
                guard let matchingDayKeys else { return true }
                return matchingDayKeys.contains(String($0.lastPathComponent.prefix(10)))
            }
            for file in files {
                var status = stat()
                guard lstat(file.path, &status) == 0,
                    (status.st_mode & S_IFMT) == S_IFREG,
                    status.st_nlink == 1
                else {
                    throw SemanticContextStoreError.unsafeFile(file)
                }
            }
            return files.sorted { $0.lastPathComponent < $1.lastPathComponent }
        }

        /// Streams `file` into a 0600 sibling temporary without the deleted rows. Exact
        /// (targeted) deletion refuses unreadable rows; a cutoff clear passes
        /// `deletingUnreadableRows` so they are removed instead.
        private func rewrite(
            file: URL,
            metrics: inout SemanticContextDeletionMetrics,
            deletingUnreadableRows: Bool = false,
            shouldDelete: (SemanticContextPayload) -> Bool
        ) throws -> (deleted: Int, unreadable: Int) {
            var initialStatus = stat()
            guard lstat(file.path, &initialStatus) == 0,
                (initialStatus.st_mode & S_IFMT) == S_IFREG,
                initialStatus.st_nlink == 1
            else {
                throw SemanticContextStoreError.unsafeFile(file)
            }
            let temporary = semanticDirectory.appendingPathComponent(
                ".\(file.lastPathComponent).delete-\(UUID().uuidString).tmp"
            )
            guard FileManager.default.createFile(
                atPath: temporary.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            ) else {
                throw SemanticContextStoreError.couldNotCreateTemporary(temporary)
            }
            defer { try? FileManager.default.removeItem(at: temporary) }
            let output = try FileHandle(forWritingTo: temporary)
            defer { try? output.close() }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let reader = HistoryJSONLinesStreamReader(
                chunkSize: Self.deletionReadChunkBytes,
                maximumLineBytes: Self.maximumSemanticLineBytes
            )
            let newline = Data([0x0A])
            var deleted = 0
            var unreadable = 0
            var retainedRows = 0
            var processingError: Error?
            let readMetrics = try reader.read(
                file: file,
                onLine: { raw, _ in
                    guard processingError == nil else { return }
                    guard let payload = try? decoder.decode(
                        SemanticContextPayload.self,
                        from: raw
                    ) else {
                        if deletingUnreadableRows {
                            unreadable += 1
                        } else {
                            processingError = SemanticContextStoreError
                                .unclassifiableTargetedDeletionRow(file)
                        }
                        return
                    }
                    if shouldDelete(payload) {
                        deleted += 1
                    } else {
                        do {
                            try output.write(contentsOf: raw)
                            try output.write(contentsOf: newline)
                            retainedRows += 1
                        } catch {
                            processingError = error
                        }
                    }
                },
                onOversizedLine: { _, _ in
                    if deletingUnreadableRows {
                        unreadable += 1
                    } else {
                        processingError = SemanticContextStoreError
                            .unclassifiableTargetedDeletionRow(file)
                    }
                }
            )
            if let processingError { throw processingError }
            guard !readMetrics.sourceChangedDuringRead else {
                throw SemanticContextStoreError.sourceChanged(file)
            }
            metrics.bytesRead += readMetrics.bytesRead
            metrics.rowsVisited += readMetrics.rowsVisited
            metrics.peakBufferedBytes = max(
                metrics.peakBufferedBytes,
                readMetrics.peakBufferedBytes
            )
            guard deleted + unreadable > 0 else { return (0, 0) }
            try output.synchronize()
            try output.close()

            var currentStatus = stat()
            guard lstat(file.path, &currentStatus) == 0,
                Self.sameSnapshot(initialStatus, currentStatus)
            else {
                throw SemanticContextStoreError.sourceChanged(file)
            }
            let result: Int32
            if retainedRows == 0 {
                result = Darwin.unlink(file.path)
            } else {
                result = Darwin.rename(temporary.path, file.path)
            }
            guard result == 0 else {
                throw SemanticContextStoreError.sourceChanged(file)
            }
            let directoryDescriptor = Darwin.open(
                semanticDirectory.path,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
            if directoryDescriptor >= 0 {
                _ = Darwin.fsync(directoryDescriptor)
                _ = Darwin.close(directoryDescriptor)
            }
            return (deleted, unreadable)
        }

        private static func sameSnapshot(_ lhs: stat, _ rhs: stat) -> Bool {
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

        private func remember(
            _ reference: SemanticContextReference,
            identity: String
        ) {
            recentReferencesByIdentity[identity] = reference
            recentIdentityOrder.removeAll { $0 == identity }
            recentIdentityOrder.append(identity)
            while recentIdentityOrder.count > Self.maximumRecentIdentities {
                let evicted = recentIdentityOrder.removeFirst()
                recentReferencesByIdentity.removeValue(forKey: evicted)
            }
        }

        private func removeRecentReferences(withSnapshotIDs snapshotIDs: Set<String>) {
            guard !snapshotIDs.isEmpty else { return }
            recentReferencesByIdentity = recentReferencesByIdentity.filter {
                !snapshotIDs.contains($0.value.snapshotID)
            }
            let retained = Set(recentReferencesByIdentity.keys)
            recentIdentityOrder.removeAll { !retained.contains($0) }
        }

        private func source(from raw: String) -> SemanticContextSource {
            let values = Set(raw.split(separator: "+").map(String.init))
            if values.count > 1 { return .mixed }
            if values.contains("selected") { return .selectedText }
            if values.contains("focused") { return .focusedValue }
            return .visibleText
        }
    }

    enum SemanticContextStoreError: LocalizedError, GoalongFrenchDescribable {
        case suppressedOrEmpty
        case unsafeDirectory(URL)
        case unsafeFile(URL)
        case couldNotCreateTemporary(URL)
        case unclassifiableTargetedDeletionRow(URL)
        case sourceChanged(URL)
        case targetedDeletionExceedsLimit(Int, Int)

        var errorDescription: String? {
            switch self {
            case .suppressedOrEmpty:
                return "The semantic observation was empty or suppressed."
            case .unsafeDirectory(let URL):
                return "Refusing to modify an unavailable or linked semantic directory at \(URL.path)."
            case .unsafeFile(let URL):
                return "Refusing to modify a linked or non-regular semantic file at \(URL.path)."
            case .couldNotCreateTemporary(let URL):
                return "Could not create the secure semantic-deletion temporary at \(URL.path)."
            case .unclassifiableTargetedDeletionRow(let URL):
                return
                    "The selected semantic source contains an undecodable row at \(URL.path); no exact semantic deletion was committed."
            case .sourceChanged(let URL):
                return
                    "The semantic source changed during deletion; its original file was not replaced at \(URL.path)."
            case .targetedDeletionExceedsLimit(let actual, let maximum):
                return
                    "Refusing to retain \(actual) targeted semantic identifiers; the bounded maximum is \(maximum)."
            }
        }

        var frenchDescription: String {
            switch self {
            case .suppressedOrEmpty: return "Le contexte observé était vide ou masqué ; rien n’a été enregistré."
            case .unsafeDirectory, .unsafeFile: return GoalongUserFacingError.unsafeHistoryPathMessage
            case .couldNotCreateTemporary: return GoalongUserFacingError.historyIOMessage
            case .unclassifiableTargetedDeletionRow: return GoalongUserFacingError.inexactDeletionMessage
            case .sourceChanged: return GoalongUserFacingError.historyChangedMessage
            case .targetedDeletionExceedsLimit: return GoalongUserFacingError.tooManySelectedMessage
            }
        }
    }
#endif
