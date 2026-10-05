#if os(macOS)
import Foundation
import Darwin

// This is an allowlist, not a regex-based scrubber. No API accepts user strings,
// URLs, error descriptions, prompts, file contents, or an arbitrary dictionary.
// The only textual values are compile-time identifiers (Swift error types and enum
// cases) and version numbers, each validated against a strict pattern.
enum SupportComponent: String, Codable { case app, permissions, capture, monitoring, storage, updates, analysis, sharing, interface, support }
enum SupportEvent: String, Codable {
    case appStarted, appStopped, heartbeat, mainThreadDelayed, mainThreadUnresponsive, mainThreadRecovered, mainThreadStalled, legacyLocation
    case permissionChecked, permissionRepairStarted, permissionRepairFinished, permissionRecoveryAction
    case captureHealthChanged, inputTapChanged, monitorCycle, requestFinished
    case operationFailed, updateChanged, sourceCheck, userMarkedIssue, reportExported
    case storageInterrupted, storageRetryFailed, storageRecovered, lowDiskSpace
    case repeatSummary, appUpdated, updateCheckStarted, updateCheckFinished, updateChoice, monitorPaused
}
enum SupportLevel: String, Codable { case info, warning, error }
enum SupportKey: String, Codable {
    case accessibilityPreflight, accessibilityFunctional, accessibilityCrossProcess, inputPreflight, axError
    case permissionObservationPending, axEvidenceThisLaunch, inputTapState, previousWorkingIdentityAvailable, capability
    case elapsedMS, errorCode, errorKind, enabled, paused, tapRunning, captureProven, state
    case previousExitUnclean, droppedEvents, writeFailures, consentEnabled, httpStatus
    case itemCount, byteCount, attempt, durationMS, decision, permission, success
    case callbackObserved, axSuccessAgeSeconds, callbackAgeSeconds, contextAgeSeconds
    case localSource, appleSource, conversationSource, globalPause, lowPower, thermalState
    case updateConfigured, updateChecking, inputCount, eventCount, pendingEvents, liveSnapshotAvailable, permissionIdentityChanged
    case errorType, errorCase, errorValue, underlyingErrorCode, underlyingErrorKind, rootErrorCode, rootErrorKind
    case lostEvents, freeSpaceMB, storageInterrupted, storageFailure, suppressedCount, repeatedEvent
    case version, build, previousVersion, previousBuild, updateResult, userChoice, automaticChecks, availableVersion
    case monitoringEnabled, websiteLinked, websiteAutoSend
    case stallFrame1, stallFrame2, stallFrame3, stallFrame4
}
enum SupportState: String, Codable {
    case unknown, ready, unavailable, denied, deferred, started, stopped, cancelled, timedOut
    case accessibility, inputMonitoring, fullDiskAccess
    case urlError, cocoaError, posixError, otherError
    case sparkleError, osStatusError, machError, swiftError
    case neverAttempted, creationFailed, createdDisabled, createdEnabled
    case permissionRequired, permissionAppearsEnabledButStaleForBuild, inputTapUnavailable
    case accessibilityContextUnavailable, paused, excludedPrivateOrSecure, healthyButIdle, awaitingInputEvidence
    case storageUnavailable, diskFull, permissionDenied
    case skipped, allowed, blocked
    case settingsOpened, relaunchPrepared, resetSucceeded
    case localComputerHistory, appleScreenTime, aiConversations
    case upToDate, updateAvailable, failed, install, later, skip, dismiss, paymentRequired, authentication
}

/// A compile-time identifier (type or case name) or a version number. Never text
/// produced at run time from user data; `isSafe` is enforced before persistence and
/// again when a record is read back for export.
enum SupportSymbol {
    static let identifierKeys: Set<SupportKey> = [.errorType, .errorCase, .repeatedEvent,
                                                   .stallFrame1, .stallFrame2, .stallFrame3, .stallFrame4]
    static let versionKeys: Set<SupportKey> = [.version, .build, .previousVersion, .previousBuild, .availableVersion]

