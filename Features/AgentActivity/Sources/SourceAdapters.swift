import CryptoKit
import Darwin
import Dispatch
import Foundation
import LocalHistoryCore
import SQLite3

public enum AgentSourceReadError: Error, LocalizedError, Sendable {
    case missing(String)
    case inaccessible(String)
    case fileTooLarge(path: String, bytes: Int64, maximum: Int64)
    case changedDuringRead(String)
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .missing(let source):
            return "The original agent source is no longer present: \(source)"
        case .inaccessible(let source):
            return "The original agent source is not readable: \(source)"
        case .fileTooLarge(let path, let bytes, let maximum):
            return "The source \(path) is \(bytes) bytes; the configured maximum is \(maximum)."
        case .changedDuringRead(let source):
            return "The original agent source changed while it was being read; it will be retried: \(source)"
        case .unsupported(let detail):
            return detail
        }
    }
}

struct AgentSourceCandidate: Equatable, Sendable {
    var reference: AgentSourceReference
    var relativePath: String
    var stableConversationID: String?
    var sourceCreatedAt: Date?
    var sourceModifiedAt: Date?
    var byteCount: Int64?
    var sourceDevice: UInt64? = nil
    var sourceInode: UInt64? = nil
    var sourceChangedSeconds: Int64? = nil
    var sourceChangedNanoseconds: Int64? = nil
    var sourceContainerByteCount: Int64? = nil
    var sourceContainerModifiedSeconds: Int64? = nil
    var sourceContainerModifiedNanoseconds: Int64? = nil
    /// Provider metadata used only while a scan is running. It is deliberately
    /// absent from the persisted source index.
    var openCodeMetadata: AgentOpenCodeSessionMetadata? = nil
}

private struct AgentSourceContainerIdentity: Equatable, Sendable {
    var device: UInt64
    var inode: UInt64
    var byteCount: Int64
    var modifiedSeconds: Int64
    var modifiedNanoseconds: Int64
    var changedSeconds: Int64
    var changedNanoseconds: Int64
}

struct AgentSourceDiscoveryResult: Equatable, Sendable {
    var candidates: [AgentSourceCandidate]
    var incompleteReason: AgentSourceInventoryIncompleteReason?
    var traversalUsage: AgentSourceTraversalUsage
    /// True when a process-local, metadata-only cursor can continue without revisiting the
    /// provider prefix already traversed.
    var hasMoreCandidates: Bool = false

    var isCompleteInventory: Bool { incompleteReason == nil }
}

enum AgentSourceInventoryIncompleteReason: String, Equatable, Sendable {
    case candidateLimit
    case visitLimit
    case metadataByteLimit
    case deadlineExceeded
    case cancelled
    case depthLimit
    case pathLengthLimit
}

struct AgentSourceTraversalUsage: Equatable, Sendable {
    var visitedNodeOrRowCount: Int
    var metadataByteCount: Int64
    var elapsedNanoseconds: UInt64
}

struct AgentSourceTraversalLimits: Equatable, Sendable {
    static let production = AgentSourceTraversalLimits(
        maximumNodeOrRowVisits: 50_000,
        maximumMetadataBytes: 16 * 1_024 * 1_024,
        maximumDurationNanoseconds: 2_000_000_000
    )

    var maximumNodeOrRowVisits: Int
    var maximumMetadataBytes: Int64
    var maximumDurationNanoseconds: UInt64

    init(
        maximumNodeOrRowVisits: Int,
        maximumMetadataBytes: Int64,
        maximumDurationNanoseconds: UInt64
    ) {
        self.maximumNodeOrRowVisits = min(max(maximumNodeOrRowVisits, 1), 1_000_000)
        self.maximumMetadataBytes = min(max(maximumMetadataBytes, 1), 256 * 1_024 * 1_024)
        self.maximumDurationNanoseconds = min(
            max(maximumDurationNanoseconds, 1),
            30_000_000_000
        )
    }

    /// Repeated incomplete inventories expand deterministically from persisted
    /// failure metadata. Every individual cycle remains bounded, while a finite
    /// provider cannot starve forever at the same enumeration prefix after a relaunch.
    func escalated(afterIncompleteAttempts attempts: Int) -> AgentSourceTraversalLimits {
        let shift = min(max(attempts, 0), 5)
        let factor = Int64(1 << shift)
        return AgentSourceTraversalLimits(
            maximumNodeOrRowVisits: min(
                1_000_000,
                maximumNodeOrRowVisits.multipliedReportingOverflow(by: Int(factor)).partialValue
            ),
            maximumMetadataBytes: min(
                256 * 1_024 * 1_024,
                maximumMetadataBytes.multipliedReportingOverflow(by: factor).partialValue
            ),
            maximumDurationNanoseconds: min(
                30_000_000_000,
                maximumDurationNanoseconds.multipliedReportingOverflow(by: UInt64(factor)).partialValue
            )
        )
    }
}

/// One transient budget is shared by every provider adapter and watched folder
/// during a scanner cycle. It bounds work only; it never contains source content
/// and is never persisted.
final class AgentSourceTraversalBudget {
    typealias UptimeNanoseconds = () -> UInt64
    typealias CancellationCheck = () -> Bool

    let limits: AgentSourceTraversalLimits
    private let uptimeNanoseconds: UptimeNanoseconds
    private let isCancelled: CancellationCheck
    private let startedAtNanoseconds: UInt64
    private(set) var visitedNodeOrRowCount = 0
    private(set) var metadataByteCount: Int64 = 0
    private(set) var stopReason: AgentSourceInventoryIncompleteReason?

    init(
        limits: AgentSourceTraversalLimits = .production,
        uptimeNanoseconds: @escaping UptimeNanoseconds = {
            DispatchTime.now().uptimeNanoseconds
        },
        isCancelled: @escaping CancellationCheck = {
            withUnsafeCurrentTask { $0?.isCancelled ?? false }
        }
    ) {
        self.limits = limits
        self.uptimeNanoseconds = uptimeNanoseconds
        self.isCancelled = isCancelled
        startedAtNanoseconds = uptimeNanoseconds()
    }

    @discardableResult
    func consumeVisit(metadataBytes requestedMetadataBytes: Int64) -> Bool {
        guard checkpoint() else { return false }
        guard visitedNodeOrRowCount < limits.maximumNodeOrRowVisits else {
            stopReason = .visitLimit
            return false
        }
        visitedNodeOrRowCount += 1
        let metadataBytes = max(0, requestedMetadataBytes)
        guard metadataBytes <= limits.maximumMetadataBytes - metadataByteCount else {
            stopReason = .metadataByteLimit
            return false
        }
        metadataByteCount += metadataBytes
        return checkpoint()
    }

    @discardableResult
    func checkpoint() -> Bool {
        guard stopReason == nil else { return false }
        if isCancelled() {
            stopReason = .cancelled
            return false
        }
        if elapsedNanoseconds >= limits.maximumDurationNanoseconds {
            stopReason = .deadlineExceeded
            return false
        }
        return true
    }

    func stop(_ reason: AgentSourceInventoryIncompleteReason) {
        if stopReason == nil { stopReason = reason }
    }

    func usage() -> AgentSourceTraversalUsage {
        AgentSourceTraversalUsage(
            visitedNodeOrRowCount: visitedNodeOrRowCount,
            metadataByteCount: metadataByteCount,
            elapsedNanoseconds: elapsedNanoseconds
        )
    }

    private var elapsedNanoseconds: UInt64 {
        let now = uptimeNanoseconds()
        return now >= startedAtNanoseconds ? now - startedAtNanoseconds : 0
    }
}

private struct AgentSourceTraversalInterrupted: Error {}

enum AgentSourceBodyReadStopReason: String, Equatable, Sendable {
    case byteLimit
    case deadlineExceeded
    case cancelled
}

struct AgentSourceBodyReadLimits: Equatable, Sendable {
    static let production = AgentSourceBodyReadLimits(
        maximumBytes: 512 * 1_024 * 1_024,
        maximumDurationNanoseconds: 10_000_000_000
    )

    /// Explicit, user-requested selected-day analysis should finish a large original
    /// transcript in one streaming pass when possible. A longer deadline avoids rereading
    /// the same prefix across several bounded background-style cycles; the byte ceiling and
    /// streaming parser memory bounds remain unchanged.
    static let selectedDayAnalysis = AgentSourceBodyReadLimits(
        maximumBytes: 512 * 1_024 * 1_024,
        maximumDurationNanoseconds: 60_000_000_000
    )

    var maximumBytes: Int64
    var maximumDurationNanoseconds: UInt64

    init(maximumBytes: Int64, maximumDurationNanoseconds: UInt64) {
        self.maximumBytes = min(max(maximumBytes, 1), 2 * 1_024 * 1_024 * 1_024)
        self.maximumDurationNanoseconds = min(
            max(maximumDurationNanoseconds, 1),
            60_000_000_000
        )
    }
}

struct AgentSourceBodyReadUsage: Equatable, Sendable {
    var byteCount: Int64
    var elapsedNanoseconds: UInt64
    var stopReason: AgentSourceBodyReadStopReason?
}

/// A single streaming I/O budget is shared across all providers and folders in
/// one scanner cycle. Only counters and monotonic timing live here.
final class AgentSourceBodyReadBudget {
    typealias UptimeNanoseconds = () -> UInt64
    typealias CancellationCheck = () -> Bool

    let limits: AgentSourceBodyReadLimits
    private let uptimeNanoseconds: UptimeNanoseconds
    private let isCancelled: CancellationCheck
    private var startedAtNanoseconds: UInt64?
    private(set) var byteCount: Int64 = 0
    private(set) var stopReason: AgentSourceBodyReadStopReason?
    private var didRejectForByteLimit = false

    init(
        limits: AgentSourceBodyReadLimits = .production,
        uptimeNanoseconds: @escaping UptimeNanoseconds = {
            DispatchTime.now().uptimeNanoseconds
        },
        isCancelled: @escaping CancellationCheck = {
            withUnsafeCurrentTask { $0?.isCancelled ?? false }
        }
    ) {
        self.limits = limits
        self.uptimeNanoseconds = uptimeNanoseconds
        self.isCancelled = isCancelled
    }

    func canReadKnownLength(_ bytes: Int64) -> Bool {
        guard checkpoint() else { return false }
        guard bytes >= 0, bytes <= limits.maximumBytes - byteCount else {
            didRejectForByteLimit = true
            return false
        }
        return true
    }

    func consume(_ bytes: Int64) -> Bool {
        guard checkpoint() else { return false }
        guard bytes >= 0, bytes <= limits.maximumBytes - byteCount else {
            didRejectForByteLimit = true
            return false
        }
        byteCount += bytes
        return checkpoint()
    }

    @discardableResult
    func checkpoint() -> Bool {
        guard stopReason == nil else { return false }
        let now = uptimeNanoseconds()
        if startedAtNanoseconds == nil { startedAtNanoseconds = now }
        if isCancelled() {
            stopReason = .cancelled
            return false
        }
        if elapsedNanoseconds(at: now) >= limits.maximumDurationNanoseconds {
            stopReason = .deadlineExceeded
            return false
        }
        return true
    }

    func usage() -> AgentSourceBodyReadUsage {
        AgentSourceBodyReadUsage(
            byteCount: byteCount,
            elapsedNanoseconds: elapsedNanoseconds(at: uptimeNanoseconds()),
            stopReason: stopReason ?? (didRejectForByteLimit ? .byteLimit : nil)
        )
    }

    var remainingBytes: Int64 {
        max(0, limits.maximumBytes - byteCount)
    }

    private func elapsedNanoseconds(at now: UInt64) -> UInt64 {
        guard let startedAtNanoseconds, now >= startedAtNanoseconds else { return 0 }
        return now - startedAtNanoseconds
    }
}

struct AgentSourceBodyReadInterrupted: Error, Sendable {
    var reason: AgentSourceBodyReadStopReason
}

struct AgentSourceCandidateResolution: Sendable {
    var entry: AgentSourceIndexEntry
    var candidate: AgentSourceCandidate?
    var error: AgentSourceReadError?
}

struct AgentSourceCandidateResolutionBatch: Sendable {
    var resolutions: [AgentSourceCandidateResolution]
    var incompleteReason: AgentSourceInventoryIncompleteReason?
    var traversalUsage: AgentSourceTraversalUsage
}

private struct BoundedCandidateCollector {
    let maximumCount: Int
    let maximumEstimatedBytes: Int
    private var heap: [AgentSourceCandidate] = []
    private var didTruncate = false
    private var estimatedBytes = 0

    init(maximumCount: Int, maximumEstimatedBytes: Int = .max) {
        self.maximumCount = min(max(maximumCount, 1), 50_000)
        self.maximumEstimatedBytes = max(maximumEstimatedBytes, 1)
        heap.reserveCapacity(self.maximumCount)
    }

    mutating func append(_ candidate: AgentSourceCandidate) {
        let candidateBytes = Self.estimatedBytes(for: candidate)
        guard candidateBytes <= maximumEstimatedBytes else {
            didTruncate = true
            return
        }
        if heap.count < maximumCount,
            candidateBytes <= maximumEstimatedBytes - estimatedBytes
        {
            heap.append(candidate)
            estimatedBytes += candidateBytes
            siftUp(from: heap.count - 1)
            return
        }

        didTruncate = true
        guard let oldest = heap.first, Self.isLessDesirable(oldest, than: candidate) else { return }
        repeat {
            removeLeastDesirable()
        } while !heap.isEmpty
            && (heap.count >= maximumCount
                || candidateBytes > maximumEstimatedBytes - estimatedBytes)
        heap.append(candidate)
        estimatedBytes += candidateBytes
        siftUp(from: heap.count - 1)
    }

    func result(traversalBudget: AgentSourceTraversalBudget) -> AgentSourceDiscoveryResult {
        _ = traversalBudget.checkpoint()
        return AgentSourceDiscoveryResult(
            candidates: heap.sorted(by: Self.outputOrder),
            incompleteReason: traversalBudget.stopReason ?? (didTruncate ? .candidateLimit : nil),
            traversalUsage: traversalBudget.usage()
        )
    }

    var retainedCount: Int { heap.count }
    var retainedEstimatedBytes: Int { estimatedBytes }
    var wasTruncated: Bool { didTruncate }

    mutating func takeSortedCandidates() -> [AgentSourceCandidate] {
        let output = heap.sorted(by: Self.outputOrder)
        heap.removeAll(keepingCapacity: false)
        estimatedBytes = 0
        return output
    }

    private mutating func removeLeastDesirable() {
        guard !heap.isEmpty else { return }
        estimatedBytes = max(0, estimatedBytes - Self.estimatedBytes(for: heap[0]))
        if heap.count == 1 {
            heap.removeLast()
            return
        }
        heap[0] = heap.removeLast()
        siftDown(from: 0)
    }

    private mutating func siftUp(from initialIndex: Int) {
        var child = initialIndex
        while child > 0 {
            let parent = (child - 1) / 2
            guard Self.isLessDesirable(heap[child], than: heap[parent]) else { return }
            heap.swapAt(child, parent)
            child = parent
        }
    }

    private mutating func siftDown(from initialIndex: Int) {
        var parent = initialIndex
        while true {
            let left = parent * 2 + 1
            guard left < heap.count else { return }
            let right = left + 1
            var least = left
            if right < heap.count, Self.isLessDesirable(heap[right], than: heap[left]) { least = right }
            guard Self.isLessDesirable(heap[least], than: heap[parent]) else { return }
            heap.swapAt(parent, least)
            parent = least
        }
    }

    private static func isLessDesirable(_ left: AgentSourceCandidate, than right: AgentSourceCandidate) -> Bool {
        let leftDate = left.sourceModifiedAt ?? left.sourceCreatedAt ?? .distantPast
        let rightDate = right.sourceModifiedAt ?? right.sourceCreatedAt ?? .distantPast
        if leftDate != rightDate { return leftDate < rightDate }
        return Self.referenceKey(left) > Self.referenceKey(right)
    }

    fileprivate static func outputOrder(_ left: AgentSourceCandidate, _ right: AgentSourceCandidate) -> Bool {
        let leftDate = left.sourceModifiedAt ?? left.sourceCreatedAt ?? .distantPast
        let rightDate = right.sourceModifiedAt ?? right.sourceCreatedAt ?? .distantPast
        if leftDate != rightDate { return leftDate > rightDate }
        return referenceKey(left) < referenceKey(right)
    }

    fileprivate static func referenceKey(_ candidate: AgentSourceCandidate) -> String {
        "\(candidate.reference.kind.rawValue)\u{0}\(candidate.reference.path)\u{0}\(candidate.reference.locator ?? "")"
    }

    fileprivate static func estimatedBytes(for candidate: AgentSourceCandidate) -> Int {
        let referenceBytes =
            candidate.reference.path.utf8.count
            + (candidate.reference.locator?.utf8.count ?? 0)
        let identityBytes =
            candidate.relativePath.utf8.count
            + (candidate.stableConversationID?.utf8.count ?? 0)
        let providerBytes =
            (candidate.openCodeMetadata?.title.utf8.count ?? 0)
            + (candidate.openCodeMetadata?.directory.utf8.count ?? 0)
        return min(64 * 1_024, 192 + referenceBytes + identityBytes + providerBytes)
    }
}

/// One short-lived direct-source context per watched-folder scan. SQLite
/// handles never escape this object and are reused for discovery, metadata,
/// and transcript reads before being closed at the end of the scan.
private final class AgentSourceRootCapability {
    let rootPath: String
    let rootURL: URL
    private let descriptor: Int32
    private let rootDevice: UInt64
    private let rootInode: UInt64

    init(path: String) throws {
        rootPath = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
        rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
        let openedDescriptor = try Self.openRoot(path: rootPath)
        var status = stat()
        guard Darwin.fstat(openedDescriptor, &status) == 0,
            status.st_mode & S_IFMT == S_IFDIR
        else {
            Darwin.close(openedDescriptor)
            throw AgentSourceReadError.inaccessible(rootPath)
        }
        descriptor = openedDescriptor
        rootDevice = UInt64(status.st_dev)
        rootInode = UInt64(status.st_ino)
    }

    deinit {
        Darwin.close(descriptor)
    }

