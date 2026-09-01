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
        private static let maximumRetryAttempts = 6
        private let queue = DispatchQueue(label: "ai.goalong.localhistory.minute-sealer")
        private let queueKey = DispatchSpecificKey<UInt8>()
        private let stateStore: IntegrityStateStore
        private let identity: MinuteSealSigningIdentity
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

            do {
                if let tail = try Self.latestPersistedSeal(in: sealDirectory) {
                    try stateStore.reconcilePersistedAnchorTail(
                        sequence: tail.anchorSequence,
                        anchorHash: tail.anchorHash
                    )
                }
            } catch {
                lastErrorDescription = error.localizedDescription
                Diagnostics.write("Could not reconcile the durable seal tail: \(error)")
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

        @discardableResult
        func stopAndSeal() -> Bool {
            onQueue {
                timer?.cancel()
                timer = nil
                guard !signingSuspended else { return false }
                retryNotBefore = nil
                let now = Date()
                guard retryFailedMinuteIfEligible(now: now, ignoreBackoff: true) else {
                    return false
                }
                guard sealElapsedMinutes(now: now, sealLimit: .max) else { return false }

                let current = Self.floorToMinute(now)
                let bucket =
                    buckets[current]
                    ?? MinuteBucket(
                        eventRoots: [],
                        coverageStates: [sealedCoverageState],
                        endingCoverageState: observedCoverageState
                    )
                guard seal(bucket: bucket, minuteStart: current, now: now) else {
                    failedMinuteStart = current
                    buckets[current] = bucket
                    return false
                }
                removeBucket(forKey: current)
                return true
            }
        }

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
                            : nil)
                )
            }
        }

        @discardableResult
        func sealElapsedMinutesForTesting(now: Date) -> Bool {
            onQueue { sealElapsedMinutes(now: now) }
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
                guard eventMinute >= nextMinuteStart.addingTimeInterval(-60) else {
                    unbufferedRootCount += 1
                    lastErrorDescription = "A root arrived outside the bounded late-minute window."
                    Diagnostics.write(
                        "Event root arrived more than one minute after its seal window; raw event retained for recovery"
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
            do {
                try durabilityBarrier?()
                let position = stateStore.takeAnchorPosition()
                let minuteEnd = sealEnd(for: bucket, minuteStart: minuteStart)
                let eventsRoot = MerkleTree.root(
                    labeledHexValues: bucket.eventRoots.enumerated().map {
                        ("event:\($0.offset)", $0.element)
                    }
                )

                var coverageFields = [
                    "states":
                        (bucket.coverageStates.isEmpty
                        ? [sealedCoverageState]
                        : bucket.coverageStates.sorted()).joined(separator: ",")
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
                return true
            } catch {
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
                signingSuspended = true
                retryNotBefore = nil
                Diagnostics.write(
                    "Minute signing suspended after an uncertain append so the same anchor sequence is not written twice; startup tail recovery will reconcile any surviving row"
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

            guard retryAttempt < Self.maximumRetryAttempts else {
                signingSuspended = true
                retryNotBefore = nil
                Diagnostics.write(
                    "Minute signing suspended after \(retryAttempt) bounded retries; raw events remain durable and pending roots remain available for this launch"
                )
                scheduleNextWakeup()
                return
            }
            let delay = min(30.0, pow(2.0, Double(retryAttempt - 1)))
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
            if let retryNotBefore, retryNotBefore > now {
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

            while fsync(descriptor) != 0 {
                if errno == EINTR { continue }
                throw MinuteSealPersistenceError.durabilityUncertain(
                    posixError(path: url.path).localizedDescription
                )
            }
            durabilityObserver?(.fileSynchronized)

            if parentDirectoryNeedsSynchronization {
                while fsync(directoryDescriptor) != 0 {
                    if errno == EINTR { continue }
                    throw MinuteSealPersistenceError.durabilityUncertain(
                        posixError(path: directoryURL.path).localizedDescription
                    )
                }
                durabilityObserver?(.parentDirectorySynchronized)
            }
        }

        private static func latestPersistedSeal(in directory: URL) throws -> LocalMinuteSeal? {
            let directoryDescriptor = directory.path.withCString {
                Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            }
            if directoryDescriptor < 0, errno == ENOENT { return nil }
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
            var latest: LocalMinuteSeal?
            for name in names {
                guard
                    let seal = try latestPersistedSeal(
                        named: name,
                        in: directoryDescriptor,
                        directoryPath: directory.path,
                        decoder: decoder
                    )
                else { continue }
                if latest?.anchorSequence ?? 0 < seal.anchorSequence { latest = seal }
            }
            return latest
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

            let maximumTailBytes = maximumEncodedSealRowBytes + 2
            let byteCount = min(Int64(information.st_size), Int64(maximumTailBytes))
            let offset = Int64(information.st_size) - byteCount
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
                        return nil
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
            return nil
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
