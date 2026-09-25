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
            deduplicationScope: String? = nil
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
                let handle = try FileHandle(forWritingTo: file)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                if let identity {
                    remember(payload.reference, identity: identity)
                }
                return payload.reference
            }
        }

        func resetDeduplicationCache() {
            queue.sync {
                recentReferencesByIdentity.removeAll(keepingCapacity: false)
                recentIdentityOrder.removeAll(keepingCapacity: false)
            }
        }

        func deleteEvents(
            since cutoff: Date,
            completion: @escaping (Result<Int, Error>) -> Void
        ) {
            queue.async {
                do {
                    let files = try self.semanticFiles()
                    var deleted = 0
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    for file in files {
                        let data = try Data(contentsOf: file)
                        let lines = data.split(separator: 0x0A)
                        var kept = Data()
                        for line in lines {
                            let payload = try decoder.decode(SemanticContextPayload.self, from: Data(line))
                            if payload.capturedAt >= cutoff {
                                deleted += 1
                            } else {
                                kept.append(line)
                                kept.append(0x0A)
                            }
                        }
                        if kept.isEmpty {
                            try? FileManager.default.removeItem(at: file)
                        } else {
                            try kept.write(to: file, options: .atomic)
                            try? FileManager.default.setAttributes(
                                [.posixPermissions: 0o600],
                                ofItemAtPath: file.path
                            )
                        }
                    }
                    self.recentReferencesByIdentity.removeAll(keepingCapacity: false)
                    self.recentIdentityOrder.removeAll(keepingCapacity: false)
                    DispatchQueue.main.async { completion(.success(deleted)) }
                } catch {
                    DispatchQueue.main.async { completion(.failure(error)) }
                }
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
                            deleting: snapshotIDs,
                            metrics: &metrics
                        )
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

        private func rewrite(
            file: URL,
            deleting snapshotIDs: Set<String>,
            metrics: inout SemanticContextDeletionMetrics
        ) throws -> Int {
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
                        processingError = SemanticContextStoreError
                            .unclassifiableTargetedDeletionRow(file)
                        return
                    }
                    if snapshotIDs.contains(payload.id) {
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
                    processingError = SemanticContextStoreError
                        .unclassifiableTargetedDeletionRow(file)
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
            guard deleted > 0 else { return 0 }
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
            return deleted
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

    enum SemanticContextStoreError: LocalizedError {
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
    }
#endif