    static func isSafe(_ value: String, for key: SupportKey) -> Bool {
        if identifierKeys.contains(key) {
            return value.range(of: #"^[A-Za-z_][A-Za-z0-9_.]{0,127}$"#, options: .regularExpression) != nil
        }
        if versionKeys.contains(key) {
            return value.range(of: #"^[0-9]{1,9}(?:\.[0-9]{1,9}){0,3}$"#, options: .regularExpression) != nil
        }
        return false
    }

    /// Module-qualified Swift type name without private-context markers, e.g.
    /// `LocalHistoryApp.JSONLStore.JSONLStoreError`.
    static func typeName(_ type: Any.Type) -> String? {
        let name = String(reflecting: type)
            .replacingOccurrences(of: #"\(unknown context at \$[0-9a-fA-F]+\)\."#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\(extension in [A-Za-z0-9_]+\):"#, with: "", options: .regularExpression)
        return isSafe(name, for: .errorType) ? name : nil
    }
}

enum SupportValue: Codable, Equatable {
    case flag(Bool), count(Int), number(Double), state(SupportState), symbol(String)
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(Bool.self) { self = .flag(v) }
        else if let v = try? c.decode(Int.self) { self = .count(v) }
        else if let v = try? c.decode(Double.self), v.isFinite { self = .number(v) }
        else if let v = try? c.decode(SupportState.self) { self = .state(v) }
        else { self = .symbol(try c.decode(String.self)) } // validated per key by `isShareable`
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .flag(let v): try c.encode(v)
        case .count(let v): try c.encode(v)
        case .number(let v): try c.encode(v.isFinite ? v : 0)
        case .state(let v): try c.encode(v)
        case .symbol(let v): try c.encode(v)
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
        schema == 1 && Self.revisionIsSafe(revision) && values.count <= 40
            && values.allSatisfy { name, value in
                guard let key = SupportKey(rawValue: name) else { return false }
                if case .symbol(let text) = value { return SupportSymbol.isSafe(text, for: key) }
                return true
            }
            && (source == nil || SupportSourceAllowlist.names.contains(source!))
            && (line == nil || line! <= 100_000)
    }
    static func revisionIsSafe(_ value: String?) -> Bool {
        guard let value else { return true }
        return (7...64).contains(value.utf8.count) && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    /// Stored in a separate daily stream so routine records can never rotate them out.
    var isImportant: Bool {
        level != .info || Self.importantEvents.contains(event)
    }
    static let importantEvents: Set<SupportEvent> = [
        .appStarted, .appStopped, .appUpdated, .userMarkedIssue, .captureHealthChanged, .updateChanged,
        .updateCheckFinished, .updateChoice, .storageRecovered, .permissionRepairStarted,
        .permissionRepairFinished, .reportExported, .monitorPaused,
    ]
}

/// A small private journal, independent of activity/history stores. All filesystem
/// work is on one utility queue behind the existing bounded ingress. Each UTC date keeps
/// two 256 KiB segments for routine records and two 128 KiB segments for warnings,
/// errors and lifecycle events; only the last seven dates are retained.
///
/// Repeated identical records are coalesced: the first three per ten minutes are kept,
/// the rest become one `repeatSummary` with their count. Periodic status producers use
/// `recordIfChanged`, which writes only when a discrete value changes (or every 15 min).
final class SupportDiagnostics {
    static let shared = SupportDiagnostics(root: AppPaths.applicationSupportDirectory.appendingPathComponent("SupportDiagnostics"))
    static let segmentBytes = 256 * 1_024
    static let importantSegmentBytes = 128 * 1_024
    static let importantDirectoryName = "important"
    static let retentionDays = 7
    static let repeatWindow: TimeInterval = 600
    static let repeatAllowance = 3
    static let enabledKey = "goalong.supportDiagnostics.enabled.v1"
    static let lastLaunchKey = "goalong.support.lastLaunchVersion.v1"
    private static let uncoalescedEvents: Set<SupportEvent> = [.appStarted, .appStopped, .userMarkedIssue, .reportExported, .repeatSummary, .appUpdated]
    /// Values that drift continuously; they never make a periodic record "new".
    private static let volatileKeys: Set<SupportKey> = [
        .elapsedMS, .durationMS, .axSuccessAgeSeconds, .callbackAgeSeconds, .contextAgeSeconds, .inputCount,
        .pendingEvents, .eventCount, .byteCount, .itemCount, .droppedEvents, .freeSpaceMB, .thermalState,
    ]

    private struct RepeatWindow {
        var startedAt: Date
        var passed: Int
        var suppressed: Int
        let component: SupportComponent
        let event: SupportEvent
        let level: SupportLevel
        let source: String?
        let line: UInt
    }

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
    private var importantLog: BoundedDiagnosticsLog?
    private var repeatWindows: [String: RepeatWindow] = [:]
    private var lastPeriodic: [String: (signature: String, at: Date)] = [:]
    private var suppressedTotal = 0
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

    func start(version: String? = nil, build: String? = nil) {
        lock.lock()
        guard !running else { lock.unlock(); return }
        enabled = isEnabled; running = true
        lock.unlock()
        let previous = defaults.object(forKey: "goalong.support.cleanExit.v1") as? Bool
        if enabled { defaults.set(false, forKey: "goalong.support.cleanExit.v1") }
        var values: [SupportKey: SupportValue] = [.previousExitUnclean: .flag(previous == false)]
        if let version { values[.version] = .symbol(version) }
        if let build { values[.build] = .symbol(build) }
        record(.appStarted, component: .app, values: values)
        recordVersionTransition(version: version, build: build)
        queue.async { [weak self] in self?.prune(at: self?.clock() ?? Date()) }
    }

    /// Records the version change that the previous launch did not know about, so a
    /// report shows exactly which update preceded a problem.
    private func recordVersionTransition(version: String?, build: String?) {
        guard let version else { return }
        let current = [version, build ?? ""].joined(separator: "|")
        let previous = defaults.string(forKey: Self.lastLaunchKey)
        defaults.set(current, forKey: Self.lastLaunchKey)
        guard let previous, previous != current else { return }
        let parts = previous.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        var values: [SupportKey: SupportValue] = [.version: .symbol(version)]
        if let build { values[.build] = .symbol(build) }
        if let old = parts.first, !old.isEmpty { values[.previousVersion] = .symbol(old) }
        if parts.count > 1, !parts[1].isEmpty { values[.previousBuild] = .symbol(parts[1]) }
        record(.appUpdated, component: .updates, values: values)
    }

    func stop() {
        flushRepeatSummaries(force: true)
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
        let source = Self.sourceName(file)
        guard admitRepeat(event, component: component, level: level, values: values, source: source, line: line) else { return }
        append(event, component: component, level: level, values: values, source: source, line: line)
    }

    /// For periodic status producers (heartbeats, permission checks, monitoring cycles):
    /// writes only when a discrete value differs from the last write at this call site,
    /// or when `refreshAfter` has elapsed. Continuous values such as delays are carried
    /// along but never make a record new on their own.
    func recordIfChanged(_ event: SupportEvent, component: SupportComponent, level: SupportLevel = .info,
                         values: [SupportKey: SupportValue] = [:], refreshAfter: TimeInterval = 900,
                         file: StaticString = #fileID, line: UInt = #line) {
        let source = Self.sourceName(file)
        let key = "\(event.rawValue)@\(source ?? "-"):\(line)"
        let signature = Self.signature(values, excludingVolatile: true)
        let now = clock()
        lock.lock()
        if let last = lastPeriodic[key], last.signature == signature, now.timeIntervalSince(last.at) < refreshAfter,
           now >= last.at {
            lock.unlock(); return
        }
        lastPeriodic[key] = (signature, now)
        lock.unlock()
        append(event, component: component, level: level, values: values, source: source, line: line)
    }

    func failure(_ error: Error, component: SupportComponent, file: StaticString = #fileID, line: UInt = #line) {
        record(.operationFailed, component: component, level: .error, values: Self.errorValues(error), file: file, line: line)
    }

    /// Numeric codes and compile-time identifiers only. Deliberately never reads
    /// `localizedDescription`, `userInfo` strings, file paths or unknown domains.
    /// Up to three levels of underlying errors contribute their numeric code and a
    /// fixed category; the deepest one (often the POSIX errno) is kept as the root.
    static func errorValues(_ error: Error) -> [SupportKey: SupportValue] {
        let nsError = error as NSError
        var values: [SupportKey: SupportValue] = [
            .errorCode: .count(nsError.code), .errorKind: .state(kind(of: error)),
        ]
        let dynamicType = type(of: error as Any)
        if !(dynamicType is NSError.Type) {
            if let name = SupportSymbol.typeName(dynamicType) { values[.errorType] = .symbol(name) }
            let mirror = Mirror(reflecting: error)
            if mirror.displayStyle == .enum {
                if let label = mirror.children.first?.label {
                    if SupportSymbol.isSafe(label, for: .errorCase) { values[.errorCase] = .symbol(label) }
                    if mirror.children.count == 1, let payload = mirror.children.first?.value as? Int {
                        values[.errorValue] = .count(payload)
                    }
                } else if !(dynamicType is CustomStringConvertible.Type), !(dynamicType is TextOutputStreamable.Type) {
                    // A payload-free case prints its own name through reflection; a type
                    // with a custom description could print anything and is skipped.
                    let name = String(describing: error)
                    if SupportSymbol.isSafe(name, for: .errorCase) { values[.errorCase] = .symbol(name) }
                }
            }
        } else if let domain = knownDomains[nsError.domain] {
            values[.errorType] = .symbol(domain)
        }
        var underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        var depth = 0
        while let current = underlying, depth < 3 {
            if depth == 0 {
                values[.underlyingErrorCode] = .count(current.code)
                values[.underlyingErrorKind] = .state(kind(of: current))
            }
            values[.rootErrorCode] = .count(current.code)
            values[.rootErrorKind] = .state(kind(of: current))
            underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        return values
    }

    private static let knownDomains: [String: String] = [
        NSCocoaErrorDomain: "NSCocoaErrorDomain", NSPOSIXErrorDomain: "NSPOSIXErrorDomain",
        NSURLErrorDomain: "NSURLErrorDomain", NSOSStatusErrorDomain: "NSOSStatusErrorDomain",
        NSMachErrorDomain: "NSMachErrorDomain", "SUSparkleErrorDomain": "SUSparkleErrorDomain",
        "kCFErrorDomainCFNetwork": "kCFErrorDomainCFNetwork",
    ]

    private static func kind(of error: Error) -> SupportState {
        let nsError = error as NSError
        switch nsError.domain {
        case NSURLErrorDomain, "kCFErrorDomainCFNetwork": return .urlError
        case NSCocoaErrorDomain: return .cocoaError
        case NSPOSIXErrorDomain: return .posixError
        case NSOSStatusErrorDomain: return .osStatusError
        case NSMachErrorDomain: return .machError
        case "SUSparkleErrorDomain": return .sparkleError
        default:
            return type(of: error as Any) is NSError.Type ? .otherError : .swiftError
        }
    }

    /// Legacy free-form messages can embed application names, paths and payloads.
    /// Keep their exact source location, never their text (even in local logs).
    func legacy(file: StaticString, line: UInt) {
        record(.legacyLocation, component: .app, file: file, line: line)
    }

    // MARK: - Coalescing

    private static func sourceName(_ file: StaticString) -> String? {
        String(describing: file).split(separator: "/").last.map(String.init)
    }

    private static func signature(_ values: [SupportKey: SupportValue], excludingVolatile: Bool) -> String {
        values.filter { key, value in
            if case .number = value { return false }
            return !(excludingVolatile && volatileKeys.contains(key))
        }
        .map { "\($0.key.rawValue)=\(String(describing: $0.value))" }
        .sorted().joined(separator: ",")
    }

    /// Returns false when this identical record already appeared `repeatAllowance`
    /// times in the current window. Closing a window that suppressed records emits
    /// one summary with the exact count.
    private func admitRepeat(_ event: SupportEvent, component: SupportComponent, level: SupportLevel,
                             values: [SupportKey: SupportValue], source: String?, line: UInt) -> Bool {
        guard !Self.uncoalescedEvents.contains(event) else { return true }
        let key = "\(component.rawValue).\(event.rawValue).\(level.rawValue)@\(source ?? "-"):\(line)|"
            + Self.signature(values, excludingVolatile: false)
        let now = clock()
        var closed: RepeatWindow?
        lock.lock()
        if var window = repeatWindows[key], now.timeIntervalSince(window.startedAt) < Self.repeatWindow,
           now >= window.startedAt {
            if window.passed >= Self.repeatAllowance {
                window.suppressed += 1; suppressedTotal += 1
                repeatWindows[key] = window
                lock.unlock()
                return false
            }
            window.passed += 1
            repeatWindows[key] = window
        } else {
            if let previous = repeatWindows[key], previous.suppressed > 0 { closed = previous }
            if repeatWindows.count >= 512 { repeatWindows = repeatWindows.filter { $0.value.suppressed > 0 } }
            if repeatWindows.count >= 512 { repeatWindows.removeAll() }
            repeatWindows[key] = RepeatWindow(startedAt: now, passed: 1, suppressed: 0, component: component,
                                              event: event, level: level, source: source, line: line)
        }
        lock.unlock()
        if let closed { appendSummary(closed) }
        return true
    }

    /// Emits summaries for windows that ended (or all pending counts when `force`),
    /// so a report never hides how often a suppressed error happened.
    func flushRepeatSummaries(force: Bool = false) {
        let now = clock()
        var due: [RepeatWindow] = []
        lock.lock()
        for (key, window) in repeatWindows {
            let expired = now.timeIntervalSince(window.startedAt) >= Self.repeatWindow || now < window.startedAt
            if window.suppressed > 0, expired || force {
                due.append(window)
                if expired { repeatWindows[key] = nil } else { repeatWindows[key]?.suppressed = 0 }
            } else if expired {
                repeatWindows[key] = nil
            }
        }
        lock.unlock()
        for window in due.sorted(by: { $0.startedAt < $1.startedAt }) { appendSummary(window) }
    }

    private func appendSummary(_ window: RepeatWindow) {
        append(.repeatSummary, component: window.component, level: window.level,
               values: [.repeatedEvent: .symbol(window.event.rawValue), .suppressedCount: .count(window.suppressed)],
               source: window.source, line: window.line)
    }

    private func append(_ event: SupportEvent, component: SupportComponent, level: SupportLevel,
                        values: [SupportKey: SupportValue], source: String?, line: UInt) {
        lock.lock()
        guard running, enabled else { lock.unlock(); return }
        sequence &+= 1
        let next = sequence
        let generation = intakeGeneration
        lock.unlock()
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

    // MARK: - Flush, snapshot and export

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
        var suppressedRepeats: Int = 0
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
        lock.lock(); let records = recentRecords; let failures = writeFailures; let enabled = enabled
        let suppressed = suppressedTotal; lock.unlock()
        let now = clock(); let days = Self.days(ending: now)
        return Snapshot(records: records.filter { $0.isShareable && days.contains(Self.day($0.timestamp)) && $0.timestamp <= now.addingTimeInterval(60) },
            dropped: ingress.snapshot.totalDroppedCount, rejected: 0, writeFailures: failures,
            enabled: enabled, diskSnapshotIncomplete: true, suppressedRepeats: suppressed)
    }

    private func readSnapshot() -> Snapshot {
            prune(at: clock())
            var records: [SupportRecord] = []; var rejected = 0
            let days = Self.days(ending: clock())
            let rootIsSafe = (try? Self.requirePrivateDirectory(root)) != nil
            for day in days where rootIsSafe {
                let bucket = root.appendingPathComponent(day)
                guard (try? Self.requirePrivateDirectory(bucket)) != nil else { continue }
                var segments: [(URL, Int)] = ["diagnostics.log.1", "diagnostics.log"].map {
                    (bucket.appendingPathComponent($0), Self.segmentBytes)
                }
                let important = bucket.appendingPathComponent(Self.importantDirectoryName)
                if (try? Self.requirePrivateDirectory(important)) != nil {
                    segments += ["diagnostics.log.1", "diagnostics.log"].map {
                        (important.appendingPathComponent($0), Self.importantSegmentBytes)
                    }
                }
                for (url, maximum) in segments {
                    guard let data = try? Self.readPrivateFile(url, maximum: maximum) else { continue }
                    for line in data.split(separator: 10) {
                        guard let record = try? Self.decoder().decode(SupportRecord.self, from: Data(line)),
                              record.isShareable, record.timestamp <= clock().addingTimeInterval(60),
                              days.contains(Self.day(record.timestamp)) else { rejected += 1; continue }
                        records.append(record)
                    }
                }
            }
            lock.lock(); let fallback = recentRecords; let failures = writeFailures; let suppressed = suppressedTotal; lock.unlock()
            records.append(contentsOf: fallback.filter { days.contains(Self.day($0.timestamp)) && $0.timestamp <= clock().addingTimeInterval(60) })
            var seen = Set<String>()
            records = records.filter { seen.insert($0.session.uuidString + ":" + String($0.sequence)).inserted }
            records.sort { $0.timestamp == $1.timestamp ? $0.sequence < $1.sequence : $0.timestamp < $1.timestamp }
            return Snapshot(records: records, dropped: ingress.snapshot.totalDroppedCount,
                rejected: rejected, writeFailures: failures, enabled: isEnabled, diskSnapshotIncomplete: failures > 0,
                suppressedRepeats: suppressed)
    }

    /// Deletes only this journal's known files, not legacy diagnostics or activity.
    func clear() throws {
        try queue.sync {
            lock.lock(); clearedThrough = sequence; intakeGeneration &+= 1; recentRecords.removeAll()
            repeatWindows.removeAll(); lastPeriodic.removeAll(); suppressedTotal = 0; lock.unlock()
            guard FileManager.default.fileExists(atPath: root.path) else { return }
            try Self.requirePrivateDirectory(root)
            let children = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            for child in children where Self.isDayName(child.lastPathComponent) {
                try Self.removeBucket(child)
            }
            log = nil; importantLog = nil; activeDay = nil
        }
    }

    private func persist(_ text: String, at date: Date) {
        let record = try? Self.decoder().decode(SupportRecord.self, from: Data(text.utf8))
        if let record {
            lock.lock(); let isCleared = record.session == session && record.sequence <= clearedThrough; lock.unlock()
            if isCleared { return }
        }
        do {
            try Self.preparePrivateDirectory(root)
            let day = Self.day(date)
            if day != activeDay {
                prune(at: clock())
                let bucket = root.appendingPathComponent(day)
                log = BoundedDiagnosticsLog(directoryURL: bucket, maximumFileBytes: Int64(Self.segmentBytes))
                importantLog = BoundedDiagnosticsLog(directoryURL: bucket.appendingPathComponent(Self.importantDirectoryName),
                                                     maximumFileBytes: Int64(Self.importantSegmentBytes))
                activeDay = day
            }
            // The ingress overload marker is not JSON and is deliberately omitted at export;
            // droppedEvents separately records its exact count in the report.
            if record?.isImportant == true {
                try Self.preparePrivateDirectory(root.appendingPathComponent(day))
                try importantLog?.append(text + "\n")
            } else {
                try log?.append(text + "\n")
            }
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
        let important = url.appendingPathComponent(importantDirectoryName)
        if (try? requirePrivateDirectory(important)) != nil {
            try removeKnownFiles(in: important)
            _ = rmdir(important.path)
        }
        try removeKnownFiles(in: url)
        _ = rmdir(url.path) // Preserve unexpected contents, never recurse.
    }

    private static func removeKnownFiles(in url: URL) throws {
        let known = Set(["diagnostics.log", "diagnostics.log.1", ".diagnostics.log.rotation.tmp"])
        let children = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
        for child in children where known.contains(child.lastPathComponent) {
            // unlink deletes a link itself, never its target; directories are refused.
            var status = stat()
            guard lstat(child.path, &status) == 0, status.st_mode & S_IFMT != S_IFDIR else { continue }
            guard unlink(child.path) == 0 else { throw POSIXError(.EIO) }
        }
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
