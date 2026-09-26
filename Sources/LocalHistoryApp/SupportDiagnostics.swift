#if os(macOS)
import Foundation
import Darwin

// This is an allowlist, not a regex-based scrubber. No API accepts user strings,
// URLs, error descriptions, prompts, file contents, or an arbitrary dictionary.
enum SupportComponent: String, Codable { case app, permissions, capture, monitoring, storage, updates, analysis, sharing, interface, support }
enum SupportEvent: String, Codable {
    case appStarted, appStopped, heartbeat, mainThreadDelayed, mainThreadUnresponsive, mainThreadRecovered, legacyLocation
    case permissionChecked, permissionRepairStarted, permissionRepairFinished
    case captureHealthChanged, inputTapChanged, monitorCycle, requestFinished
    case operationFailed, updateChanged, sourceCheck, userMarkedIssue, reportExported
}
enum SupportLevel: String, Codable { case info, warning, error }
enum SupportKey: String, Codable {
    case accessibilityPreflight, accessibilityFunctional, accessibilityCrossProcess, inputPreflight, axError
    case elapsedMS, errorCode, errorKind, enabled, paused, tapRunning, captureProven, state
    case previousExitUnclean, droppedEvents, writeFailures, consentEnabled, httpStatus
    case itemCount, byteCount, attempt, durationMS, decision, permission, success
    case callbackObserved, axSuccessAgeSeconds, callbackAgeSeconds, contextAgeSeconds
    case localSource, appleSource, conversationSource, globalPause, lowPower, thermalState
    case updateConfigured, updateChecking, inputCount, eventCount, pendingEvents, liveSnapshotAvailable, permissionIdentityChanged
}
enum SupportState: String, Codable {
    case unknown, ready, unavailable, denied, deferred, started, stopped, cancelled, timedOut
    case accessibility, inputMonitoring, fullDiskAccess
    case urlError, cocoaError, posixError, otherError
    case neverAttempted, creationFailed, createdDisabled, createdEnabled
    case permissionRequired, permissionAppearsEnabledButStaleForBuild, inputTapUnavailable
    case accessibilityContextUnavailable, paused, excludedPrivateOrSecure, healthyButIdle, awaitingInputEvidence
    case skipped, allowed, blocked
}

enum SupportValue: Codable, Equatable {
    case flag(Bool), count(Int), number(Double), state(SupportState)
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(Bool.self) { self = .flag(v) }
        else if let v = try? c.decode(Int.self) { self = .count(v) }
        else if let v = try? c.decode(Double.self), v.isFinite { self = .number(v) }
        else { self = .state(try c.decode(SupportState.self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .flag(let v): try c.encode(v)
        case .count(let v): try c.encode(v)
        case .number(let v): try c.encode(v.isFinite ? v : 0)
        case .state(let v): try c.encode(v)
        }
    }
}

struct SupportRecord: Codable {
    let schema: Int
    let revision: String?
    let timestamp: Date
    let session: UUID // random per process launch, never a device/account identifier
    let sequence: UInt64
    let component: SupportComponent
    let event: SupportEvent
    let level: SupportLevel
    let source: String?
    let line: UInt?
    let values: [String: SupportValue]

