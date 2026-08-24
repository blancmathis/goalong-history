import Darwin
import Foundation

public struct HistoryLoadIssue: Codable, Equatable, Identifiable {
    public let id: String
    public let path: String
    public let line: Int?
    public let message: String

    public init(path: String, line: Int?, message: String) {
        self.id = "\(path):\(line.map(String.init) ?? "-"):\(message)"
        self.path = path
        self.line = line
        self.message = message
    }
}

public struct HistoryLoadedData {
    public let events: [HistoryEvent]
    public let memories: [ActivityMemory]
    public let semanticSnapshots: [String: SemanticContextPayload]
    public let captureHealth: CaptureHealthSnapshot?
    public let issues: [HistoryLoadIssue]

    public init(
        events: [HistoryEvent],
        memories: [ActivityMemory],
        semanticSnapshots: [String: SemanticContextPayload],
        captureHealth: CaptureHealthSnapshot?,
        issues: [HistoryLoadIssue]
    ) {
        self.events = events
        self.memories = memories
        self.semanticSnapshots = semanticSnapshots
        self.captureHealth = captureHealth
        self.issues = issues
    }
}

/// Bounded diagnostics for the Computer History source pass. `retained*Bytes`
/// counts the compact encoded values that survived the evidence filter; it is useful
/// for proving that maintenance traffic does not inflate the analysis working
/// set without exposing any recorded content.
package struct ComputerHistoryEvidenceLoadMetrics: Equatable {
    package let eventBytesRead: Int64
    package let semanticBytesRead: Int64
    package let peakStreamBufferBytes: Int
    package let rawEventCount: Int
    package let retainedEventCount: Int
    package let retainedEventBytes: Int64
    package let semanticRowsVisited: Int
    package let retainedSemanticSnapshotCount: Int
    package let retainedSemanticSnapshotBytes: Int64
    package let wasCancelled: Bool
    package let sourceChangedDuringRead: Bool
    package let sourceAccessWasIncomplete: Bool
    package let evidenceBudgetExceeded: Bool
    package let peakRetainedEvidenceRows: Int
    package let peakEstimatedRetainedEvidenceBytes: Int64

    package init(
        eventBytesRead: Int64,
        semanticBytesRead: Int64,
        peakStreamBufferBytes: Int,
        rawEventCount: Int,
        retainedEventCount: Int,
        retainedEventBytes: Int64,
        semanticRowsVisited: Int,
        retainedSemanticSnapshotCount: Int,
        retainedSemanticSnapshotBytes: Int64,
        wasCancelled: Bool = false,
        sourceChangedDuringRead: Bool = false,
        sourceAccessWasIncomplete: Bool = false,
        evidenceBudgetExceeded: Bool = false,
        peakRetainedEvidenceRows: Int = 0,
        peakEstimatedRetainedEvidenceBytes: Int64 = 0
    ) {
        self.eventBytesRead = max(0, eventBytesRead)
        self.semanticBytesRead = max(0, semanticBytesRead)
        self.peakStreamBufferBytes = max(0, peakStreamBufferBytes)
        self.rawEventCount = max(0, rawEventCount)
        self.retainedEventCount = max(0, retainedEventCount)
        self.retainedEventBytes = max(0, retainedEventBytes)
        self.semanticRowsVisited = max(0, semanticRowsVisited)
        self.retainedSemanticSnapshotCount = max(0, retainedSemanticSnapshotCount)
        self.retainedSemanticSnapshotBytes = max(0, retainedSemanticSnapshotBytes)
        self.wasCancelled = wasCancelled
        self.sourceChangedDuringRead = sourceChangedDuringRead
        self.sourceAccessWasIncomplete = sourceAccessWasIncomplete
        self.evidenceBudgetExceeded = evidenceBudgetExceeded
        self.peakRetainedEvidenceRows = max(0, peakRetainedEvidenceRows)
        self.peakEstimatedRetainedEvidenceBytes = max(
            0,
            peakEstimatedRetainedEvidenceBytes
        )
    }
}

package struct ComputerHistoryEvidenceLoadLimits: Equatable {
    package static let production = ComputerHistoryEvidenceLoadLimits(
        maximumRetainedRows: 32_768,
        maximumRetainedBytes: 64 * 1_024 * 1_024
    )

    package var maximumRetainedRows: Int
    package var maximumRetainedBytes: Int64

    package init(
        maximumRetainedRows: Int,
        maximumRetainedBytes: Int64
    ) {
        self.maximumRetainedRows = maximumRetainedRows
        self.maximumRetainedBytes = maximumRetainedBytes
    }

    package var validated: ComputerHistoryEvidenceLoadLimits {
        ComputerHistoryEvidenceLoadLimits(
            maximumRetainedRows: min(
                max(0, maximumRetainedRows),
                Self.production.maximumRetainedRows
            ),
            maximumRetainedBytes: min(
                max(0, maximumRetainedBytes),
                Self.production.maximumRetainedBytes
            )
        )
    }
}

/// The minimal source material required by `ComputerHistoryEngine`. Raw journal
/// rows are decoded once and immediately discarded unless they can affect the
/// causal analysis. Coverage and continuity remain exact through the constant-
/// size journal summary.
package struct ComputerHistoryEvidenceLoad {
    package let events: [HistoryEvent]
    package let semanticSnapshots: [String: SemanticContextPayload]
    package let sourceJournalSummary: ComputerHistorySourceJournalSummary
    package let issues: [HistoryLoadIssue]
    package let metrics: ComputerHistoryEvidenceLoadMetrics

    package init(
        events: [HistoryEvent],
        semanticSnapshots: [String: SemanticContextPayload],
        sourceJournalSummary: ComputerHistorySourceJournalSummary,
        issues: [HistoryLoadIssue],
        metrics: ComputerHistoryEvidenceLoadMetrics
    ) {
        self.events = events
        self.semanticSnapshots = semanticSnapshots
        self.sourceJournalSummary = sourceJournalSummary
        self.issues = issues
        self.metrics = metrics
    }
}

private enum HistoryBoundedFileReadError: LocalizedError {
    case exceedsLimit(Int)
    case changedDuringRead
    case cancelled

    var errorDescription: String? {
        switch self {
        case .exceedsLimit(let maximumBytes):
            return "file exceeds the \(maximumBytes)-byte safety limit"
        case .changedDuringRead:
            return "file changed while it was being read"
        case .cancelled:
            return "file read stopped at the caller's budget"
        }
    }
}

private func historyPathReferencesPinnedRegularFile(
    _ file: URL,
    device: dev_t,
    inode: ino_t
) -> Bool {
    var pathStat = stat()
    guard lstat(file.path, &pathStat) == 0 else { return false }
    return (pathStat.st_mode & S_IFMT) == S_IFREG
        && pathStat.st_dev == device
        && pathStat.st_ino == inode
}

private enum HistoryPinnedDirectoryError: LocalizedError {
    case absent(path: String)
    case inaccessible(path: String, reason: String)
    case symbolicLink(path: String)
    case symbolicLinkFile(path: String)
    case notDirectory(path: String)
    case changed(path: String)
    case cancelled(path: String)
    case entryLimit(path: String, maximum: Int)
    case unsafeEntry(path: String)

    var errorDescription: String? {
        switch self {
        case .absent(let path):
            return "source directory is absent: \(path)"
        case .inaccessible(let path, let reason):
            return "could not access source directory \(path): \(reason)"
        case .symbolicLink(let path):
            return "refused symbolic-link source directory \(path)"
        case .symbolicLinkFile(let path):
            return "refused symbolic-link source file \(path)"
        case .notDirectory(let path):
            return "source path is not a directory: \(path)"
        case .changed(let path):
            return "source directory changed while it was being inspected: \(path)"
        case .cancelled(let path):
            return "source directory listing stopped at the caller's time budget: \(path)"
        case .entryLimit(let path, let maximum):
            return "source directory exceeded the \(maximum)-entry safety limit: \(path)"
        case .unsafeEntry(let path):
            return "source directory contained an unsafe or non-regular matching entry: \(path)"
        }
    }
}

private struct HistoryPinnedDirectoryIdentity {
    let device: dev_t
    let inode: ino_t
    let size: off_t
    let modificationTime: timespec
    let changeTime: timespec

    init(_ value: stat) {
        device = value.st_dev
        inode = value.st_ino
        size = value.st_size
        modificationTime = value.st_mtimespec
        changeTime = value.st_ctimespec
    }

    func matches(_ value: stat) -> Bool {
        (value.st_mode & S_IFMT) == S_IFDIR
            && value.st_dev == device
            && value.st_ino == inode
            && value.st_size == size
            && value.st_mtimespec.tv_sec == modificationTime.tv_sec
            && value.st_mtimespec.tv_nsec == modificationTime.tv_nsec
            && value.st_ctimespec.tv_sec == changeTime.tv_sec
            && value.st_ctimespec.tv_nsec == changeTime.tv_nsec
    }
}

private struct HistoryPinnedRegularFileIdentity: Equatable {
    let device: dev_t
    let inode: ino_t
    let size: off_t
    let modificationSeconds: Int
    let modificationNanoseconds: Int
    let changeSeconds: Int
    let changeNanoseconds: Int

    init(_ value: stat) {
        device = value.st_dev
        inode = value.st_ino
        size = value.st_size
        modificationSeconds = value.st_mtimespec.tv_sec
        modificationNanoseconds = value.st_mtimespec.tv_nsec
        changeSeconds = value.st_ctimespec.tv_sec
        changeNanoseconds = value.st_ctimespec.tv_nsec
    }

