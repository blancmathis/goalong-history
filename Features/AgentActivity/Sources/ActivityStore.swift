import Foundation
import LocalHistoryCore

public enum AgentActivityStoreError: Error, LocalizedError {
    case fileTooLarge(path: String, bytes: Int64, maximum: Int64)
    case captureNotFound(String)
    case brokenDeltaChain(String)
    case hashMismatch(String)

    public var errorDescription: String? {
        switch self {
        case .fileTooLarge(let path, let bytes, let maximum):
            return "The file \(path) is \(bytes) bytes; the configured maximum is \(maximum)."
        case .captureNotFound(let id):
            return "Agent capture \(id) could not be found."
        case .brokenDeltaChain(let id):
            return "The stored append-only chain for capture \(id) is incomplete."
        case .hashMismatch(let id):
            return "The reconstructed bytes for capture \(id) do not match its recorded SHA-256."
        }
    }
}

public final class AgentActivityStore: @unchecked Sendable {
    public let rootDirectory: URL
    public let configurationFile: URL
    public let stateFile: URL
    public let manifestsDirectory: URL
    public let blobsDirectory: URL
    public let materializedDirectory: URL
    public let hookInboxDirectory: URL

    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let lock = NSRecursiveLock()
    private var state: AgentActivityState
    private var recordsByID: [String: AgentCaptureRecord] = [:]
    private var recordOrder: [String] = []
    private var lastHashedAtBySource: [String: Date] = [:]
    private var manifestLoadHadErrors = false
    private var manifestStateMismatch = false

    public init(rootDirectory: URL, fileManager: FileManager = .default) throws {
        self.rootDirectory = rootDirectory.standardizedFileURL
        self.fileManager = fileManager
        configurationFile = self.rootDirectory.appendingPathComponent("configuration.json", isDirectory: false)
        stateFile = self.rootDirectory.appendingPathComponent("state.json", isDirectory: false)
        manifestsDirectory = self.rootDirectory.appendingPathComponent("manifests", isDirectory: true)
        blobsDirectory = self.rootDirectory.appendingPathComponent("blobs", isDirectory: true)
        materializedDirectory = self.rootDirectory.appendingPathComponent("materialized", isDirectory: true)
        hookInboxDirectory = self.rootDirectory.appendingPathComponent("hook-inbox", isDirectory: true)

        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        state = AgentActivityState()

        try prepareDirectories()
        loadManifests()
        loadOrRebuildState()
    }

