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

/// The minimal persisted state needed to assess recorder health. Keeping this
/// separate from `HistoryLoadedData` prevents lightweight status checks from
/// decoding the complete event, memory, and semantic retention horizon.
public struct CaptureHealthLoadResult {
    public let snapshot: CaptureHealthSnapshot?
    public let issues: [HistoryLoadIssue]

    public init(
        snapshot: CaptureHealthSnapshot?,
        issues: [HistoryLoadIssue]
    ) {
        self.snapshot = snapshot
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

package enum CurrentComputerHistoryMemoryState: String, Codable, Equatable {
    case current
    case absent
    case incompleteProjection
    case stale
    case inaccessible
}

/// Read-only fast path for a compact day projection that is proven to describe
/// the current append-only source tail. A miss is safe: callers fall back to the
/// authoritative journals without mutating either source.
package struct CurrentComputerHistoryMemoryLoad {
    package let memory: ComputerHistoryDayMemory?
    package let state: CurrentComputerHistoryMemoryState
    package let bytesRead: Int64
    package let issues: [HistoryLoadIssue]
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

    func matchesPathIdentity(_ value: stat) -> Bool {
        (value.st_mode & S_IFMT) == S_IFDIR
            && value.st_dev == device
            && value.st_ino == inode
    }

    func matchesSnapshot(_ value: stat) -> Bool {
        matchesPathIdentity(value)
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
        matchesPathIdentity(value)
            && value.st_size == size
            && value.st_mtimespec.tv_sec == modificationSeconds
            && value.st_mtimespec.tv_nsec == modificationNanoseconds
            && value.st_ctimespec.tv_sec == changeSeconds
            && value.st_ctimespec.tv_nsec == changeNanoseconds
    }

    func matchesPathIdentity(_ value: stat) -> Bool {
        (value.st_mode & S_IFMT) == S_IFREG
            && value.st_dev == device
            && value.st_ino == inode
    }
}

private struct HistoryPinnedFileView: Equatable {
    let identity: HistoryPinnedRegularFileIdentity
    let prefixByteCount: Int64
    let prefixFingerprint: String
    let permitsVerifiedAppendOnlyGrowth: Bool
}

/// A constant-memory digest of fixed-size source blocks. It is used only when
/// a pinned JSONL grows during a read, so an append can be distinguished from
/// an in-place edit without copying the source or retaining its contents.
private struct HistorySourcePrefixFingerprint {
    private static let blockSize = 64 * 1_024
    private var pending = Data()
    private var rolling = Data(repeating: 0, count: 32)
    private var byteCount: UInt64 = 0

    mutating func append(_ data: Data) {
        byteCount += UInt64(data.count)
        var cursor = data.startIndex
        while cursor < data.endIndex {
            let available = Self.blockSize - pending.count
            let end = data.index(
                cursor,
                offsetBy: min(available, data.distance(from: cursor, to: data.endIndex))
            )
            pending.append(contentsOf: data[cursor..<end])
            cursor = end
            if pending.count == Self.blockSize {
                fold(pending)
                pending.removeAll(keepingCapacity: true)
            }
        }
    }

    mutating func finalize() -> String {
        if !pending.isEmpty {
            fold(pending)
            pending.removeAll(keepingCapacity: false)
        }
        var material = Data("LH-SOURCE-PREFIX-V1\0".utf8)
        material.append(rolling)
        var length = byteCount.bigEndian
        withUnsafeBytes(of: &length) { material.append(contentsOf: $0) }
        return SHA256Digest.hashHex(material)
    }

    private mutating func fold(_ block: Data) {
        var material = Data("LH-SOURCE-PREFIX-BLOCK-V1\0".utf8)
        material.append(rolling)
        var length = UInt64(block.count).bigEndian
        withUnsafeBytes(of: &length) { material.append(contentsOf: $0) }
        material.append(SHA256Digest.hash(block))
        rolling = SHA256Digest.hash(material)
    }
}

private func historyFingerprint(
    descriptor: Int32,
    prefixByteCount: Int64
) throws -> String {
    guard prefixByteCount >= 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL))
    }
    var fingerprint = HistorySourcePrefixFingerprint()
    var offset: Int64 = 0
    var buffer = [UInt8](repeating: 0, count: HistoryJSONLinesStreamReader.defaultChunkSize)
    while offset < prefixByteCount {
        let requested = min(buffer.count, Int(prefixByteCount - offset))
        let count = pread(descriptor, &buffer, requested, off_t(offset))
        guard count >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        guard count > 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
        }
        fingerprint.append(Data(buffer[0..<count]))
        offset += Int64(count)
    }
    return fingerprint.finalize()
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
        guard pinnedIdentity.matchesSnapshot(pathStat) else {
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
        guard parent.isPathStable() else {
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
        guard pinnedIdentity.matchesSnapshot(pathStat), parent.isPathStable() else {
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
            identity.matchesSnapshot(descriptorStat)
        else { return false }
        var pathStat = stat()
        guard lstat(url.path, &pathStat) == 0 else { return false }
        return identity.matchesSnapshot(pathStat)
    }

    /// A pinned parent remains a valid capability while unrelated children are
    /// created or removed. Device/inode equality still rejects a path replacement;
    /// directories whose membership is source evidence use `isStable()`.
    func isPathStable() -> Bool {
        var descriptorStat = stat()
        guard fstat(descriptor, &descriptorStat) == 0,
            identity.matchesPathIdentity(descriptorStat)
        else { return false }
        var pathStat = stat()
        guard lstat(url.path, &pathStat) == 0 else { return false }
        return identity.matchesPathIdentity(pathStat)
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

    func isStable(relativeTo view: HistoryPinnedFileView) -> Bool {
        var current = stat()
        let result = name.withCString {
            fstatat(directory.descriptor, $0, &current, AT_SYMLINK_NOFOLLOW)
        }
        guard result == 0 else { return false }
        if view.identity.matches(current) { return true }
        guard view.permitsVerifiedAppendOnlyGrowth,
            view.identity.matchesPathIdentity(current),
            Int64(current.st_size) >= view.prefixByteCount
        else { return false }

        let descriptor = name.withCString {
            openat(
                directory.descriptor,
                $0,
                O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
            )
        }
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        guard
            (try? historyFingerprint(
                descriptor: descriptor,
                prefixByteCount: view.prefixByteCount
            )) == view.prefixFingerprint
        else { return false }

        var final = stat()
        guard fstat(descriptor, &final) == 0,
            view.identity.matchesPathIdentity(final),
            Int64(final.st_size) >= view.prefixByteCount
        else { return false }
        var path = stat()
        let pathResult = name.withCString {
            fstatat(directory.descriptor, $0, &path, AT_SYMLINK_NOFOLLOW)
        }
        return pathResult == 0
            && view.identity.matchesPathIdentity(path)
            && Int64(path.st_size) >= view.prefixByteCount
    }
}

/// Metrics emitted by the same bounded JSONL primitive used by
/// `HistoryLocalStoreReader`. The type is internal so tests can prove that the
/// transient read buffer stays independent of the size of the file without
/// exposing recorder contents or diagnostics in the public API.
package struct HistoryJSONLinesReadMetrics: Equatable {
    package var bytesRead: Int64 = 0
    package var peakBufferedBytes = 0
    package var rowsVisited = 0
    package var oversizedRows = 0
    package var reachedByteLimit = false
    package var wasCancelled = false
    package var sourceChangedDuringRead = false
    fileprivate var pinnedIdentity: HistoryPinnedRegularFileIdentity?
    fileprivate var pinnedFileView: HistoryPinnedFileView?
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
        allowVerifiedAppendOnlyGrowth: Bool = false,
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
        let callerByteLimit = maximumBytes.map { max(0, $0) }
        let readCeiling = min(sourceByteCount, callerByteLimit ?? sourceByteCount)

        let initialIdentity = HistoryPinnedRegularFileIdentity(sourceStat)

        func matchesInitialIdentity(_ current: stat) -> Bool {
            initialIdentity.matches(current)
        }

        var metrics = HistoryJSONLinesReadMetrics()
        metrics.pinnedIdentity = initialIdentity
        var prefixFingerprint = HistorySourcePrefixFingerprint()
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
            prefixFingerprint.append(chunk)
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

        let completedPinnedPrefix = !metrics.wasCancelled && metrics.bytesRead == readCeiling
        let pinnedPrefixFingerprint =
            completedPinnedPrefix
            ? prefixFingerprint.finalize()
            : nil
        var finalStat = stat()
        var finalStatAvailable = false
        if fstat(descriptor, &finalStat) == 0 {
            finalStatAvailable = true
            let exactMatch = matchesInitialIdentity(finalStat)
            let sameFileWithGrowth =
                allowVerifiedAppendOnlyGrowth
                && completedPinnedPrefix
                && initialIdentity.matchesPathIdentity(finalStat)
                && Int64(finalStat.st_size) >= sourceByteCount
            if !exactMatch, sameFileWithGrowth, let pinnedPrefixFingerprint {
                metrics.sourceChangedDuringRead =
                    metrics.sourceChangedDuringRead
                    || (try? historyFingerprint(
                        descriptor: descriptor,
                        prefixByteCount: readCeiling
                    )) != pinnedPrefixFingerprint
            } else {
                metrics.sourceChangedDuringRead =
                    metrics.sourceChangedDuringRead || !exactMatch
            }
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
        if !metrics.reachedByteLimit, !metrics.wasCancelled,
            discardingOversizedLine || !pending.isEmpty
        {
            let endedInsideVerifiedAppend =
                allowVerifiedAppendOnlyGrowth
                && finalStatAvailable
                && !metrics.sourceChangedDuringRead
                && Int64(finalStat.st_size) > sourceByteCount
                && !pending.isEmpty
            if endedInsideVerifiedAppend {
                pending.removeAll(keepingCapacity: false)
            } else {
                finishLine()
            }
        }
        if let pinnedPrefixFingerprint, !metrics.sourceChangedDuringRead {
            metrics.pinnedFileView = HistoryPinnedFileView(
                identity: initialIdentity,
                prefixByteCount: readCeiling,
                prefixFingerprint: pinnedPrefixFingerprint,
                permitsVerifiedAppendOnlyGrowth: allowVerifiedAppendOnlyGrowth
            )
        }
        return metrics
    }
}

/// Stable, read-only filesystem adapter for ChatGPT, Codex and a future MCP server.
/// It never asks for Accessibility/Input Monitoring and never mutates recorder files.
public struct HistoryLocalStoreReader {
    private static let maximumCaptureHealthBytes = 1 * 1_024 * 1_024
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

    public func loadCaptureHealth() -> CaptureHealthLoadResult {
        guard FileManager.default.fileExists(atPath: captureHealthFile.path) else {
            return CaptureHealthLoadResult(snapshot: nil, issues: [])
        }
        do {
            return CaptureHealthLoadResult(
                snapshot: try decoder().decode(
                    CaptureHealthSnapshot.self,
                    from: readBoundedFile(
                        captureHealthFile,
                        maximumBytes: Self.maximumCaptureHealthBytes
                    )
                ),
                issues: []
            )
        } catch {
            return CaptureHealthLoadResult(
                snapshot: nil,
                issues: [
                    HistoryLoadIssue(
                        path: captureHealthFile.path,
                        line: nil,
                        message: "Could not decode capture health: \(error)"
                    )
                ]
            )
        }
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

        let health = loadCaptureHealth()
        issues.append(contentsOf: health.issues)

        return HistoryLoadedData(
            events: events.sorted { $0.timestamp < $1.timestamp },
            memories: memories.sorted { $0.start < $1.start },
            semanticSnapshots: semantic,
            captureHealth: health.snapshot,
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

    /// Loads a persisted bounded day memory only when it contains every episode
    /// shell and its recorded tail hash, sequence and modification time still
    /// match the authoritative event journal. This avoids repeated whole-day
    /// decoding for lightweight indexes while never accepting stale evidence.
    package func loadCurrentComputerHistoryMemory(
        day: Date,
        calendar: Calendar = .current
    ) -> CurrentComputerHistoryMemoryLoad {
        let dayStart = calendar.startOfDay(for: day)
        let components = calendar.dateComponents([.year, .month, .day], from: dayStart)
        guard let year = components.year, let month = components.month, let day = components.day else {
            return CurrentComputerHistoryMemoryLoad(
                memory: nil,
                state: .inaccessible,
                bytesRead: 0,
                issues: [
                    HistoryLoadIssue(
                        path: rootDirectory.path,
                        line: nil,
                        message: "Could not derive the requested local Computer History day."
                    )
                ]
            )
        }
        let dayKey = String(format: "%04d-%02d-%02d", year, month, day)
        let memoryName = "\(dayKey).computer-history.json"
        let eventName = "\(dayKey).jsonl"
        var bytesRead: Int64 = 0
        var memoryIdentity: HistoryPinnedRegularFileIdentity?
        var eventIdentity: HistoryPinnedRegularFileIdentity?

        do {
            let sourceRoot = try HistoryPinnedSourceDirectory(rootURL: rootDirectory)
            let memoryDirectory = try HistoryPinnedSourceDirectory(
                parent: sourceRoot,
                name: "computer-history"
            )
            let eventDirectory = try HistoryPinnedSourceDirectory(
                parent: sourceRoot,
                name: "events"
            )
            guard let memoryFile = try memoryDirectory.matchingFiles(
                extensions: ["json"]
            ).first(where: { $0.name == memoryName }),
                let eventFile = try eventDirectory.matchingFiles(
                    extensions: ["jsonl"]
                ).first(where: { $0.name == eventName })
            else {
                return CurrentComputerHistoryMemoryLoad(
                    memory: nil,
                    state: .absent,
                    bytesRead: 0,
                    issues: []
                )
            }

            let rawMemory = try readBoundedFile(
                memoryFile.url,
                directoryDescriptor: memoryDirectory.descriptor,
                relativeName: memoryFile.name,
                maximumBytes: 16 * 1_024 * 1_024,
                onPinnedIdentity: { memoryIdentity = $0 }
            )
            bytesRead += Int64(rawMemory.count)
            let memory = try decoder().decode(
                ComputerHistoryDayMemory.self,
                from: rawMemory
            )
            guard memory.analysisRevision == ComputerHistoryAnalysisContract.currentRevision else {
                return CurrentComputerHistoryMemoryLoad(
                    memory: nil,
                    state: .stale,
                    bytesRead: bytesRead,
                    issues: []
                )
            }
            guard memory.coverage.episodeCount == memory.episodes.count,
                memory.coverage.retainedEpisodeCount == nil
                    || memory.coverage.retainedEpisodeCount == memory.coverage.episodeCount
            else {
                return CurrentComputerHistoryMemoryLoad(
                    memory: nil,
                    state: .incompleteProjection,
                    bytesRead: bytesRead,
                    issues: []
                )
            }

            let tail = try readLastCompleteJSONLine(
                eventFile,
                maximumBytes: 512 * 1_024
            )
            bytesRead += Int64(tail.line.count)
            eventIdentity = tail.identity
            let lastEvent = try decoder(compactEventIntegrity: true).decode(
                HistoryEvent.self,
                from: tail.line
            )
            guard let integrity = lastEvent.integrity,
                memory.coverage.lastSourceSequence == integrity.sequence,
                memory.coverage.lastSourceEventHash == integrity.eventHash,
                eventModificationDate(tail.identity) <= memory.generatedAt
            else {
                return CurrentComputerHistoryMemoryLoad(
                    memory: nil,
                    state: .stale,
                    bytesRead: bytesRead,
                    issues: []
                )
            }
            guard let memoryIdentity, let eventIdentity,
                memoryFile.isStable(relativeTo: memoryIdentity),
                eventFile.isStable(relativeTo: eventIdentity),
                memoryDirectory.isStable(),
                eventDirectory.isStable(),
                sourceRoot.isPathStable()
            else {
                return CurrentComputerHistoryMemoryLoad(
                    memory: nil,
                    state: .stale,
                    bytesRead: bytesRead,
                    issues: []
                )
            }
            return CurrentComputerHistoryMemoryLoad(
                memory: memory,
                state: .current,
                bytesRead: bytesRead,
                issues: []
            )
        } catch {
            return CurrentComputerHistoryMemoryLoad(
                memory: nil,
                state: .inaccessible,
                bytesRead: bytesRead,
                issues: [
                    HistoryLoadIssue(
                        path: rootDirectory.path,
                        line: nil,
                        message:
                            "Could not validate the bounded Computer History index; the authoritative journal must be read instead: \(error.localizedDescription)"
                    )
                ]
            )
        }
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
        let rowDecoder = decoder(compactEventIntegrity: true)
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
                view: HistoryPinnedFileView
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

        func revalidate(
            _ directory: HistoryPinnedSourceDirectory?,
            membershipIsSourceEvidence: Bool = true
        ) {
            guard let directory else { return }
            let stable =
                membershipIsSourceEvidence
                ? directory.isStable()
                : directory.isPathStable()
            guard !stable else { return }
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
                    allowVerifiedAppendOnlyGrowth: true,
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
                if let view = streamMetrics.pinnedFileView {
                    pinnedReadFiles.append((sourceFile, view))
                } else if !streamMetrics.wasCancelled,
                    !streamMetrics.sourceChangedDuringRead
                {
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
                        allowVerifiedAppendOnlyGrowth: true,
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
                    if let view = streamMetrics.pinnedFileView {
                        pinnedReadFiles.append((sourceFile, view))
                    } else if !streamMetrics.wasCancelled,
                        !streamMetrics.sourceChangedDuringRead
                    {
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
                        pinnedReadFiles.append(
                            (
                                sourceFile,
                                HistoryPinnedFileView(
                                    identity: pinnedIdentity,
                                    prefixByteCount: Int64(pinnedIdentity.size),
                                    prefixFingerprint: "",
                                    permitsVerifiedAppendOnlyGrowth: false
                                )
                            )
                        )
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
        where !pinnedReadFile.file.isStable(relativeTo: pinnedReadFile.view) {
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
        revalidate(pinnedSourceRoot, membershipIsSourceEvidence: false)

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
        let rowDecoder = decoder(compactEventIntegrity: true)
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
                view: HistoryPinnedFileView
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
                    allowVerifiedAppendOnlyGrowth: true,
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
                if let view = streamMetrics.pinnedFileView {
                    pinnedSearchFiles.append((sourceFile, view))
                } else if !streamMetrics.wasCancelled,
                    !streamMetrics.sourceChangedDuringRead
                {
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
                    pinnedSearchFiles.append(
                        (
                            sourceFile,
                            HistoryPinnedFileView(
                                identity: pinnedIdentity,
                                prefixByteCount: Int64(pinnedIdentity.size),
                                prefixFingerprint: "",
                                permitsVerifiedAppendOnlyGrowth: false
                            )
                        )
                    )
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
                    allowVerifiedAppendOnlyGrowth: true,
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
                if let view = streamMetrics.pinnedFileView {
                    pinnedSearchFiles.append((sourceFile, view))
                } else if !streamMetrics.wasCancelled,
                    !streamMetrics.sourceChangedDuringRead
                {
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
        where !pinnedSearchFile.file.isStable(relativeTo: pinnedSearchFile.view) {
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

    private func readLastCompleteJSONLine(
        _ sourceFile: HistoryPinnedSourceFile,
        maximumBytes: Int
    ) throws -> (line: Data, identity: HistoryPinnedRegularFileIdentity) {
        let descriptor = sourceFile.name.withCString {
            openat(
                sourceFile.directory.descriptor,
                $0,
                O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
            )
        }
        guard descriptor >= 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSFilePathErrorKey: sourceFile.url.path]
            )
        }
        defer { close(descriptor) }
        var sourceStat = stat()
        guard fstat(descriptor, &sourceStat) == 0,
            (sourceStat.st_mode & S_IFMT) == S_IFREG,
            sourceStat.st_size > 0
        else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(EINVAL),
                userInfo: [NSFilePathErrorKey: sourceFile.url.path]
            )
        }
        let identity = HistoryPinnedRegularFileIdentity(sourceStat)
        let count = min(max(1, maximumBytes), Int(sourceStat.st_size))
        let offset = Int(sourceStat.st_size) - count
        var bytes = [UInt8](repeating: 0, count: count)
        let readCount = pread(descriptor, &bytes, count, off_t(offset))
        guard readCount == count else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(readCount < 0 ? errno : EIO),
                userInfo: [NSFilePathErrorKey: sourceFile.url.path]
            )
        }
        var finalStat = stat()
        guard fstat(descriptor, &finalStat) == 0,
            identity.matches(finalStat),
            sourceFile.isStable(relativeTo: identity)
        else { throw HistoryBoundedFileReadError.changedDuringRead }

        var end = bytes.count
        guard end > 0, bytes[end - 1] == 0x0A else {
            throw HistoryBoundedFileReadError.changedDuringRead
        }
        end -= 1
        if end > 0, bytes[end - 1] == 0x0D { end -= 1 }
        let previousNewline = bytes[..<end].lastIndex(of: 0x0A)
        let start: Int
        if let previousNewline {
            start = previousNewline + 1
        } else if offset == 0 {
            start = 0
        } else {
            throw HistoryBoundedFileReadError.exceedsLimit(maximumBytes)
        }
        guard start < end else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(EINVAL),
                userInfo: [NSFilePathErrorKey: sourceFile.url.path]
            )
        }
        return (Data(bytes[start..<end]), identity)
    }

    private func eventModificationDate(
        _ identity: HistoryPinnedRegularFileIdentity
    ) -> Date {
        Date(
            timeIntervalSince1970:
                TimeInterval(identity.modificationSeconds)
                + TimeInterval(identity.modificationNanoseconds) / 1_000_000_000
        )
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
                    allowVerifiedAppendOnlyGrowth: true,
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

    private func decoder(compactEventIntegrity: Bool = false) -> JSONDecoder {
        let decoder = JSONDecoder()
        if compactEventIntegrity {
            decoder.userInfo[.compactHistoryEventIntegrity] = true
        }
        decoder.dateDecodingStrategy = .custom { value in
            let container = try value.singleValueContainer()
            if let raw = try? container.decode(String.self) {
                if raw.hasPrefix("b:"),
                    let bits = UInt64(raw.dropFirst(2), radix: 16)
                {
                    return Date(
                        timeIntervalSinceReferenceDate: Double(bitPattern: bits)
                    )
                }
                if let date = FastISO8601DateParser.parseCanonicalUTC(raw)
                    ?? Self.fractionalISO.date(from: raw)
                    ?? Self.basicISO.date(from: raw)
                {
                    return date
                }
            }
            if let seconds = try? container.decode(Double.self) {
                return Date(timeIntervalSince1970: seconds)
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported Computer History timestamp"
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