    func matches(_ value: stat) -> Bool {
        (value.st_mode & S_IFMT) == S_IFREG
            && value.st_dev == device
            && value.st_ino == inode
            && value.st_size == size
            && value.st_mtimespec.tv_sec == modificationSeconds
            && value.st_mtimespec.tv_nsec == modificationNanoseconds
            && value.st_ctimespec.tv_sec == changeSeconds
            && value.st_ctimespec.tv_nsec == changeNanoseconds
    }
}

private final class HistoryPinnedSourceDirectory {
    static let maximumEntries = 8_192
    static let maximumMatchingFiles = 4_096

    let url: URL
    let descriptor: Int32
    private let identity: HistoryPinnedDirectoryIdentity

    init(rootURL: URL) throws {
        var pathStat = stat()
        guard lstat(rootURL.path, &pathStat) == 0 else {
            if errno == ENOENT {
                throw HistoryPinnedDirectoryError.absent(path: rootURL.path)
            }
            throw HistoryPinnedDirectoryError.inaccessible(
                path: rootURL.path,
                reason: String(cString: strerror(errno))
            )
        }
        guard (pathStat.st_mode & S_IFMT) != S_IFLNK else {
            throw HistoryPinnedDirectoryError.symbolicLink(path: rootURL.path)
        }
        guard (pathStat.st_mode & S_IFMT) == S_IFDIR else {
            throw HistoryPinnedDirectoryError.notDirectory(path: rootURL.path)
        }
        let openedDescriptor = open(
            rootURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
        )
        guard openedDescriptor >= 0 else {
            throw HistoryPinnedDirectoryError.inaccessible(
                path: rootURL.path,
                reason: String(cString: strerror(errno))
            )
        }
        var descriptorStat = stat()
        guard fstat(openedDescriptor, &descriptorStat) == 0 else {
            let reason = String(cString: strerror(errno))
            close(openedDescriptor)
            throw HistoryPinnedDirectoryError.inaccessible(
                path: rootURL.path,
                reason: reason
            )
        }
        let pinnedIdentity = HistoryPinnedDirectoryIdentity(descriptorStat)
        guard pinnedIdentity.matches(pathStat) else {
            close(openedDescriptor)
            throw HistoryPinnedDirectoryError.changed(path: rootURL.path)
        }
        url = rootURL
        descriptor = openedDescriptor
        identity = pinnedIdentity
    }

    init(parent: HistoryPinnedSourceDirectory, name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
            throw HistoryPinnedDirectoryError.unsafeEntry(
                path: parent.url.appendingPathComponent(name).path
            )
        }
        let childURL = parent.url.appendingPathComponent(name, isDirectory: true)
        guard parent.isStable() else {
            throw HistoryPinnedDirectoryError.changed(path: parent.url.path)
        }
        var pathStat = stat()
        let inspectionResult = name.withCString {
            fstatat(parent.descriptor, $0, &pathStat, AT_SYMLINK_NOFOLLOW)
        }
        guard inspectionResult == 0 else {
            if errno == ENOENT {
                throw HistoryPinnedDirectoryError.absent(path: childURL.path)
            }
            throw HistoryPinnedDirectoryError.inaccessible(
                path: childURL.path,
                reason: String(cString: strerror(errno))
            )
        }
        guard (pathStat.st_mode & S_IFMT) != S_IFLNK else {
            throw HistoryPinnedDirectoryError.symbolicLink(path: childURL.path)
        }
        guard (pathStat.st_mode & S_IFMT) == S_IFDIR else {
            throw HistoryPinnedDirectoryError.notDirectory(path: childURL.path)
        }
        let openedDescriptor = name.withCString {
            openat(
                parent.descriptor,
                $0,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
            )
        }
        guard openedDescriptor >= 0 else {
            throw HistoryPinnedDirectoryError.inaccessible(
                path: childURL.path,
                reason: String(cString: strerror(errno))
            )
        }
        var descriptorStat = stat()
        guard fstat(openedDescriptor, &descriptorStat) == 0 else {
            let reason = String(cString: strerror(errno))
            close(openedDescriptor)
            throw HistoryPinnedDirectoryError.inaccessible(
                path: childURL.path,
                reason: reason
            )
        }
        let pinnedIdentity = HistoryPinnedDirectoryIdentity(descriptorStat)
        guard pinnedIdentity.matches(pathStat), parent.isStable() else {
            close(openedDescriptor)
            throw HistoryPinnedDirectoryError.changed(path: childURL.path)
        }
        url = childURL
        descriptor = openedDescriptor
        identity = pinnedIdentity
    }

    deinit {
        close(descriptor)
    }

    func isStable() -> Bool {
        var descriptorStat = stat()
        guard fstat(descriptor, &descriptorStat) == 0,
            identity.matches(descriptorStat)
        else { return false }
        var pathStat = stat()
        guard lstat(url.path, &pathStat) == 0 else { return false }
        return identity.matches(pathStat)
    }

    func matchingFiles(
        extensions: Set<String>,
        maximumEntries: Int = HistoryPinnedSourceDirectory.maximumEntries,
        maximumMatchingFiles: Int = HistoryPinnedSourceDirectory.maximumMatchingFiles,
        shouldContinue: () -> Bool = { true }
    ) throws -> [HistoryPinnedSourceFile] {
        guard isStable() else {
            throw HistoryPinnedDirectoryError.changed(path: url.path)
        }
        let duplicatedDescriptor = dup(descriptor)
        guard duplicatedDescriptor >= 0 else {
            throw HistoryPinnedDirectoryError.inaccessible(
                path: url.path,
                reason: String(cString: strerror(errno))
            )
        }
        guard let stream = fdopendir(duplicatedDescriptor) else {
            let reason = String(cString: strerror(errno))
            close(duplicatedDescriptor)
            throw HistoryPinnedDirectoryError.inaccessible(path: url.path, reason: reason)
        }
        defer { closedir(stream) }

        var files: [HistoryPinnedSourceFile] = []
        var visitedEntries = 0
        while true {
            guard shouldContinue() else {
                throw HistoryPinnedDirectoryError.cancelled(path: url.path)
            }
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else {
                    throw HistoryPinnedDirectoryError.inaccessible(
                        path: url.path,
                        reason: String(cString: strerror(errno))
                    )
                }
                break
            }
            visitedEntries += 1
            guard visitedEntries <= max(0, maximumEntries) else {
                throw HistoryPinnedDirectoryError.entryLimit(
                    path: url.path,
                    maximum: max(0, maximumEntries)
                )
            }
            let name = withUnsafePointer(to: entry.pointee.d_name) { namePointer in
                namePointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(validatingUTF8: $0)
                }
            }
            guard let name else {
                throw HistoryPinnedDirectoryError.unsafeEntry(path: url.path)
            }
            guard name != ".", name != ".." else { continue }
            guard !name.contains("/") else {
                throw HistoryPinnedDirectoryError.unsafeEntry(
                    path: url.appendingPathComponent(name).path
                )
            }
            let lowercasedName = name.lowercased()
            guard extensions.contains(where: { lowercasedName.hasSuffix(".\($0)") }) else {
                continue
            }
            var entryStat = stat()
            let inspectionResult = name.withCString {
                fstatat(descriptor, $0, &entryStat, AT_SYMLINK_NOFOLLOW)
            }
            guard inspectionResult == 0 else {
                throw HistoryPinnedDirectoryError.inaccessible(
                    path: url.appendingPathComponent(name).path,
                    reason: String(cString: strerror(errno))
                )
            }
            guard (entryStat.st_mode & S_IFMT) == S_IFREG else {
                if (entryStat.st_mode & S_IFMT) == S_IFLNK {
                    throw HistoryPinnedDirectoryError.symbolicLinkFile(
                        path: url.appendingPathComponent(name).path
                    )
                }
                throw HistoryPinnedDirectoryError.unsafeEntry(
                    path: url.appendingPathComponent(name).path
                )
            }
            guard files.count < max(0, maximumMatchingFiles) else {
                throw HistoryPinnedDirectoryError.entryLimit(
                    path: url.path,
                    maximum: max(0, maximumMatchingFiles)
                )
            }
            files.append(
                HistoryPinnedSourceFile(directory: self, name: name)
            )
        }
        guard isStable() else {
            throw HistoryPinnedDirectoryError.changed(path: url.path)
        }
        return files.sorted { $0.name < $1.name }
    }
}

private struct HistoryPinnedSourceFile {
    let directory: HistoryPinnedSourceDirectory
    let name: String

    var url: URL {
        directory.url.appendingPathComponent(name, isDirectory: false)
    }

    func isStable(relativeTo identity: HistoryPinnedRegularFileIdentity) -> Bool {
        var current = stat()
        let result = name.withCString {
            fstatat(directory.descriptor, $0, &current, AT_SYMLINK_NOFOLLOW)
        }
        return result == 0 && identity.matches(current)
    }
}

/// Metrics emitted by the same bounded JSONL primitive used by
/// `HistoryLocalStoreReader`. The type is internal so tests can prove that the
/// transient read buffer stays independent of the size of the file without
/// exposing recorder contents or diagnostics in the public API.
package struct HistoryJSONLinesReadMetrics: Equatable {
    var bytesRead: Int64 = 0
    var peakBufferedBytes = 0
    var rowsVisited = 0
    var oversizedRows = 0
    var reachedByteLimit = false
    var wasCancelled = false
    var sourceChangedDuringRead = false
    fileprivate var pinnedIdentity: HistoryPinnedRegularFileIdentity?
}