    func absoluteURL(relativePath: String, isDirectory: Bool = false) -> URL {
        guard !relativePath.isEmpty else { return rootURL }
        return rootURL.appendingPathComponent(relativePath, isDirectory: isDirectory)
    }

    func relativePath(forAbsolutePath path: String) throws -> String {
        let source = URL(fileURLWithPath: path).standardizedFileURL
        let rootComponents = rootURL.pathComponents
        let sourceComponents = source.pathComponents
        guard sourceComponents.count > rootComponents.count,
            Array(sourceComponents.prefix(rootComponents.count)) == rootComponents
        else {
            throw AgentSourceReadError.inaccessible(path)
        }
        let suffixStart = sourceComponents.index(
            sourceComponents.startIndex,
            offsetBy: rootComponents.count
        )
        let components: [String] = Array(sourceComponents[suffixStart...])
        guard Self.componentsAreSafe(components) else {
            throw AgentSourceReadError.inaccessible(path)
        }
        return components.joined(separator: "/")
    }

    func openRegularFile(relativePath: String, displayPath: String? = nil) throws -> Int32 {
        let components = try Self.safeComponents(relativePath, displayPath: displayPath ?? relativePath)
        let parent = try openDirectory(components: Array(components.dropLast()))
        defer { Darwin.close(parent) }
        let file = components.last!.withCString {
            Darwin.openat(parent, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard file >= 0 else {
            if errno == ENOENT { throw AgentSourceReadError.missing(displayPath ?? relativePath) }
            throw AgentSourceReadError.inaccessible(displayPath ?? relativePath)
        }
        var status = stat()
        guard Darwin.fstat(file, &status) == 0,
            status.st_mode & S_IFMT == S_IFREG
        else {
            Darwin.close(file)
            throw AgentSourceReadError.inaccessible(displayPath ?? relativePath)
        }
        return file
    }

    func directoryExists(relativePath: String) throws -> Bool {
        do {
            let directory = try openDirectory(relativePath: relativePath)
            Darwin.close(directory)
            return true
        } catch let error as AgentSourceReadError {
            if case .missing = error { return false }
            throw error
        }
    }

    func regularFileExists(relativePath: String) throws -> Bool {
        do {
            let file = try openRegularFile(relativePath: relativePath)
            Darwin.close(file)
            return true
        } catch let error as AgentSourceReadError {
            if case .missing = error { return false }
            throw error
        }
    }

    /// A discovery cursor can outlive the short scan session that created it. Reopen the
    /// configured path before every continuation so a renamed or replaced provider root cannot
    /// be silently combined with the still-open descriptor for the previous directory.
    func verifyCurrentRootIdentity() throws {
        let current = try Self.openRoot(path: rootPath)
        defer { Darwin.close(current) }
        var status = stat()
        guard Darwin.fstat(current, &status) == 0,
            status.st_mode & S_IFMT == S_IFDIR
        else {
            throw AgentSourceReadError.inaccessible(rootPath)
        }
        guard UInt64(status.st_dev) == rootDevice,
            UInt64(status.st_ino) == rootInode
        else {
            throw AgentSourceReadError.changedDuringRead(rootPath)
        }
    }

    func sourceContainerIdentity(
        relativePath: String,
        displayPath: String? = nil
    ) throws -> AgentSourceContainerIdentity? {
        guard let status = try status(relativePath: relativePath, displayPath: displayPath) else {
            return nil
        }
        guard status.st_mode & S_IFMT == S_IFREG else {
            throw AgentSourceReadError.inaccessible(displayPath ?? relativePath)
        }
        return AgentSourceContainerIdentity(
            device: UInt64(status.st_dev),
            inode: UInt64(status.st_ino),
            byteCount: Int64(status.st_size),
            modifiedSeconds: Int64(status.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(status.st_mtimespec.tv_nsec),
            changedSeconds: Int64(status.st_ctimespec.tv_sec),
            changedNanoseconds: Int64(status.st_ctimespec.tv_nsec)
        )
    }

    func status(relativePath: String, displayPath: String? = nil) throws -> stat? {
        let components = try Self.safeComponents(relativePath, displayPath: displayPath ?? relativePath)
        let parent = try openDirectory(components: Array(components.dropLast()))
        defer { Darwin.close(parent) }
        var value = stat()
        let result = components.last!.withCString {
            Darwin.fstatat(parent, $0, &value, AT_SYMLINK_NOFOLLOW)
        }
        guard result == 0 else {
            if errno == ENOENT { return nil }
            throw AgentSourceReadError.inaccessible(displayPath ?? relativePath)
        }
        return value
    }

    func forEachDirectoryChild(
        relativePath: String,
        traversalBudget: AgentSourceTraversalBudget,
        body: (String, stat) throws -> Void
    ) throws {
        let directory = try openDirectory(relativePath: relativePath)
        defer { Darwin.close(directory) }
        try withoutActuallyEscaping(body) { escapedBody in
            try enumerateDirectory(
                descriptor: directory,
                relativePath: relativePath,
                traversalBudget: traversalBudget,
                recursive: false,
                fileBody: nil,
                childBody: escapedBody
            )
        }
    }

    func forEachRegularFile(
        relativeRoot: String,
        recursively: Bool,
        traversalBudget: AgentSourceTraversalBudget,
        shouldSkipDirectory: (String) -> Bool = { _ in false },
        body: (String, Int32) throws -> Void
    ) throws {
        let directory = try openDirectory(relativePath: relativeRoot)
        defer { Darwin.close(directory) }
        try withoutActuallyEscaping(shouldSkipDirectory) { escapedSkip in
            try withoutActuallyEscaping(body) { escapedBody in
                try enumerateDirectory(
                    descriptor: directory,
                    relativePath: relativeRoot,
                    traversalBudget: traversalBudget,
                    recursive: recursively,
                    shouldSkipDirectory: escapedSkip,
                    fileBody: escapedBody,
                    childBody: nil
                )
            }
        }
    }

    private func enumerateDirectory(
        descriptor directoryDescriptor: Int32,
        relativePath: String,
        traversalBudget: AgentSourceTraversalBudget,
        recursive: Bool,
        depth: Int = 0,
        shouldSkipDirectory: (String) -> Bool = { _ in false },
        fileBody: ((String, Int32) throws -> Void)?,
        childBody: ((String, stat) throws -> Void)?
    ) throws {
        let enumerationDescriptor = Darwin.dup(directoryDescriptor)
        guard enumerationDescriptor >= 0 else {
            throw AgentSourceReadError.inaccessible(absoluteURL(relativePath: relativePath).path)
        }
        _ = Darwin.fcntl(enumerationDescriptor, F_SETFD, FD_CLOEXEC)
        guard let directory = Darwin.fdopendir(enumerationDescriptor) else {
            Darwin.close(enumerationDescriptor)
            throw AgentSourceReadError.inaccessible(absoluteURL(relativePath: relativePath).path)
        }
        defer { Darwin.closedir(directory) }

        while true {
            errno = 0
            guard let entry = Darwin.readdir(directory) else {
                guard errno == 0 else {
                    throw AgentSourceReadError.inaccessible(
                        absoluteURL(relativePath: relativePath).path
                    )
                }
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            guard name != ".", name != "..", Self.componentsAreSafe([name]) else { continue }
            let childRelative = relativePath.isEmpty ? name : "\(relativePath)/\(name)"
            guard childRelative.utf8.count <= 8_192 else {
                traversalBudget.stop(.pathLengthLimit)
                return
            }
            let metadataCost = Int64(rootPath.utf8.count + childRelative.utf8.count) + 65
            guard traversalBudget.consumeVisit(metadataBytes: metadataCost) else { return }

            var childStatus = stat()
            let statusResult = name.withCString {
                Darwin.fstatat(directoryDescriptor, $0, &childStatus, AT_SYMLINK_NOFOLLOW)
            }
            guard statusResult == 0 else {
                if errno == ENOENT { continue }
                throw AgentSourceReadError.inaccessible(absoluteURL(relativePath: childRelative).path)
            }
            try childBody?(childRelative, childStatus)
            switch childStatus.st_mode & S_IFMT {
            case S_IFREG:
                guard let fileBody else { continue }
                let file = name.withCString {
                    Darwin.openat(directoryDescriptor, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                }
                guard file >= 0 else {
                    if errno == ENOENT { continue }
                    throw AgentSourceReadError.inaccessible(absoluteURL(relativePath: childRelative).path)
                }
                var openedStatus = stat()
                guard Darwin.fstat(file, &openedStatus) == 0,
                    openedStatus.st_mode & S_IFMT == S_IFREG
                else {
                    Darwin.close(file)
                    throw AgentSourceReadError.inaccessible(absoluteURL(relativePath: childRelative).path)
                }
                do {
                    defer { Darwin.close(file) }
                    try fileBody(childRelative, file)
                }
            case S_IFDIR where recursive:
                let childURL = absoluteURL(relativePath: childRelative, isDirectory: true)
                guard !AgentScannerPolicy.shouldSkipCapabilityAuthorizedDirectory(childURL),
                    !shouldSkipDirectory(childRelative)
                else { continue }
                guard depth < 64 else {
                    traversalBudget.stop(.depthLimit)
                    return
                }
                let childDirectory = name.withCString {
                    Darwin.openat(
                        directoryDescriptor,
                        $0,
                        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                    )
                }
                guard childDirectory >= 0 else {
                    if errno == ENOENT { continue }
                    throw AgentSourceReadError.inaccessible(childURL.path)
                }
                do {
                    defer { Darwin.close(childDirectory) }
                    try enumerateDirectory(
                        descriptor: childDirectory,
                        relativePath: childRelative,
                        traversalBudget: traversalBudget,
                        recursive: true,
                        depth: depth + 1,
                        shouldSkipDirectory: shouldSkipDirectory,
                        fileBody: fileBody,
                        childBody: nil
                    )
                }
                guard traversalBudget.checkpoint() else { return }
            default:
                continue
            }
        }
    }

    fileprivate func openDirectory(relativePath: String) throws -> Int32 {
        let components =
            relativePath.isEmpty
            ? []
            : try Self.safeComponents(relativePath, displayPath: relativePath)
        return try openDirectory(components: components)
    }

    private func openDirectory(components: [String]) throws -> Int32 {
        var current = Darwin.dup(descriptor)
        guard current >= 0 else { throw AgentSourceReadError.inaccessible(rootPath) }
        _ = Darwin.fcntl(current, F_SETFD, FD_CLOEXEC)
        for component in components {
            let child = component.withCString {
                Darwin.openat(current, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            Darwin.close(current)
            guard child >= 0 else {
                if errno == ENOENT { throw AgentSourceReadError.missing(rootPath) }
                throw AgentSourceReadError.inaccessible(rootPath)
            }
            current = child
        }
        return current
    }

    private static func safeComponents(_ path: String, displayPath: String) throws -> [String] {
        let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !components.isEmpty,
            components.joined(separator: "/") == path.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
            componentsAreSafe(components)
        else {
            throw AgentSourceReadError.inaccessible(displayPath)
        }
        return components
    }

    private static func componentsAreSafe(_ components: [String]) -> Bool {
        components.allSatisfy { component in
            !component.isEmpty
                && component != "."
                && component != ".."
                && !component.contains("/")
                && !component.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        }
    }

    private static func openRoot(path: String) throws -> Int32 {
        var components = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
            .filter { $0 != "/" }
        if components.first == "var" {
            components.replaceSubrange(0...0, with: ["private", "var"])
        } else if components.first == "tmp" {
            components.replaceSubrange(0...0, with: ["private", "tmp"])
        }
        guard componentsAreSafe(components) else { throw AgentSourceReadError.inaccessible(path) }
        var current = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard current >= 0 else { throw AgentSourceReadError.inaccessible(path) }
        for component in components {
            let child = component.withCString {
                Darwin.openat(current, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            Darwin.close(current)
            guard child >= 0 else {
                if errno == ENOENT { throw AgentSourceReadError.missing(path) }
                throw AgentSourceReadError.inaccessible(path)
            }
            current = child
        }
        return current
    }
}

private final class AgentDirectoryCursorFrame {
    let relativePath: String
    let recursively: Bool
    let stream: UnsafeMutablePointer<DIR>
    var pendingName: String?

    init(relativePath: String, recursively: Bool, descriptor: Int32) throws {
        self.relativePath = relativePath
        self.recursively = recursively
        guard let stream = Darwin.fdopendir(descriptor) else {
            Darwin.close(descriptor)
            throw AgentSourceReadError.inaccessible(relativePath)
        }
        self.stream = stream
    }

    deinit {
        Darwin.closedir(stream)
    }

    func nextName() throws -> String? {
        if let pendingName {
            self.pendingName = nil
            return pendingName
        }
        while true {
            errno = 0
            guard let entry = Darwin.readdir(stream) else {
                guard errno == 0 else {
                    throw AgentSourceReadError.inaccessible(relativePath)
                }
                return nil
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            if name != ".", name != ".." { return name }
        }
    }
}

/// A process-local metadata cursor for one provider root. It retains only open directory
/// descriptors, traversal offsets and at most one deferred directory name; no source body is
/// retained. Pages therefore continue after the exact visited prefix instead of recursively
/// reopening a 10k-source tree for every scanner batch.
final class AgentDirectSourceDiscoveryCursor: @unchecked Sendable {
    private struct RootPlan {
        var relativePath: String
        var recursively: Bool
    }

    private let folder: AgentWatchedFolder
    private let sourceRoot: AgentSourceRootCapability
    private var rootPlans: [RootPlan]
    private var nextRootPlanIndex = 0
    private var directoryFrames: [AgentDirectoryCursorFrame] = []
    private var openCodeBeforeRowID: Int64?
    private var openCodeCatalogFinished: Bool
    private var openCodeSourceIdentity: AgentSourceContainerIdentity?
    private var candidateCollector: BoundedCandidateCollector
    private var drainingCandidates: [AgentSourceCandidate] = []
    private var drainingCandidateIndex = 0
    private var emittedIncompleteCandidateKeys: Set<String> = []
    private var didEmitIncompleteCandidates = false
    private var finished = false
    private var capacityLimited = false

    fileprivate init(
        folder: AgentWatchedFolder,
        sourceRoot: AgentSourceRootCapability,
        maximumCandidates: Int
    ) {
        self.folder = folder
        self.sourceRoot = sourceRoot
        candidateCollector = BoundedCandidateCollector(
            maximumCount: maximumCandidates,
            maximumEstimatedBytes: 12 * 1_024 * 1_024
        )
        switch folder.provider {
        case .codex:
            rootPlans = [
                RootPlan(relativePath: "sessions", recursively: true),
                RootPlan(relativePath: "archived_sessions", recursively: true),
            ]
        case .claudeCode:
            rootPlans = [RootPlan(relativePath: "projects", recursively: true)]
        case .openCode:
            rootPlans = [RootPlan(relativePath: "storage/session", recursively: true)]
        case .gemini, .copilot:
            rootPlans = [RootPlan(relativePath: "", recursively: true)]
        case .cursor, .custom:
            rootPlans = [RootPlan(relativePath: "", recursively: folder.includeSubdirectories)]
        }
        openCodeCatalogFinished = folder.provider != .openCode
    }

    fileprivate func nextPage(
        maximumPageCandidates: Int,
        traversalBudget: AgentSourceTraversalBudget,
        openCodeConnection: (String) throws -> SQLiteReadConnection
    ) throws -> AgentSourceDiscoveryResult {
        let pageLimit = min(max(maximumPageCandidates, 1), 512)
        var newlyDiscoveredCandidates: [AgentSourceCandidate] = []
        newlyDiscoveredCandidates.reserveCapacity(pageLimit)
        try sourceRoot.verifyCurrentRootIdentity()
        try verifyOpenCodeSourceIdentity()
        if drainingCandidateIndex < drainingCandidates.count {
            return drainPage(maximumCandidates: pageLimit, traversalBudget: traversalBudget)
        }

        while !finished, traversalBudget.checkpoint() {
            if !openCodeCatalogFinished {
                let databasePath = sourceRoot.absoluteURL(relativePath: "opencode.db").path
                guard try sourceRoot.regularFileExists(relativePath: "opencode.db") else {
                    openCodeCatalogFinished = true
                    continue
                }
                let connection = try openCodeConnection(databasePath)
                let sourceIdentity = try connection.sourceContainerIdentity()
                if let openCodeSourceIdentity, openCodeSourceIdentity != sourceIdentity {
                    throw AgentSourceReadError.changedDuringRead(databasePath)
                }
                openCodeSourceIdentity = sourceIdentity
                let requestCount = 512
                let rows = try connection.openCodeSessionPage(
                    beforeRowID: openCodeBeforeRowID,
                    limit: requestCount,
                    traversalBudget: traversalBudget
                )
                if let last = rows.last { openCodeBeforeRowID = last.rowID }
                for row in rows {
                    let candidate = row.session.candidate(
                        databasePath: databasePath,
                        sourceIdentity: sourceIdentity
                    )
                    candidateCollector.append(candidate)
                    if newlyDiscoveredCandidates.count < pageLimit {
                        newlyDiscoveredCandidates.append(candidate)
                    }
                }
                // A progress-handler interruption returns the bounded prefix already stepped.
                // That short page is not end-of-catalog evidence; resume below its last rowid in
                // the next cycle instead of silently accepting a partial OpenCode inventory.
                if traversalBudget.stopReason != nil { break }
                if rows.count < requestCount { openCodeCatalogFinished = true }
                continue
            }

            guard let candidate = try nextFilesystemCandidate(traversalBudget: traversalBudget) else {
                if traversalBudget.stopReason == nil { finished = true }
                break
            }
            candidateCollector.append(candidate)
            if newlyDiscoveredCandidates.count < pageLimit {
                newlyDiscoveredCandidates.append(candidate)
            }
        }

        if finished {
            capacityLimited = candidateCollector.wasTruncated
            drainingCandidates = candidateCollector.takeSortedCandidates().filter {
                !emittedIncompleteCandidateKeys.contains(
                    BoundedCandidateCollector.referenceKey($0)
                )
            }
            emittedIncompleteCandidateKeys.removeAll(keepingCapacity: false)
            drainingCandidateIndex = 0
            return drainPage(maximumCandidates: pageLimit, traversalBudget: traversalBudget)
        }
        let incompleteCandidates: [AgentSourceCandidate]
        if didEmitIncompleteCandidates {
            incompleteCandidates = []
        } else {
            incompleteCandidates = newlyDiscoveredCandidates.sorted(
                by: BoundedCandidateCollector.outputOrder
            )
            emittedIncompleteCandidateKeys = Set(
                incompleteCandidates.map(BoundedCandidateCollector.referenceKey)
            )
            didEmitIncompleteCandidates = true
        }
        return AgentSourceDiscoveryResult(
            candidates: incompleteCandidates,
            incompleteReason: traversalBudget.stopReason,
            traversalUsage: traversalBudget.usage(),
            hasMoreCandidates: true
        )
    }

    var retainedCandidateCount: Int {
        candidateCollector.retainedCount + max(0, drainingCandidates.count - drainingCandidateIndex)
    }

    var retainedEstimatedBytes: Int {
        var total = candidateCollector.retainedEstimatedBytes
        total += emittedIncompleteCandidateKeys.reduce(0) {
            $0 + min(8_224, $1.utf8.count + 32)
        }
        guard drainingCandidateIndex < drainingCandidates.count else { return total }
        for candidate in drainingCandidates[drainingCandidateIndex...] {
            total += BoundedCandidateCollector.estimatedBytes(for: candidate)
        }
        return total
    }

    private func verifyOpenCodeSourceIdentity() throws {
        guard let expected = openCodeSourceIdentity else { return }
        let databasePath = sourceRoot.absoluteURL(relativePath: "opencode.db").path
        guard
            let current = try sourceRoot.sourceContainerIdentity(
                relativePath: "opencode.db",
                displayPath: databasePath
            ),
            current == expected
        else {
            throw AgentSourceReadError.changedDuringRead(databasePath)
        }
    }

    private func drainPage(
        maximumCandidates: Int,
        traversalBudget: AgentSourceTraversalBudget
    ) -> AgentSourceDiscoveryResult {
        let end = min(drainingCandidateIndex + maximumCandidates, drainingCandidates.count)
        let candidates = Array(drainingCandidates[drainingCandidateIndex..<end])
        drainingCandidateIndex = end
        let hasMore = drainingCandidateIndex < drainingCandidates.count
        if !hasMore {
            drainingCandidates.removeAll(keepingCapacity: false)
            drainingCandidateIndex = 0
        }
        return AgentSourceDiscoveryResult(
            candidates: candidates,
            incompleteReason: !hasMore && capacityLimited ? .candidateLimit : nil,
            traversalUsage: traversalBudget.usage(),
            hasMoreCandidates: hasMore
        )
    }

    private func nextFilesystemCandidate(
        traversalBudget: AgentSourceTraversalBudget
    ) throws -> AgentSourceCandidate? {
        while traversalBudget.checkpoint() {
            if directoryFrames.isEmpty {
                guard nextRootPlanIndex < rootPlans.count else { return nil }
                let plan = rootPlans[nextRootPlanIndex]
                nextRootPlanIndex += 1
                do {
                    let descriptor = try sourceRoot.openDirectory(relativePath: plan.relativePath)
                    directoryFrames.append(
                        try AgentDirectoryCursorFrame(
                            relativePath: plan.relativePath,
                            recursively: plan.recursively,
                            descriptor: descriptor
                        )
                    )
                } catch let error as AgentSourceReadError {
                    if case .missing = error { continue }
                    throw error
                }
                continue
            }

            let frame = directoryFrames[directoryFrames.count - 1]
            guard let name = try frame.nextName() else {
                directoryFrames.removeLast()
                continue
            }
            guard nameIsSafe(name) else { continue }
            let relativePath = frame.relativePath.isEmpty ? name : "\(frame.relativePath)/\(name)"
            guard relativePath.utf8.count <= 8_192 else {
                traversalBudget.stop(.pathLengthLimit)
                return nil
            }
            let metadataBytes = Int64(sourceRoot.rootPath.utf8.count + relativePath.utf8.count) + 65
            guard traversalBudget.consumeVisit(metadataBytes: metadataBytes) else {
                frame.pendingName = name
                return nil
            }

            let parentDescriptor = Darwin.dirfd(frame.stream)
            var status = stat()
            let statusResult = name.withCString {
                Darwin.fstatat(parentDescriptor, $0, &status, AT_SYMLINK_NOFOLLOW)
            }
            guard statusResult == 0 else {
                if errno == ENOENT { continue }
                throw AgentSourceReadError.inaccessible(
                    sourceRoot.absoluteURL(relativePath: relativePath).path
                )
            }
            switch status.st_mode & S_IFMT {
            case S_IFDIR where frame.recursively:
                guard shouldEnterDirectory(relativePath) else { continue }
                let descriptor = name.withCString {
                    Darwin.openat(
                        parentDescriptor,
                        $0,
                        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                    )
                }
                guard descriptor >= 0 else {
                    if errno == ENOENT { continue }
                    throw AgentSourceReadError.inaccessible(
                        sourceRoot.absoluteURL(relativePath: relativePath).path
                    )
                }
                guard directoryFrames.count < 65 else {
                    Darwin.close(descriptor)
                    traversalBudget.stop(.depthLimit)
                    return nil
                }
                directoryFrames.append(
                    try AgentDirectoryCursorFrame(
                        relativePath: relativePath,
                        recursively: true,
                        descriptor: descriptor
                    )
                )
            case S_IFREG:
                let url = sourceRoot.absoluteURL(relativePath: relativePath)
                guard shouldIncludeFile(relativePath: relativePath, url: url) else { continue }
                let descriptor = name.withCString {
                    Darwin.openat(parentDescriptor, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                }
                guard descriptor >= 0 else {
                    if errno == ENOENT { continue }
                    throw AgentSourceReadError.inaccessible(url.path)
                }
                defer { Darwin.close(descriptor) }
                let metadata = try AgentDirectSourceReader.fileMetadata(
                    descriptor: descriptor,
                    path: url.path
                )
                var candidate = AgentSourceCandidate(
                    reference: AgentSourceReference(kind: .file, path: url.path),
                    relativePath: relativePath,
                    stableConversationID: nil,
                    sourceCreatedAt: metadata.createdAt,
                    sourceModifiedAt: metadata.modifiedAt,
                    byteCount: metadata.byteCount,
                    sourceDevice: metadata.device,
                    sourceInode: metadata.inode,
                    sourceChangedSeconds: metadata.changedSeconds,
                    sourceChangedNanoseconds: metadata.changedNanoseconds
                )
                switch folder.provider {
                case .codex, .claudeCode, .copilot:
                    candidate.stableConversationID =
                        AgentDirectSourceReader.stableIdentifierFromFileName(
                            url,
                            provider: folder.provider
                        )
                case .cursor, .openCode, .gemini, .custom:
                    break
                }
                return candidate
            default:
                continue
            }
        }
        return nil
    }

    private func shouldEnterDirectory(_ relativePath: String) -> Bool {
        let url = sourceRoot.absoluteURL(relativePath: relativePath, isDirectory: true)
        guard !AgentScannerPolicy.shouldSkipCapabilityAuthorizedDirectory(url) else { return false }
        let components = relativePath.split(separator: "/").map(String.init)
        switch folder.provider {
        case .gemini:
            if components.count == 1 {
                return AgentDirectSourceReader.isHexIdentifier(components[0], exactLength: 64)
            }
            return components.count == 2 && components[1] == "chats"
        case .copilot:
            if components.count == 1 {
                return AgentDirectSourceReader.isHexIdentifier(
                    components[0],
                    minimumLength: 16,
                    maximumLength: 128
                )
            }
            return components.count == 2 && components[1] == "chatSessions"
        case .custom:
            return !AgentDirectSourceReader.isDedicatedProviderSubtree(relativePath)
        case .codex, .claudeCode, .cursor, .openCode:
            return true
        }
    }

    private func shouldIncludeFile(relativePath: String, url: URL) -> Bool {
        let lowerExtension = url.pathExtension.lowercased()
        switch folder.provider {
        case .codex:
            return lowerExtension == "jsonl" && url.lastPathComponent.hasPrefix("rollout-")
        case .claudeCode:
            return lowerExtension == "jsonl" && url.lastPathComponent != "sessions-index.json"
        case .openCode:
            return ["json", "jsonl", "ndjson"].contains(lowerExtension)
        case .gemini:
            let components = relativePath.split(separator: "/")
            return components.count == 3
                && components[1] == "chats"
                && lowerExtension == "json"
                && url.lastPathComponent.hasPrefix("session-")
        case .copilot:
            let components = relativePath.split(separator: "/")
            return components.count == 3
                && components[1] == "chatSessions"
                && ["json", "jsonl"].contains(lowerExtension)
        case .cursor, .custom:
            return AgentScannerPolicy.shouldIndexCapabilityAuthorized(
                url,
                mode: folder.captureMode,
                sourceRoot: folder.url
            )
        }
    }

    private func nameIsSafe(_ name: String) -> Bool {
        !name.isEmpty
            && name != "."
            && name != ".."
            && !name.contains("/")
            && !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
}

final class AgentDirectSourceScanSession {
    private let folder: AgentWatchedFolder
    private let fileManager: FileManager
    private let traversalBudget: AgentSourceTraversalBudget
    private let bodyReadBudget: AgentSourceBodyReadBudget
    private let sourceRoot: AgentSourceRootCapability
    private var openCodeConnections: [String: SQLiteReadConnection] = [:]
    private var openCodeConnectionErrors: [String: AgentSourceReadError] = [:]
    private var boundsOpenCodeConnectionSetup = false

    fileprivate init(
        folder: AgentWatchedFolder,
        fileManager: FileManager,
        traversalBudget: AgentSourceTraversalBudget,
        bodyReadBudget: AgentSourceBodyReadBudget
    ) throws {
        self.folder = folder
        self.fileManager = fileManager
        self.traversalBudget = traversalBudget
        self.bodyReadBudget = bodyReadBudget
        sourceRoot = try AgentSourceRootCapability(path: folder.path)
    }

    func makeDiscoveryCursor(maximumCandidates: Int) -> AgentDirectSourceDiscoveryCursor {
        AgentDirectSourceDiscoveryCursor(
            folder: folder,
            sourceRoot: sourceRoot,
            maximumCandidates: maximumCandidates
        )
    }

    func discoverNextPage(
        using cursor: AgentDirectSourceDiscoveryCursor,
        maximumCandidates: Int
    ) throws -> AgentSourceDiscoveryResult {
        boundsOpenCodeConnectionSetup = true
        defer { boundsOpenCodeConnectionSetup = false }
        return try cursor.nextPage(
            maximumPageCandidates: maximumCandidates,
            traversalBudget: traversalBudget,
            openCodeConnection: openCodeConnection(at:)
        )
    }

    func discover(maximumCandidates: Int) throws -> AgentSourceDiscoveryResult {
        var collector = BoundedCandidateCollector(maximumCount: maximumCandidates)
        boundsOpenCodeConnectionSetup = true
        defer { boundsOpenCodeConnectionSetup = false }
        do {
            try AgentDirectSourceReader.discover(
                folder: folder,
                collector: &collector,
                traversalBudget: traversalBudget,
                connection: openCodeConnection(at:),
                sourceRoot: sourceRoot,
                fileManager: fileManager
            )
        } catch is AgentSourceTraversalInterrupted {
            // The budget carries the explicit reason returned below. Expiration is
            // incomplete inventory, not provider inaccessibility.
        }
        return collector.result(traversalBudget: traversalBudget)
    }

    func candidates(for entries: [AgentSourceIndexEntry]) throws -> AgentSourceCandidateResolutionBatch {
        boundsOpenCodeConnectionSetup = true
        defer { boundsOpenCodeConnectionSetup = false }
        let batch = try AgentDirectSourceReader.candidates(
            for: entries,
            traversalBudget: traversalBudget,
            connection: openCodeConnection(at:),
            fileDescriptor: { [self] entry in
                try openFileDescriptor(
                    reference: entry.reference,
                    relativePath: entry.relativePath
                )
            }
        )
        return batch
    }

    func candidate(for entry: AgentSourceIndexEntry) throws -> AgentSourceCandidate {
        let batch = try candidates(for: [entry])
        guard let resolution = batch.resolutions.first else {
            throw AgentSourceReadError.missing(entry.reference.path)
        }
        if let candidate = resolution.candidate { return candidate }
        if let error = resolution.error { throw error }
        throw AgentSourceReadError.unsupported(
            "The provider catalog read was bounded before this source could be resolved; retry later."
        )
    }

    func read(
        candidate: AgentSourceCandidate,
        previous: AgentSourceIndexEntry?,
        maximumBytes: Int64,
        analyzeContent: Bool = true,
        analysisInterval: DateInterval? = nil,
        observedAt: Date = Date()
    ) throws -> AgentCaptureRecord {
        let record = try AgentDirectSourceReader.read(
            candidate: candidate,
            folder: folder,
            previous: previous,
            maximumBytes: maximumBytes,
            analyzeContent: analyzeContent,
            analysisInterval: analysisInterval,
            observedAt: observedAt,
            bodyReadBudget: bodyReadBudget,
            connection: openCodeConnection(at:),
            fileDescriptor: { [self] in try openFileDescriptor(candidate: $0) },
            verifyFileIdentity: { [self] candidate, expectedStatus in
                try currentFileMatches(
                    candidate: candidate,
                    expectedStatus: expectedStatus,
                    allowAppendOnlyGrowth: analysisInterval != nil && folder.provider == .codex
                )
            },
            fileManager: fileManager
        )
        return record
    }

    func verifyOpenCodeSourcesUnchanged() throws {
        for connection in openCodeConnections.values {
            try connection.verifySourceUnchanged(bodyReadBudget: bodyReadBudget)
        }
    }

    private func openCodeConnection(at path: String) throws -> SQLiteReadConnection {
        let expectedPath = folder.url.appendingPathComponent("opencode.db", isDirectory: false)
            .standardizedFileURL.path
        guard folder.provider == .openCode,
            URL(fileURLWithPath: path).standardizedFileURL.path == expectedPath
        else {
            throw AgentSourceReadError.inaccessible(path)
        }
        if let connection = openCodeConnections[path] { return connection }
        if let error = openCodeConnectionErrors[path] { throw error }
        do {
            let connection = try SQLiteReadConnection(
                path: path,
                sourceRoot: sourceRoot,
                relativePath: "opencode.db",
                fileManager: fileManager,
                traversalBudget: boundsOpenCodeConnectionSetup ? traversalBudget : nil
            )
            openCodeConnections[path] = connection
            return connection
        } catch is AgentSourceTraversalInterrupted {
            throw AgentSourceTraversalInterrupted()
        } catch let error as AgentSourceBodyReadInterrupted {
            throw error
        } catch let error as AgentSourceReadError {
            openCodeConnectionErrors[path] = error
            throw error
        } catch {
            let sourceError = AgentSourceReadError.inaccessible(path)
            openCodeConnectionErrors[path] = sourceError
            throw sourceError
        }
    }

    private func openFileDescriptor(candidate: AgentSourceCandidate) throws -> Int32 {
        try openFileDescriptor(
            reference: candidate.reference,
            relativePath: candidate.relativePath
        )
    }

    private func openFileDescriptor(
        reference: AgentSourceReference,
        relativePath: String
    ) throws -> Int32 {
        guard reference.kind == .file else {
            throw AgentSourceReadError.inaccessible(reference.path)
        }
        let relative = try sourceRoot.relativePath(forAbsolutePath: reference.path)
        guard relative == relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        else {
            throw AgentSourceReadError.inaccessible(reference.path)
        }
        return try sourceRoot.openRegularFile(relativePath: relative, displayPath: reference.path)
    }

    private func currentFileMatches(
        candidate: AgentSourceCandidate,
        expectedStatus: stat,
        allowAppendOnlyGrowth: Bool
    ) throws -> Bool {
        let descriptor = try openFileDescriptor(candidate: candidate)
        defer { Darwin.close(descriptor) }
        var currentStatus = stat()
        guard Darwin.fstat(descriptor, &currentStatus) == 0 else { return false }
        if allowAppendOnlyGrowth {
            return AgentDirectSourceReader.isSameAppendOnlyFile(
                currentStatus,
                initialStatus: expectedStatus
            )
        }
        return AgentDirectSourceReader.sameFileSnapshot(currentStatus, expectedStatus)
    }

}

enum AgentDirectSourceReader {
    static func makeScanSession(
        folder: AgentWatchedFolder,
        traversalBudget: AgentSourceTraversalBudget = AgentSourceTraversalBudget(),
        bodyReadBudget: AgentSourceBodyReadBudget = AgentSourceBodyReadBudget(),
        fileManager: FileManager = .default
    ) throws -> AgentDirectSourceScanSession {
        try AgentDirectSourceScanSession(
            folder: folder,
            fileManager: fileManager,
            traversalBudget: traversalBudget,
            bodyReadBudget: bodyReadBudget
        )
    }

    static func discover(
        folder: AgentWatchedFolder,
        fileManager: FileManager = .default
    ) throws -> [AgentSourceCandidate] {
        let session = try makeScanSession(folder: folder, fileManager: fileManager)
        let result = try session.discover(maximumCandidates: 50_000)
        try session.verifyOpenCodeSourcesUnchanged()
        return result.candidates
    }

    static func candidate(
        for entry: AgentSourceIndexEntry,
        fileManager: FileManager = .default
    ) throws -> AgentSourceCandidate {
        let sourceRoot: URL
        switch entry.reference.kind {
        case .sqliteConversation:
            sourceRoot = URL(fileURLWithPath: entry.reference.path).deletingLastPathComponent()
        case .file:
            let relative = entry.relativePath.split(separator: "/", omittingEmptySubsequences: true)
            var root = URL(fileURLWithPath: entry.reference.path)
            for _ in relative { root.deleteLastPathComponent() }
            sourceRoot = root
        }
        let session = try makeScanSession(
            folder: AgentWatchedFolder(
                id: entry.watchedFolderID,
                displayName: entry.watchedFolderName,
                path: sourceRoot.path,
                provider: entry.provider
            ),
            fileManager: fileManager
        )
        let candidate = try session.candidate(for: entry)
        try session.verifyOpenCodeSourcesUnchanged()
        return candidate
    }

    static func read(
        candidate: AgentSourceCandidate,
        folder: AgentWatchedFolder,
        previous: AgentSourceIndexEntry?,
        maximumBytes: Int64,
        analyzeContent: Bool = true,
        analysisInterval: DateInterval? = nil,
        observedAt: Date = Date(),
        fileManager: FileManager = .default
    ) throws -> AgentCaptureRecord {
        let session = try makeScanSession(folder: folder, fileManager: fileManager)
        let record = try session.read(
            candidate: candidate,
            previous: previous,
            maximumBytes: maximumBytes,
            analyzeContent: analyzeContent,
            analysisInterval: analysisInterval,
            observedAt: observedAt
        )
        try session.verifyOpenCodeSourcesUnchanged()
        return record
    }

    fileprivate static func read(
        candidate: AgentSourceCandidate,
        folder: AgentWatchedFolder,
        previous: AgentSourceIndexEntry?,
        maximumBytes: Int64,
        analyzeContent: Bool,
        analysisInterval: DateInterval?,
        observedAt: Date,
        bodyReadBudget: AgentSourceBodyReadBudget,
        connection: (String) throws -> SQLiteReadConnection,
        fileDescriptor: (AgentSourceCandidate) throws -> Int32,
        verifyFileIdentity: (AgentSourceCandidate, stat) throws -> Bool,
        fileManager: FileManager
    ) throws -> AgentCaptureRecord {
        switch candidate.reference.kind {
        case .file:
            return try readFile(
                candidate: candidate,
                folder: folder,
                previous: previous,
                maximumBytes: maximumBytes,
                analyzeContent: analyzeContent,
                analysisInterval: analysisInterval,
                observedAt: observedAt,
                bodyReadBudget: bodyReadBudget,
                fileDescriptor: fileDescriptor,
                verifyFileIdentity: verifyFileIdentity,
                fileManager: fileManager
            )
        case .sqliteConversation:
            return try readOpenCodeSession(
                candidate: candidate,
                folder: folder,
                previous: previous,
                maximumBytes: maximumBytes,
                analyzeContent: analyzeContent,
                observedAt: observedAt,
                bodyReadBudget: bodyReadBudget,
                connection: connection
            )
        }
    }

    private static func readFile(
        candidate: AgentSourceCandidate,
        folder: AgentWatchedFolder,
        previous: AgentSourceIndexEntry?,
        maximumBytes: Int64,
        analyzeContent: Bool,
        analysisInterval: DateInterval?,
        observedAt: Date,
        bodyReadBudget: AgentSourceBodyReadBudget,
        fileDescriptor: (AgentSourceCandidate) throws -> Int32,
        verifyFileIdentity: (AgentSourceCandidate, stat) throws -> Bool,
        fileManager: FileManager
    ) throws -> AgentCaptureRecord {
        _ = fileManager
        let url = URL(fileURLWithPath: candidate.reference.path)
        let descriptor = try fileDescriptor(candidate)
        let readResult = try streamFile(
            at: url,
            descriptor: descriptor,
            provider: folder.provider,
            maximumBytes: maximumBytes,
            analyzeContent: analyzeContent,
            analysisInterval: analysisInterval,
            allowAppendOnlyGrowth: analysisInterval != nil && folder.provider == .codex,
            bodyReadBudget: bodyReadBudget,
            verifyCurrentIdentity: { try verifyFileIdentity(candidate, $0) }
        )
        let stableID =
            nonEmpty(candidate.stableConversationID) ?? nonEmpty(readResult.summary.sessionID)
            ?? "file-" + String(SHA256Digest.hashHex(url.standardizedFileURL.path).prefix(32))
        let id = indexID(provider: folder.provider, stableConversationID: stableID)
        let entry = AgentSourceIndexEntry(
            id: id,
            stableConversationID: stableID,
            watchedFolderID: folder.id,
            watchedFolderName: folder.displayName,
            provider: folder.provider,
            reference: candidate.reference,
            relativePath: candidate.relativePath,
            sourceCreatedAt: readResult.createdAt,
            sourceModifiedAt: readResult.modifiedAt,
            conversationStartedAt: readResult.isAnalyzed
                ? readResult.summary.startedAt ?? previous?.conversationStartedAt
                : previous?.conversationStartedAt,
            conversationEndedAt: readResult.isAnalyzed
                ? readResult.summary.endedAt ?? previous?.conversationEndedAt
                : previous?.conversationEndedAt,
            firstIndexedAt: previous?.firstIndexedAt ?? observedAt,
            lastObservedAt: observedAt,
            byteCount: readResult.byteCount,
            sha256: readResult.sha256,
            sourceDevice: readResult.device,
            sourceInode: readResult.inode,
            sourceChangedSeconds: readResult.changedSeconds,
            sourceChangedNanoseconds: readResult.changedNanoseconds,
            startOffset: 0,
            endOffset: readResult.byteCount,
            availability: .available
        )
        return AgentCaptureRecord(
            index: entry,
            summary: readResult.summary,
            isAnalyzed: readResult.isAnalyzed
        )
    }

    private static func readOpenCodeSession(
        candidate: AgentSourceCandidate,
        folder: AgentWatchedFolder,
        previous: AgentSourceIndexEntry?,
        maximumBytes: Int64,
        analyzeContent: Bool,
        observedAt: Date,
        bodyReadBudget: AgentSourceBodyReadBudget,
        connection connectionProvider: (String) throws -> SQLiteReadConnection
    ) throws -> AgentCaptureRecord {
        guard let opaqueLocator = candidate.reference.locator else {
            throw AgentSourceReadError.missing(candidate.reference.path)
        }
        let connection = try connectionProvider(candidate.reference.path)
        let session: AgentOpenCodeSessionMetadata?
        if let metadata = candidate.openCodeMetadata {
            session = metadata
        } else {
            session = try connection.openCodeSession(locator: opaqueLocator)
        }
        guard let session else {
            throw AgentSourceReadError.missing("\(candidate.reference.path)#session/\(opaqueLocator)")
        }
        guard session.opaqueLocator(databasePath: candidate.reference.path) == opaqueLocator else {
            throw AgentSourceReadError.changedDuringRead(candidate.reference.path)
        }
        let content = try connection.readOpenCodeConversation(
            sessionID: session.id,
            opaqueLocator: opaqueLocator,
            maximumBytes: maximumBytes,
            analyzeContent: analyzeContent,
            bodyReadBudget: bodyReadBudget
        )
        var summary = content.summary
        summary.format = .database
        summary.sessionID = opaqueLocator
        summary.title = session.title
        summary.projectPath = session.directory
        summary.startedAt = session.createdAt
        summary.endedAt = session.modifiedAt
        let stableID = opaqueLocator
        let entry = AgentSourceIndexEntry(
            id: indexID(provider: folder.provider, stableConversationID: stableID),
            stableConversationID: stableID,
            watchedFolderID: folder.id,
            watchedFolderName: folder.displayName,
            provider: folder.provider,
            reference: candidate.reference,
            relativePath: candidate.relativePath,
            sourceCreatedAt: session.createdAt,
            sourceModifiedAt: session.modifiedAt,
            conversationStartedAt: session.createdAt,
            conversationEndedAt: session.modifiedAt,
            firstIndexedAt: previous?.firstIndexedAt ?? observedAt,
            lastObservedAt: observedAt,
            byteCount: content.byteCount,
            sha256: content.sha256,
            sourceDevice: candidate.sourceDevice,
            sourceInode: candidate.sourceInode,
            sourceChangedSeconds: candidate.sourceChangedSeconds,
            sourceChangedNanoseconds: candidate.sourceChangedNanoseconds,
            sourceContainerByteCount: candidate.sourceContainerByteCount,
            sourceContainerModifiedSeconds: candidate.sourceContainerModifiedSeconds,
            sourceContainerModifiedNanoseconds: candidate.sourceContainerModifiedNanoseconds,
            availability: .available
        )
        return AgentCaptureRecord(index: entry, summary: summary, isAnalyzed: analyzeContent)
    }

    fileprivate static func discover(
        folder: AgentWatchedFolder,
        collector: inout BoundedCandidateCollector,
        traversalBudget: AgentSourceTraversalBudget,
        connection: (String) throws -> SQLiteReadConnection,
        sourceRoot: AgentSourceRootCapability,
        fileManager: FileManager
    ) throws {
        guard traversalBudget.checkpoint() else { return }
        switch folder.provider {
        case .codex:
            try discoverCodex(
                folder: folder,
                collector: &collector,
                traversalBudget: traversalBudget,
                sourceRoot: sourceRoot
            )
        case .claudeCode:
            try discoverClaude(
                folder: folder,
                collector: &collector,
                traversalBudget: traversalBudget,
                sourceRoot: sourceRoot
            )
        case .openCode:
            try discoverOpenCode(
                folder: folder,
                collector: &collector,
                traversalBudget: traversalBudget,
                connection: connection,
                sourceRoot: sourceRoot
            )
        case .gemini:
            try discoverGemini(
                folder: folder,
                collector: &collector,
                traversalBudget: traversalBudget,
                sourceRoot: sourceRoot
            )
        case .copilot:
            try discoverCopilot(
                folder: folder,
                collector: &collector,
                traversalBudget: traversalBudget,
                sourceRoot: sourceRoot
            )
        case .cursor, .custom:
            try discoverGenericFiles(
                folder: folder,
                collector: &collector,
                traversalBudget: traversalBudget,
                sourceRoot: sourceRoot
            )
        }
        _ = fileManager
    }

    fileprivate static func candidates(
        for entries: [AgentSourceIndexEntry],
        traversalBudget: AgentSourceTraversalBudget,
        connection: (String) throws -> SQLiteReadConnection,
        fileDescriptor: (AgentSourceIndexEntry) throws -> Int32
    ) throws -> AgentSourceCandidateResolutionBatch {
        var output = [AgentSourceCandidateResolution?](repeating: nil, count: entries.count)
        var sqliteEntriesByPath: [String: [(offset: Int, entry: AgentSourceIndexEntry, locator: String)]] = [:]

        for (offset, entry) in entries.enumerated() {
            let metadataCost =
                Int64(entry.reference.path.utf8.count)
                + Int64(entry.reference.locator?.utf8.count ?? 0)
                + 64
            guard traversalBudget.consumeVisit(metadataBytes: metadataCost) else { break }
            switch entry.reference.kind {
            case .file:
                do {
                    let descriptor = try fileDescriptor(entry)
                    defer { Darwin.close(descriptor) }
                    let metadata = try self.fileMetadata(
                        descriptor: descriptor,
                        path: entry.reference.path
                    )
                    output[offset] = AgentSourceCandidateResolution(
                        entry: entry,
                        candidate: AgentSourceCandidate(
                            reference: entry.reference,
                            relativePath: entry.relativePath,
                            stableConversationID: entry.stableConversationID,
                            sourceCreatedAt: metadata.createdAt,
                            sourceModifiedAt: metadata.modifiedAt,
                            byteCount: metadata.byteCount,
                            sourceDevice: metadata.device,
                            sourceInode: metadata.inode,
                            sourceChangedSeconds: metadata.changedSeconds,
                            sourceChangedNanoseconds: metadata.changedNanoseconds
                        ),
                        error: nil
                    )
                } catch let error as AgentSourceReadError {
                    output[offset] = AgentSourceCandidateResolution(entry: entry, candidate: nil, error: error)
                }
            case .sqliteConversation:
                guard let locator = entry.reference.locator,
                    !locator.isEmpty,
                    locator.utf8.count <= 1_024
                else {
                    output[offset] = AgentSourceCandidateResolution(
                        entry: entry,
                        candidate: nil,
                        error: .missing(entry.reference.path)
                    )
                    continue
                }
                sqliteEntriesByPath[entry.reference.path, default: []].append((offset, entry, locator))
            }
        }

        for (databasePath, pending) in sqliteEntriesByPath {
            guard traversalBudget.checkpoint() else { break }
            do {
                let database = try connection(databasePath)
                let sourceIdentity = try database.sourceContainerIdentity()
                let byLocator = try database.openCodeSessions(
                    resolving: pending.map(\.locator),
                    traversalBudget: traversalBudget
                )
                for item in pending {
                    if let session = byLocator[item.locator] {
                        output[item.offset] = AgentSourceCandidateResolution(
                            entry: item.entry,
                            candidate: session.candidate(
                                databasePath: databasePath,
                                sourceIdentity: sourceIdentity
                            ),
                            error: nil
                        )
                    } else if traversalBudget.stopReason == nil {
                        let safeLocator =
                            AgentStableConversationIdentifier.isPersisted(item.locator)
                            ? item.locator
                            : AgentStableConversationIdentifier.persisted(
                                provider: .openCode,
                                folderID: AgentFolderIdentifier.persisted(
                                    provider: .openCode,
                                    path: URL(fileURLWithPath: databasePath)
                                        .deletingLastPathComponent().path
                                ),
                                rawValue: item.locator,
                                reference: AgentSourceReference(
                                    kind: .sqliteConversation,
                                    path: databasePath
                                )
                            )
                        output[item.offset] = AgentSourceCandidateResolution(
                            entry: item.entry,
                            candidate: nil,
                            error: .missing("\(databasePath)#session/\(safeLocator)")
                        )
                    }
                }
            } catch is AgentSourceTraversalInterrupted {
                break
            } catch let error as AgentSourceReadError {
                for item in pending {
                    output[item.offset] = AgentSourceCandidateResolution(
                        entry: item.entry,
                        candidate: nil,
                        error: error
                    )
                }
            }
        }

        let resolutions = output.enumerated().map { offset, resolution in
            resolution
                ?? AgentSourceCandidateResolution(
                    entry: entries[offset],
                    candidate: nil,
                    error: traversalBudget.stopReason == nil
                        ? .inaccessible(entries[offset].reference.path)
                        : nil
                )
        }
        return AgentSourceCandidateResolutionBatch(
            resolutions: resolutions,
            incompleteReason: traversalBudget.stopReason,
            traversalUsage: traversalBudget.usage()
        )
    }

    private static func discoverCodex(
        folder: AgentWatchedFolder,
        collector: inout BoundedCandidateCollector,
        traversalBudget: AgentSourceTraversalBudget,
        sourceRoot: AgentSourceRootCapability
    ) throws {
        for relativeRoot in ["sessions", "archived_sessions"]
        where try sourceRoot.directoryExists(relativePath: relativeRoot) {
            guard traversalBudget.checkpoint() else { break }
            try discoverFiles(
                folder: folder,
                sourceRoot: sourceRoot,
                relativeRoot: relativeRoot,
                recursively: true,
                traversalBudget: traversalBudget,
                include: {
                    $0.pathExtension.lowercased() == "jsonl"
                        && $0.lastPathComponent.hasPrefix("rollout-")
                },
                transform: { candidate in
                    var candidate = candidate
                    candidate.stableConversationID = stableIdentifierFromFileName(
                        URL(fileURLWithPath: candidate.reference.path),
                        provider: .codex
                    )
                    return candidate
                },
                collector: &collector
            )
        }
    }

    private static func discoverClaude(
        folder: AgentWatchedFolder,
        collector: inout BoundedCandidateCollector,
        traversalBudget: AgentSourceTraversalBudget,
        sourceRoot: AgentSourceRootCapability
    ) throws {
        let projects = "projects"
        guard try sourceRoot.directoryExists(relativePath: projects) else { return }
        try discoverFiles(
            folder: folder,
            sourceRoot: sourceRoot,
            relativeRoot: projects,
            recursively: true,
            traversalBudget: traversalBudget,
            include: { url in
                url.pathExtension.lowercased() == "jsonl" && url.lastPathComponent != "sessions-index.json"
            },
            transform: { candidate in
                var candidate = candidate
                candidate.stableConversationID = stableIdentifierFromFileName(
                    URL(fileURLWithPath: candidate.reference.path),
                    provider: .claudeCode
                )
                return candidate
            },
            collector: &collector
        )
    }

    private static func discoverGemini(
        folder: AgentWatchedFolder,
        collector: inout BoundedCandidateCollector,
        traversalBudget: AgentSourceTraversalBudget,
        sourceRoot: AgentSourceRootCapability
    ) throws {
        try sourceRoot.forEachDirectoryChild(relativePath: "", traversalBudget: traversalBudget) {
            projectRelative, status in
            guard status.st_mode & S_IFMT == S_IFDIR else { return }
            let project = sourceRoot.absoluteURL(relativePath: projectRelative, isDirectory: true)
            guard isHexIdentifier(project.lastPathComponent, exactLength: 64) else { return }
            let chats = "\(projectRelative)/chats"
            guard try sourceRoot.directoryExists(relativePath: chats) else { return }
            try discoverFiles(
                folder: folder,
                sourceRoot: sourceRoot,
                relativeRoot: chats,
                recursively: false,
                traversalBudget: traversalBudget,
                include: {
                    $0.pathExtension.lowercased() == "json"
                        && $0.lastPathComponent.hasPrefix("session-")
                },
                collector: &collector
            )
        }
    }

    private static func discoverCopilot(
        folder: AgentWatchedFolder,
        collector: inout BoundedCandidateCollector,
        traversalBudget: AgentSourceTraversalBudget,
        sourceRoot: AgentSourceRootCapability
    ) throws {
        try sourceRoot.forEachDirectoryChild(relativePath: "", traversalBudget: traversalBudget) {
            workspaceRelative, status in
            guard status.st_mode & S_IFMT == S_IFDIR else { return }
            let workspace = sourceRoot.absoluteURL(relativePath: workspaceRelative, isDirectory: true)
            guard
                isHexIdentifier(
                    workspace.lastPathComponent,
                    minimumLength: 16,
                    maximumLength: 128
                )
            else { return }
            let sessions = "\(workspaceRelative)/chatSessions"
            guard try sourceRoot.directoryExists(relativePath: sessions) else { return }
            try discoverFiles(
                folder: folder,
                sourceRoot: sourceRoot,
                relativeRoot: sessions,
                recursively: false,
                traversalBudget: traversalBudget,
                include: { ["json", "jsonl"].contains($0.pathExtension.lowercased()) },
                transform: { candidate in
                    var candidate = candidate
                    candidate.stableConversationID = stableIdentifierFromFileName(
                        URL(fileURLWithPath: candidate.reference.path),
                        provider: .copilot
                    )
                    return candidate
                },
                collector: &collector
            )
        }
    }

    private static func discoverOpenCode(
        folder: AgentWatchedFolder,
        collector: inout BoundedCandidateCollector,
        traversalBudget: AgentSourceTraversalBudget,
        connection connectionProvider: (String) throws -> SQLiteReadConnection,
        sourceRoot: AgentSourceRootCapability
    ) throws {
        let database = sourceRoot.absoluteURL(relativePath: "opencode.db")
        if traversalBudget.checkpoint(), try sourceRoot.regularFileExists(relativePath: "opencode.db") {
            let connection = try connectionProvider(database.path)
            let sourceIdentity = try connection.sourceContainerIdentity()
            try connection.forEachOpenCodeSession(
                limit: collector.maximumCount + 1,
                traversalBudget: traversalBudget
            ) { session in
                collector.append(
                    session.candidate(
                        databasePath: database.path,
                        sourceIdentity: sourceIdentity
                    )
                )
            }
        }

        let legacySessionRoot = "storage/session"
        if traversalBudget.checkpoint(), try sourceRoot.directoryExists(relativePath: legacySessionRoot) {
            try discoverFiles(
                folder: folder,
                sourceRoot: sourceRoot,
                relativeRoot: legacySessionRoot,
                recursively: true,
                traversalBudget: traversalBudget,
                include: { ["json", "jsonl", "ndjson"].contains($0.pathExtension.lowercased()) },
                collector: &collector
            )
        }
    }

    private static func discoverGenericFiles(
        folder: AgentWatchedFolder,
        collector: inout BoundedCandidateCollector,
        traversalBudget: AgentSourceTraversalBudget,
        sourceRoot: AgentSourceRootCapability
    ) throws {
        try discoverFiles(
            folder: folder,
            sourceRoot: sourceRoot,
            relativeRoot: "",
            recursively: folder.includeSubdirectories,
            traversalBudget: traversalBudget,
            include: {
                AgentScannerPolicy.shouldIndexCapabilityAuthorized(
                    $0,
                    mode: folder.captureMode,
                    sourceRoot: folder.url
                )
            },
            collector: &collector
        )
    }

    private static func discoverFiles(
        folder: AgentWatchedFolder,
        sourceRoot: AgentSourceRootCapability,
        relativeRoot: String,
        recursively: Bool,
        traversalBudget: AgentSourceTraversalBudget,
        include: (URL) -> Bool,
        transform: (AgentSourceCandidate) -> AgentSourceCandidate = { $0 },
        collector: inout BoundedCandidateCollector
    ) throws {
        try sourceRoot.forEachRegularFile(
            relativeRoot: relativeRoot,
            recursively: recursively,
            traversalBudget: traversalBudget,
            shouldSkipDirectory: { relativePath in
                folder.provider == .custom && isDedicatedProviderSubtree(relativePath)
            },
            body: { relativePath, descriptor in
                let url = sourceRoot.absoluteURL(relativePath: relativePath)
                guard include(url) else { return }
                let metadata = try fileMetadata(descriptor: descriptor, path: url.path)
                collector.append(
                    transform(
                        AgentSourceCandidate(
                            reference: AgentSourceReference(kind: .file, path: url.path),
                            relativePath: relativePath,
                            stableConversationID: nil,
                            sourceCreatedAt: metadata.createdAt,
                            sourceModifiedAt: metadata.modifiedAt,
                            byteCount: metadata.byteCount,
                            sourceDevice: metadata.device,
                            sourceInode: metadata.inode,
                            sourceChangedSeconds: metadata.changedSeconds,
                            sourceChangedNanoseconds: metadata.changedNanoseconds
                        )))
            })
    }

    /// A custom parent source must not silently become a second implementation of a provider
    /// adapter. Those roots have provider-specific filtering and identity rules, so the generic
    /// walker prunes them before examining any file in either capture mode.
    fileprivate static func isDedicatedProviderSubtree(_ relativePath: String) -> Bool {
        let components = relativePath.split(separator: "/").map {
            $0.lowercased().unicodeScalars
                .filter(CharacterSet.alphanumerics.contains)
                .map(String.init)
                .joined()
        }
        let providerComponents: Set<String> = [
            "codex", "claude", "gemini", "opencode", "cursor", "githubcopilotchat",
        ]
        if components.contains(where: providerComponents.contains) { return true }
        let joined = components.joined(separator: "/")
        return joined.contains("library/applicationsupport/code/user/workspacestorage")
            || joined.contains("library/applicationsupport/code/user/globalstorage")
            || joined.contains("library/applicationsupport/cursor/user/workspacestorage")
            || joined.contains("library/applicationsupport/cursor/user/globalstorage")
    }

    fileprivate struct FileMetadata {
        var createdAt: Date?
        var modifiedAt: Date?
        var byteCount: Int64
        var device: UInt64
        var inode: UInt64
        var changedSeconds: Int64
        var changedNanoseconds: Int64
    }

    fileprivate static func fileMetadata(descriptor: Int32, path: String) throws -> FileMetadata {
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0,
            status.st_mode & S_IFMT == S_IFREG
        else {
            throw AgentSourceReadError.inaccessible(path)
        }
        return FileMetadata(
            createdAt: date(from: status.st_birthtimespec),
            modifiedAt: date(from: status.st_mtimespec),
            byteCount: Int64(status.st_size),
            device: UInt64(status.st_dev),
            inode: UInt64(status.st_ino),
            changedSeconds: Int64(status.st_ctimespec.tv_sec),
            changedNanoseconds: Int64(status.st_ctimespec.tv_nsec)
        )
    }

    private struct FileReadResult {
        var createdAt: Date?
        var modifiedAt: Date?
        var byteCount: Int64
        var device: UInt64
        var inode: UInt64
        var changedSeconds: Int64
        var changedNanoseconds: Int64
        var sha256: String
        var summary: AgentDocumentSummary
        var isAnalyzed: Bool
    }

    fileprivate static func sameFileSnapshot(_ left: stat, _ right: stat) -> Bool {
        FileSnapshot(left) == FileSnapshot(right)
    }

    static func isSameAppendOnlyFile(_ current: stat, initialStatus: stat) -> Bool {
        current.st_mode & S_IFMT == S_IFREG
            && current.st_dev == initialStatus.st_dev
            && current.st_ino == initialStatus.st_ino
            && current.st_size >= initialStatus.st_size
            && current.st_birthtimespec.tv_sec == initialStatus.st_birthtimespec.tv_sec
            && current.st_birthtimespec.tv_nsec == initialStatus.st_birthtimespec.tv_nsec
    }

    private struct FileSnapshot: Equatable {
        var device: UInt64
        var inode: UInt64
        var byteCount: Int64
        var modifiedSeconds: Int64
        var modifiedNanoseconds: Int64
        var changedSeconds: Int64
        var changedNanoseconds: Int64
        var createdAt: Date?
        var modifiedAt: Date?

        init(_ status: stat) {
            device = UInt64(status.st_dev)
            inode = UInt64(status.st_ino)
            byteCount = Int64(status.st_size)
            modifiedSeconds = Int64(status.st_mtimespec.tv_sec)
            modifiedNanoseconds = Int64(status.st_mtimespec.tv_nsec)
            changedSeconds = Int64(status.st_ctimespec.tv_sec)
            changedNanoseconds = Int64(status.st_ctimespec.tv_nsec)
            createdAt = date(from: status.st_birthtimespec)
            modifiedAt = date(from: status.st_mtimespec)
        }
    }

    private static func streamFile(
        at url: URL,
        descriptor: Int32,
        provider: AgentProvider,
        maximumBytes: Int64,
        analyzeContent: Bool,
        analysisInterval: DateInterval?,
        allowAppendOnlyGrowth: Bool,
        bodyReadBudget: AgentSourceBodyReadBudget,
        verifyCurrentIdentity: (stat) throws -> Bool
    ) throws -> FileReadResult {
        defer { _ = close(descriptor) }

        var initialStatus = stat()
        guard fstat(descriptor, &initialStatus) == 0,
            initialStatus.st_mode & S_IFMT == S_IFREG
        else {
            throw AgentSourceReadError.inaccessible(url.path)
        }
        let initial = FileSnapshot(initialStatus)
        let effectiveMaximumBytes = max(
            0,
            min(maximumBytes, bodyReadBudget.limits.maximumBytes)
        )
        guard initial.byteCount <= effectiveMaximumBytes else {
            throw AgentSourceReadError.fileTooLarge(
                path: url.path,
                bytes: initial.byteCount,
                maximum: effectiveMaximumBytes
            )
        }
        let ext = url.pathExtension.lowercased()
        let maximumBufferedJSONBytes: Int64 = 8 * 1_024 * 1_024
        if analyzeContent,
            ["json", "agent-event"].contains(ext),
            initial.byteCount > maximumBufferedJSONBytes
        {
            throw AgentSourceReadError.unsupported(
                "JSON transcript analysis is bounded to 8 MiB; the source was left unanalyzed."
            )
        }
        guard bodyReadBudget.canReadKnownLength(initial.byteCount) else {
            throw AgentSourceBodyReadInterrupted(
                reason: bodyReadBudget.stopReason ?? .byteLimit
            )
        }

        var jsonLines =
            analyzeContent && ["jsonl", "ndjson", "trace"].contains(ext)
            ? AgentTranscriptParser.IncrementalJSONLines(
                fileURL: url,
                provider: provider,
                analysisInterval: analysisInterval
            )
            : nil
        let streamingTextExtensions: Set<String> = [
            "md", "markdown", "txt", "log", "csv", "yaml", "yml", "toml", "session",
        ]
        var text =
            analyzeContent && streamingTextExtensions.contains(ext)
            ? AgentTranscriptParser.IncrementalText(fileURL: url, markdown: ["md", "markdown"].contains(ext))
            : nil
        let buffersJSON =
            analyzeContent
            && ["json", "agent-event"].contains(ext)
            && initial.byteCount <= maximumBufferedJSONBytes
        var jsonData = buffersJSON ? Data() : nil
        if buffersJSON { jsonData?.reserveCapacity(Int(initial.byteCount)) }

        var hasher = CryptoKit.SHA256()
        var bytesRead: Int64 = 0
        var readBuffer = [UInt8](repeating: 0, count: 128 * 1_024)
        do {
            // Read exactly the descriptor size that was authorized above. A provider may append
            // after the initial fstat; reading to EOF would otherwise let a JSON file selected for
            // the 8 MiB in-memory parser grow all the way to the much larger per-file limit before
            // the final identity check rejects it.
            while bytesRead < initial.byteCount {
                let remaining = initial.byteCount - bytesRead
                let requestedBytes = Int(min(Int64(readBuffer.count), remaining))
                let readCount = readBuffer.withUnsafeMutableBytes { rawBuffer -> Int in
                    guard let baseAddress = rawBuffer.baseAddress else { return 0 }
                    while true {
                        let result = Darwin.read(descriptor, baseAddress, requestedBytes)
                        if result >= 0 { return result }
                        if errno != EINTR { return -1 }
                    }
                }
                guard readCount >= 0 else {
                    throw AgentSourceReadError.inaccessible(url.path)
                }
                guard readCount > 0 else { break }
                guard bodyReadBudget.consume(Int64(readCount)) else {
                    throw AgentSourceBodyReadInterrupted(
                        reason: bodyReadBudget.stopReason ?? .byteLimit
                    )
                }
                bytesRead += Int64(readCount)
                guard bytesRead <= maximumBytes else {
                    throw AgentSourceReadError.fileTooLarge(
                        path: url.path,
                        bytes: bytesRead,
                        maximum: maximumBytes
                    )
                }
                readBuffer.withUnsafeBytes { rawBuffer in
                    let chunk = UnsafeRawBufferPointer(rebasing: rawBuffer[..<readCount])
                    hasher.update(bufferPointer: chunk)
                    jsonLines?.consume(bytes: chunk)
                    text?.consume(bytes: chunk)
                    jsonData?.append(contentsOf: chunk)
                }
            }
        } catch let error as AgentSourceReadError {
            throw error
        } catch let error as AgentSourceBodyReadInterrupted {
            throw error
        } catch {
            throw AgentSourceReadError.inaccessible(url.path)
        }

        var finalStatus = stat()
        guard fstat(descriptor, &finalStatus) == 0 else {
            throw AgentSourceReadError.inaccessible(url.path)
        }
        let final = FileSnapshot(finalStatus)
        let descriptorMatches = allowAppendOnlyGrowth
            ? isSameAppendOnlyFile(finalStatus, initialStatus: initialStatus)
            : initial == final
        guard descriptorMatches,
            try verifyCurrentIdentity(initialStatus),
            bytesRead == initial.byteCount
        else {
            throw AgentSourceReadError.changedDuringRead(url.path)
        }

        let summary: AgentDocumentSummary
        let isAnalyzed: Bool
        if var parser = jsonLines {
            summary = parser.finish()
            isAnalyzed = true
        } else if var parser = text {
            summary = parser.finish()
            isAnalyzed = true
        } else if let jsonData {
            summary = AgentTranscriptParser.parse(data: jsonData, fileURL: url, provider: provider)
            isAnalyzed = true
        } else {
            summary = AgentTranscriptParser.unanalyzedSummary(for: url)
            isAnalyzed = false
        }

        return FileReadResult(
            createdAt: initial.createdAt,
            modifiedAt: initial.modifiedAt,
            byteCount: bytesRead,
            device: initial.device,
            inode: initial.inode,
            changedSeconds: initial.changedSeconds,
            changedNanoseconds: initial.changedNanoseconds,
            sha256: digestHex(hasher.finalize()),
            summary: summary,
            isAnalyzed: isAnalyzed
        )
    }

    fileprivate static func isHexIdentifier(_ value: String, exactLength: Int) -> Bool {
        isHexIdentifier(value, minimumLength: exactLength, maximumLength: exactLength)
    }

    fileprivate static func isHexIdentifier(
        _ value: String,
        minimumLength: Int,
        maximumLength: Int
    ) -> Bool {
        guard value.count >= minimumLength, value.count <= maximumLength else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains(scalar)
        }
    }

    fileprivate static func stableIdentifierFromFileName(
        _ url: URL,
        provider: AgentProvider
    ) -> String? {
        let base = url.deletingPathExtension().lastPathComponent
        switch provider {
        case .codex:
            let groups = base.split(separator: "-")
            guard groups.count >= 5 else { return nil }
            let candidate = groups.suffix(5).joined(separator: "-")
            return UUID(uuidString: candidate)?.uuidString.lowercased()
        case .claudeCode, .copilot:
            return UUID(uuidString: base)?.uuidString.lowercased()
        case .cursor, .openCode, .gemini, .custom:
            return nil
        }
    }

    private static func date(from value: timespec) -> Date? {
        guard value.tv_sec > 0 else { return nil }
        return Date(
            timeIntervalSince1970: TimeInterval(value.tv_sec)
                + TimeInterval(value.tv_nsec) / 1_000_000_000
        )
    }

    private static func digestHex<S: Sequence>(_ digest: S) -> String where S.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func indexID(provider: AgentProvider, stableConversationID: String) -> String {
        "agent-conversation-"
            + String(SHA256Digest.hashHex("\(provider.rawValue)\u{0}\(stableConversationID)").prefix(32))
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : String(trimmed.prefix(500))
    }

}

struct AgentOpenCodeSessionMetadata: Equatable, Sendable {
    var id: String
    var title: String
    var directory: String
    var createdAt: Date
    var modifiedAt: Date

    func opaqueLocator(databasePath: String) -> String {
        let folderID = AgentFolderIdentifier.persisted(
            provider: .openCode,
            path: URL(fileURLWithPath: databasePath).deletingLastPathComponent().path
        )
        return AgentStableConversationIdentifier.persisted(
            provider: .openCode,
            folderID: folderID,
            rawValue: id,
            reference: AgentSourceReference(kind: .sqliteConversation, path: databasePath)
        )
    }

    fileprivate func candidate(
        databasePath: String,
        sourceIdentity: AgentSourceContainerIdentity
    ) -> AgentSourceCandidate {
        let opaqueLocator = opaqueLocator(databasePath: databasePath)
        return AgentSourceCandidate(
            reference: AgentSourceReference(
                kind: .sqliteConversation,
                path: databasePath,
                locator: opaqueLocator
            ),
            relativePath: "opencode.db#session/\(opaqueLocator)",
            stableConversationID: opaqueLocator,
            sourceCreatedAt: createdAt,
            sourceModifiedAt: modifiedAt,
            byteCount: nil,
            sourceDevice: sourceIdentity.device,
            sourceInode: sourceIdentity.inode,
            sourceChangedSeconds: sourceIdentity.changedSeconds,
            sourceChangedNanoseconds: sourceIdentity.changedNanoseconds,
            sourceContainerByteCount: sourceIdentity.byteCount,
            sourceContainerModifiedSeconds: sourceIdentity.modifiedSeconds,
            sourceContainerModifiedNanoseconds: sourceIdentity.modifiedNanoseconds,
            openCodeMetadata: self
        )
    }
}

private struct AgentOpenCodeSessionRow: Sendable {
    var rowID: Int64
    var session: AgentOpenCodeSessionMetadata
}

enum AgentSQLiteReadMetrics {
    struct ReadOnlyConfiguration: Equatable, Sendable {
        var databaseIsReadOnly: Bool
        var tempStoreMode: Int32
        var memoryMapSizeBytes: Int32
        var queryOnlyMode: Int32
        var noFollowOpenAttempted: Bool
        var usesPinnedSourceDescriptor: Bool
    }

    #if DEBUG
        private static let lock = NSLock()
        private static var opensByPath: [String: Int] = [:]
        private static var configurationsByPath: [String: ReadOnlyConfiguration] = [:]
        private static var catalogScansByPath: [String: Int] = [:]
        private static var databasePageReadBytesByPath: [String: Int64] = [:]
        private static var maximumObservedBodyRowBytesByPath: [String: Int64] = [:]
        private static var bodyBlobReadBytesByPath: [String: Int64] = [:]
        private static var maximumBodyBlobReadChunkBytesByPath: [String: Int] = [:]
        private static var statementSortCountByPath: [String: Int] = [:]
        private static var maximumStatementMemoryBytesByPath: [String: Int] = [:]
    #endif

    static func recordOpen(path: String) {
        #if DEBUG
            lock.lock()
            opensByPath[path, default: 0] += 1
            lock.unlock()
        #endif
    }

    static func recordConfiguration(path: String, configuration: ReadOnlyConfiguration) {
        #if DEBUG
            lock.lock()
            configurationsByPath[path] = configuration
            lock.unlock()
        #endif
    }

    static func recordCatalogScan(path: String) {
        #if DEBUG
            lock.lock()
            catalogScansByPath[path, default: 0] += 1
            lock.unlock()
        #endif
    }

    static func recordDatabasePageReadBytes(path: String, byteCount: Int64) {
        #if DEBUG
            guard byteCount > 0 else { return }
            lock.lock()
            databasePageReadBytesByPath[path, default: 0] += byteCount
            lock.unlock()
        #else
            _ = path
            _ = byteCount
        #endif
    }

    static func recordBodyRowObservation(path: String, byteCount: Int64) {
        #if DEBUG
            guard byteCount >= 0 else { return }
            lock.lock()
            maximumObservedBodyRowBytesByPath[path] = max(
                maximumObservedBodyRowBytesByPath[path, default: 0],
                byteCount
            )
            lock.unlock()
        #else
            _ = path
            _ = byteCount
        #endif
    }

    static func recordBodyBlobRead(path: String, byteCount: Int) {
        #if DEBUG
            guard byteCount > 0 else { return }
            lock.lock()
            bodyBlobReadBytesByPath[path, default: 0] += Int64(byteCount)
            maximumBodyBlobReadChunkBytesByPath[path] = max(
                maximumBodyBlobReadChunkBytesByPath[path, default: 0],
                byteCount
            )
            lock.unlock()
        #else
            _ = path
            _ = byteCount
        #endif
    }

    static func recordStatementResources(path: String, statement: OpaquePointer?) {
        #if DEBUG
            guard let statement else { return }
            let sortCount = Int(sqlite3_stmt_status(statement, SQLITE_STMTSTATUS_SORT, 0))
            let memoryBytes = Int(sqlite3_stmt_status(statement, SQLITE_STMTSTATUS_MEMUSED, 0))
            lock.lock()
            statementSortCountByPath[path, default: 0] += max(sortCount, 0)
            maximumStatementMemoryBytesByPath[path] = max(
                maximumStatementMemoryBytesByPath[path, default: 0],
                max(memoryBytes, 0)
            )
            lock.unlock()
        #else
            _ = path
            _ = statement
        #endif
    }

    static func reset() {
        #if DEBUG
            lock.lock()
            opensByPath.removeAll(keepingCapacity: false)
            configurationsByPath.removeAll(keepingCapacity: false)
            catalogScansByPath.removeAll(keepingCapacity: false)
            databasePageReadBytesByPath.removeAll(keepingCapacity: false)
            maximumObservedBodyRowBytesByPath.removeAll(keepingCapacity: false)
            bodyBlobReadBytesByPath.removeAll(keepingCapacity: false)
            maximumBodyBlobReadChunkBytesByPath.removeAll(keepingCapacity: false)
            statementSortCountByPath.removeAll(keepingCapacity: false)
            maximumStatementMemoryBytesByPath.removeAll(keepingCapacity: false)
            lock.unlock()
        #endif
        SQLiteReadConnection.resetSnapshotCache()
    }

    static func reset(path: String) {
        #if DEBUG
            lock.lock()
            opensByPath[path] = 0
            configurationsByPath[path] = nil
            catalogScansByPath[path] = 0
            databasePageReadBytesByPath[path] = 0
            maximumObservedBodyRowBytesByPath[path] = 0
            bodyBlobReadBytesByPath[path] = 0
            maximumBodyBlobReadChunkBytesByPath[path] = 0
            statementSortCountByPath[path] = 0
            maximumStatementMemoryBytesByPath[path] = 0
            lock.unlock()
        #endif
        SQLiteReadConnection.resetSnapshotCache(path: path)
    }

    static func readOnlyConfiguration(path: String) -> ReadOnlyConfiguration? {
        #if DEBUG
            lock.lock()
            defer { lock.unlock() }
            return configurationsByPath[path]
        #else
            return nil
        #endif
    }

    static func openCount(path: String) -> Int {
        #if DEBUG
            lock.lock()
            defer { lock.unlock() }
            return opensByPath[path, default: 0]
        #else
            return 0
        #endif
    }

    static func sourceHashCount(path: String) -> Int {
        _ = path
        return 0
    }

    static func catalogScanCount(path: String) -> Int {
        #if DEBUG
            lock.lock()
            defer { lock.unlock() }
            return catalogScansByPath[path, default: 0]
        #else
            return 0
        #endif
    }

    static func databasePageReadBytes(path: String) -> Int64 {
        #if DEBUG
            lock.lock()
            defer { lock.unlock() }
            return databasePageReadBytesByPath[path, default: 0]
        #else
            return 0
        #endif
    }

    static func maximumObservedBodyRowBytes(path: String) -> Int64 {
        #if DEBUG
            lock.lock()
            defer { lock.unlock() }
            return maximumObservedBodyRowBytesByPath[path, default: 0]
        #else
            return 0
        #endif
    }

    static func bodyBlobReadBytes(path: String) -> Int64 {
        #if DEBUG
            lock.lock()
            defer { lock.unlock() }
            return bodyBlobReadBytesByPath[path, default: 0]
        #else
            return 0
        #endif
    }

    static func maximumBodyBlobReadChunkBytes(path: String) -> Int {
        #if DEBUG
            lock.lock()
            defer { lock.unlock() }
            return maximumBodyBlobReadChunkBytesByPath[path, default: 0]
        #else
            return 0
        #endif
    }

    static func statementSortCount(path: String) -> Int {
        #if DEBUG
            lock.lock()
            defer { lock.unlock() }
            return statementSortCountByPath[path, default: 0]
        #else
            return 0
        #endif
    }

    static func maximumStatementMemoryBytes(path: String) -> Int {
        #if DEBUG
            lock.lock()
            defer { lock.unlock() }
            return maximumStatementMemoryBytesByPath[path, default: 0]
        #else
            return 0
        #endif
    }

    static var totalOpenCount: Int {
        #if DEBUG
            lock.lock()
            defer { lock.unlock() }
            return opensByPath.values.reduce(0, +)
        #else
            return 0
        #endif
    }

    static var snapshotCacheEntryCount: Int {
        SQLiteReadConnection.snapshotCacheEntryCount
    }

    static var sessionCacheEntryCount: Int {
        SQLiteReadConnection.sessionCacheEntryCount
    }
}

private final class SQLiteReadConnection {
    private enum OpenCodeBodyTable: String, CaseIterable, Hashable {
        case message
        case part
    }

    private struct OpenCodeBodyAccessPlan {
        var orderedSQL: String
    }

    private static let maximumBodyBlobReadChunkBytes = 128 * 1_024
    private static let sortFreeSessionCatalogSQL =
        "SELECT id, title, directory, time_created, time_updated "
        + "FROM session NOT INDEXED ORDER BY rowid DESC LIMIT ?"
    private static let sortFreePaginatedSessionCatalogSQL =
        "SELECT rowid, id, title, directory, time_created, time_updated "
        + "FROM session NOT INDEXED WHERE rowid < ? ORDER BY rowid DESC LIMIT ?"

    private struct SessionResolutionComplete: Error {}

    private struct SourceSnapshot: Equatable {
        var exists: Bool
        var type: mode_t
        var mode: mode_t
        var device: UInt64
        var inode: UInt64
        var byteCount: Int64
        var modifiedSeconds: Int64
        var modifiedNanoseconds: Int64
        var changedSeconds: Int64
        var changedNanoseconds: Int64

        func hasSameMetadata(as other: SourceSnapshot) -> Bool {
            exists == other.exists
                && type == other.type
                && mode == other.mode
                && device == other.device
                && inode == other.inode
                && byteCount == other.byteCount
                && modifiedSeconds == other.modifiedSeconds
                && modifiedNanoseconds == other.modifiedNanoseconds
                && changedSeconds == other.changedSeconds
                && changedNanoseconds == other.changedNanoseconds
        }
    }

    private struct CachedSessionMetadata {
        var metadata: AgentOpenCodeSessionMetadata
        var accessSequence: UInt64
    }

    private struct CachedSessionCatalog {
        var snapshot: SourceSnapshot
        var sessionsByOpaqueLocator: [String: CachedSessionMetadata]
        var accessSequence: UInt64
    }

    private static let sessionCacheLock = NSLock()
    private static let maximumSessionCacheDatabases = AgentActivityConfiguration.maximumWatchedFolders
    private static let maximumSessionsPerDatabase = 256
    private static let maximumSessionCacheEntries = 512
    private static var sessionCache: [String: CachedSessionCatalog] = [:]
    private static var sessionCacheSequence: UInt64 = 0

    struct OpenCodeReadResult {
        var byteCount: Int64
        var sha256: String
        var summary: AgentDocumentSummary
    }

    private let path: String
    private let sourceRoot: AgentSourceRootCapability
    private let relativePath: String
    private let sourcePaths: [String]
    private let sourceRelativePaths: [String]
    private let initialSnapshots: [String: SourceSnapshot]
    private var database: OpaquePointer?
    private var sourceDescriptor: Int32 = -1
    private var usesPinnedSQLiteURI = false
    private var bodyAccessPlans: [OpenCodeBodyTable: OpenCodeBodyAccessPlan] = [:]
    private var invalidationError: AgentSourceReadError?
    #if DEBUG
        private var databasePageSizeBytes: Int64 = 0
        private var reportedDatabaseCacheMisses: Int32 = 0
    #endif

    init(
        path: String,
        sourceRoot: AgentSourceRootCapability,
        relativePath: String,
        fileManager: FileManager,
        traversalBudget: AgentSourceTraversalBudget? = nil
    ) throws {
        self.path = path
        self.sourceRoot = sourceRoot
        self.relativePath = relativePath
        guard
            sourceRoot.absoluteURL(relativePath: relativePath).standardizedFileURL.path
                == URL(fileURLWithPath: path).standardizedFileURL.path
        else {
            throw AgentSourceReadError.inaccessible(path)
        }
        sourceRelativePaths = [relativePath, relativePath + "-wal", relativePath + "-shm", relativePath + "-journal"]
        sourcePaths = sourceRelativePaths.map { sourceRoot.absoluteURL(relativePath: $0).path }
        let snapshots = try Dictionary(
            uniqueKeysWithValues: zip(sourcePaths, sourceRelativePaths).map { sourcePath, sourceRelativePath in
                (
                    sourcePath,
                    try Self.snapshot(
                        sourceRoot: sourceRoot,
                        relativePath: sourceRelativePath,
                        displayPath: sourcePath,
                        traversalBudget: traversalBudget
                    )
                )
            })

        guard snapshots[path]?.exists == true,
            snapshots[path]?.type == mode_t(S_IFREG)
        else {
            if snapshots[path]?.exists == true { throw AgentSourceReadError.inaccessible(path) }
            throw AgentSourceReadError.missing(path)
        }
        if let wal = snapshots[path + "-wal"], wal.exists, wal.byteCount > 0 {
            throw AgentSourceReadError.unsupported(
                "OpenCode analysis is deferred while its live WAL contains uncheckpointed data: \(path)-wal"
            )
        }
        if let journal = snapshots[path + "-journal"], journal.exists, journal.byteCount > 0 {
            throw AgentSourceReadError.unsupported(
                "OpenCode analysis is deferred while its rollback journal is active: \(path)-journal"
            )
        }
        initialSnapshots = snapshots

        sourceDescriptor = try sourceRoot.openRegularFile(relativePath: relativePath, displayPath: path)
        guard sourceDescriptor >= 0,
            let mainSnapshot = snapshots[path],
            Self.descriptor(sourceDescriptor, matches: mainSnapshot)
        else {
            if sourceDescriptor >= 0 { Darwin.close(sourceDescriptor) }
            sourceDescriptor = -1
            throw AgentSourceReadError.inaccessible(path)
        }

        let baseFlags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_FULLMUTEX
        AgentSQLiteReadMetrics.recordOpen(path: path)
        // SQLite reads the exact O_NOFOLLOW descriptor that was fingerprinted above. This
        // closes the path replacement window between source authorization and catalog reads.
        usesPinnedSQLiteURI = true
        let descriptorURI = "file:/dev/fd/\(sourceDescriptor)?mode=ro&immutable=1"
        let result = sqlite3_open_v2(descriptorURI, &database, baseFlags, nil)
        guard result == SQLITE_OK else {
            if database != nil { sqlite3_close(database) }
            database = nil
            Darwin.close(sourceDescriptor)
            sourceDescriptor = -1
            throw AgentSourceReadError.inaccessible(path)
        }
        guard sqlite3_db_readonly(database, "main") == 1 else {
            sqlite3_close(database)
            database = nil
            Darwin.close(sourceDescriptor)
            sourceDescriptor = -1
            throw AgentSourceReadError.inaccessible(path)
        }
        do {
            try configureReadOnlyConnection()
            try configureSortFreeBodyAccessPlans()
        } catch {
            sqlite3_close(database)
            database = nil
            Darwin.close(sourceDescriptor)
            sourceDescriptor = -1
            throw error
        }
        sqlite3_busy_timeout(database, 1_000)
        _ = fileManager
    }

    deinit {
        #if DEBUG
            recordDatabasePageReads()
        #endif
        if database != nil { sqlite3_close(database) }
        if sourceDescriptor >= 0 { Darwin.close(sourceDescriptor) }
    }

    func forEachOpenCodeSession(
        limit: Int,
        traversalBudget: AgentSourceTraversalBudget? = nil,
        body: (AgentOpenCodeSessionMetadata) throws -> Void
    ) throws {
        try ensureUsable()
        let boundedLimit = min(max(limit, 1), 50_001)
        AgentSQLiteReadMetrics.recordCatalogScan(path: path)
        var cacheCandidates: [AgentOpenCodeSessionMetadata] = []
        cacheCandidates.reserveCapacity(min(boundedLimit, Self.maximumSessionsPerDatabase))
        defer {
            if let snapshot = initialSnapshots[path] {
                Self.cacheSessions(cacheCandidates, path: path, matching: snapshot)
            }
        }
        try forEachSession(
            sql: Self.sortFreeSessionCatalogSQL,
            binds: [.integer(Int64(boundedLimit))],
            traversalBudget: traversalBudget,
            body: { session in
                if cacheCandidates.count < Self.maximumSessionsPerDatabase {
                    cacheCandidates.append(session)
                }
                try body(session)
            })
    }

    func openCodeSessionPage(
        beforeRowID: Int64?,
        limit: Int,
        traversalBudget: AgentSourceTraversalBudget
    ) throws -> [AgentOpenCodeSessionRow] {
        try ensureUsable()
        let boundedLimit = min(max(limit, 1), 512)
        AgentSQLiteReadMetrics.recordCatalogScan(path: path)
        var statement: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                database,
                Self.sortFreePaginatedSessionCatalogSQL,
                -1,
                &statement,
                nil
            ) == SQLITE_OK
        else {
            throw AgentSourceReadError.unsupported("OpenCode's session page could not be read.")
        }
        defer {
            AgentSQLiteReadMetrics.recordStatementResources(path: path, statement: statement)
            sqlite3_finalize(statement)
        }
        guard sqlite3_stmt_readonly(statement) == 1,
            sqlite3_bind_int64(statement, 1, beforeRowID ?? Int64.max) == SQLITE_OK,
            sqlite3_bind_int64(statement, 2, Int64(boundedLimit)) == SQLITE_OK
        else {
            throw AgentSourceReadError.unsupported("OpenCode session paging was not read-only.")
        }
        sqlite3_progress_handler(
            database,
            1_000,
            { context in
                guard let context else { return 1 }
                let budget = Unmanaged<AgentSourceTraversalBudget>
                    .fromOpaque(context)
                    .takeUnretainedValue()
                return budget.checkpoint() ? 0 : 1
            },
            Unmanaged.passUnretained(traversalBudget).toOpaque()
        )
        defer { sqlite3_progress_handler(database, 0, nil, nil) }
        guard traversalBudget.checkpoint() else { return [] }

        var rows: [AgentOpenCodeSessionRow] = []
        rows.reserveCapacity(boundedLimit)
        var stepResult = sqlite3_step(statement)
        while stepResult == SQLITE_ROW {
            let metadataByteCount =
                Int64(sqlite3_column_bytes(statement, 1))
                + Int64(sqlite3_column_bytes(statement, 2))
                + Int64(sqlite3_column_bytes(statement, 3))
                + 24
            guard traversalBudget.consumeVisit(metadataBytes: metadataByteCount) else { return rows }
            let rowID = sqlite3_column_int64(statement, 0)
            guard let id = try string(statement, column: 1, maximumBytes: 1_024), !id.isEmpty else {
                throw AgentSourceReadError.unsupported(
                    "OpenCode returned a session without a bounded identifier."
                )
            }
            rows.append(
                AgentOpenCodeSessionRow(
                    rowID: rowID,
                    session: AgentOpenCodeSessionMetadata(
                        id: id,
                        title: try string(statement, column: 2, maximumBytes: 4_096)
                            ?? "OpenCode session",
                        directory: try string(statement, column: 3, maximumBytes: 8_192) ?? "",
                        createdAt: Date(
                            timeIntervalSince1970:
                                Double(sqlite3_column_int64(statement, 4)) / 1_000
                        ),
                        modifiedAt: Date(
                            timeIntervalSince1970:
                                Double(sqlite3_column_int64(statement, 5)) / 1_000
                        )
                    )
                )
            )
            stepResult = sqlite3_step(statement)
        }
        if stepResult == SQLITE_INTERRUPT, traversalBudget.stopReason != nil { return rows }
        guard stepResult == SQLITE_DONE else { throw sqliteReadError("session page") }
        if let snapshot = initialSnapshots[path] {
            Self.cacheSessions(rows.map(\.session), path: path, matching: snapshot)
        }
        return rows
    }

    func openCodeSession(locator: String) throws -> AgentOpenCodeSessionMetadata? {
        try ensureUsable()
        return try openCodeSessions(resolving: [locator])[locator]
    }

    func sourceContainerIdentity() throws -> AgentSourceContainerIdentity {
        try ensureUsable()
        guard let snapshot = initialSnapshots[path], snapshot.exists else {
            throw AgentSourceReadError.inaccessible(path)
        }
        return AgentSourceContainerIdentity(
            device: snapshot.device,
            inode: snapshot.inode,
            byteCount: snapshot.byteCount,
            modifiedSeconds: snapshot.modifiedSeconds,
            modifiedNanoseconds: snapshot.modifiedNanoseconds,
            changedSeconds: snapshot.changedSeconds,
            changedNanoseconds: snapshot.changedNanoseconds
        )
    }

    /// Resolves current opaque locators and one-release legacy raw locators by
    /// reading source metadata in memory. Returned candidates always carry the
    /// opaque form, so the next upsert migrates an old index without duplication.
    func openCodeSessions(
        resolving locators: [String],
        traversalBudget: AgentSourceTraversalBudget? = nil
    ) throws -> [String: AgentOpenCodeSessionMetadata] {
        try ensureUsable()
        let requested = Set(locators.filter { !$0.isEmpty && $0.utf8.count <= 1_024 })
        guard !requested.isEmpty else { return [:] }
        guard let snapshot = initialSnapshots[path] else {
            throw AgentSourceReadError.inaccessible(path)
        }
        var output: [String: AgentOpenCodeSessionMetadata] = [:]
        output.reserveCapacity(requested.count)

        let requestedOpaque = Set(requested.filter(AgentStableConversationIdentifier.isPersisted))
        output.merge(
            Self.cachedSessions(path: path, matching: snapshot, locators: requestedOpaque),
            uniquingKeysWith: { cached, _ in cached }
        )

        // Legacy raw provider IDs can be resolved by SQLite's primary-key index without
        // walking the catalog. They remain process-local and are never copied to the index.
        let requestedRaw = Array(requested.subtracting(requestedOpaque))
        for chunkStart in stride(from: 0, to: requestedRaw.count, by: 200) {
            guard traversalBudget?.checkpoint() != false else { break }
            let chunkEnd = min(chunkStart + 200, requestedRaw.count)
            let chunk = Array(requestedRaw[chunkStart..<chunkEnd])
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            try forEachSession(
                sql:
                    "SELECT id, title, directory, time_created, time_updated "
                    + "FROM session WHERE id IN (\(placeholders))",
                binds: chunk.map(SQLiteBindValue.text),
                traversalBudget: traversalBudget
            ) { session in
                if requested.contains(session.id) { output[session.id] = session }
            }
        }

        var unresolvedOpaque = requestedOpaque.subtracting(output.keys)
        guard !unresolvedOpaque.isEmpty, traversalBudget?.checkpoint() != false else {
            Self.cacheSessions(Array(output.values), path: path, matching: snapshot)
            return output
        }
        do {
            try forEachOpenCodeSession(limit: 50_001, traversalBudget: traversalBudget) { session in
                let opaqueLocator = session.opaqueLocator(databasePath: path)
                guard unresolvedOpaque.remove(opaqueLocator) != nil else { return }
                output[opaqueLocator] = session
                if unresolvedOpaque.isEmpty { throw SessionResolutionComplete() }
            }
        } catch is SessionResolutionComplete {
            // All requested opaque locators were found; do not visit the remaining catalog rows.
        }
        Self.cacheSessions(Array(output.values), path: path, matching: snapshot)
        return output
    }

    func readOpenCodeConversation(
        sessionID: String,
        opaqueLocator: String,
        maximumBytes: Int64,
        analyzeContent: Bool,
        bodyReadBudget: AgentSourceBodyReadBudget
    ) throws -> OpenCodeReadResult {
        try ensureUsable()
        let virtualURL = URL(fileURLWithPath: "opencode-\(opaqueLocator).jsonl")
        let effectiveMaximumBytes = min(maximumBytes, bodyReadBudget.limits.maximumBytes)
        let projectedBodyBytes = try conversationBodyByteCount(
            sessionID: sessionID,
            opaqueLocator: opaqueLocator,
            maximumBytes: effectiveMaximumBytes,
            bodyReadBudget: bodyReadBudget
        )
        guard bodyReadBudget.canReadKnownLength(projectedBodyBytes) else {
            throw AgentSourceBodyReadInterrupted(
                reason: bodyReadBudget.stopReason ?? .byteLimit
            )
        }
        var parser = AgentTranscriptParser.IncrementalJSONLines(
            fileURL: virtualURL,
            provider: .openCode
        )
        var hasher = CryptoKit.SHA256()
        hasher.update(data: Data("LH-OPENCODE-SESSION-V2\0".utf8))
        var byteCount: Int64 = 0
        try streamRows(
            kind: "message",
            table: .message,
            orderedSQL: try orderedBodySQL(for: .message),
            sessionID: sessionID,
            opaqueLocator: opaqueLocator,
            maximumBytes: effectiveMaximumBytes,
            analyzeContent: analyzeContent,
            bodyReadBudget: bodyReadBudget,
            byteCount: &byteCount,
            hasher: &hasher,
            parser: &parser
        )
        try streamRows(
            kind: "part",
            table: .part,
            orderedSQL: try orderedBodySQL(for: .part),
            sessionID: sessionID,
            opaqueLocator: opaqueLocator,
            maximumBytes: effectiveMaximumBytes,
            analyzeContent: analyzeContent,
            bodyReadBudget: bodyReadBudget,
            byteCount: &byteCount,
            hasher: &hasher,
            parser: &parser
        )
        guard byteCount == projectedBodyBytes else {
            throw AgentSourceReadError.changedDuringRead(path)
        }
        return OpenCodeReadResult(
            byteCount: byteCount,
            sha256: Self.digestHex(hasher.finalize()),
            summary: analyzeContent
                ? parser.finish()
                : AgentTranscriptParser.unanalyzedSummary(for: virtualURL)
        )
    }

    private func conversationBodyByteCount(
        sessionID: String,
        opaqueLocator: String,
        maximumBytes: Int64,
        bodyReadBudget: AgentSourceBodyReadBudget
    ) throws -> Int64 {
        var byteCount: Int64 = 0
        for table in OpenCodeBodyTable.allCases {
            var statement: OpaquePointer?
            // Text-length expressions can scan an entire value, and direct column
            // extraction can materialize the complete row. A pinned, read-only
            // incremental BLOB handle exposes the byte count without copying the
            // body, so per-row and conversation limits run first.
            let sql =
                "SELECT rowid, data IS NULL FROM \(table.rawValue) "
                + "WHERE session_id = ?"
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
                throw AgentSourceReadError.unsupported(
                    "OpenCode conversation size could not be bounded safely."
                )
            }
            defer {
                AgentSQLiteReadMetrics.recordStatementResources(path: path, statement: statement)
                sqlite3_finalize(statement)
            }
            guard sqlite3_stmt_readonly(statement) == 1,
                sqlite3_bind_text(statement, 1, sessionID, -1, sqliteTransient) == SQLITE_OK
            else {
                throw AgentSourceReadError.unsupported(
                    "OpenCode conversation size access was not read-only."
                )
            }
            installProgressHandler(bodyReadBudget)
            defer { sqlite3_progress_handler(database, 0, nil, nil) }
            guard bodyReadBudget.checkpoint() else {
                throw AgentSourceBodyReadInterrupted(
                    reason: bodyReadBudget.stopReason ?? .deadlineExceeded
                )
            }

            var stepResult = sqlite3_step(statement)
            while stepResult == SQLITE_ROW {
                let rowID = sqlite3_column_int64(statement, 0)
                let rowBytes =
                    sqlite3_column_int(statement, 1) == 1
                    ? 0
                    : try withOpenCodeBodyBlob(table: table, rowID: rowID) { _, bytes in bytes }
                AgentSQLiteReadMetrics.recordBodyRowObservation(path: path, byteCount: rowBytes)
                guard rowBytes <= maximumBytes,
                    byteCount <= maximumBytes - rowBytes
                else {
                    throw AgentSourceReadError.fileTooLarge(
                        path: "\(path)#session/\(opaqueLocator)",
                        bytes: byteCount + rowBytes,
                        maximum: maximumBytes
                    )
                }
                byteCount += rowBytes
                guard bodyReadBudget.checkpoint() else {
                    throw AgentSourceBodyReadInterrupted(
                        reason: bodyReadBudget.stopReason ?? .deadlineExceeded
                    )
                }
                stepResult = sqlite3_step(statement)
            }
            if stepResult == SQLITE_INTERRUPT, let reason = bodyReadBudget.stopReason {
                throw AgentSourceBodyReadInterrupted(reason: reason)
            }
            guard stepResult == SQLITE_DONE else {
                throw sqliteReadError("conversation size")
            }
        }
        return byteCount
    }

    func verifySourceUnchanged(
        traversalBudget: AgentSourceTraversalBudget? = nil,
        bodyReadBudget: AgentSourceBodyReadBudget? = nil
    ) throws {
        try ensureUsable()
        #if DEBUG
            recordDatabasePageReads()
        #endif
        for (sourcePath, sourceRelativePath) in zip(sourcePaths, sourceRelativePaths) {
            guard let initial = initialSnapshots[sourcePath],
                try Self.snapshot(
                    sourceRoot: sourceRoot,
                    relativePath: sourceRelativePath,
                    displayPath: sourcePath,
                    traversalBudget: traversalBudget
                ).hasSameMetadata(as: initial)
            else {
                Self.resetSnapshotCache(path: sourcePath)
                let error = AgentSourceReadError.changedDuringRead(path)
                invalidationError = error
                throw error
            }
        }
        _ = bodyReadBudget
    }

    private func ensureUsable() throws {
        if let invalidationError { throw invalidationError }
    }

    /// Keeps any bounded SQLite temporary bookkeeping in RAM and then locks the connection to
    /// query-only operation. Sort/materializing access plans are rejected separately. The source
    /// itself was already opened with both
    /// `SQLITE_OPEN_READONLY` and SQLite's immutable URI flag; all three checks
    /// must succeed before any provider query is prepared.
    private func configureReadOnlyConnection() throws {
        guard let database else { throw AgentSourceReadError.inaccessible(path) }
        try executeConnectionPragma("PRAGMA temp_store=MEMORY")
        let tempStoreMode = try integerConnectionPragma("PRAGMA temp_store")
        guard tempStoreMode == 2 else {
            throw AgentSourceReadError.unsupported(
                "OpenCode temporary query storage could not be confined to memory."
            )
        }
        let memoryMapSizeBytes = try integerConnectionPragma("PRAGMA mmap_size=0")
        guard memoryMapSizeBytes == 0 else {
            throw AgentSourceReadError.unsupported(
                "OpenCode memory-mapped database reads could not be disabled."
            )
        }

        try executeConnectionPragma("PRAGMA query_only=ON")
        let queryOnlyMode = try integerConnectionPragma("PRAGMA query_only")
        let databaseIsReadOnly = sqlite3_db_readonly(database, "main") == 1
        guard databaseIsReadOnly, queryOnlyMode == 1 else {
            throw AgentSourceReadError.unsupported(
                "OpenCode's SQLite connection could not be locked to read-only queries."
            )
        }
        #if DEBUG
            let pageSize = try integerConnectionPragma("PRAGMA page_size")
            guard (512...65_536).contains(pageSize), pageSize.nonzeroBitCount == 1 else {
                throw AgentSourceReadError.unsupported(
                    "OpenCode's SQLite page size could not be bounded for read accounting."
                )
            }
            databasePageSizeBytes = Int64(pageSize)
            recordDatabasePageReads()
        #endif
        AgentSQLiteReadMetrics.recordConfiguration(
            path: path,
            configuration: .init(
                databaseIsReadOnly: databaseIsReadOnly,
                tempStoreMode: tempStoreMode,
                memoryMapSizeBytes: memoryMapSizeBytes,
                queryOnlyMode: queryOnlyMode,
                noFollowOpenAttempted: true,
                usesPinnedSourceDescriptor: usesPinnedSQLiteURI
            )
        )
    }

    /// A read-only SQLite query can still build a TEMP B-TREE before returning
    /// its first row. Since temporary storage is deliberately kept in memory to
    /// avoid provider-side files, such a plan would bypass Goalong's row and
    /// deadline budgets. These statements use stable rowid order and are refused
    /// at connection setup if SQLite proposes any materializing plan.
    private func configureSortFreeBodyAccessPlans() throws {
        try requireNonMaterializingQueryPlan(
            sql: Self.sortFreeSessionCatalogSQL,
            binds: [.integer(1)],
            context: "session catalog"
        )
        try requireNonMaterializingQueryPlan(
            sql: Self.sortFreePaginatedSessionCatalogSQL,
            binds: [.integer(Int64.max), .integer(1)],
            context: "paginated session catalog"
        )

        var plans: [OpenCodeBodyTable: OpenCodeBodyAccessPlan] = [:]
        plans.reserveCapacity(OpenCodeBodyTable.allCases.count)
        for table in OpenCodeBodyTable.allCases {
            let relatedMessageColumn = table == .part && tableHasColumn("message_id", in: table)
                ? "message_id"
                : "NULL"
            let sql =
                "SELECT id, rowid, data IS NULL, \(relatedMessageColumn) FROM \(table.rawValue) NOT INDEXED "
                + "WHERE session_id = ? ORDER BY rowid"
            try requireNonMaterializingQueryPlan(
                sql: sql,
                binds: [.text("goalong-query-plan-probe")],
                context: "\(table.rawValue) body"
            )
            plans[table] = OpenCodeBodyAccessPlan(orderedSQL: sql)
        }
        bodyAccessPlans = plans
    }

    /// OpenCode's current schema relates `part` rows to `message` rows through
    /// `message_id`. Older test/export schemas can omit that optional projection column;
    /// their metadata and fingerprints remain readable, while visible dialogue simply
    /// has no relationship to reconstruct. SQLite answers this from schema metadata only.
    private func tableHasColumn(_ column: String, in table: OpenCodeBodyTable) -> Bool {
        "main".withCString { databaseName in
            table.rawValue.withCString { tableName in
                column.withCString { columnName in
                    sqlite3_table_column_metadata(
                        database,
                        databaseName,
                        tableName,
                        columnName,
                        nil,
                        nil,
                        nil,
                        nil,
                        nil
                    ) == SQLITE_OK
                }
            }
        }
    }

    private func orderedBodySQL(for table: OpenCodeBodyTable) throws -> String {
        guard let plan = bodyAccessPlans[table] else {
            throw AgentSourceReadError.unsupported(
                "OpenCode's bounded \(table.rawValue) access plan is unavailable."
            )
        }
        return plan.orderedSQL
    }

    private func requireNonMaterializingQueryPlan(
        sql: String,
        binds: [SQLiteBindValue],
        context: String
    ) throws {
        var statement: OpaquePointer?
        let explainedSQL = "EXPLAIN QUERY PLAN \(sql)"
        guard sqlite3_prepare_v2(database, explainedSQL, -1, &statement, nil) == SQLITE_OK else {
            throw AgentSourceReadError.unsupported(
                "OpenCode's bounded \(context) plan could not be inspected."
            )
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_stmt_readonly(statement) == 1 else {
            throw AgentSourceReadError.unsupported(
                "OpenCode's \(context) plan was not read-only."
            )
        }
        for (offset, bind) in binds.enumerated() {
            let parameter = Int32(offset + 1)
            let result: Int32
            switch bind {
            case .integer(let value):
                result = sqlite3_bind_int64(statement, parameter, value)
            case .text(let value):
                result = sqlite3_bind_text(statement, parameter, value, -1, sqliteTransient)
            }
            guard result == SQLITE_OK else {
                throw AgentSourceReadError.unsupported(
                    "OpenCode's bounded \(context) plan parameters were rejected."
                )
            }
        }

        var observedPlanRow = false
        var stepResult = sqlite3_step(statement)
        while stepResult == SQLITE_ROW {
            observedPlanRow = true
            let detail = try string(statement, column: 3, maximumBytes: 8_192) ?? ""
            let normalized = detail.uppercased()
            guard !normalized.contains("TEMP B-TREE"),
                !normalized.contains("MATERIALIZE")
            else {
                throw AgentSourceReadError.unsupported(
                    "OpenCode's \(context) query would materialize unbounded temporary state."
                )
            }
            stepResult = sqlite3_step(statement)
        }
        guard observedPlanRow, stepResult == SQLITE_DONE else {
            throw AgentSourceReadError.unsupported(
                "OpenCode's bounded \(context) plan could not be verified completely."
            )
        }
    }

    #if DEBUG
        /// Records SQLite pager cache misses, not source-file size. `sourceDescriptor` is only handed
        /// to SQLite through its pinned `/dev/fd` URI and is never read directly by this adapter, so
        /// this metric accounts for the database-content pages the adapter actually touches.
        private func recordDatabasePageReads() {
            guard let database, databasePageSizeBytes > 0 else { return }
            var cacheMisses: Int32 = 0
            var highwater: Int32 = 0
            guard
                sqlite3_db_status(
                    database,
                    SQLITE_DBSTATUS_CACHE_MISS,
                    &cacheMisses,
                    &highwater,
                    0
                ) == SQLITE_OK
            else { return }
            let newMisses = max(Int64(cacheMisses) - Int64(reportedDatabaseCacheMisses), 0)
            reportedDatabaseCacheMisses = cacheMisses
            AgentSQLiteReadMetrics.recordDatabasePageReadBytes(
                path: path,
                byteCount: newMisses * databasePageSizeBytes
            )
        }
    #endif

    private func executeConnectionPragma(_ sql: String) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw AgentSourceReadError.unsupported(
                "OpenCode's SQLite read-only safeguards could not be configured."
            )
        }
        defer {
            AgentSQLiteReadMetrics.recordStatementResources(path: path, statement: statement)
            sqlite3_finalize(statement)
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw AgentSourceReadError.unsupported(
                "OpenCode's SQLite read-only safeguards could not be configured."
            )
        }
    }

    private func integerConnectionPragma(_ sql: String) throws -> Int32 {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw AgentSourceReadError.unsupported(
                "OpenCode's SQLite read-only safeguards could not be verified."
            )
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_stmt_readonly(statement) == 1,
            sqlite3_step(statement) == SQLITE_ROW
        else {
            throw AgentSourceReadError.unsupported(
                "OpenCode's SQLite read-only safeguards could not be verified."
            )
        }
        return sqlite3_column_int(statement, 0)
    }

    private enum SQLiteBindValue {
        case integer(Int64)
        case text(String)
    }

    private func forEachSession(
        sql: String,
        binds: [SQLiteBindValue],
        traversalBudget: AgentSourceTraversalBudget?,
        body: (AgentOpenCodeSessionMetadata) throws -> Void
    ) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw AgentSourceReadError.unsupported("OpenCode's session table could not be read.")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_stmt_readonly(statement) == 1 else {
            throw AgentSourceReadError.unsupported("OpenCode metadata access was not read-only.")
        }
        for (offset, bind) in binds.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch bind {
            case .integer(let value):
                result = sqlite3_bind_int64(statement, index, value)
            case .text(let value):
                result = sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
            }
            guard result == SQLITE_OK else { throw sqliteReadError("session metadata parameters") }
        }
        if let traversalBudget {
            sqlite3_progress_handler(
                database,
                1_000,
                { context in
                    guard let context else { return 1 }
                    let budget = Unmanaged<AgentSourceTraversalBudget>
                        .fromOpaque(context)
                        .takeUnretainedValue()
                    return budget.checkpoint() ? 0 : 1
                },
                Unmanaged.passUnretained(traversalBudget).toOpaque()
            )
        }
        defer { sqlite3_progress_handler(database, 0, nil, nil) }
        guard traversalBudget?.checkpoint() != false else { return }
        var rowCount = 0
        var stepResult = sqlite3_step(statement)
        while stepResult == SQLITE_ROW {
            let metadataByteCount =
                Int64(sqlite3_column_bytes(statement, 0))
                + Int64(sqlite3_column_bytes(statement, 1))
                + Int64(sqlite3_column_bytes(statement, 2))
                + 16
            guard traversalBudget?.consumeVisit(metadataBytes: metadataByteCount) != false else {
                return
            }
            let id = try string(statement, column: 0, maximumBytes: 1_024)
            guard let id, !id.isEmpty else {
                throw AgentSourceReadError.unsupported("OpenCode returned a session without a bounded identifier.")
            }
            let created = Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 3)) / 1_000)
            let modified = Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 4)) / 1_000)
            rowCount += 1
            guard rowCount <= 50_001 else {
                throw AgentSourceReadError.unsupported("OpenCode returned an unexpectedly large metadata result.")
            }
            try body(
                AgentOpenCodeSessionMetadata(
                    id: id,
                    title: try string(statement, column: 1, maximumBytes: 4_096) ?? "OpenCode session",
                    directory: try string(statement, column: 2, maximumBytes: 8_192) ?? "",
                    createdAt: created,
                    modifiedAt: modified
                ))
            stepResult = sqlite3_step(statement)
        }
        if stepResult == SQLITE_INTERRUPT, traversalBudget?.stopReason != nil { return }
        guard stepResult == SQLITE_DONE else { throw sqliteReadError("session metadata") }
    }