    var isShareable: Bool {
        schema == 1 && Self.revisionIsSafe(revision) && values.count <= 40 && values.keys.allSatisfy { SupportKey(rawValue: $0) != nil }
            && (source == nil || SupportSourceAllowlist.names.contains(source!))
            && (line == nil || line! <= 100_000)
    }
    static func revisionIsSafe(_ value: String?) -> Bool {
        guard let value else { return true }
        return (7...64).contains(value.utf8.count) && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

/// A small private journal, independent of activity/history stores. All filesystem
/// work is on one utility queue behind the existing bounded ingress. Daily buckets
/// contain at most two 256 KiB segments; only the last seven UTC dates are retained.
final class SupportDiagnostics {
    static let shared = SupportDiagnostics(root: AppPaths.applicationSupportDirectory.appendingPathComponent("SupportDiagnostics"))
    static let segmentBytes = 256 * 1_024
    static let retentionDays = 7
    static let enabledKey = "goalong.supportDiagnostics.enabled.v1"
    private let root: URL
    private let queue = DispatchQueue(label: "ai.goalong.support-diagnostics", qos: .utility)
    private let lock = NSLock()
    private let session = UUID()
    private var sequence: UInt64 = 0
    private var running = false
    private var recentRecords: [SupportRecord] = [] // bounded fallback when the disk cannot be written
    private var intakeGeneration: UInt64 = 0
    private var clearedThrough: UInt64 = 0
    private let revision: String?
    private var enabled = true
    private var writeFailures = 0
    private var flushPending: DispatchGroup?
    private var snapshotPending = false
    private let queueKey = DispatchSpecificKey<Bool>()
    private var activeDay: String?
    private var log: BoundedDiagnosticsLog?
    private let defaults: UserDefaults
    private let clock: () -> Date
    private lazy var ingress = BoundedDiagnosticsIngress(
        capacity: 128, maximumPendingBytes: 256 * 1_024, maximumMessageBytes: 8 * 1_024,
        scheduler: { [weak self] work in self?.queue.async(execute: work) },
        sink: { [weak self] date, text in self?.persist(text, at: date) }
    )

    init(root: URL, defaults: UserDefaults = .standard, clock: @escaping () -> Date = Date.init) {
        self.root = root; self.defaults = defaults; self.clock = clock
        let sourceRevision = Bundle.main.object(forInfoDictionaryKey: "GoalongSourceRevision") as? String
        revision = SupportRecord.revisionIsSafe(sourceRevision) ? sourceRevision : nil
        // Materialize the ingress before concurrent producers can enter it.
        _ = ingress
        queue.setSpecific(key: queueKey, value: true)
    }

    var isEnabled: Bool {
        defaults.object(forKey: Self.enabledKey) == nil || defaults.bool(forKey: Self.enabledKey)
    }

    func start() {
        lock.lock()
        guard !running else { lock.unlock(); return }
        enabled = isEnabled; running = true
        lock.unlock()
        let previous = defaults.object(forKey: "goalong.support.cleanExit.v1") as? Bool
        if enabled { defaults.set(false, forKey: "goalong.support.cleanExit.v1") }
        record(.appStarted, component: .app, values: [.previousExitUnclean: .flag(previous == false)])
        queue.async { [weak self] in self?.prune(at: self?.clock() ?? Date()) }
    }

    func stop() {
        record(.appStopped, component: .app)
        lock.lock(); running = false; intakeGeneration &+= 1; lock.unlock()
        // A broken/locked filesystem must never stop the user from quitting.
        if flush(timeout: 1) { defaults.set(true, forKey: "goalong.support.cleanExit.v1") }
    }

    func setEnabled(_ value: Bool) {
        defaults.set(value, forKey: Self.enabledKey)
        lock.lock(); enabled = value; intakeGeneration &+= 1; lock.unlock()
        if value { defaults.set(false, forKey: "goalong.support.cleanExit.v1") }
        else { defaults.removeObject(forKey: "goalong.support.cleanExit.v1") }
    }

    func record(_ event: SupportEvent, component: SupportComponent, level: SupportLevel = .info,
                values: [SupportKey: SupportValue] = [:], file: StaticString = #fileID, line: UInt = #line) {
        lock.lock()
        guard running, enabled else { lock.unlock(); return }
        sequence &+= 1
        let next = sequence
        let generation = intakeGeneration
        lock.unlock()
        let source = String(describing: file).split(separator: "/").last.map(String.init)
        let record = SupportRecord(schema: 1, revision: revision, timestamp: clock(), session: session, sequence: next,
            component: component, event: event, level: level,
            source: source.flatMap { SupportSourceAllowlist.names.contains($0) ? $0 : nil }, line: line,
            values: Dictionary(uniqueKeysWithValues: values.map { ($0.key.rawValue, $0.value) }))
        guard record.isShareable, let data = try? Self.encoder().encode(record),
              let text = String(data: data, encoding: .utf8) else { return }
        lock.lock()
        guard running, enabled, generation == intakeGeneration, next > clearedThrough else { lock.unlock(); return }
        recentRecords.append(record)
        if recentRecords.count > 128 { recentRecords.removeFirst(recentRecords.count - 128) }
        // Submission is nonblocking; holding this lock makes opt-out/clear linearizable.
        ingress.submit(text, at: record.timestamp)
        lock.unlock()
    }

    func failure(_ error: Error, component: SupportComponent, file: StaticString = #fileID, line: UInt = #line) {
        let error = error as NSError
        let kind: SupportState
        switch error.domain {
        case NSURLErrorDomain: kind = .urlError
        case NSCocoaErrorDomain: kind = .cocoaError
        case NSPOSIXErrorDomain: kind = .posixError
        default: kind = .otherError
        }
        record(.operationFailed, component: component, level: .error,
            values: [.errorCode: .count(error.code), .errorKind: .state(kind)], file: file, line: line)
        // Deliberately do not inspect localizedDescription, userInfo or underlyingError.
    }

    /// Legacy free-form messages can embed application names, paths and payloads.
    /// Keep their exact source location, never their text (even in local logs).
    func legacy(file: StaticString, line: UInt) {
        record(.legacyLocation, component: .app, file: file, line: line)
    }

    @discardableResult func flush(timeout: TimeInterval = 2) -> Bool {
        if DispatchQueue.getSpecific(key: queueKey) == true { return true }
        lock.lock()
        let group: DispatchGroup
        if let pending = flushPending { group = pending }
        else {
            group = DispatchGroup(); group.enter(); flushPending = group
            queue.async { [self] in
                lock.lock(); flushPending = nil; lock.unlock()
                group.leave()
            }
        }
        lock.unlock()
        return group.wait(timeout: .now() + Self.boundedTimeout(timeout)) == .success
    }
    private static func boundedTimeout(_ seconds: TimeInterval) -> TimeInterval {
        seconds.isFinite ? min(10, max(0, seconds)) : 2
    }

    struct Snapshot {
        let records: [SupportRecord]
        let dropped: Int
        let rejected: Int
        let writeFailures: Int
        let enabled: Bool
        let diskSnapshotIncomplete: Bool
    }

    private final class SnapshotResult { var value: Snapshot? }

    func snapshot(timeout: TimeInterval = 2) -> Snapshot {
        if DispatchQueue.getSpecific(key: queueKey) == true { return readSnapshot() }
        lock.lock()
        guard !snapshotPending else { lock.unlock(); return memorySnapshot() }
        snapshotPending = true; lock.unlock()
        let result = SnapshotResult(); let ready = DispatchSemaphore(value: 0)
        queue.async { [self] in
            result.value = readSnapshot()
            lock.lock(); snapshotPending = false; lock.unlock()
            ready.signal()
        }
        guard ready.wait(timeout: .now() + Self.boundedTimeout(timeout)) == .success,
              let value = result.value else { return memorySnapshot() }
        return value
    }

    private func memorySnapshot() -> Snapshot {
        lock.lock(); let records = recentRecords; let failures = writeFailures; let enabled = enabled; lock.unlock()
        let now = clock(); let days = Self.days(ending: now)
        return Snapshot(records: records.filter { $0.isShareable && days.contains(Self.day($0.timestamp)) && $0.timestamp <= now.addingTimeInterval(60) },
            dropped: ingress.snapshot.totalDroppedCount, rejected: 0, writeFailures: failures,
            enabled: enabled, diskSnapshotIncomplete: true)
    }

    private func readSnapshot() -> Snapshot {
            prune(at: clock())
            var records: [SupportRecord] = []; var rejected = 0
            let days = Self.days(ending: clock())
            let rootIsSafe = (try? Self.requirePrivateDirectory(root)) != nil
            for day in days where rootIsSafe {
                let bucket = root.appendingPathComponent(day)
                guard (try? Self.requirePrivateDirectory(bucket)) != nil else { continue }
                for name in ["diagnostics.log.1", "diagnostics.log"] {
                    let url = root.appendingPathComponent(day).appendingPathComponent(name)
                    guard let data = try? Self.readPrivateFile(url, maximum: Self.segmentBytes) else { continue }
                    for line in data.split(separator: 10) {
                        guard let record = try? Self.decoder().decode(SupportRecord.self, from: Data(line)),
                              record.isShareable, record.timestamp <= clock().addingTimeInterval(60),
                              days.contains(Self.day(record.timestamp)) else { rejected += 1; continue }
                        records.append(record)
                    }
                }
            }
            lock.lock(); let fallback = recentRecords; let failures = writeFailures; lock.unlock()
            records.append(contentsOf: fallback.filter { days.contains(Self.day($0.timestamp)) && $0.timestamp <= clock().addingTimeInterval(60) })
            var seen = Set<String>()
            records = records.filter { seen.insert($0.session.uuidString + ":" + String($0.sequence)).inserted }
            records.sort { $0.timestamp == $1.timestamp ? $0.sequence < $1.sequence : $0.timestamp < $1.timestamp }
            return Snapshot(records: records, dropped: ingress.snapshot.totalDroppedCount,
                rejected: rejected, writeFailures: failures, enabled: isEnabled, diskSnapshotIncomplete: failures > 0)
    }

    /// Deletes only this journal's known files, not legacy diagnostics or activity.
    func clear() throws {
        try queue.sync {
            lock.lock(); clearedThrough = sequence; intakeGeneration &+= 1; recentRecords.removeAll(); lock.unlock()
            guard FileManager.default.fileExists(atPath: root.path) else { return }
            try Self.requirePrivateDirectory(root)
            let children = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            for child in children where Self.isDayName(child.lastPathComponent) {
                try Self.removeBucket(child)
            }
            log = nil; activeDay = nil
        }
    }

    private func persist(_ text: String, at date: Date) {
        if let record = try? Self.decoder().decode(SupportRecord.self, from: Data(text.utf8)) {
            lock.lock(); let isCleared = record.session == session && record.sequence <= clearedThrough; lock.unlock()
            if isCleared { return }
        }
        do {
            try Self.preparePrivateDirectory(root)
            let day = Self.day(date)
            if day != activeDay {
                prune(at: clock())
                log = BoundedDiagnosticsLog(directoryURL: root.appendingPathComponent(day), maximumFileBytes: Int64(Self.segmentBytes))
                activeDay = day
            }
            // The ingress overload marker is not JSON and is deliberately omitted at export;
            // droppedEvents separately records its exact count in the report.
            try log?.append(text + "\n")
        } catch { lock.lock(); writeFailures += 1; lock.unlock() } // Never recursively log a logger failure.
    }

    private func prune(at date: Date) {
        guard (try? Self.requirePrivateDirectory(root)) != nil,
              let children = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        let keep = Set(Self.days(ending: date))
        for child in children where Self.isDayName(child.lastPathComponent) && !keep.contains(child.lastPathComponent) {
            do { try Self.removeBucket(child) } catch { lock.lock(); writeFailures += 1; lock.unlock() }
        }
    }

    private static func removeBucket(_ url: URL) throws {
        try requirePrivateDirectory(url)
        let known = Set(["diagnostics.log", "diagnostics.log.1", ".diagnostics.log.rotation.tmp"])
        let children = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
        for child in children where known.contains(child.lastPathComponent) {
            // unlink deletes a link itself, never its target; directories are refused.
            var status = stat()
            guard lstat(child.path, &status) == 0, status.st_mode & S_IFMT != S_IFDIR else { continue }
            guard unlink(child.path) == 0 else { throw POSIXError(.EIO) }
        }
        _ = rmdir(url.path) // Preserve unexpected contents, never recurse.
    }

    static func preparePrivateDirectory(_ url: URL) throws {
        if mkdir(url.path, 0o700) != 0 && errno != EEXIST { throw POSIXError(.EIO) }
        try requirePrivateDirectory(url)
    }
    static func requirePrivateDirectory(_ url: URL) throws {
        var s = stat()
        guard lstat(url.path, &s) == 0, s.st_mode & S_IFMT == S_IFDIR, s.st_uid == getuid(),
              s.st_mode & 0o077 == 0 else { throw POSIXError(.EPERM) }
    }
    static func readPrivateFile(_ url: URL, maximum: Int, requireOwner: Bool = true) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw POSIXError(.ENOENT) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var s = stat()
        guard fstat(fd, &s) == 0, s.st_mode & S_IFMT == S_IFREG, s.st_nlink == 1,
              (!requireOwner || s.st_uid == getuid()), s.st_size >= 0, s.st_size <= maximum else { throw POSIXError(.EPERM) }
        let data = try handle.read(upToCount: maximum + 1) ?? Data()
        guard data.count <= maximum else { throw POSIXError(.EFBIG) }
        return data
    }
    static func encoder() -> JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]; return e }
    static func decoder() -> JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
    static func day(_ date: Date) -> String {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(secondsFromGMT: 0)!
        let p = c.dateComponents([.year, .month, .day], from: date)
        return String(format: "day-%04d-%02d-%02d", p.year!, p.month!, p.day!)
    }
    static func days(ending date: Date) -> [String] { (0..<retentionDays).reversed().map { day(date.addingTimeInterval(-Double($0) * 86400)) } }
    static func isDayName(_ name: String) -> Bool { name.range(of: #"^day-[0-9]{4}-[0-9]{2}-[0-9]{2}$"#, options: .regularExpression) != nil }
}
#endif