/// Incremental, read-only JSONL framing. A complete row must be buffered for
/// `JSONDecoder`, but the complete file never is. Oversized rows are discarded
/// without retaining their contents and scanning resumes at the next newline.
package struct HistoryJSONLinesStreamReader {
    package static let defaultChunkSize = 64 * 1_024
    package static let defaultMaximumLineBytes = 8 * 1_024 * 1_024

    let chunkSize: Int
    let maximumLineBytes: Int

    package init(
        chunkSize: Int = Self.defaultChunkSize,
        maximumLineBytes: Int = Self.defaultMaximumLineBytes
    ) {
        precondition(chunkSize > 0)
        precondition(maximumLineBytes > 0)
        self.chunkSize = chunkSize
        self.maximumLineBytes = maximumLineBytes
    }

    package func read(
        file: URL,
        directoryDescriptor: Int32? = nil,
        relativeName: String? = nil,
        maximumBytes: Int64? = nil,
        shouldContinue: () -> Bool = { true },
        onLine: (Data, Int) -> Void,
        onOversizedLine: (Int, Int) -> Void
    ) throws -> HistoryJSONLinesReadMetrics {
        let descriptor: Int32
        if let directoryDescriptor, let relativeName,
            !relativeName.isEmpty, relativeName != ".", relativeName != "..",
            !relativeName.contains("/")
        {
            descriptor = relativeName.withCString {
                openat(
                    directoryDescriptor,
                    $0,
                    O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
                )
            }
        } else if directoryDescriptor == nil, relativeName == nil {
            descriptor = open(
                file.path,
                O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
            )
        } else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(EINVAL),
                userInfo: [NSFilePathErrorKey: file.path]
            )
        }
        guard descriptor >= 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSFilePathErrorKey: file.path]
            )
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var sourceStat = stat()
        guard fstat(descriptor, &sourceStat) == 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSFilePathErrorKey: file.path]
            )
        }
        guard (sourceStat.st_mode & S_IFMT) == S_IFREG else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(EINVAL),
                userInfo: [
                    NSFilePathErrorKey: file.path,
                    NSLocalizedDescriptionKey: "raw-source path is not a regular file",
                ]
            )
        }
        let sourceByteCount = Int64(sourceStat.st_size)
        let sourceDevice = sourceStat.st_dev
        let sourceInode = sourceStat.st_ino
        let sourceModificationTime = sourceStat.st_mtimespec
        let sourceChangeTime = sourceStat.st_ctimespec
        let callerByteLimit = maximumBytes.map { max(0, $0) }
        let readCeiling = min(sourceByteCount, callerByteLimit ?? sourceByteCount)

        func matchesInitialIdentity(_ current: stat) -> Bool {
            current.st_dev == sourceDevice
                && current.st_ino == sourceInode
                && Int64(current.st_size) == sourceByteCount
                && current.st_mtimespec.tv_sec == sourceModificationTime.tv_sec
                && current.st_mtimespec.tv_nsec == sourceModificationTime.tv_nsec
                && current.st_ctimespec.tv_sec == sourceChangeTime.tv_sec
                && current.st_ctimespec.tv_nsec == sourceChangeTime.tv_nsec
        }

        var metrics = HistoryJSONLinesReadMetrics()
        metrics.pinnedIdentity = HistoryPinnedRegularFileIdentity(sourceStat)
        var pending = Data()
        pending.reserveCapacity(min(chunkSize, maximumLineBytes))
        var discardingOversizedLine = false
        var nonEmptyLineNumber = 0

        func append<C: Collection>(_ bytes: C) where C.Element == UInt8 {
            guard !discardingOversizedLine else { return }
            let incomingCount = bytes.count
            guard incomingCount <= maximumLineBytes - pending.count else {
                discardingOversizedLine = true
                pending.removeAll(keepingCapacity: false)
                return
            }
            pending.append(contentsOf: bytes)
        }

        func finishLine() {
            if discardingOversizedLine {
                nonEmptyLineNumber += 1
                metrics.rowsVisited += 1
                metrics.oversizedRows += 1
                onOversizedLine(nonEmptyLineNumber, maximumLineBytes)
                discardingOversizedLine = false
                return
            }
            guard !pending.isEmpty else { return }
            nonEmptyLineNumber += 1
            metrics.rowsVisited += 1
            onLine(pending, nonEmptyLineNumber)
            pending.removeAll(keepingCapacity: true)
        }

        while true {
            guard shouldContinue() else {
                metrics.wasCancelled = true
                break
            }
            let requestedCount: Int
            let remaining = readCeiling - metrics.bytesRead
            guard remaining > 0 else {
                if let callerByteLimit {
                    metrics.reachedByteLimit = sourceByteCount > callerByteLimit
                }
                break
            }
            requestedCount = min(chunkSize, Int(min(remaining, Int64(Int.max))))
            guard let chunk = try handle.read(upToCount: requestedCount), !chunk.isEmpty else {
                break
            }
            metrics.bytesRead += Int64(chunk.count)
            metrics.peakBufferedBytes = max(metrics.peakBufferedBytes, pending.count + chunk.count)

            var segmentStart = chunk.startIndex
            while segmentStart < chunk.endIndex,
                let newline = chunk[segmentStart...].firstIndex(of: 0x0A)
            {
                append(chunk[segmentStart..<newline])
                finishLine()
                segmentStart = chunk.index(after: newline)
            }
            if segmentStart < chunk.endIndex {
                append(chunk[segmentStart..<chunk.endIndex])
            }
            metrics.peakBufferedBytes = max(metrics.peakBufferedBytes, pending.count + chunk.count)
        }

        if !metrics.reachedByteLimit, !metrics.wasCancelled,
            discardingOversizedLine || !pending.isEmpty
        {
            finishLine()
        }
        var finalStat = stat()
        if fstat(descriptor, &finalStat) == 0 {
            metrics.sourceChangedDuringRead =
                metrics.sourceChangedDuringRead || !matchesInitialIdentity(finalStat)
        } else {
            metrics.sourceChangedDuringRead = true
        }
        metrics.sourceChangedDuringRead =
            metrics.sourceChangedDuringRead
            || !historyPathReferencesPinnedRegularFile(
                file,
                device: sourceDevice,
                inode: sourceInode
            )
        return metrics
    }
}

/// Stable, read-only filesystem adapter for ChatGPT, Codex and a future MCP server.
/// It never asks for Accessibility/Input Monitoring and never mutates recorder files.
public struct HistoryLocalStoreReader {
    private static let maximumComputerHistoryIssues = 256
    private static let maximumSourceSearchDirectoryEntries = 8_192
    private static let maximumSourceSearchFiles = 4_096

    public let rootDirectory: URL