    private func streamRows(
        kind: String,
        table: OpenCodeBodyTable,
        orderedSQL: String,
        sessionID: String,
        opaqueLocator: String,
        maximumBytes: Int64,
        analyzeContent: Bool,
        bodyReadBudget: AgentSourceBodyReadBudget,
        byteCount: inout Int64,
        hasher: inout CryptoKit.SHA256,
        parser: inout AgentTranscriptParser.IncrementalJSONLines
    ) throws {
        var orderedStatement: OpaquePointer?
        guard sqlite3_prepare_v2(database, orderedSQL, -1, &orderedStatement, nil) == SQLITE_OK else {
            throw AgentSourceReadError.unsupported("OpenCode's conversation rows could not be read.")
        }
        defer {
            AgentSQLiteReadMetrics.recordStatementResources(path: path, statement: orderedStatement)
            sqlite3_finalize(orderedStatement)
        }
        guard sqlite3_stmt_readonly(orderedStatement) == 1,
            sqlite3_bind_text(orderedStatement, 1, sessionID, -1, sqliteTransient) == SQLITE_OK
        else {
            throw AgentSourceReadError.unsupported("OpenCode conversation access was not read-only.")
        }

        sqlite3_progress_handler(
            database,
            1_000,
            { context in
                guard let context else { return 1 }
                let budget = Unmanaged<AgentSourceBodyReadBudget>
                    .fromOpaque(context)
                    .takeUnretainedValue()
                return budget.checkpoint() ? 0 : 1
            },
            Unmanaged.passUnretained(bodyReadBudget).toOpaque()
        )
        defer { sqlite3_progress_handler(database, 0, nil, nil) }
        guard bodyReadBudget.checkpoint() else {
            throw AgentSourceBodyReadInterrupted(
                reason: bodyReadBudget.stopReason ?? .deadlineExceeded
            )
        }

        var stepResult = sqlite3_step(orderedStatement)
        while stepResult == SQLITE_ROW {
            guard let identifier = try string(orderedStatement, column: 0, maximumBytes: 2_048) else {
                throw AgentSourceReadError.unsupported("OpenCode returned a conversation row without an identifier.")
            }
            let messageID = try string(orderedStatement, column: 3, maximumBytes: 2_048)

            hasher.update(data: Data(kind.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: Data(identifier.utf8))
            hasher.update(data: Data([0]))
            if let messageID {
                hasher.update(data: Data(messageID.utf8))
            }
            hasher.update(data: Data([0]))
            let rowID = sqlite3_column_int64(orderedStatement, 1)
            let rowBytes =
                sqlite3_column_int(orderedStatement, 2) == 1
                ? 0
                : try streamOpenCodeBodyBlob(
                    table: table,
                    rowID: rowID,
                    identifier: identifier,
                    messageID: messageID,
                    opaqueLocator: opaqueLocator,
                    maximumBytes: maximumBytes,
                    analyzeContent: analyzeContent,
                    bodyReadBudget: bodyReadBudget,
                    byteCount: byteCount,
                    hasher: &hasher,
                    parser: &parser
                )
            hasher.update(data: Data([0x0A]))
            byteCount += rowBytes
            stepResult = sqlite3_step(orderedStatement)
        }
        if stepResult == SQLITE_INTERRUPT, let reason = bodyReadBudget.stopReason {
            throw AgentSourceBodyReadInterrupted(reason: reason)
        }
        guard stepResult == SQLITE_DONE else { throw sqliteReadError("conversation rows") }
    }

    private func streamOpenCodeBodyBlob(
        table: OpenCodeBodyTable,
        rowID: Int64,
        identifier: String,
        messageID: String?,
        opaqueLocator: String,
        maximumBytes: Int64,
        analyzeContent: Bool,
        bodyReadBudget: AgentSourceBodyReadBudget,
        byteCount: Int64,
        hasher: inout CryptoKit.SHA256,
        parser: inout AgentTranscriptParser.IncrementalJSONLines
    ) throws -> Int64 {
        try withOpenCodeBodyBlob(table: table, rowID: rowID) { blob, rowBytes in
            AgentSQLiteReadMetrics.recordBodyRowObservation(path: path, byteCount: rowBytes)
            let effectiveMaximumBytes = min(maximumBytes, bodyReadBudget.limits.maximumBytes)
            guard rowBytes <= effectiveMaximumBytes,
                byteCount <= effectiveMaximumBytes - rowBytes
            else {
                throw AgentSourceReadError.fileTooLarge(
                    path: "\(path)#session/\(opaqueLocator)",
                    bytes: byteCount + rowBytes,
                    maximum: effectiveMaximumBytes
                )
            }
            guard rowBytes > 0 else { return 0 }

            let bufferCapacity = min(Int(rowBytes), Self.maximumBodyBlobReadChunkBytes)
            var buffer = [UInt8](repeating: 0, count: bufferCapacity)
            var analysisRow: Data?
            if analyzeContent,
                rowBytes <= Int64(AgentTranscriptParser.maximumBufferedLineBytes)
            {
                analysisRow = Data()
                analysisRow?.reserveCapacity(Int(rowBytes))
            }
            var offset: Int64 = 0
            while offset < rowBytes {
                guard bodyReadBudget.checkpoint() else {
                    throw AgentSourceBodyReadInterrupted(
                        reason: bodyReadBudget.stopReason ?? .deadlineExceeded
                    )
                }
                let chunkByteCount = min(Int64(bufferCapacity), rowBytes - offset)
                guard offset <= Int64(Int32.max), chunkByteCount <= Int64(Int32.max) else {
                    throw AgentSourceReadError.unsupported(
                        "OpenCode returned a conversation row outside SQLite's incremental-read range."
                    )
                }
                let readResult = buffer.withUnsafeMutableBytes { rawBuffer in
                    sqlite3_blob_read(
                        blob,
                        rawBuffer.baseAddress,
                        Int32(chunkByteCount),
                        Int32(offset)
                    )
                }
                guard readResult == SQLITE_OK else {
                    throw sqliteReadError("conversation body")
                }
                guard bodyReadBudget.consume(chunkByteCount) else {
                    throw AgentSourceBodyReadInterrupted(
                        reason: bodyReadBudget.stopReason ?? .byteLimit
                    )
                }
                AgentSQLiteReadMetrics.recordBodyBlobRead(
                    path: path,
                    byteCount: Int(chunkByteCount)
                )
                buffer.withUnsafeBytes { rawBuffer in
                    let chunk = UnsafeRawBufferPointer(rebasing: rawBuffer[..<Int(chunkByteCount)])
                    hasher.update(bufferPointer: chunk)
                    analysisRow?.append(contentsOf: chunk)
                }
                offset += chunkByteCount
            }
            if let analysisRow {
                parser.consumeOpenCodeRow(
                    kind: table.rawValue,
                    identifier: identifier,
                    messageID: messageID,
                    data: analysisRow
                )
            }
            return rowBytes
        }
    }

    private func withOpenCodeBodyBlob<T>(
        table: OpenCodeBodyTable,
        rowID: Int64,
        body: (OpaquePointer, Int64) throws -> T
    ) throws -> T {
        var blob: OpaquePointer?
        let openResult = table.rawValue.withCString { tableName in
            sqlite3_blob_open(database, "main", tableName, "data", rowID, 0, &blob)
        }
        guard openResult == SQLITE_OK, let blob else {
            throw sqliteReadError("conversation body handle")
        }
        defer { sqlite3_blob_close(blob) }
        let byteCount = Int64(sqlite3_blob_bytes(blob))
        guard byteCount >= 0 else {
            throw AgentSourceReadError.unsupported(
                "OpenCode returned a conversation row outside the supported range."
            )
        }
        return try body(blob, byteCount)
    }

    private func installProgressHandler(_ bodyReadBudget: AgentSourceBodyReadBudget) {
        sqlite3_progress_handler(
            database,
            1_000,
            { context in
                guard let context else { return 1 }
                let budget = Unmanaged<AgentSourceBodyReadBudget>
                    .fromOpaque(context)
                    .takeUnretainedValue()
                return budget.checkpoint() ? 0 : 1
            },
            Unmanaged.passUnretained(bodyReadBudget).toOpaque()
        )
    }

    private func string(
        _ statement: OpaquePointer?,
        column: Int32,
        maximumBytes: Int
    ) throws -> String? {
        if sqlite3_column_type(statement, column) == SQLITE_NULL { return nil }
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count >= 0, count <= maximumBytes,
            let bytes = sqlite3_column_text(statement, column)
        else {
            throw AgentSourceReadError.unsupported("OpenCode returned an oversized metadata field.")
        }
        return String(decoding: UnsafeBufferPointer(start: bytes, count: count), as: UTF8.self)
    }

    private func sqliteReadError(_ context: String) -> AgentSourceReadError {
        let detail = database.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown SQLite error"
        return .unsupported("OpenCode \(context) could not be read completely: \(detail)")
    }

    private static func snapshot(
        sourceRoot: AgentSourceRootCapability,
        relativePath: String,
        displayPath path: String,
        traversalBudget: AgentSourceTraversalBudget? = nil
    ) throws -> SourceSnapshot {
        guard traversalBudget?.checkpoint() != false else {
            throw AgentSourceTraversalInterrupted()
        }
        guard let status = try sourceRoot.status(relativePath: relativePath, displayPath: path) else {
            return SourceSnapshot(
                exists: false,
                type: 0,
                mode: 0,
                device: 0,
                inode: 0,
                byteCount: 0,
                modifiedSeconds: 0,
                modifiedNanoseconds: 0,
                changedSeconds: 0,
                changedNanoseconds: 0
            )
        }
        let type = status.st_mode & S_IFMT
        guard type == S_IFREG else { throw AgentSourceReadError.inaccessible(path) }
        return SourceSnapshot(
            exists: true,
            type: type,
            mode: status.st_mode & 0o777,
            device: UInt64(status.st_dev),
            inode: UInt64(status.st_ino),
            byteCount: Int64(status.st_size),
            modifiedSeconds: Int64(status.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(status.st_mtimespec.tv_nsec),
            changedSeconds: Int64(status.st_ctimespec.tv_sec),
            changedNanoseconds: Int64(status.st_ctimespec.tv_nsec)
        )
    }

    private static func descriptor(_ descriptor: Int32, matches snapshot: SourceSnapshot) -> Bool {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else { return false }
        return (status.st_mode & S_IFMT) == S_IFREG
            && (status.st_mode & 0o777) == snapshot.mode
            && UInt64(status.st_dev) == snapshot.device
            && UInt64(status.st_ino) == snapshot.inode
            && Int64(status.st_size) == snapshot.byteCount
            && Int64(status.st_mtimespec.tv_sec) == snapshot.modifiedSeconds
            && Int64(status.st_mtimespec.tv_nsec) == snapshot.modifiedNanoseconds
            && Int64(status.st_ctimespec.tv_sec) == snapshot.changedSeconds
            && Int64(status.st_ctimespec.tv_nsec) == snapshot.changedNanoseconds
    }

    private static func cachedSessions(
        path: String,
        matching snapshot: SourceSnapshot,
        locators: Set<String>
    ) -> [String: AgentOpenCodeSessionMetadata] {
        guard !locators.isEmpty else { return [:] }
        sessionCacheLock.lock()
        defer { sessionCacheLock.unlock() }
        guard var catalog = sessionCache[path], catalog.snapshot.hasSameMetadata(as: snapshot) else {
            sessionCache[path] = nil
            return [:]
        }
        sessionCacheSequence &+= 1
        catalog.accessSequence = sessionCacheSequence
        var output: [String: AgentOpenCodeSessionMetadata] = [:]
        output.reserveCapacity(locators.count)
        for locator in locators {
            guard var cached = catalog.sessionsByOpaqueLocator[locator] else { continue }
            sessionCacheSequence &+= 1
            cached.accessSequence = sessionCacheSequence
            catalog.sessionsByOpaqueLocator[locator] = cached
            output[locator] = cached.metadata
        }
        sessionCache[path] = catalog
        return output
    }

    private static func cacheSessions(
        _ sessions: [AgentOpenCodeSessionMetadata],
        path: String,
        matching snapshot: SourceSnapshot
    ) {
        guard !sessions.isEmpty else { return }
        sessionCacheLock.lock()
        defer { sessionCacheLock.unlock() }
        sessionCacheSequence &+= 1
        var catalog: CachedSessionCatalog
        if let cached = sessionCache[path], cached.snapshot.hasSameMetadata(as: snapshot) {
            catalog = cached
            catalog.accessSequence = sessionCacheSequence
        } else {
            catalog = CachedSessionCatalog(
                snapshot: snapshot,
                sessionsByOpaqueLocator: [:],
                accessSequence: sessionCacheSequence
            )
        }
        catalog.sessionsByOpaqueLocator.reserveCapacity(
            min(Self.maximumSessionsPerDatabase, catalog.sessionsByOpaqueLocator.count + sessions.count)
        )
        for session in sessions {
            sessionCacheSequence &+= 1
            catalog.sessionsByOpaqueLocator[session.opaqueLocator(databasePath: path)] =
                CachedSessionMetadata(metadata: session, accessSequence: sessionCacheSequence)
        }
        while catalog.sessionsByOpaqueLocator.count > maximumSessionsPerDatabase,
            let leastRecentlyUsed = catalog.sessionsByOpaqueLocator.min(by: {
                $0.value.accessSequence < $1.value.accessSequence
            })?.key
        {
            catalog.sessionsByOpaqueLocator[leastRecentlyUsed] = nil
        }
        sessionCache[path] = catalog
        enforceSessionCacheBoundLocked()
    }

    private static func enforceSessionCacheBoundLocked() {
        func totalEntryCount() -> Int {
            sessionCache.values.reduce(0) { $0 + $1.sessionsByOpaqueLocator.count }
        }
        while sessionCache.count > maximumSessionCacheDatabases
            || totalEntryCount() > maximumSessionCacheEntries
        {
            guard
                let leastRecentlyUsedDatabase = sessionCache.min(by: {
                    $0.value.accessSequence < $1.value.accessSequence
                })?.key
            else { break }
            sessionCache[leastRecentlyUsedDatabase] = nil
        }
    }

    private static func resetSessionCache(path: String? = nil) {
        sessionCacheLock.lock()
        defer { sessionCacheLock.unlock() }
        if let path {
            sessionCache[path] = nil
        } else {
            sessionCache.removeAll(keepingCapacity: false)
            sessionCacheSequence = 0
        }
    }

    fileprivate static func resetSnapshotCache(path: String? = nil) {
        resetSessionCache(path: path)
    }

    fileprivate static var snapshotCacheEntryCount: Int {
        0
    }

    fileprivate static var sessionCacheEntryCount: Int {
        sessionCacheLock.lock()
        defer { sessionCacheLock.unlock() }
        return sessionCache.values.reduce(0) { $0 + $1.sessionsByOpaqueLocator.count }
    }

    private static func digestHex<S: Sequence>(_ digest: S) -> String where S.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}