    public func loadConfiguration() -> AgentActivityConfiguration {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: configurationFile),
            let value = try? decoder.decode(AgentActivityConfiguration.self, from: data)
        else { return .default }
        return value.validated()
    }

    @discardableResult
    public func saveConfiguration(_ configuration: AgentActivityConfiguration) throws -> AgentActivityConfiguration {
        let validated = configuration.validated()
        let data = try encoder.encode(validated)
        lock.lock()
        defer { lock.unlock() }
        try secureAtomicWrite(data, to: configurationFile)
        return validated
    }

    public func capture(
        fileURL: URL,
        relativePath: String,
        folder: AgentWatchedFolder,
        configuration: AgentActivityConfiguration,
        capturedAt: Date = Date()
    ) throws -> AgentCaptureRecord? {
        let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
        guard (attributes[.type] as? FileAttributeType) == .typeRegular else { return nil }
        let byteCount = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let sourceModifiedAt = attributes[.modificationDate] as? Date
        guard byteCount <= configuration.maximumFileBytes else {
            throw AgentActivityStoreError.fileTooLarge(
                path: fileURL.path,
                bytes: byteCount,
                maximum: configuration.maximumFileBytes
            )
        }

        let standardizedPath = fileURL.standardizedFileURL.path
        let sourceKey = SHA256Digest.hashHex("LH-AGENT-SOURCE-V1\u{0}\(folder.id)\u{0}\(standardizedPath)")

        // Avoid re-reading large unchanged transcripts every few seconds, while still
        // forcing a full hash at least once per minute to detect same-size or timestamp-preserving rewrites.
        lock.lock()
        let metadataState = state.latestBySource[sourceKey]
        let lastHashedAt = lastHashedAtBySource[sourceKey]
        lock.unlock()
        let metadataMatches =
            metadataState?.byteCount == byteCount
            && metadataState?.sourceModifiedAt == sourceModifiedAt
        if metadataMatches, let lastHashedAt, capturedAt.timeIntervalSince(lastHashedAt) < 60 {
            return nil
        }

        let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        let fullHash = SHA256Digest.hashHex(data)

        lock.lock()
        defer { lock.unlock() }
        lastHashedAtBySource[sourceKey] = capturedAt

        var priorState = state.latestBySource[sourceKey]
        if priorState?.sha256 == fullHash {
            priorState?.byteCount = byteCount
            priorState?.sourceModifiedAt = sourceModifiedAt
            if let priorState { state.latestBySource[sourceKey] = priorState }
            state.updatedAt = capturedAt
            try persistState()
            return nil
        }
        let priorRecord = priorState.flatMap { recordsByID[$0.captureID] }

        let storage = try chooseStorage(
            newData: data,
            priorRecord: priorRecord,
            configuration: configuration
        )
        let blobHash = SHA256Digest.hashHex(storage.bytes)
        let blobRelativePath: String?
        if storage.kind == .digestOnly {
            blobRelativePath = nil
        } else {
            blobRelativePath = try writeBlobIfNeeded(storage.bytes, hash: blobHash)
        }

        let summary = AgentTranscriptParser.parse(data: data, fileURL: fileURL, provider: folder.provider)
        let captureID = UUID().uuidString
        let version = (priorState?.version ?? 0) + 1
        let previousManifestHash = state.lastManifestHash

        var record = AgentCaptureRecord(
            id: captureID,
            sourceKey: sourceKey,
            watchedFolderID: folder.id,
            watchedFolderName: folder.displayName,
            provider: folder.provider,
            sourcePath: standardizedPath,
            relativePath: relativePath,
            sourceModifiedAt: sourceModifiedAt,
            capturedAt: capturedAt,
            byteCount: Int64(data.count),
            storedByteCount: Int64(storage.bytes.count),
            sha256: fullHash,
            blobSHA256: blobHash,
            blobRelativePath: blobRelativePath,
            storageKind: storage.kind,
            baseCaptureID: storage.baseCaptureID,
            previousCaptureID: priorRecord?.id,
            version: version,
            deltaDepth: storage.deltaDepth,
            summary: summary,
            previousManifestHash: previousManifestHash,
            manifestHash: ""
        )
        record.manifestHash = Self.manifestHash(for: record)

        try appendManifest(record)
        recordsByID[record.id] = record
        recordOrder.append(record.id)
        state.latestBySource[sourceKey] = AgentSourceState(
            captureID: record.id,
            sha256: record.sha256,
            byteCount: record.byteCount,
            sourceModifiedAt: record.sourceModifiedAt,
            version: record.version,
            deltaDepth: record.deltaDepth
        )
        state.lastManifestHash = record.manifestHash
        state.updatedAt = capturedAt
        try persistState()
        return record
    }

    public func records(for day: Date? = nil) -> [AgentCaptureRecord] {
        lock.lock()
        defer { lock.unlock() }
        let values = Array(recordsByID.values)
        let filtered: [AgentCaptureRecord]
        if let day {
            filtered = values.filter { Calendar.current.isDate($0.capturedAt, inSameDayAs: day) }
        } else {
            filtered = values
        }
        return filtered.sorted { left, right in
            if left.capturedAt == right.capturedAt { return left.id > right.id }
            return left.capturedAt > right.capturedAt
        }
    }

    public func latestRecords() -> [AgentCaptureRecord] {
        lock.lock()
        defer { lock.unlock() }
        return state.latestBySource.values.compactMap { recordsByID[$0.captureID] }.sorted {
            $0.capturedAt > $1.capturedAt
        }
    }

    public func overview(for day: Date) -> AgentActivityOverview {
        lock.lock()
        let captures = recordsByID.values
            .filter { Calendar.current.isDate($0.capturedAt, inSameDayAs: day) }
            .sorted { left, right in
                if left.capturedAt == right.capturedAt { return left.id > right.id }
                return left.capturedAt > right.capturedAt
            }
        let allRecords = recordsByID
        lock.unlock()

        let sessionKeys = Set(
            captures.compactMap { record -> String? in
                if let session = record.summary.sessionID, !session.isEmpty {
                    return "\(record.provider.rawValue):\(session)"
                }
                return record.summary.messageCount > 0 ? "source:\(record.sourceKey)" : nil
            })

        func incrementalCount(
            _ record: AgentCaptureRecord,
            _ value: (AgentDocumentSummary) -> Int
        ) -> Int {
            let current = value(record.summary)
            guard let previousID = record.previousCaptureID, let previous = allRecords[previousID] else {
                return current
            }
            return max(0, current - value(previous.summary))
        }

        return AgentActivityOverview(
            day: Calendar.current.startOfDay(for: day),
            captures: captures,
            sessionCount: sessionKeys.count,
            messageCount: captures.reduce(0) { $0 + incrementalCount($1, { $0.messageCount }) },
            toolCallCount: captures.reduce(0) { $0 + incrementalCount($1, { $0.toolCallCount }) },
            errorCount: captures.reduce(0) { $0 + incrementalCount($1, { $0.errorCount }) },
            capturedBytes: captures.reduce(0) { $0 + $1.byteCount },
            storedBytes: captures.reduce(0) { $0 + $1.storedByteCount },
            lastCaptureAt: captures.first?.capturedAt
        )
    }

    public func record(id: String) -> AgentCaptureRecord? {
        lock.lock()
        defer { lock.unlock() }
        return recordsByID[id]
    }

    public func reconstructedData(for captureID: String) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        return try reconstructLocked(captureID, visited: [])
    }

    public func materialize(captureID: String) throws -> URL {
        lock.lock()
        defer { lock.unlock() }
        guard let record = recordsByID[captureID] else {
            throw AgentActivityStoreError.captureNotFound(captureID)
        }
        let data = try reconstructLocked(captureID, visited: [])
        let filename = Self.safeFilename(record.relativePath.isEmpty ? record.sourcePath : record.relativePath)
        let destination = materializedDirectory.appendingPathComponent("\(captureID)-\(filename)", isDirectory: false)
        try secureAtomicWrite(data, to: destination)
        return destination
    }

    public func verifies(captureID: String) -> Bool {
        guard let record = record(id: captureID),
            let data = try? reconstructedData(for: captureID)
        else { return false }
        return SHA256Digest.hashHex(data) == record.sha256
    }

    public func manifestChainIsValid() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !manifestLoadHadErrors, !manifestStateMismatch, !state.integrityFaultDetected else { return false }
        let ordered = recordOrder.compactMap { recordsByID[$0] }
        guard Self.recordsFormValidManifestChain(ordered) else { return false }
        return ordered.last?.manifestHash == state.lastManifestHash
            || (ordered.isEmpty && state.lastManifestHash.isEmpty)
    }

    public func storageBytes() -> Int64 {
        guard
            let enumerator = fileManager.enumerator(
                at: rootDirectory,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            )
        else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            if let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                values.isRegularFile == true
            {
                total += Int64(values.fileSize ?? 0)
            }
        }
        return total
    }

    private struct StorageChoice {
        let kind: AgentCaptureStorageKind
        let bytes: Data
        let baseCaptureID: String?
        let deltaDepth: Int
    }

    private func chooseStorage(
        newData: Data,
        priorRecord: AgentCaptureRecord?,
        configuration: AgentActivityConfiguration
    ) throws -> StorageChoice {
        guard configuration.captureFullContents else {
            return StorageChoice(kind: .digestOnly, bytes: Data(), baseCaptureID: nil, deltaDepth: 0)
        }
        guard configuration.keepEveryVersion,
            let priorRecord,
            priorRecord.deltaDepth < configuration.maximumDeltaDepth,
            priorRecord.byteCount <= Int64(newData.count),
            let oldData = try? reconstructLocked(priorRecord.id, visited: []),
            newData.count > oldData.count,
            newData.prefix(oldData.count) == oldData
        else {
            return StorageChoice(kind: .full, bytes: newData, baseCaptureID: nil, deltaDepth: 0)
        }
        let delta = Data(newData.dropFirst(oldData.count))
        return StorageChoice(
            kind: .appendDelta,
            bytes: delta,
            baseCaptureID: priorRecord.id,
            deltaDepth: priorRecord.deltaDepth + 1
        )
    }

    private func reconstructLocked(_ captureID: String, visited: Set<String>) throws -> Data {
        guard !visited.contains(captureID) else {
            throw AgentActivityStoreError.brokenDeltaChain(captureID)
        }
        guard let record = recordsByID[captureID] else {
            throw AgentActivityStoreError.captureNotFound(captureID)
        }
        guard record.storageKind != .digestOnly, let relative = record.blobRelativePath else {
            throw AgentActivityStoreError.brokenDeltaChain(captureID)
        }
        let blobURL = rootDirectory.appendingPathComponent(relative, isDirectory: false)
        let blob = try Data(contentsOf: blobURL)
        guard SHA256Digest.hashHex(blob) == record.blobSHA256 else {
            throw AgentActivityStoreError.hashMismatch(captureID)
        }

        let reconstructed: Data
        switch record.storageKind {
        case .full:
            reconstructed = blob
        case .appendDelta:
            guard let base = record.baseCaptureID else {
                throw AgentActivityStoreError.brokenDeltaChain(captureID)
            }
            var nextVisited = visited
            nextVisited.insert(captureID)
            var baseData = try reconstructLocked(base, visited: nextVisited)
            baseData.append(blob)
            reconstructed = baseData
        case .digestOnly:
            throw AgentActivityStoreError.brokenDeltaChain(captureID)
        }
        guard SHA256Digest.hashHex(reconstructed) == record.sha256 else {
            throw AgentActivityStoreError.hashMismatch(captureID)
        }
        return reconstructed
    }

    private func writeBlobIfNeeded(_ data: Data, hash: String) throws -> String {
        let shard = String(hash.prefix(2))
        let directory = blobsDirectory.appendingPathComponent(shard, isDirectory: true)
        try createSecureDirectory(directory)
        let destination = directory.appendingPathComponent("\(hash).blob", isDirectory: false)
        if !fileManager.fileExists(atPath: destination.path) {
            try secureAtomicWrite(data, to: destination)
        }
        return destination.path.replacingOccurrences(of: rootDirectory.path + "/", with: "")
    }

    private func appendManifest(_ record: AgentCaptureRecord) throws {
        let day = Self.localDay(record.capturedAt)
        let file = manifestsDirectory.appendingPathComponent("\(day).captures.jsonl", isDirectory: false)
        var line = try encoder.encode(record)
        line.append(0x0A)
        if !fileManager.fileExists(atPath: file.path) {
            _ = fileManager.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
        try handle.synchronize()
        try handle.close()
    }

    private func loadManifests() {
        lock.lock()
        defer { lock.unlock() }
        guard
            let files = try? fileManager.contentsOfDirectory(
                at: manifestsDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        else {
            manifestLoadHadErrors = true
            return
        }
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where file.pathExtension == "jsonl" {
            guard let data = try? Data(contentsOf: file), let text = String(data: data, encoding: .utf8) else {
                manifestLoadHadErrors = true
                continue
            }
            for line in text.split(whereSeparator: \.isNewline) {
                guard let lineData = String(line).data(using: .utf8),
                    let record = try? decoder.decode(AgentCaptureRecord.self, from: lineData)
                else {
                    manifestLoadHadErrors = true
                    continue
                }
                guard recordsByID[record.id] == nil else {
                    manifestLoadHadErrors = true
                    continue
                }
                recordOrder.append(record.id)
                recordsByID[record.id] = record
            }
        }
    }

    private func loadOrRebuildState() {
        lock.lock()
        defer { lock.unlock() }
        let loadedState: AgentActivityState? = {
            guard fileManager.fileExists(atPath: stateFile.path) else { return nil }
            guard let data = try? Data(contentsOf: stateFile),
                let loaded = try? decoder.decode(AgentActivityState.self, from: data)
            else {
                manifestStateMismatch = true
                return nil
            }
            return loaded
        }()

        let ordered = recordOrder.compactMap { recordsByID[$0] }
        var rebuilt = AgentActivityState()
        for record in ordered {
            let current = rebuilt.latestBySource[record.sourceKey]
            if current == nil || record.version >= current!.version {
                rebuilt.latestBySource[record.sourceKey] = AgentSourceState(
                    captureID: record.id,
                    sha256: record.sha256,
                    byteCount: record.byteCount,
                    sourceModifiedAt: record.sourceModifiedAt,
                    version: record.version,
                    deltaDepth: record.deltaDepth
                )
            }
            rebuilt.lastManifestHash = record.manifestHash
            rebuilt.updatedAt = max(rebuilt.updatedAt, record.capturedAt)
        }
        state = rebuilt
        state.integrityFaultDetected = loadedState?.integrityFaultDetected == true

        guard !manifestLoadHadErrors, Self.recordsFormValidManifestChain(ordered) else {
            markManifestFaultLocked()
            return
        }

        if let loadedState {
            guard !loadedState.integrityFaultDetected else {
                markManifestFaultLocked()
                return
            }
            let loadedHeadIsRecoverable =
                loadedState.lastManifestHash.isEmpty
                || ordered.contains(where: { $0.manifestHash == loadedState.lastManifestHash })
            guard loadedHeadIsRecoverable else {
                markManifestFaultLocked()
                return
            }
        }
        try? persistState()
    }

    private func markManifestFaultLocked() {
        manifestStateMismatch = true
        state.integrityFaultDetected = true
        state.updatedAt = Date()
        try? persistState()
    }

    private func persistState() throws {
        let data = try encoder.encode(state)
        try secureAtomicWrite(data, to: stateFile)
    }

    private func prepareDirectories() throws {
        for directory in [rootDirectory, manifestsDirectory, blobsDirectory, materializedDirectory, hookInboxDirectory]
        {
            try createSecureDirectory(directory)
        }
    }

    private func createSecureDirectory(_ url: URL) throws {
        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private func secureAtomicWrite(_ data: Data, to url: URL) throws {
        try createSecureDirectory(url.deletingLastPathComponent())
        try data.write(to: url, options: [.atomic])
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func manifestHash(for record: AgentCaptureRecord) -> String {
        let summaryEncoder = JSONEncoder()
        summaryEncoder.dateEncodingStrategy = .iso8601
        summaryEncoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let summaryHash =
            (try? summaryEncoder.encode(record.summary)).map(SHA256Digest.hashHex)
            ?? "summary-encoding-error"
        let fields: [String: String] = [
            "id": record.id,
            "source_key": record.sourceKey,
            "folder_id": record.watchedFolderID,
            "folder_name": record.watchedFolderName,
            "provider": record.provider.rawValue,
            "source_path": record.sourcePath,
            "relative_path": record.relativePath,
            "captured_at": iso8601(record.capturedAt),
            "source_modified_at": record.sourceModifiedAt.map(iso8601) ?? "",
            "byte_count": String(record.byteCount),
            "stored_byte_count": String(record.storedByteCount),
            "sha256": record.sha256,
            "blob_sha256": record.blobSHA256,
            "blob_relative_path": record.blobRelativePath ?? "",
            "storage_kind": record.storageKind.rawValue,
            "base_capture_id": record.baseCaptureID ?? "",
            "previous_capture_id": record.previousCaptureID ?? "",
            "version": String(record.version),
            "delta_depth": String(record.deltaDepth),
            "summary_sha256": summaryHash,
            "previous_manifest_hash": record.previousManifestHash,
        ]
        var material = Data("LH-AGENT-CAPTURE-MANIFEST-V1\0".utf8)
        material.append(CanonicalFields.encode(fields))
        return SHA256Digest.hashHex(material)
    }

    private static func recordsFormValidManifestChain(_ ordered: [AgentCaptureRecord]) -> Bool {
        var previous = ""
        for record in ordered {
            guard record.previousManifestHash == previous else { return false }
            guard record.manifestHash == manifestHash(for: record) else { return false }
            previous = record.manifestHash
        }
        return true
    }

    private static func localDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func safeFilename(_ path: String) -> String {
        let raw = URL(fileURLWithPath: path).lastPathComponent
        let safe = raw.map { character -> Character in
            character.isLetter || character.isNumber || ".-_".contains(character) ? character : "_"
        }
        let value = String(safe)
        return value.isEmpty ? "capture.data" : String(value.prefix(180))
    }
}