    public init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory.standardizedFileURL
    }

    public var eventsDirectory: URL {
        rootDirectory.appendingPathComponent("events", isDirectory: true)
    }

    public var memoriesDirectory: URL {
        rootDirectory.appendingPathComponent("memories", isDirectory: true)
    }

    public var analysisDirectory: URL {
        rootDirectory.appendingPathComponent("analysis", isDirectory: true)
    }

    public var semanticDirectory: URL {
        rootDirectory.appendingPathComponent("semantic", isDirectory: true)
    }

    public var captureHealthFile: URL {
        rootDirectory.appendingPathComponent("capture-health.json")
    }

    public func load(
        start: Date? = nil,
        end: Date? = nil
    ) -> HistoryLoadedData {
        var issues: [HistoryLoadIssue] = []
        let events = loadJSONLines(
            HistoryEvent.self,
            from: files(
                in: eventsDirectory,
                extensions: ["jsonl"],
                intersecting: start,
                end: end
            ),
            start: start,
            end: end,
            timestamp: { $0.timestamp },
            issues: &issues
        )
        let memories = loadJSONFiles(
            ActivityMemory.self,
            from: files(
                in: memoriesDirectory,
                extensions: ["json"],
                intersecting: start,
                end: end
            )
                + files(
                    in: analysisDirectory,
                    extensions: ["memory.json"],
                    intersecting: start,
                    end: end
                ),
            issues: &issues
        ).filter { memory in
            if let start, memory.end < start { return false }
            if let end, memory.start > end { return false }
            return true
        }
        let semanticRows =
            loadJSONLines(
                SemanticContextPayload.self,
                from: files(
                    in: semanticDirectory,
                    extensions: ["jsonl"],
                    intersecting: start,
                    end: end
                ),
                start: start,
                end: end,
                timestamp: { $0.capturedAt },
                issues: &issues
            )
            + loadJSONFiles(
                SemanticContextPayload.self,
                from: files(
                    in: semanticDirectory,
                    extensions: ["json"],
                    intersecting: start,
                    end: end
                ),
                issues: &issues
            ).filter { payload in
                if let start, payload.capturedAt < start { return false }
                if let end, payload.capturedAt > end { return false }
                return true
            }

        var semantic: [String: SemanticContextPayload] = [:]
        var conflictingSemanticIDs = Set<String>()
        for row in semanticRows.sorted(by: {
            if $0.capturedAt == $1.capturedAt { return $0.id < $1.id }
            return $0.capturedAt < $1.capturedAt
        }) {
            guard !conflictingSemanticIDs.contains(row.id) else { continue }
            if let existing = semantic[row.id] {
                guard existing != row else { continue }
                semantic.removeValue(forKey: row.id)
                conflictingSemanticIDs.insert(row.id)
            } else {
                semantic[row.id] = row
            }
        }
        if !conflictingSemanticIDs.isEmpty {
            issues.append(
                HistoryLoadIssue(
                    path: semanticDirectory.path,
                    line: nil,
                    message:
                        "Omitted \(conflictingSemanticIDs.count) semantic snapshot identifier(s) with conflicting duplicate contents."
                )
            )
        }

        let health: CaptureHealthSnapshot? = {
            guard FileManager.default.fileExists(atPath: captureHealthFile.path) else { return nil }
            do {
                return try decoder().decode(CaptureHealthSnapshot.self, from: Data(contentsOf: captureHealthFile))
            } catch {
                issues.append(
                    HistoryLoadIssue(
                        path: captureHealthFile.path,
                        line: nil,
                        message: "Could not decode capture health: \(error)"
                    )
                )
                return nil
            }
        }()

        return HistoryLoadedData(
            events: events.sorted { $0.timestamp < $1.timestamp },
            memories: memories.sorted { $0.start < $1.start },
            semanticSnapshots: semantic,
            captureHealth: health,
            issues: issues
        )
    }

    /// Streams a half-open source interval and retains only events that can
    /// influence Computer History. Callers reconstructing multiple days should
    /// invoke this once per day so peak memory is bounded by one day's useful
    /// evidence rather than the complete retention horizon.
    package func loadComputerHistoryEvidence(
        start: Date,
        endExclusive: Date,
        limits rawLimits: ComputerHistoryEvidenceLoadLimits = .production,
        shouldContinue: () -> Bool = { true }
    ) -> ComputerHistoryEvidenceLoad {
        loadBoundedDerivedEvidence(
            start: start,
            endExclusive: endExclusive,
            projection: .computerHistory,
            limits: rawLimits,
            shouldContinue: shouldContinue
        )
    }

    /// Uses the same bounded, stable direct-source read as Computer History but
    /// retains the additional classification, input-origin and metadata fields
    /// consumed by the compact activity-memory summarizer.
    package func loadActivityMemoryEvidence(
        start: Date,
        endExclusive: Date,
        limits rawLimits: ComputerHistoryEvidenceLoadLimits = .production,
        shouldContinue: () -> Bool = { true }
    ) -> ComputerHistoryEvidenceLoad {
        loadBoundedDerivedEvidence(
            start: start,
            endExclusive: endExclusive,
            projection: .activityMemory,
            limits: rawLimits,
            shouldContinue: shouldContinue
        )
    }

    private enum BoundedDerivedEvidenceProjection {
        case computerHistory
        case activityMemory

        func project(_ event: HistoryEvent) -> HistoryEvent? {
            switch self {
            case .computerHistory:
                guard event.isComputerHistoryEvidence else { return nil }
                return event.compactedForComputerHistoryAnalysis
            case .activityMemory:
                guard event.isDerivedAnalysisEvidence else { return nil }
                return event.compactedForDerivedAnalysis
            }
        }
    }

    private func loadBoundedDerivedEvidence(
        start: Date,
        endExclusive: Date,
        projection: BoundedDerivedEvidenceProjection,
        limits rawLimits: ComputerHistoryEvidenceLoadLimits,
        shouldContinue: () -> Bool
    ) -> ComputerHistoryEvidenceLoad {
        guard endExclusive > start else {
            return ComputerHistoryEvidenceLoad(
                events: [],
                semanticSnapshots: [:],
                sourceJournalSummary: ComputerHistorySourceJournalSummary(
                    eventCount: 0,
                    continuityBoundaryCount: 0,
                    firstSourceSequence: nil,
                    lastSourceSequence: nil,
                    lastSourceEventHash: nil
                ),
                issues: [],
                metrics: ComputerHistoryEvidenceLoadMetrics(
                    eventBytesRead: 0,
                    semanticBytesRead: 0,
                    peakStreamBufferBytes: 0,
                    rawEventCount: 0,
                    retainedEventCount: 0,
                    retainedEventBytes: 0,
                    semanticRowsVisited: 0,
                    retainedSemanticSnapshotCount: 0,
                    retainedSemanticSnapshotBytes: 0
                )
            )
        }

        var issues: [HistoryLoadIssue] = []
        var events: [HistoryEvent] = []
        var rawEventCount = 0
        var continuityBoundaryCount = 0
        struct IntegrityBoundary {
            let timestamp: Date
            let eventID: String
            let sequence: UInt64
            let eventHash: String

            init(event: HistoryEvent, integrity: EventIntegrity) {
                timestamp = event.timestamp
                eventID = event.id
                sequence = integrity.sequence
                eventHash = integrity.eventHash
            }

            static func precedes(_ left: Self, _ right: Self) -> Bool {
                if left.timestamp == right.timestamp { return left.eventID < right.eventID }
                return left.timestamp < right.timestamp
            }
        }
        var firstIntegrityBoundary: IntegrityBoundary?
        var lastIntegrityBoundary: IntegrityBoundary?
        var eventBytesRead: Int64 = 0
        var retainedEventBytes: Int64 = 0
        var semanticBytesRead: Int64 = 0
        var retainedSemanticSnapshotBytes: Int64 = 0
        var semanticRowsVisited = 0
        var peakStreamBufferBytes = 0
        var wasCancelled = false
        var sourceChangedDuringRead = false
        var sourceAccessWasIncomplete = false
        var evidenceBudgetExceeded = false
        var retainedEvidenceRowCount = 0
        var retainedEvidenceBytes: Int64 = 0
        let limits = rawLimits.validated
        let rowDecoder = decoder()
        let evidenceEncoder = JSONEncoder()
        evidenceEncoder.dateEncodingStrategy = .iso8601
        evidenceEncoder.outputFormatting = [.sortedKeys]
        let streamReader = HistoryJSONLinesStreamReader()
        var pinnedSourceRoot: HistoryPinnedSourceDirectory?
        var pinnedEventsDirectory: HistoryPinnedSourceDirectory?
        var pinnedSemanticDirectory: HistoryPinnedSourceDirectory?
        var pinnedReadFiles:
            [(
                file: HistoryPinnedSourceFile,
                identity: HistoryPinnedRegularFileIdentity
            )] = []

        func recordCancellationIfNeeded() {
            guard !wasCancelled else { return }
            wasCancelled = true
            appendComputerHistoryIssue(
                HistoryLoadIssue(
                    path: rootDirectory.path,
                    line: nil,
                    message: "Computer History evidence loading stopped at the caller's time budget."
                ),
                to: &issues
            )
        }

        func recordSourceAccessIssue(_ error: Error, path: String) {
            sourceAccessWasIncomplete = true
            appendComputerHistoryIssue(
                HistoryLoadIssue(
                    path: path,
                    line: nil,
                    message:
                        "Computer History source access was incomplete; the day projection was rejected: \(error.localizedDescription)"
                ),
                to: &issues
            )
        }

        func recordSourceContentIssue(
            path: String,
            line: Int?,
            message: String
        ) {
            sourceAccessWasIncomplete = true
            appendComputerHistoryIssue(
                HistoryLoadIssue(
                    path: path,
                    line: line,
                    message:
                        "Computer History source content was incomplete; the day projection was rejected: \(message)"
                ),
                to: &issues
            )
        }

        func revalidate(_ directory: HistoryPinnedSourceDirectory?) {
            guard let directory, !directory.isStable() else { return }
            sourceChangedDuringRead = true
            appendComputerHistoryIssue(
                HistoryLoadIssue(
                    path: directory.url.path,
                    line: nil,
                    message:
                        "Computer History source directory changed during read; the day projection was rejected."
                ),
                to: &issues
            )
        }

        func reserveEvidence(rowBytes: Int, inlineBytes: Int) -> Bool {
            guard !evidenceBudgetExceeded else { return false }
            let boundedBytes =
                Int64(max(0, rowBytes))
                + Int64(max(0, inlineBytes))
                + 256
            guard retainedEvidenceRowCount < limits.maximumRetainedRows,
                boundedBytes <= limits.maximumRetainedBytes - retainedEvidenceBytes
            else {
                evidenceBudgetExceeded = true
                appendComputerHistoryIssue(
                    HistoryLoadIssue(
                        path: rootDirectory.path,
                        line: nil,
                        message:
                            "Computer History retained-evidence budget exceeded (\(limits.maximumRetainedRows) rows or \(limits.maximumRetainedBytes) bytes); the day projection was rejected."
                    ),
                    to: &issues
                )
                return false
            }
            retainedEvidenceRowCount += 1
            retainedEvidenceBytes += boundedBytes
            return true
        }

        func continueEvidenceLoading() -> Bool {
            !sourceAccessWasIncomplete && !evidenceBudgetExceeded && shouldContinue()
        }

        var eventFiles: [HistoryPinnedSourceFile] = []
        do {
            let sourceRoot = try HistoryPinnedSourceDirectory(rootURL: rootDirectory)
            let eventsSource = try HistoryPinnedSourceDirectory(
                parent: sourceRoot,
                name: "events"
            )
            eventFiles = try eventsSource.matchingFiles(extensions: ["jsonl"])
                .filter { file in
                    guard let interval = localDayInterval(from: file.name) else { return true }
                    return interval.end > start && interval.start < endExclusive
                }
            pinnedSourceRoot = sourceRoot
            pinnedEventsDirectory = eventsSource
        } catch {
            recordSourceAccessIssue(error, path: eventsDirectory.path)
        }

        for sourceFile in eventFiles {
            let file = sourceFile.url
            guard shouldContinue() else {
                recordCancellationIfNeeded()
                break
            }
            do {
                let streamMetrics = try streamReader.read(
                    file: file,
                    directoryDescriptor: sourceFile.directory.descriptor,
                    relativeName: sourceFile.name,
                    shouldContinue: continueEvidenceLoading,
                    onLine: { rawLine, lineNumber in
                        autoreleasepool {
                            guard !sourceAccessWasIncomplete, !evidenceBudgetExceeded else {
                                return
                            }
                            do {
                                let event = try rowDecoder.decode(HistoryEvent.self, from: rawLine)
                                guard event.timestamp >= start, event.timestamp < endExclusive else { return }
                                rawEventCount += 1
                                if event.isObservationContinuityBoundary {
                                    continuityBoundaryCount += 1
                                }
                                if let integrity = event.integrity {
                                    let boundary = IntegrityBoundary(
                                        event: event,
                                        integrity: integrity
                                    )
                                    if let currentFirst = firstIntegrityBoundary {
                                        if IntegrityBoundary.precedes(boundary, currentFirst) {
                                            firstIntegrityBoundary = boundary
                                        }
                                    } else {
                                        firstIntegrityBoundary = boundary
                                    }
                                    if let currentLast = lastIntegrityBoundary {
                                        if IntegrityBoundary.precedes(currentLast, boundary) {
                                            lastIntegrityBoundary = boundary
                                        }
                                    } else {
                                        lastIntegrityBoundary = boundary
                                    }
                                }
                                guard let compactedEvent = projection.project(event) else { return }
                                let compactedBytes = try evidenceEncoder.encode(compactedEvent).count
                                guard
                                    reserveEvidence(
                                        rowBytes: compactedBytes,
                                        inlineBytes: MemoryLayout<HistoryEvent>.stride
                                    )
                                else { return }
                                events.append(compactedEvent)
                                retainedEventBytes += Int64(compactedBytes)
                            } catch {
                                recordSourceContentIssue(
                                    path: file.path,
                                    line: lineNumber,
                                    message: "could not decode event JSONL row: \(error)"
                                )
                            }
                        }
                    },
                    onOversizedLine: { lineNumber, maximumBytes in
                        recordSourceContentIssue(
                            path: file.path,
                            line: lineNumber,
                            message:
                                "event JSONL row exceeds the \(maximumBytes)-byte safety limit"
                        )
                    }
                )
                eventBytesRead += streamMetrics.bytesRead
                peakStreamBufferBytes = max(peakStreamBufferBytes, streamMetrics.peakBufferedBytes)
                if let identity = streamMetrics.pinnedIdentity {
                    pinnedReadFiles.append((sourceFile, identity))
                } else {
                    recordSourceContentIssue(
                        path: file.path,
                        line: nil,
                        message: "the pinned file identity was unavailable"
                    )
                }
                if streamMetrics.sourceChangedDuringRead {
                    sourceChangedDuringRead = true
                    appendComputerHistoryIssue(
                        HistoryLoadIssue(
                            path: file.path,
                            line: nil,
                            message:
                                "Computer History event source changed during read; the day projection was rejected."
                        ),
                        to: &issues
                    )
                    break
                }
                if sourceAccessWasIncomplete { break }
                if evidenceBudgetExceeded { break }
                if streamMetrics.wasCancelled {
                    recordCancellationIfNeeded()
                    break
                }
            } catch {
                sourceAccessWasIncomplete = true
                appendComputerHistoryIssue(
                    HistoryLoadIssue(
                        path: file.path,
                        line: nil,
                        message:
                            "Could not read Computer History JSONL from its pinned source directory; the day projection was rejected: \(error.localizedDescription)"
                    ),
                    to: &issues
                )
                break
            }
        }

        let referencedSemanticIDs = Set(
            events.compactMap { event -> String? in
                guard event.suppressionReason == nil,
                    !event.isObservationContinuityBoundary
                else { return nil }
                return event.semanticContext?.snapshotID
            }
        )
        var semanticSnapshots: [String: SemanticContextPayload] = [:]

        if !referencedSemanticIDs.isEmpty, !wasCancelled, !sourceChangedDuringRead,
            !sourceAccessWasIncomplete, !evidenceBudgetExceeded
        {
            var semanticFiles: [HistoryPinnedSourceFile] = []
            do {
                guard let sourceRoot = pinnedSourceRoot else {
                    throw HistoryPinnedDirectoryError.changed(path: rootDirectory.path)
                }
                let semanticSource = try HistoryPinnedSourceDirectory(
                    parent: sourceRoot,
                    name: "semantic"
                )
                semanticFiles = try semanticSource.matchingFiles(
                    extensions: ["jsonl", "json"]
                ).filter { file in
                    guard let interval = localDayInterval(from: file.name) else { return true }
                    return interval.end > start && interval.start < endExclusive
                }
                pinnedSemanticDirectory = semanticSource
            } catch HistoryPinnedDirectoryError.absent {
                // Semantic plaintext has its own retention lifecycle. Detailed
                // events remain valid evidence when that optional store is absent.
            } catch {
                recordSourceAccessIssue(error, path: semanticDirectory.path)
            }
            let semanticJSONLFiles = semanticFiles.filter {
                $0.name.lowercased().hasSuffix(".jsonl")
            }
            for sourceFile in semanticJSONLFiles where !sourceAccessWasIncomplete {
                let file = sourceFile.url
                guard shouldContinue() else {
                    recordCancellationIfNeeded()
                    break
                }
                do {
                    let streamMetrics = try streamReader.read(
                        file: file,
                        directoryDescriptor: sourceFile.directory.descriptor,
                        relativeName: sourceFile.name,
                        shouldContinue: continueEvidenceLoading,
                        onLine: { rawLine, lineNumber in
                            autoreleasepool {
                                guard !sourceAccessWasIncomplete, !evidenceBudgetExceeded else {
                                    return
                                }
                                do {
                                    let payload = try rowDecoder.decode(SemanticContextPayload.self, from: rawLine)
                                    guard payload.capturedAt >= start, payload.capturedAt < endExclusive else {
                                        return
                                    }
                                    guard referencedSemanticIDs.contains(payload.id) else { return }
                                    if let existing = semanticSnapshots[payload.id] {
                                        guard existing != payload else { return }
                                        recordSourceContentIssue(
                                            path: file.path,
                                            line: lineNumber,
                                            message:
                                                "duplicate semantic payload identifier has conflicting contents"
                                        )
                                        return
                                    }
                                    let retainedBytes = try evidenceEncoder.encode(payload).count
                                    guard
                                        reserveEvidence(
                                            rowBytes: retainedBytes,
                                            inlineBytes: MemoryLayout<SemanticContextPayload>.stride
                                        )
                                    else { return }
                                    retainedSemanticSnapshotBytes += Int64(retainedBytes)
                                    semanticSnapshots[payload.id] = payload
                                } catch {
                                    recordSourceContentIssue(
                                        path: file.path,
                                        line: lineNumber,
                                        message: "could not decode semantic JSONL row: \(error)"
                                    )
                                }
                            }
                        },
                        onOversizedLine: { lineNumber, maximumBytes in
                            recordSourceContentIssue(
                                path: file.path,
                                line: lineNumber,
                                message:
                                    "semantic JSONL row exceeds the \(maximumBytes)-byte safety limit"
                            )
                        }
                    )
                    semanticBytesRead += streamMetrics.bytesRead
                    semanticRowsVisited += streamMetrics.rowsVisited
                    peakStreamBufferBytes = max(peakStreamBufferBytes, streamMetrics.peakBufferedBytes)
                    if let identity = streamMetrics.pinnedIdentity {
                        pinnedReadFiles.append((sourceFile, identity))
                    } else {
                        recordSourceContentIssue(
                            path: file.path,
                            line: nil,
                            message: "the pinned file identity was unavailable"
                        )
                    }
                    if streamMetrics.sourceChangedDuringRead {
                        sourceChangedDuringRead = true
                        appendComputerHistoryIssue(
                            HistoryLoadIssue(
                                path: file.path,
                                line: nil,
                                message:
                                    "Computer History semantic source changed during read; the day projection was rejected."
                            ),
                            to: &issues
                        )
                        break
                    }
                    if sourceAccessWasIncomplete { break }
                    if evidenceBudgetExceeded { break }
                    if streamMetrics.wasCancelled {
                        recordCancellationIfNeeded()
                        break
                    }
                } catch {
                    sourceAccessWasIncomplete = true
                    appendComputerHistoryIssue(
                        HistoryLoadIssue(
                            path: file.path,
                            line: nil,
                            message:
                                "Could not read Computer History semantic JSONL from its pinned source directory; the day projection was rejected: \(error.localizedDescription)"
                        ),
                        to: &issues
                    )
                    break
                }
            }

            let semanticJSONFiles = semanticFiles.filter {
                $0.name.lowercased().hasSuffix(".json")
            }
            for sourceFile in semanticJSONFiles
            where !wasCancelled && !sourceChangedDuringRead && !sourceAccessWasIncomplete
                && !evidenceBudgetExceeded
            {
                let file = sourceFile.url
                guard shouldContinue() else {
                    recordCancellationIfNeeded()
                    break
                }
                do {
                    var pinnedIdentity: HistoryPinnedRegularFileIdentity?
                    let raw = try readBoundedFile(
                        file,
                        directoryDescriptor: sourceFile.directory.descriptor,
                        relativeName: sourceFile.name,
                        maximumBytes: HistoryJSONLinesStreamReader.defaultMaximumLineBytes,
                        shouldContinue: continueEvidenceLoading,
                        onPinnedIdentity: { pinnedIdentity = $0 }
                    )
                    if let pinnedIdentity {
                        pinnedReadFiles.append((sourceFile, pinnedIdentity))
                    } else {
                        recordSourceContentIssue(
                            path: file.path,
                            line: nil,
                            message: "the pinned file identity was unavailable"
                        )
                        break
                    }
                    guard shouldContinue() else {
                        recordCancellationIfNeeded()
                        break
                    }
                    semanticBytesRead += Int64(raw.count)
                    peakStreamBufferBytes = max(peakStreamBufferBytes, raw.count)
                    let payload = try rowDecoder.decode(SemanticContextPayload.self, from: raw)
                    semanticRowsVisited += 1
                    guard payload.capturedAt >= start, payload.capturedAt < endExclusive else { continue }
                    guard referencedSemanticIDs.contains(payload.id) else { continue }
                    if let existing = semanticSnapshots[payload.id] {
                        guard existing != payload else { continue }
                        recordSourceContentIssue(
                            path: file.path,
                            line: nil,
                            message:
                                "duplicate semantic payload identifier has conflicting contents"
                        )
                        break
                    }
                    let retainedBytes = try evidenceEncoder.encode(payload).count
                    guard
                        reserveEvidence(
                            rowBytes: retainedBytes,
                            inlineBytes: MemoryLayout<SemanticContextPayload>.stride
                        )
                    else { break }
                    retainedSemanticSnapshotBytes += Int64(retainedBytes)
                    semanticSnapshots[payload.id] = payload
                } catch HistoryBoundedFileReadError.changedDuringRead {
                    sourceChangedDuringRead = true
                    appendComputerHistoryIssue(
                        HistoryLoadIssue(
                            path: file.path,
                            line: nil,
                            message:
                                "Computer History semantic source changed during read; the day projection was rejected."
                        ),
                        to: &issues
                    )
                    break
                } catch HistoryBoundedFileReadError.cancelled {
                    if !evidenceBudgetExceeded {
                        recordCancellationIfNeeded()
                    }
                    break
                } catch HistoryBoundedFileReadError.exceedsLimit {
                    recordSourceContentIssue(
                        path: file.path,
                        line: nil,
                        message:
                            "semantic JSON file exceeds the \(HistoryJSONLinesStreamReader.defaultMaximumLineBytes)-byte safety limit"
                    )
                    break
                } catch {
                    if error is DecodingError {
                        recordSourceContentIssue(
                            path: file.path,
                            line: nil,
                            message: "could not decode semantic JSON file: \(error)"
                        )
                        break
                    } else {
                        recordSourceAccessIssue(error, path: file.path)
                        break
                    }
                }
            }
        }

        for pinnedReadFile in pinnedReadFiles
        where !pinnedReadFile.file.isStable(relativeTo: pinnedReadFile.identity) {
            sourceChangedDuringRead = true
            appendComputerHistoryIssue(
                HistoryLoadIssue(
                    path: pinnedReadFile.file.url.path,
                    line: nil,
                    message:
                        "Computer History source file changed after its initial read; the whole-day projection was rejected."
                ),
                to: &issues
            )
        }
        revalidate(pinnedSemanticDirectory)
        revalidate(pinnedEventsDirectory)
        revalidate(pinnedSourceRoot)

        let projectionWasRejected =
            sourceChangedDuringRead || sourceAccessWasIncomplete || evidenceBudgetExceeded
        let acceptedEvents = projectionWasRejected ? [] : events
        let acceptedSemanticSnapshots = projectionWasRejected ? [:] : semanticSnapshots
        let sourceJournalSummary =
            projectionWasRejected
            ? ComputerHistorySourceJournalSummary(
                eventCount: 0,
                continuityBoundaryCount: 0,
                firstSourceSequence: nil,
                lastSourceSequence: nil,
                lastSourceEventHash: nil
            )
            : ComputerHistorySourceJournalSummary(
                eventCount: rawEventCount,
                continuityBoundaryCount: continuityBoundaryCount,
                firstSourceSequence: firstIntegrityBoundary?.sequence,
                lastSourceSequence: lastIntegrityBoundary?.sequence,
                lastSourceEventHash: lastIntegrityBoundary?.eventHash
            )
        return ComputerHistoryEvidenceLoad(
            events: acceptedEvents,
            semanticSnapshots: acceptedSemanticSnapshots,
            sourceJournalSummary: sourceJournalSummary,
            issues: issues,
            metrics: ComputerHistoryEvidenceLoadMetrics(
                eventBytesRead: eventBytesRead,
                semanticBytesRead: semanticBytesRead,
                peakStreamBufferBytes: peakStreamBufferBytes,
                rawEventCount: rawEventCount,
                retainedEventCount: acceptedEvents.count,
                retainedEventBytes: projectionWasRejected ? 0 : retainedEventBytes,
                semanticRowsVisited: semanticRowsVisited,
                retainedSemanticSnapshotCount: acceptedSemanticSnapshots.count,
                retainedSemanticSnapshotBytes: projectionWasRejected
                    ? 0
                    : retainedSemanticSnapshotBytes,
                wasCancelled: wasCancelled,
                sourceChangedDuringRead: sourceChangedDuringRead,
                sourceAccessWasIncomplete: sourceAccessWasIncomplete,
                evidenceBudgetExceeded: evidenceBudgetExceeded,
                peakRetainedEvidenceRows: retainedEvidenceRowCount,
                peakEstimatedRetainedEvidenceBytes: retainedEvidenceBytes
            )
        )
    }

    /// Performs a lexical fallback directly against the original journals. Rows
    /// are decoded one at a time and only a bounded result set survives the pass;
    /// no auxiliary search index, cache or source copy is written.
    package func searchComputerHistorySource(
        query: String,
        start: Date,
        endExclusive: Date,
        maximumHits: Int = 100,
        limits rawLimits: ComputerHistorySourceSearchLimits = .production
    ) -> ComputerHistorySourceSearchResult {
        var accumulator = ComputerHistorySourceSearchAccumulator(
            query: query,
            start: start,
            endExclusive: endExclusive,
            maximumHits: maximumHits
        )
        guard endExclusive > start else { return accumulator.result() }

        let limits = rawLimits.validated
        let deadlineUptime =
            ProcessInfo.processInfo.systemUptime
            + limits.maximumElapsedSeconds
        let rowDecoder = decoder()
        let streamReader = HistoryJSONLinesStreamReader()
        var semanticBytesRemaining = limits.maximumSemanticBytes
        var eventBytesRemaining = limits.maximumEventBytes
        var timeBudgetIssueRecorded = false

        func hasTimeRemaining() -> Bool {
            ProcessInfo.processInfo.systemUptime < deadlineUptime
        }

        func recordTimeBudgetIssueIfNeeded() {
            guard !timeBudgetIssueRecorded else { return }
            timeBudgetIssueRecorded = true
            accumulator.recordIssue(
                HistoryLoadIssue(
                    path: rootDirectory.path,
                    line: nil,
                    message: "Raw-source search stopped at the \(limits.maximumElapsedSeconds)-second time budget."
                )
            )
        }

        let sourceRoot: HistoryPinnedSourceDirectory
        do {
            sourceRoot = try HistoryPinnedSourceDirectory(rootURL: rootDirectory)
        } catch {
            accumulator.recordIssue(
                HistoryLoadIssue(
                    path: rootDirectory.path,
                    line: nil,
                    message: "Could not pin raw-source root safely: \(error.localizedDescription)"
                )
            )
            return accumulator.result()
        }
        var pinnedSearchFiles:
            [(
                file: HistoryPinnedSourceFile,
                identity: HistoryPinnedRegularFileIdentity
            )] = []
        var semanticSourceDirectory: HistoryPinnedSourceDirectory?
        var eventSourceDirectory: HistoryPinnedSourceDirectory?
        var semanticFiles: [HistoryPinnedSourceFile] = []
        do {
            let directory = try HistoryPinnedSourceDirectory(
                parent: sourceRoot,
                name: "semantic"
            )
            semanticFiles = try directory.matchingFiles(
                extensions: ["jsonl", "json"],
                maximumEntries: Self.maximumSourceSearchDirectoryEntries,
                maximumMatchingFiles: Self.maximumSourceSearchFiles,
                shouldContinue: hasTimeRemaining
            ).filter { file in
                guard let interval = localDayInterval(from: file.name) else { return true }
                return interval.end > start && interval.start < endExclusive
            }
            semanticSourceDirectory = directory
        } catch HistoryPinnedDirectoryError.absent {
            // Semantic journals are optional when no semantic capture was produced.
        } catch {
            accumulator.recordIssue(
                HistoryLoadIssue(
                    path: semanticDirectory.path,
                    line: nil,
                    message: "Could not pin raw semantic source safely: \(error.localizedDescription)"
                )
            )
        }
        var eventFiles: [HistoryPinnedSourceFile] = []
        do {
            let directory = try HistoryPinnedSourceDirectory(
                parent: sourceRoot,
                name: "events"
            )
            eventFiles = try directory.matchingFiles(
                extensions: ["jsonl"],
                maximumEntries: Self.maximumSourceSearchDirectoryEntries,
                maximumMatchingFiles: Self.maximumSourceSearchFiles,
                shouldContinue: hasTimeRemaining
            ).filter { file in
                guard let interval = localDayInterval(from: file.name) else { return true }
                return interval.end > start && interval.start < endExclusive
            }
            eventSourceDirectory = directory
        } catch {
            accumulator.recordIssue(
                HistoryLoadIssue(
                    path: eventsDirectory.path,
                    line: nil,
                    message: "Could not pin required raw event source safely: \(error.localizedDescription)"
                )
            )
        }
        let semanticJSONLFiles = semanticFiles.filter {
            $0.name.lowercased().hasSuffix(".jsonl")
        }
        for sourceFile in semanticJSONLFiles {
            let file = sourceFile.url
            guard hasTimeRemaining() else {
                recordTimeBudgetIssueIfNeeded()
                break
            }
            guard semanticBytesRemaining > 0 else {
                accumulator.recordIssue(
                    HistoryLoadIssue(
                        path: semanticDirectory.path,
                        line: nil,
                        message:
                            "Raw-source semantic search stopped at the \(limits.maximumSemanticBytes)-byte cumulative budget."
                    )
                )
                break
            }
            do {
                let streamMetrics = try streamReader.read(
                    file: file,
                    directoryDescriptor: sourceFile.directory.descriptor,
                    relativeName: sourceFile.name,
                    maximumBytes: semanticBytesRemaining,
                    shouldContinue: hasTimeRemaining,
                    onLine: { rawLine, lineNumber in
                        autoreleasepool {
                            do {
                                let payload = try rowDecoder.decode(
                                    SemanticContextPayload.self,
                                    from: rawLine
                                )
                                accumulator.consume(payload)
                            } catch {
                                accumulator.recordIssue(
                                    HistoryLoadIssue(
                                        path: file.path,
                                        line: lineNumber,
                                        message: "Could not decode semantic JSONL row: \(error)"
                                    )
                                )
                            }
                        }
                    },
                    onOversizedLine: { lineNumber, maximumBytes in
                        accumulator.recordIssue(
                            HistoryLoadIssue(
                                path: file.path,
                                line: lineNumber,
                                message:
                                    "Could not search semantic JSONL row: row exceeds the \(maximumBytes)-byte safety limit"
                            )
                        )
                    }
                )
                accumulator.recordSemanticStream(
                    bytesRead: streamMetrics.bytesRead,
                    peakBufferedBytes: streamMetrics.peakBufferedBytes
                )
                if let identity = streamMetrics.pinnedIdentity {
                    pinnedSearchFiles.append((sourceFile, identity))
                } else {
                    accumulator.recordIssue(
                        HistoryLoadIssue(
                            path: file.path,
                            line: nil,
                            message: "Raw-source semantic identity was unavailable after search."
                        )
                    )
                }
                semanticBytesRemaining -= streamMetrics.bytesRead
                if streamMetrics.sourceChangedDuringRead {
                    accumulator.recordIssue(
                        HistoryLoadIssue(
                            path: file.path,
                            line: nil,
                            message:
                                "Raw-source semantic file changed during search; coverage is not a single stable snapshot."
                        )
                    )
                }
                if streamMetrics.reachedByteLimit {
                    accumulator.recordIssue(
                        HistoryLoadIssue(
                            path: file.path,
                            line: nil,
                            message:
                                "Raw-source semantic search stopped at the \(limits.maximumSemanticBytes)-byte cumulative budget."
                        )
                    )
                    break
                }
                if streamMetrics.wasCancelled {
                    recordTimeBudgetIssueIfNeeded()
                    break
                }
            } catch {
                accumulator.recordIssue(
                    HistoryLoadIssue(
                        path: file.path,
                        line: nil,
                        message: "Could not read semantic JSONL for search: \(error.localizedDescription)"
                    )
                )
            }
        }

        let semanticJSONFiles = semanticFiles.filter {
            $0.name.lowercased().hasSuffix(".json")
        }
        for sourceFile in semanticJSONFiles {
            let file = sourceFile.url
            guard hasTimeRemaining() else {
                recordTimeBudgetIssueIfNeeded()
                break
            }
            guard semanticBytesRemaining > 0 else {
                accumulator.recordIssue(
                    HistoryLoadIssue(
                        path: semanticDirectory.path,
                        line: nil,
                        message:
                            "Raw-source semantic search stopped at the \(limits.maximumSemanticBytes)-byte cumulative budget."
                    )
                )
                break
            }
            let maximumReadBytes = min(
                Int64(HistoryJSONLinesStreamReader.defaultMaximumLineBytes),
                semanticBytesRemaining
            )
            do {
                var pinnedIdentity: HistoryPinnedRegularFileIdentity?
                let raw = try readBoundedFile(
                    file,
                    directoryDescriptor: sourceFile.directory.descriptor,
                    relativeName: sourceFile.name,
                    maximumBytes: Int(maximumReadBytes),
                    shouldContinue: hasTimeRemaining,
                    onPinnedIdentity: { pinnedIdentity = $0 }
                )
                if let pinnedIdentity {
                    pinnedSearchFiles.append((sourceFile, pinnedIdentity))
                } else {
                    accumulator.recordIssue(
                        HistoryLoadIssue(
                            path: file.path,
                            line: nil,
                            message: "Raw-source semantic identity was unavailable after search."
                        )
                    )
                }
                let payload = try rowDecoder.decode(
                    SemanticContextPayload.self,
                    from: raw
                )
                accumulator.consume(payload)
                accumulator.recordSemanticStream(
                    bytesRead: Int64(raw.count),
                    peakBufferedBytes: raw.count
                )
                semanticBytesRemaining -= Int64(raw.count)
            } catch HistoryBoundedFileReadError.exceedsLimit
                where maximumReadBytes == semanticBytesRemaining
                && semanticBytesRemaining
                    < Int64(HistoryJSONLinesStreamReader.defaultMaximumLineBytes)
            {
                accumulator.recordIssue(
                    HistoryLoadIssue(
                        path: file.path,
                        line: nil,
                        message:
                            "Raw-source semantic search stopped at the \(limits.maximumSemanticBytes)-byte cumulative budget."
                    )
                )
                break
            } catch HistoryBoundedFileReadError.cancelled {
                recordTimeBudgetIssueIfNeeded()
                break
            } catch {
                accumulator.recordIssue(
                    HistoryLoadIssue(
                        path: file.path,
                        line: nil,
                        message: "Could not read semantic JSON for search: \(error)"
                    )
                )
            }
        }

        for sourceFile in eventFiles {
            let file = sourceFile.url
            guard hasTimeRemaining() else {
                recordTimeBudgetIssueIfNeeded()
                break
            }
            guard eventBytesRemaining > 0 else {
                accumulator.recordIssue(
                    HistoryLoadIssue(
                        path: eventsDirectory.path,
                        line: nil,
                        message:
                            "Raw-source event search stopped at the \(limits.maximumEventBytes)-byte cumulative budget."
                    )
                )
                break
            }
            do {
                let streamMetrics = try streamReader.read(
                    file: file,
                    directoryDescriptor: sourceFile.directory.descriptor,
                    relativeName: sourceFile.name,
                    maximumBytes: eventBytesRemaining,
                    shouldContinue: hasTimeRemaining,
                    onLine: { rawLine, lineNumber in
                        autoreleasepool {
                            do {
                                let event = try rowDecoder.decode(
                                    HistoryEvent.self,
                                    from: rawLine
                                )
                                accumulator.consume(event)
                            } catch {
                                accumulator.recordIssue(
                                    HistoryLoadIssue(
                                        path: file.path,
                                        line: lineNumber,
                                        message: "Could not decode event JSONL row for search: \(error)"
                                    )
                                )
                            }
                        }
                    },
                    onOversizedLine: { lineNumber, maximumBytes in
                        accumulator.recordIssue(
                            HistoryLoadIssue(
                                path: file.path,
                                line: lineNumber,
                                message:
                                    "Could not search event JSONL row: row exceeds the \(maximumBytes)-byte safety limit"
                            )
                        )
                    }
                )
                accumulator.recordEventStream(
                    bytesRead: streamMetrics.bytesRead,
                    peakBufferedBytes: streamMetrics.peakBufferedBytes
                )
                if let identity = streamMetrics.pinnedIdentity {
                    pinnedSearchFiles.append((sourceFile, identity))
                } else {
                    accumulator.recordIssue(
                        HistoryLoadIssue(
                            path: file.path,
                            line: nil,
                            message: "Raw-source event identity was unavailable after search."
                        )
                    )
                }
                eventBytesRemaining -= streamMetrics.bytesRead
                if streamMetrics.sourceChangedDuringRead {
                    accumulator.recordIssue(
                        HistoryLoadIssue(
                            path: file.path,
                            line: nil,
                            message:
                                "Raw-source event file changed during search; coverage is not a single stable snapshot."
                        )
                    )
                }
                if streamMetrics.reachedByteLimit {
                    accumulator.recordIssue(
                        HistoryLoadIssue(
                            path: file.path,
                            line: nil,
                            message:
                                "Raw-source event search stopped at the \(limits.maximumEventBytes)-byte cumulative budget."
                        )
                    )
                    break
                }
                if streamMetrics.wasCancelled {
                    recordTimeBudgetIssueIfNeeded()
                    break
                }
            } catch {
                accumulator.recordIssue(
                    HistoryLoadIssue(
                        path: file.path,
                        line: nil,
                        message: "Could not read event JSONL for search: \(error.localizedDescription)"
                    )
                )
            }
        }
        if !hasTimeRemaining() {
            recordTimeBudgetIssueIfNeeded()
        }
        for pinnedSearchFile in pinnedSearchFiles
        where !pinnedSearchFile.file.isStable(relativeTo: pinnedSearchFile.identity) {
            accumulator.recordIssue(
                HistoryLoadIssue(
                    path: pinnedSearchFile.file.url.path,
                    line: nil,
                    message:
                        "Raw-source file changed after its initial search pass; coverage is not a single stable snapshot."
                )
            )
        }
        for directory in [semanticSourceDirectory, eventSourceDirectory].compactMap({ $0 })
        where !directory.isStable() {
            accumulator.recordIssue(
                HistoryLoadIssue(
                    path: directory.url.path,
                    line: nil,
                    message:
                        "Raw-source directory changed during search; coverage is not a single stable snapshot."
                )
            )
        }
        if !sourceRoot.isStable() {
            accumulator.recordIssue(
                HistoryLoadIssue(
                    path: rootDirectory.path,
                    line: nil,
                    message:
                        "Raw-source root changed during search; coverage is not a single stable snapshot."
                )
            )
        }
        return accumulator.result()
    }

    private func appendComputerHistoryIssue(
        _ issue: HistoryLoadIssue,
        to issues: inout [HistoryLoadIssue]
    ) {
        guard issues.count < Self.maximumComputerHistoryIssues else { return }
        issues.append(issue)
    }

    private func readBoundedFile(
        _ fileURL: URL,
        directoryDescriptor: Int32? = nil,
        relativeName: String? = nil,
        maximumBytes: Int,
        shouldContinue: () -> Bool = { true },
        onPinnedIdentity: (HistoryPinnedRegularFileIdentity) -> Void = { _ in }
    ) throws -> Data {
        let boundedMaximum = max(0, maximumBytes)
        let descriptor: Int32
        if let directoryDescriptor, let relativeName,
            !relativeName.isEmpty, relativeName != ".", relativeName != "..",
            !relativeName.contains("/")
        {
            descriptor = relativeName.withCString {
                openat(
                    directoryDescriptor,
                    $0,
                    O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
                )
            }
        } else if directoryDescriptor == nil, relativeName == nil {
            descriptor = open(
                fileURL.path,
                O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
            )
        } else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(EINVAL),
                userInfo: [NSFilePathErrorKey: fileURL.path]
            )
        }
        guard descriptor >= 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSFilePathErrorKey: fileURL.path]
            )
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var sourceStat = stat()
        guard fstat(descriptor, &sourceStat) == 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSFilePathErrorKey: fileURL.path]
            )
        }
        guard (sourceStat.st_mode & S_IFMT) == S_IFREG else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(EINVAL),
                userInfo: [
                    NSFilePathErrorKey: fileURL.path,
                    NSLocalizedDescriptionKey: "raw-source path is not a regular file",
                ]
            )
        }
        guard sourceStat.st_size <= off_t(boundedMaximum) else {
            throw HistoryBoundedFileReadError.exceedsLimit(boundedMaximum)
        }
        let sourceDevice = sourceStat.st_dev
        let sourceInode = sourceStat.st_ino
        let sourceSize = sourceStat.st_size
        let sourceModificationTime = sourceStat.st_mtimespec
        let sourceChangeTime = sourceStat.st_ctimespec
        let pinnedIdentity = HistoryPinnedRegularFileIdentity(sourceStat)
        var raw = Data()
        raw.reserveCapacity(min(boundedMaximum, Int(sourceSize)))
        while raw.count < Int(sourceSize) {
            guard shouldContinue() else {
                throw HistoryBoundedFileReadError.cancelled
            }
            let requestedCount = min(
                HistoryJSONLinesStreamReader.defaultChunkSize,
                Int(sourceSize) - raw.count
            )
            guard let chunk = try handle.read(upToCount: requestedCount), !chunk.isEmpty else {
                break
            }
            raw.append(chunk)
        }
        guard fstat(descriptor, &sourceStat) == 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSFilePathErrorKey: fileURL.path]
            )
        }
        guard sourceStat.st_dev == sourceDevice,
            sourceStat.st_ino == sourceInode,
            sourceStat.st_size == sourceSize,
            sourceStat.st_mtimespec.tv_sec == sourceModificationTime.tv_sec,
            sourceStat.st_mtimespec.tv_nsec == sourceModificationTime.tv_nsec,
            sourceStat.st_ctimespec.tv_sec == sourceChangeTime.tv_sec,
            sourceStat.st_ctimespec.tv_nsec == sourceChangeTime.tv_nsec
        else {
            throw HistoryBoundedFileReadError.changedDuringRead
        }
        guard
            historyPathReferencesPinnedRegularFile(
                fileURL,
                device: sourceDevice,
                inode: sourceInode
            )
        else {
            throw HistoryBoundedFileReadError.changedDuringRead
        }
        guard sourceStat.st_size <= off_t(boundedMaximum),
            raw.count <= boundedMaximum
        else {
            throw HistoryBoundedFileReadError.exceedsLimit(boundedMaximum)
        }
        onPinnedIdentity(pinnedIdentity)
        return raw
    }

    private func files(
        in directory: URL,
        extensions: Set<String>,
        intersecting start: Date? = nil,
        end: Date? = nil
    ) -> [URL] {
        guard
            let rows = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        else { return [] }
        return rows.filter { url in
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                return false
            }
            let name = url.lastPathComponent.lowercased()
            guard extensions.contains(where: { suffix in name.hasSuffix(".\(suffix)") }) else {
                return false
            }
            guard let interval = localDayInterval(from: name) else {
                // Unknown legacy names remain readable; only proven-disjoint daily
                // files may be skipped without decoding their contents.
                return true
            }
            if let start, interval.end <= start { return false }
            if let end, interval.start > end { return false }
            return true
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func localDayInterval(from fileName: String) -> DateInterval? {
        guard fileName.utf8.count >= 10 else { return nil }
        let prefix = String(fileName.prefix(10))
        let pieces = prefix.split(separator: "-", omittingEmptySubsequences: false)
        guard pieces.count == 3,
            pieces[0].count == 4,
            pieces[1].count == 2,
            pieces[2].count == 2,
            let year = Int(pieces[0]),
            let month = Int(pieces[1]),
            let day = Int(pieces[2])
        else { return nil }
        var calendar = Calendar.current
        calendar.locale = Locale(identifier: "en_US_POSIX")
        guard let start = calendar.date(from: DateComponents(year: year, month: month, day: day)) else {
            return nil
        }
        let verified = calendar.dateComponents([.year, .month, .day], from: start)
        guard verified.year == year, verified.month == month, verified.day == day,
            let end = calendar.date(byAdding: .day, value: 1, to: start)
        else { return nil }
        return DateInterval(start: start, end: end)
    }

    private func loadJSONLines<T: Decodable>(
        _ type: T.Type,
        from files: [URL],
        start: Date?,
        end: Date?,
        timestamp: (T) -> Date,
        issues: inout [HistoryLoadIssue]
    ) -> [T] {
        var result: [T] = []
        let rowDecoder = decoder()
        let streamReader = HistoryJSONLinesStreamReader()
        for file in files {
            let resultCountBeforeFile = result.count
            do {
                let metrics = try streamReader.read(
                    file: file,
                    onLine: { rawLine, lineNumber in
                        autoreleasepool {
                            do {
                                let value = try rowDecoder.decode(T.self, from: rawLine)
                                let date = timestamp(value)
                                if let start, date < start { return }
                                if let end, date > end { return }
                                result.append(value)
                            } catch {
                                issues.append(
                                    HistoryLoadIssue(
                                        path: file.path,
                                        line: lineNumber,
                                        message: "Could not decode JSONL row: \(error)"
                                    )
                                )
                            }
                        }
                    },
                    onOversizedLine: { lineNumber, maximumBytes in
                        issues.append(
                            HistoryLoadIssue(
                                path: file.path,
                                line: lineNumber,
                                message: "Could not decode JSONL row: row exceeds the \(maximumBytes)-byte safety limit"
                            )
                        )
                    }
                )
                if metrics.sourceChangedDuringRead {
                    result.removeSubrange(resultCountBeforeFile..<result.count)
                    issues.append(
                        HistoryLoadIssue(
                            path: file.path,
                            line: nil,
                            message: "Source changed while JSONL was being read; rows from this file were discarded."
                        )
                    )
                }
            } catch {
                issues.append(
                    HistoryLoadIssue(
                        path: file.path,
                        line: nil,
                        message: "Could not read JSONL: \(error.localizedDescription)"
                    )
                )
            }
        }
        return result
    }

    private func loadJSONFiles<T: Decodable>(
        _ type: T.Type,
        from files: [URL],
        issues: inout [HistoryLoadIssue]
    ) -> [T] {
        files.compactMap { file in
            do {
                return try decoder().decode(T.self, from: Data(contentsOf: file))
            } catch {
                issues.append(
                    HistoryLoadIssue(
                        path: file.path,
                        line: nil,
                        message: "Could not decode JSON file: \(error)"
                    )
                )
                return nil
            }
        }
    }

    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { value in
            let container = try value.singleValueContainer()
            let raw = try container.decode(String.self)
            if let date = Self.fractionalISO.date(from: raw) ?? Self.basicISO.date(from: raw) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid ISO-8601 timestamp: \(raw)"
            )
        }
        return decoder
    }

    private static let fractionalISO: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let basicISO: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
