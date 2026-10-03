#if os(macOS)
    import Foundation
    import LocalHistoryCore

    protocol CaptureHealthScheduledTask: AnyObject {
        func cancel()
    }

    private final class CaptureHealthDispatchTask: CaptureHealthScheduledTask {
        private let workItem: DispatchWorkItem

        init(workItem: DispatchWorkItem) {
            self.workItem = workItem
        }

        func cancel() {
            workItem.cancel()
        }
    }

    private let captureHealthPersistenceQueueKey = DispatchSpecificKey<UUID>()

    final class CaptureHealthStore {
        typealias PersistenceWriter = (CaptureHealthSnapshot, URL) throws -> Void
        typealias PersistenceSchedule = (
            TimeInterval,
            @escaping () -> Void
        ) -> CaptureHealthScheduledTask

        private struct PendingPersist {
            let token: UUID
            var task: CaptureHealthScheduledTask?
            let isRoutine: Bool
        }

        private struct PermissionBits: Equatable {
            let accessibilityPreflight: Bool
            let accessibilityFunctionalProbe: Bool
            let inputMonitoringPreflight: Bool
            let accessibilityCrossProcessProbe: Bool
            let accessibilityProbeDenied: Bool

            init(_ status: PermissionStatus) {
                accessibilityPreflight = status.accessibilityPreflight
                accessibilityFunctionalProbe = status.accessibilityFunctionalProbe
                inputMonitoringPreflight = status.inputMonitoringDirectlyGranted
                accessibilityCrossProcessProbe = status.accessibilityCrossProcessProbe
                accessibilityProbeDenied = status.accessibilityProbeDenied
            }
        }

        private let accumulator: CaptureHealthAccumulator

        private let fileURL: URL
        private let persistenceQueue: DispatchQueue
        private let persistenceQueueID: UUID
        private let persistenceDelay: TimeInterval
        /// Input, recorded-event and AX-success marks only refresh timestamps and
        /// counters. Writing them twice a second rewrote this file all day long.
        private let routinePersistenceDelay: TimeInterval
        private let persistenceWriter: PersistenceWriter
        private let persistenceSchedule: PersistenceSchedule
        private let workLock = NSLock()
        private var pendingPersist: PendingPersist?
        /// Last suppression state written by `setSuppression`; `nil` until the first sample.
        private var lastSuppression: SuppressionReason??
        private var mutationGeneration: UInt64 = 0
        private let permissionLock = NSLock()
        private var lastPermissionBits: PermissionBits

        init(
            permissions: PermissionManager,
            fileURL: URL = AppPaths.captureHealthFile,
            persistenceDelay: TimeInterval = 0.5,
            routinePersistenceDelay: TimeInterval = 15,
            persistenceWriter: PersistenceWriter? = nil,
            persistenceSchedule: PersistenceSchedule? = nil
        ) {
            let queue = DispatchQueue(
                label: "ai.goalong.localhistory.capture-health",
                qos: .utility
            )
            let queueID = UUID()
            self.fileURL = fileURL
            self.persistenceQueue = queue
            self.persistenceQueueID = queueID
            self.persistenceDelay = max(0, persistenceDelay)
            self.routinePersistenceDelay = max(self.persistenceDelay, routinePersistenceDelay)
            self.persistenceWriter = persistenceWriter ?? Self.write
            self.persistenceSchedule =
                persistenceSchedule ?? { delay, action in
                    let workItem = DispatchWorkItem(block: action)
                    queue.asyncAfter(
                        deadline: .now() + max(0, delay),
                        execute: workItem
                    )
                    return CaptureHealthDispatchTask(workItem: workItem)
                }
            let initialStatus = permissions.snapshot
            lastPermissionBits = PermissionBits(initialStatus)
            let previous = Self.load(from: fileURL)
            let previousWorkingBuild =
                previous?.lastKnownWorkingBuild
                ?? (previous?.inputCallbackObservedThisLaunch == true && previous?.permissions.accessibilityUsable == true ? previous?.build : nil)
            accumulator = CaptureHealthAccumulator(
                build: BuildIdentityReader.current(),
                lastKnownWorkingBuild: previousWorkingBuild,
                permissions: Self.observation(from: initialStatus),
                restoring: previous
            )
            queue.setSpecific(key: captureHealthPersistenceQueueKey, value: queueID)
            persistImmediately()
        }

        var snapshot: CaptureHealthSnapshot {
            accumulator.snapshot()
        }

        var assessment: CaptureHealthAssessment {
            CaptureHealthEvaluator.assess(snapshot)
        }

        @discardableResult
        func updatePermissions(_ status: PermissionStatus) -> Bool {
            let nextBits = PermissionBits(status)
            permissionLock.lock()
            guard nextBits != lastPermissionBits else {
                permissionLock.unlock()
                return false
            }
            lastPermissionBits = nextBits
            let prepared = mutateAndPreparePersist {
                accumulator.updatePermissions(Self.observation(from: status))
                return false
            }
            permissionLock.unlock()
            schedulePreparedPersist(prepared)
            return true
        }

        func markTapCreationFailed(_ error: String) {
            SupportDiagnostics.shared.record(.inputTapChanged, component: .capture, values: [.state: .state(.creationFailed)])
            mutateAndSchedule { accumulator.markTapCreationFailed(error) }
        }

        func markTapEnabled() {
            SupportDiagnostics.shared.record(.inputTapChanged, component: .capture, values: [.state: .state(.createdEnabled)])
            mutateAndSchedule { accumulator.markTapEnabled() }
        }

        func markTapDisabled(_ error: String?) {
            SupportDiagnostics.shared.record(.inputTapChanged, component: .capture, values: [.state: .state(.createdDisabled)])
            mutateAndSchedule { accumulator.markTapDisabled(error) }
        }

        func markStorageInterrupted(_ kind: CaptureStorageFailureKind, at date: Date = Date()) {
            mutateAndSchedule { accumulator.markStorageInterrupted(kind, at: date) }
        }

        func markStorageRestored() {
            mutateAndSchedule { accumulator.markStorageRestored() }
        }

        func markInputCallback(at date: Date = Date()) {
            mutateAndSchedule(routine: true) { accumulator.markInputCallback(at: date) }
        }

        func markTapControlCallback(at date: Date = Date()) {
            mutateAndSchedule(routine: true) { accumulator.markTapControlCallback(at: date) }
        }

        func markRecordedEvent(_ kind: EventKind, at date: Date = Date()) {
            mutateAndSchedule(routine: true) { accumulator.markRecordedEvent(kind: kind, at: date) }
        }

        func markAXSuccess(urlAvailable: Bool, at date: Date = Date()) {
            mutateAndSchedule(routine: true) {
                accumulator.markAXSuccess(urlAvailable: urlAvailable, at: date)
            }
        }

        func markAXFailure(at date: Date = Date()) {
            mutateAndSchedule { accumulator.markAXFailure(at: date) }
        }

        func setSuppression(_ reason: SuppressionReason?, at date: Date = Date()) {
            schedulePreparedPersist(mutateAndPreparePersist {
                // Every foreground sample reports its state; only a change is prompt.
                let unchanged = lastSuppression == .some(reason)
                lastSuppression = .some(reason)
                accumulator.setSuppression(reason, at: date)
                return unchanged
            })
        }

        func setPaused(_ value: Bool) {
            mutateAndSchedule { accumulator.setPaused(value) }
        }

        func beginControlledInputValidation() {
            mutateAndPersistImmediately { accumulator.expectUserInput() }
        }

        func flush() {
            if DispatchQueue.getSpecific(key: captureHealthPersistenceQueueKey)
                == persistenceQueueID
            {
                flushOnPersistenceQueue()
                return
            }
            persistenceQueue.sync { [self] in flushOnPersistenceQueue() }
        }

        private func flushOnPersistenceQueue() {
            while true {
                workLock.lock()
                let generation = mutationGeneration
                let cancelledPersist = pendingPersist
                pendingPersist = nil
                let value = accumulator.snapshot()
                workLock.unlock()

                cancelledPersist?.task?.cancel()
                persist(value)

                workLock.lock()
                let caughtUp = mutationGeneration == generation
                workLock.unlock()
                if caughtUp { return }
            }
        }

        private struct PreparedPersist {
            let token: UUID?
            let delay: TimeInterval
            let replacedTask: CaptureHealthScheduledTask?
        }

        private func mutateAndSchedule(routine: Bool = false, _ mutation: () -> Void) {
            schedulePreparedPersist(mutateAndPreparePersist {
                mutation()
                return routine
            })
        }

        /// `mutation` runs under the work lock and returns whether it was routine.
        private func mutateAndPreparePersist(_ mutation: () -> Bool) -> PreparedPersist {
            workLock.lock()
            let routine = mutation()
            mutationGeneration &+= 1
            var token: UUID?
            var replacedTask: CaptureHealthScheduledTask?
            if let pending = pendingPersist {
                // A state change must not wait behind a routine refresh.
                if pending.isRoutine && !routine {
                    replacedTask = pending.task
                    token = UUID()
                }
            } else {
                token = UUID()
            }
            if let token {
                pendingPersist = PendingPersist(token: token, task: nil, isRoutine: routine)
            }
            workLock.unlock()
            return PreparedPersist(
                token: token,
                delay: routine ? routinePersistenceDelay : persistenceDelay,
                replacedTask: replacedTask
            )
        }

        private func schedulePreparedPersist(_ prepared: PreparedPersist) {
            prepared.replacedTask?.cancel()
            guard let token = prepared.token else { return }
            let task = persistenceSchedule(prepared.delay) { [weak self] in
                self?.persistScheduled(token: token)
            }

            workLock.lock()
            let installed: Bool
            if pendingPersist?.token == token {
                pendingPersist?.task = task
                installed = true
            } else {
                installed = false
            }
            workLock.unlock()
            if !installed { task.cancel() }
        }

        private func persistImmediately() {
            persistenceQueue.async { [weak self] in
                self?.persistCurrentSnapshot()
            }
        }

        private func mutateAndPersistImmediately(_ mutation: () -> Void) {
            workLock.lock()
            mutation()
            mutationGeneration &+= 1
            let cancelledPersist = pendingPersist
            pendingPersist = nil
            workLock.unlock()

            cancelledPersist?.task?.cancel()
            persistenceQueue.async { [weak self] in
                self?.persistCurrentSnapshot()
            }
        }

        private func persistCurrentSnapshot() {
            workLock.lock()
            let value = accumulator.snapshot()
            workLock.unlock()
            persist(value)
        }

        private func persistScheduled(token: UUID) {
            workLock.lock()
            guard pendingPersist?.token == token else {
                workLock.unlock()
                return
            }
            pendingPersist = nil
            let value = accumulator.snapshot()
            workLock.unlock()
            persist(value)
        }

        private func persist(_ value: CaptureHealthSnapshot) {
            do {
                try persistenceWriter(value, fileURL)
            } catch {
                SupportDiagnostics.shared.failure(error, component: .storage)
                Diagnostics.write("Capture-health persistence failed: \(error)")
            }
        }

        private static func write(_ value: CaptureHealthSnapshot, to fileURL: URL) throws {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(value)
            try data.write(to: fileURL, options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
        }

        private static func observation(from status: PermissionStatus) -> CapturePermissionObservation {
            CapturePermissionObservation(
                accessibilityPreflight: status.accessibilityPreflight,
                accessibilityFunctionalProbe: status.accessibilityFunctionalProbe,
                inputMonitoringPreflight: status.inputMonitoringDirectlyGranted,
                observedAt: Date(),
                accessibilityCrossProcessProbe: status.accessibilityCrossProcessProbe,
                accessibilityProbeDenied: status.accessibilityProbeDenied
            )
        }

        private static func load(from fileURL: URL) -> CaptureHealthSnapshot? {
            guard FileManager.default.fileExists(atPath: fileURL.path),
                let data = try? Data(contentsOf: fileURL)
            else { return nil }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try? decoder.decode(CaptureHealthSnapshot.self, from: data)
        }
    }
#endif
