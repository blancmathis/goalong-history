#if os(macOS)
    import Darwin
    import Foundation
    import LocalHistoryCore
    import Security

    protocol MinuteSealSigningIdentity: AnyObject {
        var info: DeviceIdentityInfo { get }
        func sign(_ message: Data) throws -> Data
    }

    extension DeviceIdentity: MinuteSealSigningIdentity {}

    protocol MinuteSealUploader: AnyObject {
        func enqueue(_ seal: LocalMinuteSeal)
    }

    struct MinuteSealerRuntimeSnapshot: Equatable {
        let pendingMinuteCount: Int
        let pendingRootCount: Int
        let retryAttempt: Int
        let signingSuspended: Bool
        let unbufferedRootCount: Int
        let lastErrorDescription: String?
        /// Signing waits until the seal journal tail is confirmed (startup, uncertain append,
        /// unreadable seal file or checkpoint). T-057 d4-01/d4-02.
        var journalRecoveryPending = false
    }

    enum MinuteSealJournalError: LocalizedError {
        case unconfirmedAnchorCursor

        var errorDescription: String? {
            switch self {
            case .unconfirmedAnchorCursor:
                return "The integrity checkpoint is unreadable and no durable seal confirms the anchor cursor."
            }
        }
    }

    enum MinuteSealPersistenceError: LocalizedError {
        case durabilityUncertain(String)
        case encodedRowExceedsLimit(actualBytes: Int, maximumBytes: Int)

        var errorDescription: String? {
            switch self {
            case .durabilityUncertain(let detail):
                return
                    "The minute-seal append may have reached disk, but its durability could not be confirmed: \(detail)"
            case .encodedRowExceedsLimit(let actualBytes, let maximumBytes):
                return
                    "The encoded minute-seal row is \(actualBytes) bytes; the bounded maximum is \(maximumBytes) bytes."
            }
        }
    }

    final class MinuteSealer {
        enum AppendDurabilityStep: Equatable {
            case fileCreated
            case fileSynchronized
            case parentDirectorySynchronized
        }

        private struct MinuteBucket {
            var eventRoots: [String] = []
            var coverageStates: Set<String> = []
            var intervalEnd: Date?
            var endingCoverageState: String?
        }

        private enum CoverageSignal {
            case set(String)
            case normalActivity
            case unchanged
        }

        private struct PendingRoot {
            let root: String
            let timestamp: Date
            let coverageSignal: CoverageSignal
        }

        typealias SealAppender = (LocalMinuteSeal, URL) throws -> Void

        private static let boundaryGraceSeconds: TimeInterval = 1
        private static let maximumBufferedMinutes = 3
        private static let maximumSealsPerWake = 8
        static let maximumBufferedRoots = 16_384
        static let maximumEncodedSealRowBytes = 2 * 1_024 * 1_024
        /// Plain write failures (disk full) retry without limit at this ceiling (T-057 d4-01).
        private static let maximumRetryDelay: TimeInterval = 30
        private static let maximumJournalRecoveryDelay: TimeInterval = 300
        /// Coverage state added to seals whose minutes lost roots to the bounded retry buffer.
        static let rootsDroppedCoverageState = "sealBufferOverflow"
        private let queue = DispatchQueue(label: "ai.goalong.localhistory.minute-sealer")
        private let queueKey = DispatchSpecificKey<UInt8>()
        private let stateStore: IntegrityStateStore
        private var identity: MinuteSealSigningIdentity
        private let sealDirectory: URL
        private let sealAppender: SealAppender
        private weak var uploader: MinuteSealUploader?

        private var timer: DispatchSourceTimer?
        private var nextMinuteStart: Date
        private var buckets: [Date: MinuteBucket] = [:]
        private var bufferedRootCount = 0
        private var failedMinuteStart: Date?
        private var retryNotBefore: Date?
        private var retryAttempt = 0
        private var observedCoverageState = "captured"
        private var sealedCoverageState = "captured"
        private var signingSuspended = false
        private var unbufferedRootCount = 0
        private var reportedBufferLimit = false
        private var lastErrorDescription: String?
        private var durabilityBarrier: (() throws -> Void)?
        /// Non-nil: signing waits for a confirmed seal-journal tail (never sign from a doubtful cursor).
        private var journalRecoveryReason: String?
        private var journalRecoveryNotBefore: Date?
        private var journalRecoveryAttempt = 0
        private var reportedJournalSuspension = false
        /// The seal whose append ended in `durabilityUncertain`; recovery decides if it landed.
        private var uncertainSeal: LocalMinuteSeal?
        /// Last minute that lost a root to the bounded buffer; seals up to it say so.
        private var droppedRootsThrough: Date?
        private var suspensionObserver: ((String?) -> Void)?

        private let ingressLock = NSLock()
        private var ingressSlots = [PendingRoot?](
            repeating: nil,
            count: MinuteSealer.maximumBufferedRoots
        )
        private var ingressHead = 0
        private var ingressCount = 0
        private var ingressDrainScheduled = false
        private var ingressDroppedRootCount = 0
        private var reportedIngressLimit = false

        init(
            stateStore: IntegrityStateStore,
            identity: MinuteSealSigningIdentity,
            initialDate: Date = Date(),
            sealDirectory: URL = AppPaths.sealsDirectory,
            prepareStorage: () throws -> Void = { try AppPaths.prepare() },
            sealAppender: SealAppender? = nil
        ) {
            self.stateStore = stateStore
            self.identity = identity
            self.sealDirectory = sealDirectory
            nextMinuteStart = Self.floorToMinute(initialDate)
            self.sealAppender =
                sealAppender ?? { seal, url in
                    try Self.appendJSONLine(seal, to: url)
                }
            queue.setSpecific(key: queueKey, value: 1)
            try? prepareStorage()

            // The tail scan runs on the sealer queue, off the launching thread (T-057 d4-03).
            // Every seal goes through this serial queue, so none can be signed before it.
            journalRecoveryReason = "startup tail recovery"
            queue.async { [weak self] in
                _ = self?.recoverJournalIfNeeded(now: initialDate, ignoreBackoff: true)
            }
        }

        /// Reports a signing pause the user should see (nil = resumed). Called on the sealer queue.
        func setSuspensionObserver(_ observer: @escaping (String?) -> Void) {
            queue.async { [weak self] in
                guard let self else { return }
                self.suspensionObserver = observer
                if self.reportedJournalSuspension { observer(self.lastErrorDescription) }
            }
        }

        /// « Réessayer » : retries the seal-journal recovery now, then seals what is due.
        func retryJournalRecovery() {
            queue.async { [weak self] in
                guard let self, self.journalRecoveryReason != nil else { return }
                self.journalRecoveryNotBefore = nil
                _ = self.sealElapsedMinutes(now: Date())
                self.scheduleNextWakeup()
            }
        }

        /// Confirms the durable seal tail before any signing. Any doubt (unreadable seal file,
        /// unreadable checkpoint without a seal, unconfirmed uncertain append) keeps signing
        /// paused and retries later: the chain is never restarted or forked (T-057 d4-01/d4-02).
        private func recoverJournalIfNeeded(now: Date, ignoreBackoff: Bool) -> Bool {
            guard let reason = journalRecoveryReason else { return true }
            if !ignoreBackoff, let notBefore = journalRecoveryNotBefore, now < notBefore {
                return false
            }
            do {
                let scan = try Self.latestPersistedSeal(in: sealDirectory)
                let tail = scan.latest
                if !scan.unreadable.isEmpty {
                    // An unreadable day file never pauses signing for good (T-057 D4 relecture 1).
                    // It is skipped and logged when it cannot hide the tail: an older day file
                    // (sequences grow with the day), or any file once a valid checkpoint (or a
                    // seal of this launch) confirms the cursor. The pause stays only when the
                    // cursor is unconfirmed and the newest day file is unreadable, or when the
                    // uncertain row's file is unreadable (its landing must be decided).
                    let newestIsUnreadable = scan.newestName.map(scan.unreadable.contains) ?? false
                    let uncertainIsUnreadable = uncertainSeal.map {
                        scan.unreadable.contains(sealFileURL(for: $0.minuteStart).lastPathComponent)
                    } ?? false
                    if uncertainIsUnreadable
                        || (newestIsUnreadable && !stateStore.anchorCursorIsConfirmed)
                    {
                        throw scan.firstError ?? MinuteSealJournalError.unconfirmedAnchorCursor
                    }
                    Diagnostics.write(
                        "Skipped \(scan.unreadable.count) unreadable seal file(s) during tail recovery (cursor kept): \(scan.unreadable.sorted().joined(separator: ", "))"
                    )
                }
                var uncertainSealLanded = false
                if let pending = uncertainSeal, let tail,
                    tail.anchorSequence == pending.anchorSequence,
                    tail.anchorHash == pending.anchorHash
                {
                    // The row is on disk: make it durable before building on it.
                    try Self.synchronizeSealFile(sealFileURL(for: pending.minuteStart))
                    uncertainSealLanded = true
                }
                if let tail {
                    do {
                        try stateStore.reconcilePersistedAnchorTail(
                            sequence: tail.anchorSequence,
                            anchorHash: tail.anchorHash
                        )
                    } catch IntegrityStateError.anchorStateAheadOfJournal(let stateNext, let journalNext) {
                        // A valid checkpoint ahead of the remaining seals (removed by an explicit
                        // retention choice) never reuses a sequence: keep following it.
                        Diagnostics.write(
                            "Anchor checkpoint is ahead of the seal journal (state \(stateNext), journal \(journalNext)); keeping the checkpoint"
                        )
                    }
                }
                if stateStore.anchorCursorIsDoubtful {
                    throw MinuteSealJournalError.unconfirmedAnchorCursor
                }
                if let pending = uncertainSeal {
                    uncertainSeal = nil
                    if uncertainSealLanded { finishLandedUncertainSeal(pending) }
                }
                journalRecoveryReason = nil
                journalRecoveryNotBefore = nil
                journalRecoveryAttempt = 0
                if reportedJournalSuspension {
                    reportedJournalSuspension = false
                    lastErrorDescription = nil
                    Diagnostics.write("Minute signing resumed after seal-journal recovery (\(reason))")
                    suspensionObserver?(nil)
                }
                return true
            } catch {
                journalRecoveryAttempt += 1
                let delay = min(
                    Self.maximumJournalRecoveryDelay,
                    pow(2.0, Double(journalRecoveryAttempt - 1))
                )
                journalRecoveryNotBefore = now.addingTimeInterval(delay)
                lastErrorDescription = "Minute signing paused: \(error.localizedDescription)"
                Diagnostics.write(
                    "Minute signing paused until the seal journal is confirmed (\(reason)); retry in \(Int(delay)) s: \(error)"
                )
                if !reportedJournalSuspension {
                    reportedJournalSuspension = true
                    suspensionObserver?(lastErrorDescription)
                }
                scheduleNextWakeup()
                return false
            }
        }

        /// The uncertain row reached disk and is now synchronized: its minute is sealed.
        private func finishLandedUncertainSeal(_ seal: LocalMinuteSeal) {
            let minuteStart = seal.minuteStart
            if failedMinuteStart == minuteStart {
                if let bucket = buckets[minuteStart] {
                    removeBucket(forKey: minuteStart)
                    if minuteStart == nextMinuteStart {
                        advanceChronology(after: bucket, minuteStart: minuteStart)
                    }
                }
                failedMinuteStart = nil
            }
            retryAttempt = 0
            retryNotBefore = nil
            uploader?.enqueue(seal)
            Diagnostics.write("Uncertain minute-seal append confirmed on disk at sequence \(seal.anchorSequence)")
        }

        private static func synchronizeSealFile(_ url: URL) throws {
            let descriptor = url.path.withCString {
                Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            }
            guard descriptor >= 0 else { throw posixError(path: url.path) }
            defer { _ = Darwin.close(descriptor) }
            let code = DurableSync.sync(sealSync, descriptor)
            guard code == 0 else { throw posixError(path: url.path, code: code) }
        }

        /// Starts the sealer with signing suspended (identity unavailable at startup).
        func suspendSigning(reason: String) {
            queue.async { [weak self] in
                guard let self else { return }
                self.signingSuspended = true
                self.retryNotBefore = nil
                self.lastErrorDescription = reason
                Diagnostics.write("Minute signing suspended for this launch: \(reason)")
            }
        }

        /// Resumes sealing with a freshly resolved identity; pending roots are kept.
        func resumeSigning(with identity: MinuteSealSigningIdentity) {
            queue.async { [weak self] in
                guard let self else { return }
                self.identity = identity
                self.signingSuspended = false
                self.retryAttempt = 0
                self.retryNotBefore = nil
                // A pending journal recovery stays in force: a new identity does not confirm the tail.
                if self.journalRecoveryReason == nil {
                    self.lastErrorDescription = nil
                } else {
                    self.journalRecoveryNotBefore = nil
                }
                self.scheduleNextWakeup()
            }
        }

        func setUploader(_ uploader: MinuteSealUploader?) {
            queue.async { [weak self] in self?.uploader = uploader }
        }

        func setDurabilityBarrier(_ barrier: @escaping () throws -> Void) {
            queue.async { [weak self] in self?.durabilityBarrier = barrier }
        }

        func start() {
            queue.async { [weak self] in
                guard let self, self.timer == nil else { return }
                let timer = DispatchSource.makeTimerSource(queue: self.queue)
                self.timer = timer
                timer.setEventHandler { [weak self] in
                    guard let self else { return }
                    _ = self.sealElapsedMinutes(now: Date())
                    self.scheduleNextWakeup()
                }
                self.scheduleNextWakeup()
                timer.resume()
            }
        }

        /// Seals everything up to and including the current minute because capture
        /// stops (manual pause, consent off or quit). The chronology then moves past
        /// that minute and the time until the next start is labelled `manualPause`,
        /// so a resume neither seals the stop minute twice nor reports the paused gap
        /// as captured.
        @discardableResult
        func stopAndSeal(now: Date = Date()) -> Bool {
            onQueue {
                timer?.cancel()
                timer = nil
                // The stop is known even if the seal fails below: later roots and
                // gaps must not inherit the pre-stop "captured" state.
                observedCoverageState = Self.stoppedCoverageState
                guard !signingSuspended else { return false }
                guard recoverJournalIfNeeded(now: now, ignoreBackoff: true) else { return false }
                retryNotBefore = nil
                guard retryFailedMinuteIfEligible(now: now, ignoreBackoff: true) else {
                    return false
                }
                guard sealElapsedMinutes(now: now, sealLimit: .max) else { return false }

                let current = Self.floorToMinute(now)
                var bucket =
                    buckets[current]
                    ?? MinuteBucket(
                        eventRoots: [],
                        coverageStates: [sealedCoverageState]
                    )
                bucket.endingCoverageState = Self.stoppedCoverageState
                guard seal(bucket: bucket, minuteStart: current, now: now) else {
                    // A later retry advances the chronology from this bucket, so it
                    // carries the stopped state too.
                    failedMinuteStart = current
                    buckets[current] = bucket
                    return false
                }
                removeBucket(forKey: current)
                advanceChronology(after: bucket, minuteStart: current)
                return true
            }
        }

        private static let stoppedCoverageState = "manualPause"

        func receive(_ event: HistoryEvent) {
            guard let root = event.integrity?.eventRoot else { return }
            let pending = PendingRoot(
                root: root,
                timestamp: event.timestamp,
                coverageSignal: Self.coverageSignal(from: event)
            )

            var shouldScheduleDrain = false
            var shouldReportLimit = false
            ingressLock.lock()
            if ingressCount < ingressSlots.count {
                let insertionIndex = (ingressHead + ingressCount) % ingressSlots.count
                ingressSlots[insertionIndex] = pending
                ingressCount += 1
                if !ingressDrainScheduled {
                    ingressDrainScheduled = true
                    shouldScheduleDrain = true
                }
            } else {
                ingressDroppedRootCount += 1
                if !reportedIngressLimit {
                    reportedIngressLimit = true
                    shouldReportLimit = true
                }
            }
            ingressLock.unlock()

            if shouldReportLimit {
                Diagnostics.write(
                    "Minute-seal ingress reached its bounded root capacity; raw events remain durable for recovery"
                )
            }
            if shouldScheduleDrain {
                // Exactly one drain closure represents the whole bounded ingress. The
                // event writer never waits for signing, fsync, Keychain, or upload work.
                queue.async { [weak self] in self?.drainIngress() }
            }
        }

        var runtimeSnapshot: MinuteSealerRuntimeSnapshot {
            onQueue {
                let ingress = ingressSnapshot()
                return MinuteSealerRuntimeSnapshot(
                    pendingMinuteCount: buckets.count,
                    pendingRootCount: bufferedRootCount + ingress.pendingCount,
                    retryAttempt: retryAttempt,
                    signingSuspended: signingSuspended,
                    unbufferedRootCount: unbufferedRootCount + ingress.droppedCount,
                    lastErrorDescription:
                        lastErrorDescription
                        ?? (ingress.droppedCount > 0
                            ? "Minute-seal ingress reached its bounded root capacity."
                            : nil),
                    journalRecoveryPending: journalRecoveryReason != nil
                )
            }
        }

        @discardableResult
        func sealElapsedMinutesForTesting(now: Date) -> Bool {
            onQueue { sealElapsedMinutes(now: now) }
        }

        func receiveForTesting(_ event: HistoryEvent, now: Date) {
            guard let root = event.integrity?.eventRoot else { return }
            onQueue {
                receive(
                    PendingRoot(
                        root: root,
                        timestamp: event.timestamp,
                        coverageSignal: Self.coverageSignal(from: event)
                    ),
                    now: now
                )
            }
        }

        func waitUntilIdleForTesting() {
            onQueue {}
        }

        private func drainIngress() {
            while let pending = takePendingRoot() {
                receive(pending, now: Date())
            }
        }

        private func takePendingRoot() -> PendingRoot? {
            ingressLock.lock()
            defer { ingressLock.unlock() }
            guard ingressCount > 0 else {
                ingressDrainScheduled = false
                reportedIngressLimit = false
                return nil
            }
            let pending = ingressSlots[ingressHead]
            ingressSlots[ingressHead] = nil
            ingressHead = (ingressHead + 1) % ingressSlots.count
            ingressCount -= 1
            return pending
        }

        private func ingressSnapshot() -> (pendingCount: Int, droppedCount: Int) {
            ingressLock.lock()
            defer { ingressLock.unlock() }
            return (ingressCount, ingressDroppedRootCount)
        }

        private func receive(_ pending: PendingRoot, now: Date) {
            let eventMinute = Self.floorToMinute(pending.timestamp)

            if eventMinute < nextMinuteStart {
                // Debounced typing/scroll may arrive just after the boundary wake with
                // a timestamp in the previous minute. Emit a supplemental chained seal
                // instead of silently discarding that root. Older agent timestamps stay
                // in the durable raw journal and are reported, but never grow this buffer.
                // T-057 F2 (bugs-temps-07): after the wall clock is set back, a root
                // stamped about now is fresh, not delayed. It gets a supplemental chained
                // seal; a genuinely late root (stamped long before now) stays refused.
                let freshAfterRollback =
                    now < nextMinuteStart.addingTimeInterval(-60)
                    && abs(now.timeIntervalSince(pending.timestamp)) <= 60
                guard eventMinute >= nextMinuteStart.addingTimeInterval(-60) || freshAfterRollback
                else {
                    unbufferedRootCount += 1
                    lastErrorDescription = "A root arrived outside the bounded late-minute window."
                    Diagnostics.write(
                        "Event root arrived more than one minute after its seal window; raw event retained for recovery"
                    )
                    return
                }
                if freshAfterRollback, eventMinute < nextMinuteStart.addingTimeInterval(-60) {
                    // Seal the finished set-back minutes when a new one starts, then keep
                    // this minute open: one seal per minute, the bucket bound holds, and the
                    // minute wake seals the open one (`sealQueuedSupplementalMinutes`).
                    if buckets[eventMinute] == nil, failedMinuteStart == nil {
                        var sealCount = 0
                        _ = sealQueuedSupplementalMinutes(now: now, sealCount: &sealCount)
                    }
                    _ = insert(
                        root: pending.root,
                        coverageState: observeCoverage(pending.coverageSignal),
                        minuteStart: eventMinute
                    )
                    return
                }
                let coverageState = observeCoverage(pending.coverageSignal)
                guard
                    insert(
                        root: pending.root,
                        coverageState: coverageState,
                        minuteStart: eventMinute
                    )
                else {
                    return
                }
                if failedMinuteStart == nil {
                    let bucket = buckets[eventMinute]!
                    if seal(bucket: bucket, minuteStart: eventMinute, now: now) {
                        removeBucket(forKey: eventMinute)
                    } else {
                        failedMinuteStart = eventMinute
                    }
                }
                return
            }

            if eventMinute > nextMinuteStart {
                _ = sealElapsedMinutes(now: pending.timestamp)
            }
            let coverageState = observeCoverage(pending.coverageSignal)
            _ = insert(
                root: pending.root,
                coverageState: coverageState,
                minuteStart: eventMinute
            )
        }

        @discardableResult
        private func insert(
            root: String,
            coverageState: String,
            minuteStart: Date
        ) -> Bool {
            if buckets[minuteStart] == nil, buckets.count >= Self.maximumBufferedMinutes {
                unbufferedRootCount += 1
                noteDroppedRoot(minuteStart: minuteStart)
                lastErrorDescription = "Minute-seal retry buffer reached its bounded capacity."
                if !reportedBufferLimit {
                    reportedBufferLimit = true
                    Diagnostics.write(
                        "Minute-seal retry buffer reached its three-minute bound; raw events remain durable but require seal recovery"
                    )
                }
                return false
            }
            guard bufferedRootCount < Self.maximumBufferedRoots else {
                unbufferedRootCount += 1
                noteDroppedRoot(minuteStart: minuteStart)
                lastErrorDescription = "Minute-seal retry buffer reached its root-count limit."
                if !reportedBufferLimit {
                    reportedBufferLimit = true
                    Diagnostics.write(
                        "Minute-seal retry buffer reached its root-count bound; raw events remain durable but require seal recovery"
                    )
                }
                return false
            }
            var bucket =
                buckets[minuteStart]
                ?? MinuteBucket(
                    eventRoots: [],
                    coverageStates: [sealedCoverageState]
                )
            bucket.eventRoots.append(root)
            bucket.coverageStates.insert(coverageState)
            bucket.endingCoverageState = coverageState
            buckets[minuteStart] = bucket
            bufferedRootCount += 1
            return true
        }

        /// A minute that lost a root must not be signed as complete: its seal says so.
        private func noteDroppedRoot(minuteStart: Date) {
            droppedRootsThrough = max(droppedRootsThrough ?? minuteStart, minuteStart)
        }

        private static func coverageSignal(from event: HistoryEvent) -> CoverageSignal {
            switch event.kind {
            case .recordingPaused:
                return .set("manualPause")
            case .recordingResumed, .captureResumed, .sessionUnlocked, .systemWake:
                return .set("captured")
            case .sessionLocked:
                return .set("sessionUnavailable")
            case .systemSleep:
                return .set("systemSleep")
            case .secureInputSuppressed:
                return .set("secureInput")
            case .secureInputResumed:
                return .set("captured")
            case .permissionStatus:
                if event.metadata?["accessibility"] == "false"
                    || event.metadata?["input_monitoring"] == "false"
                {
                    return .set("permissionsMissing")
                }
                return .set("captured")
            default:
                if let suppressionReason = event.suppressionReason {
                    return .set(suppressionReason.rawValue)
                }
                return event.kind == .captureSuppressed ? .unchanged : .normalActivity
            }
        }

        private func observeCoverage(_ signal: CoverageSignal) -> String {
            switch signal {
            case .set(let state):
                observedCoverageState = state
            case .normalActivity:
                if observedCoverageState == "privateBrowserWindow" {
                    observedCoverageState = "captured"
                }
            case .unchanged:
                break
            }
            return observedCoverageState
        }

        @discardableResult
        private func sealElapsedMinutes(
            now: Date,
            sealLimit: Int = MinuteSealer.maximumSealsPerWake
        ) -> Bool {
            guard !signingSuspended else { return false }
            guard recoverJournalIfNeeded(now: now, ignoreBackoff: false) else { return false }
            guard retryFailedMinuteIfEligible(now: now, ignoreBackoff: false) else {
                return false
            }
            var sealCount = 0
            guard
                sealQueuedSupplementalMinutes(
                    now: now,
                    sealCount: &sealCount,
                    sealLimit: sealLimit
                )
            else {
                return false
            }

            let nowMinute = Self.floorToMinute(now)
            while nextMinuteStart < nowMinute {
                guard sealCount < sealLimit else {
                    // Bounded yielding protects the serial sealer queue even if future
                    // buffering rules change. The timer observes that we are behind and
                    // schedules the next small batch almost immediately.
                    scheduleNextWakeup()
                    return false
                }
                let minute = nextMinuteStart
                let bucket: MinuteBucket
                if let buffered = buckets[minute] {
                    bucket = buffered
                } else {
                    // Empty time carries no event roots. Represent the entire consecutive
                    // interval with one signed opening instead of signing and fsyncing one
                    // row per missed minute after sleep or a long app absence.
                    let nextBufferedMinute = buckets.keys
                        .filter { $0 > minute && $0 < nowMinute }
                        .min()
                    let intervalEnd = min(
                        Self.nextLocalDayBoundary(after: minute),
                        min(nextBufferedMinute ?? nowMinute, nowMinute)
                    )
                    bucket = MinuteBucket(
                        eventRoots: [],
                        coverageStates: [sealedCoverageState],
                        intervalEnd: intervalEnd
                    )
                }
                guard seal(bucket: bucket, minuteStart: minute, now: now) else {
                    buckets[minute] = bucket
                    failedMinuteStart = minute
                    return false
                }
                removeBucket(forKey: minute)
                advanceChronology(after: bucket, minuteStart: minute)
                sealCount += 1
            }
            return true
        }

        private func sealQueuedSupplementalMinutes(
            now: Date,
            sealCount: inout Int,
            sealLimit: Int = MinuteSealer.maximumSealsPerWake
        ) -> Bool {
            while let minute = buckets.keys.filter({ $0 < nextMinuteStart }).min() {
                guard sealCount < sealLimit else {
                    scheduleNextWakeup()
                    return false
                }
                guard let bucket = buckets[minute] else { continue }
                guard seal(bucket: bucket, minuteStart: minute, now: now) else {
                    failedMinuteStart = minute
                    return false
                }
                removeBucket(forKey: minute)
                sealCount += 1
            }
            return true
        }

        private func retryFailedMinuteIfEligible(now: Date, ignoreBackoff: Bool) -> Bool {
            guard let failedMinuteStart else { return true }
            if !ignoreBackoff, let retryNotBefore, now < retryNotBefore { return false }
            guard let bucket = buckets[failedMinuteStart] else {
                self.failedMinuteStart = nil
                retryAttempt = 0
                retryNotBefore = nil
                return true
            }
            guard seal(bucket: bucket, minuteStart: failedMinuteStart, now: now) else {
                return false
            }

            removeBucket(forKey: failedMinuteStart)
            if failedMinuteStart == nextMinuteStart {
                advanceChronology(after: bucket, minuteStart: failedMinuteStart)
            }
            self.failedMinuteStart = nil
            retryAttempt = 0
            retryNotBefore = nil
            reportedBufferLimit = false
            return true
        }

        private func removeBucket(forKey minuteStart: Date) {
            guard let removed = buckets.removeValue(forKey: minuteStart) else { return }
            bufferedRootCount = max(0, bufferedRootCount - removed.eventRoots.count)
            if bufferedRootCount < Self.maximumBufferedRoots,
                buckets.count < Self.maximumBufferedMinutes
            {
                reportedBufferLimit = false
            }
        }

        private func advanceChronology(after bucket: MinuteBucket, minuteStart: Date) {
            nextMinuteStart = sealEnd(for: bucket, minuteStart: minuteStart)
            if let endingCoverageState = bucket.endingCoverageState {
                sealedCoverageState = endingCoverageState
            }
        }

        private func seal(bucket: MinuteBucket, minuteStart: Date, now: Date) -> Bool {
            // Every path (wake, late root, stop) passes here: nothing is signed while suspended
            // or before the journal tail is confirmed.
            guard !signingSuspended, journalRecoveryReason == nil else { return false }
            var attemptedSeal: LocalMinuteSeal?
            do {
                try durabilityBarrier?()
                let position = stateStore.takeAnchorPosition()
                let minuteEnd = sealEnd(for: bucket, minuteStart: minuteStart)
                let eventsRoot = MerkleTree.root(
                    labeledHexValues: bucket.eventRoots.enumerated().map {
                        ("event:\($0.offset)", $0.element)
                    }
                )

                var coverageStates =
                    bucket.coverageStates.isEmpty ? [sealedCoverageState] : bucket.coverageStates
                if let droppedRootsThrough, minuteStart <= droppedRootsThrough {
                    coverageStates.insert(Self.rootsDroppedCoverageState)
                }
                var coverageFields = [
                    "states": coverageStates.sorted().joined(separator: ",")
                ]
                if bucket.eventRoots.isEmpty,
                    minuteEnd.timeIntervalSince(minuteStart) > 60
                {
                    coverageFields["interval_kind"] = "coalesced_empty"
                    coverageFields["elapsed_minute_count"] = String(
                        Int(minuteEnd.timeIntervalSince(minuteStart) / 60)
                    )
                }

                let minuteFields = MinuteIntegrityMaterial.makeFieldCommitments(
                    minuteStart: minuteStart,
                    minuteEnd: minuteEnd,
                    localDay: AppPaths.localDayString(for: minuteStart),
                    timeZone: TimeZone.current.identifier,
                    utcOffsetSeconds: String(
                        TimeZone.current.secondsFromGMT(for: minuteStart)
                    ),
                    eventRoots: bucket.eventRoots,
                    precomputedEventsRoot: eventsRoot,
                    coverageFields: coverageFields,
                    salts: IntegrityDomains.minuteFieldOrder.map { _ in
                        Self.randomBytes(count: 32)
                    }
                )

                let byName = Dictionary(
                    uniqueKeysWithValues: minuteFields.map { ($0.name, $0.commitmentHex) }
                )
                let leaves = IntegrityDomains.minuteFieldOrder.compactMap { name -> (String, String)? in
                    guard let value = byName[name] else { return nil }
                    return (name, value)
                }
                let minuteRoot = MerkleTree.root(labeledHexValues: leaves)
                let anchorHash = ChainHash.anchor(
                    sequence: position.sequence,
                    previous: position.previousHash,
                    minuteRoot: minuteRoot
                )
                let signingMessage = ChainHash.signingMessage(
                    deviceID: identity.info.deviceID,
                    sequence: position.sequence,
                    previous: position.previousHash,
                    minuteRoot: minuteRoot
                )
                let signature = try identity.sign(signingMessage)

                let seal = LocalMinuteSeal(
                    schemaVersion: 2,
                    anchorSequence: position.sequence,
                    minuteStart: minuteStart,
                    minuteEnd: minuteEnd,
                    minuteFields: minuteFields,
                    eventRoots: bucket.eventRoots,
                    minuteRoot: minuteRoot,
                    previousAnchorHash: position.previousHash,
                    anchorHash: anchorHash,
                    deviceID: identity.info.deviceID,
                    publicKeyBase64: identity.info.publicKeyBase64,
                    trustTier: identity.info.trustTier,
                    signatureBase64: signature.base64EncodedString(),
                    signatureAlgorithm: identity.info.algorithm,
                    storageFormat: .compactSalts
                )

                attemptedSeal = seal
                try sealAppender(seal, sealFileURL(for: minuteStart))
                if let checkpointError = try stateStore.commitPersistedAnchor(
                    sequence: position.sequence,
                    anchorHash: anchorHash
                ) {
                    lastErrorDescription = checkpointError.localizedDescription
                    Diagnostics.write(
                        "Seal is durable but its integrity checkpoint will require tail recovery: \(checkpointError)")
                }
                uploader?.enqueue(seal)
                retryAttempt = 0
                retryNotBefore = nil
                if let through = droppedRootsThrough, minuteEnd > through,
                    !buckets.keys.contains(where: { $0 <= through && $0 != minuteStart })
                {
                    droppedRootsThrough = nil
                }
                return true
            } catch {
                if let persistenceError = error as? MinuteSealPersistenceError,
                    case .durabilityUncertain = persistenceError
                {
                    uncertainSeal = attemptedSeal
                }
                registerSealFailure(error, now: now)
                return false
            }
        }

        private func sealEnd(for bucket: MinuteBucket, minuteStart: Date) -> Date {
            let minimumEnd = minuteStart.addingTimeInterval(60)
            guard let intervalEnd = bucket.intervalEnd else { return minimumEnd }
            return max(minimumEnd, intervalEnd)
        }

        private func registerSealFailure(_ error: Error, now: Date) {
            lastErrorDescription = error.localizedDescription
            Diagnostics.write("Failed to seal minute: \(error)")
            retryAttempt += 1

            if let persistenceError = error as? MinuteSealPersistenceError,
                case .durabilityUncertain = persistenceError
            {
                // Never reuse or skip the sequence blindly: pause signing until the tail scan
                // says whether the row landed, then go on in this launch (T-057 d4-01).
                retryNotBefore = nil
                journalRecoveryReason = "uncertain seal append"
                journalRecoveryAttempt = 0
                journalRecoveryNotBefore = now.addingTimeInterval(1)
                Diagnostics.write(
                    "Minute signing paused after an uncertain append; the seal-journal tail is checked before the next signature"
                )
                scheduleNextWakeup()
                return
            }

            if let persistenceError = error as? MinuteSealPersistenceError,
                case .encodedRowExceedsLimit = persistenceError
            {
                signingSuspended = true
                retryNotBefore = nil
                Diagnostics.write(
                    "Minute signing suspended because the bounded seal-row limit was exceeded; raw events remain durable"
                )
                scheduleNextWakeup()
                return
            }

            if let identityError = error as? DeviceIdentityError,
                identityError.shouldSuspendBackgroundSigning
            {
                signingSuspended = true
                retryNotBefore = nil
                Diagnostics.write(
                    "Minute signing suspended for this launch to prevent recurring Keychain authorization dialogs; pending roots remain bounded in memory"
                )
                scheduleNextWakeup()
                return
            }

            // A plain write failure (disk full, 0 byte written) never suspends signing: it
            // retries at most every 30 s until the disk accepts the seal (T-057 d4-01).
            let delay = min(Self.maximumRetryDelay, pow(2.0, Double(min(retryAttempt, 16) - 1)))
            retryNotBefore = now.addingTimeInterval(delay)
            scheduleNextWakeup()
        }

        private func scheduleNextWakeup() {
            guard let timer else { return }
            if signingSuspended {
                timer.schedule(deadline: .distantFuture)
                return
            }
            let now = Date()
            let delay: TimeInterval
            if journalRecoveryReason != nil, let journalRecoveryNotBefore {
                delay = max(0.01, journalRecoveryNotBefore.timeIntervalSince(now))
            } else if let retryNotBefore, retryNotBefore > now {
                delay = max(0.01, retryNotBefore.timeIntervalSince(now))
            } else {
                delay = Self.nextWakeDelay(now: now, currentMinuteStart: nextMinuteStart)
            }
            timer.schedule(deadline: .now() + delay, leeway: .milliseconds(100))
        }

        private func sealFileURL(for date: Date) -> URL {
            sealDirectory.appendingPathComponent(
                AppPaths.localDayString(for: date) + ".seals.jsonl"
            )
        }

        private func onQueue<T>(_ operation: () -> T) -> T {
            if DispatchQueue.getSpecific(key: queueKey) != nil {
                return operation()
            }
            return queue.sync(execute: operation)
        }

        /// A seal is the durable proof of its minute: its full sync also flushes the drive cache
        /// for the minute's journal rows and checkpoint, which the durability barrier wrote before it.
        static let sealSync = DurableSync.Kind.full

        static func appendJSONLine<T: Encodable>(
            _ value: T,
            to url: URL,
            durabilityObserver: ((AppendDurabilityStep) -> Void)? = nil,
            afterFileCreationForTesting: (() throws -> Void)? = nil
        ) throws {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            var data = try encoder.encode(value)
            guard data.count <= Self.maximumEncodedSealRowBytes else {
                throw MinuteSealPersistenceError.encodedRowExceedsLimit(
                    actualBytes: data.count,
                    maximumBytes: Self.maximumEncodedSealRowBytes
                )
            }
            data.append(0x0A)

            let directoryURL = url.deletingLastPathComponent()
            let directoryDescriptor = directoryURL.path.withCString {
                Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            }
            guard directoryDescriptor >= 0 else {
                throw posixError(path: directoryURL.path)
            }
            defer { _ = Darwin.close(directoryDescriptor) }

            var directoryInformation = stat()
            guard fstat(directoryDescriptor, &directoryInformation) == 0 else {
                throw posixError(path: directoryURL.path)
            }
            guard (directoryInformation.st_mode & S_IFMT) == S_IFDIR else {
                throw posixError(path: directoryURL.path, code: ENOTDIR)
            }

            let commonFlags = O_RDWR | O_APPEND | O_CLOEXEC | O_NOFOLLOW
            let fileName = url.lastPathComponent
            var descriptor = fileName.withCString {
                openat(directoryDescriptor, $0, commonFlags)
            }
            let fileWasMissingBeforeOpen = descriptor < 0 && errno == ENOENT
            var fileWasCreated = false
            if fileWasMissingBeforeOpen {
                descriptor = fileName.withCString {
                    openat(
                        directoryDescriptor,
                        $0,
                        commonFlags | O_CREAT | O_EXCL,
                        mode_t(0o600)
                    )
                }
                if descriptor >= 0 {
                    fileWasCreated = true
                }
                if descriptor < 0, errno == EEXIST {
                    descriptor = fileName.withCString {
                        openat(directoryDescriptor, $0, commonFlags)
                    }
                }
            }
            guard descriptor >= 0 else {
                throw posixError(path: url.path)
            }
            defer { _ = Darwin.close(descriptor) }
            if fileWasCreated {
                durabilityObserver?(.fileCreated)
                try afterFileCreationForTesting?()
            }

            var information = stat()
            guard fstat(descriptor, &information) == 0 else {
                throw posixError(path: url.path)
            }
            guard (information.st_mode & S_IFMT) == S_IFREG else {
                throw posixError(path: url.path, code: EINVAL)
            }
            let parentDirectoryNeedsSynchronization =
                fileWasMissingBeforeOpen || information.st_size == 0
            guard fchmod(descriptor, mode_t(0o600)) == 0 else {
                throw posixError(path: url.path)
            }

            if information.st_size > 0 {
                var finalByte: UInt8 = 0
                let readCount = pread(descriptor, &finalByte, 1, information.st_size - 1)
                guard readCount == 1 else { throw posixError(path: url.path) }
                if finalByte != 0x0A {
                    data.insert(0x0A, at: 0)
                    Diagnostics.write(
                        "Preserved an incomplete minute-seal tail as its own malformed row before appending the next seal"
                    )
                }
            }

            var appendedByteCount = 0
            try data.withUnsafeBytes { buffer in
                guard let baseAddress = buffer.baseAddress else { return }
                while appendedByteCount < data.count {
                    let result = Darwin.write(
                        descriptor,
                        baseAddress.advanced(by: appendedByteCount),
                        data.count - appendedByteCount
                    )
                    if result > 0 {
                        appendedByteCount += result
                        continue
                    }
                    if result < 0, errno == EINTR { continue }
                    let error = posixError(
                        path: url.path,
                        code: result == 0 ? EIO : errno
                    )
                    if appendedByteCount > 0 {
                        throw MinuteSealPersistenceError.durabilityUncertain(
                            error.localizedDescription
                        )
                    }
                    throw error
                }
            }

            let fileSyncCode = DurableSync.sync(sealSync, descriptor)
            if fileSyncCode != 0 {
                throw MinuteSealPersistenceError.durabilityUncertain(
                    posixError(path: url.path, code: fileSyncCode).localizedDescription
                )
            }
            durabilityObserver?(.fileSynchronized)

            if parentDirectoryNeedsSynchronization {
                let directorySyncCode = DurableSync.sync(sealSync, directoryDescriptor)
                if directorySyncCode != 0 {
                    throw MinuteSealPersistenceError.durabilityUncertain(
                        posixError(path: directoryURL.path, code: directorySyncCode).localizedDescription
                    )
                }
                durabilityObserver?(.parentDirectorySynchronized)
            }
        }

        /// Tail scan result. A day file that cannot be read is listed, not fatal: the caller
        /// decides whether it may hide the tail.
        struct PersistedTailScan {
            var latest: LocalMinuteSeal?
            var unreadable: Set<String> = []
            var firstError: Error?
            /// Largest day-file name (yyyy-MM-dd sorts by date).
            var newestName: String?
        }

        private static func latestPersistedSeal(in directory: URL) throws -> PersistedTailScan {
            let directoryDescriptor = directory.path.withCString {
                Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            }
            if directoryDescriptor < 0, errno == ENOENT { return PersistedTailScan() }
            guard directoryDescriptor >= 0 else { throw posixError(path: directory.path) }
            defer { _ = Darwin.close(directoryDescriptor) }

            var directoryInformation = stat()
            guard fstat(directoryDescriptor, &directoryInformation) == 0 else {
                throw posixError(path: directory.path)
            }
            guard (directoryInformation.st_mode & S_IFMT) == S_IFDIR else {
                throw posixError(path: directory.path, code: ENOTDIR)
            }

            let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
                .filter {
                    !$0.hasPrefix(".")
                        && !$0.contains("/")
                        && $0.hasSuffix(".seals.jsonl")
                }

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            var scan = PersistedTailScan(newestName: names.max())
            for name in names {
                let found: LocalMinuteSeal?
                do {
                    found = try latestPersistedSeal(
                        named: name,
                        in: directoryDescriptor,
                        directoryPath: directory.path,
                        decoder: decoder
                    )
                } catch {
                    scan.unreadable.insert(name)
                    if scan.firstError == nil { scan.firstError = error }
                    continue
                }
                guard let seal = found else { continue }
                if scan.latest?.anchorSequence ?? 0 < seal.anchorSequence { scan.latest = seal }
            }
            return scan
        }

        private static func latestPersistedSeal(
            named name: String,
            in directoryDescriptor: Int32,
            directoryPath: String,
            decoder: JSONDecoder
        ) throws -> LocalMinuteSeal? {
            let descriptor = name.withCString {
                openat(directoryDescriptor, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            }
            if descriptor < 0, errno == ENOENT || errno == ELOOP { return nil }
            let filePath = URL(fileURLWithPath: directoryPath)
                .appendingPathComponent(name, isDirectory: false).path
            guard descriptor >= 0 else { throw posixError(path: filePath) }
            defer { _ = Darwin.close(descriptor) }

            var information = stat()
            guard fstat(descriptor, &information) == 0 else {
                throw posixError(path: filePath)
            }
            guard (information.st_mode & S_IFMT) == S_IFREG,
                information.st_size > 0
            else { return nil }

            // Start with a small tail and grow it only when no complete seal decodes,
            // so a normal launch reads kilobytes. Same result as one full-cap read.
            let fileSize = Int64(information.st_size)
            let cap = min(fileSize, Int64(maximumEncodedSealRowBytes + 2))
            // A seal row is a few kilobytes: start small, every launch reads each file's tail.
            var window = min(Int64(16 * 1_024), cap)
            tailWindow: while true {
                let byteCount = window
                let offset = fileSize - byteCount
                var data = Data(count: Int(byteCount))
                var totalRead = 0
                try data.withUnsafeMutableBytes { buffer in
                    guard let baseAddress = buffer.baseAddress else { return }
                    while totalRead < Int(byteCount) {
                        let result = pread(
                            descriptor,
                            baseAddress.advanced(by: totalRead),
                            Int(byteCount) - totalRead,
                            off_t(offset) + off_t(totalRead)
                        )
                        if result > 0 {
                            totalRead += result
                            continue
                        }
                        if result == 0 { break }
                        if errno == EINTR { continue }
                        throw posixError(path: filePath)
                    }
                }
                if totalRead < data.count { data.removeSubrange(totalRead..<data.count) }

                var completeRows = data[data.startIndex...]
                if offset > 0 {
                    var precedingByte: UInt8 = 0
                    while true {
                        let result = pread(
                            descriptor,
                            &precedingByte,
                            1,
                            off_t(offset - 1)
                        )
                        if result == 1 { break }
                        if result < 0, errno == EINTR { continue }
                        throw posixError(path: filePath, code: result == 0 ? EIO : errno)
                    }

                    if precedingByte != 0x0A {
                        guard let firstNewline = completeRows.firstIndex(of: 0x0A) else {
                            if window >= cap { return nil }
                            window = min(window * 4, cap)
                            continue tailWindow
                        }
                        completeRows = completeRows[completeRows.index(after: firstNewline)...]
                    }
                }

                let rows = completeRows.split(separator: 0x0A, omittingEmptySubsequences: true)
                for row in rows.reversed() {
                    guard let seal = try? decoder.decode(LocalMinuteSeal.self, from: Data(row)) else {
                        continue
                    }
                    return seal
                }
                if window >= cap { return nil }
                window = min(window * 4, cap)
            }
        }

        private static func posixError(path: String, code: Int32 = errno) -> NSError {
            NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(code),
                userInfo: [NSFilePathErrorKey: path]
            )
        }

        private static func floorToMinute(_ date: Date) -> Date {
            Date(timeIntervalSince1970: floor(date.timeIntervalSince1970 / 60.0) * 60.0)
        }

        private static func nextLocalDayBoundary(after date: Date) -> Date {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .current
            let dayStart = calendar.startOfDay(for: date)
            return calendar.date(byAdding: .day, value: 1, to: dayStart)
                ?? date.addingTimeInterval(24 * 60 * 60)
        }

        static func secondsUntilNextMinute(now: Date) -> TimeInterval {
            let elapsed = now.timeIntervalSince1970
                .truncatingRemainder(dividingBy: 60)
            let normalizedElapsed = elapsed >= 0 ? elapsed : elapsed + 60
            return max(0.001, 60 - normalizedElapsed + boundaryGraceSeconds)
        }

        static func nextWakeDelay(
            now: Date,
            currentMinuteStart: Date
        ) -> TimeInterval {
            let latestEligibleMinute = floorToMinute(
                now.addingTimeInterval(-boundaryGraceSeconds)
            )
            if currentMinuteStart < latestEligibleMinute { return 0.01 }
            return secondsUntilNextMinute(now: now)
        }

        private static func randomBytes(count: Int) -> Data {
            var bytes = [UInt8](repeating: 0, count: count)
            if SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess {
                return Data(bytes)
            }
            return Data((0..<count).map { _ in UInt8.random(in: 0...255) })
        }
    }
#endif
