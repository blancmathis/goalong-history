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
        }

        private struct PermissionBits: Equatable {
            let accessibilityPreflight: Bool
            let accessibilityFunctionalProbe: Bool
            let inputMonitoringPreflight: Bool

            init(_ status: PermissionStatus) {
                accessibilityPreflight = status.accessibilityPreflight
                accessibilityFunctionalProbe = status.accessibilityFunctionalProbe
                inputMonitoringPreflight = status.inputMonitoringDirectlyGranted
            }
        }

        private let accumulator: CaptureHealthAccumulator

        private let fileURL: URL
        private let persistenceQueue: DispatchQueue
        private let persistenceQueueID: UUID
        private let persistenceDelay: TimeInterval
        private let persistenceWriter: PersistenceWriter
        private let persistenceSchedule: PersistenceSchedule
        private let workLock = NSLock()
        private var pendingPersist: PendingPersist?
        private var mutationGeneration: UInt64 = 0
        private let permissionLock = NSLock()
        private var lastPermissionBits: PermissionBits

        init(
            permissions: PermissionManager,
            fileURL: URL = AppPaths.captureHealthFile,
            persistenceDelay: TimeInterval = 0.5,
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
                ?? (previous?.lastInputEventAt == nil ? nil : previous?.build)
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
            let token = mutateAndPreparePersist {
                accumulator.updatePermissions(Self.observation(from: status))
            }
            permissionLock.unlock()
            schedulePreparedPersist(token)
            return true
        }

        func markTapCreationFailed(_ error: String) {
            mutateAndSchedule { accumulator.markTapCreationFailed(error) }
        }

        func markTapEnabled() {
            mutateAndSchedule { accumulator.markTapEnabled() }
        }

        func markTapDisabled(_ error: String?) {
            mutateAndSchedule { accumulator.markTapDisabled(error) }
        }

        func markInputCallback(at date: Date = Date()) {
            mutateAndSchedule { accumulator.markInputCallback(at: date) }
        }

        func markTapControlCallback(at date: Date = Date()) {
            mutateAndSchedule { accumulator.markTapControlCallback(at: date) }
        }

        func markRecordedEvent(_ kind: EventKind, at date: Date = Date()) {
            mutateAndSchedule { accumulator.markRecordedEvent(kind: kind, at: date) }
        }

        func markAXSuccess(urlAvailable: Bool, at date: Date = Date()) {
            mutateAndSchedule {
                accumulator.markAXSuccess(urlAvailable: urlAvailable, at: date)
            }
        }

        func markAXFailure(at date: Date = Date()) {
            mutateAndSchedule { accumulator.markAXFailure(at: date) }
        }

        func setSuppression(_ reason: SuppressionReason?, at date: Date = Date()) {
            mutateAndSchedule { accumulator.setSuppression(reason, at: date) }
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

        private func mutateAndSchedule(_ mutation: () -> Void) {
            schedulePreparedPersist(mutateAndPreparePersist(mutation))
        }

        private func mutateAndPreparePersist(_ mutation: () -> Void) -> UUID? {
            workLock.lock()
            mutation()
            mutationGeneration &+= 1
            let token: UUID?
            if pendingPersist == nil {
                let nextToken = UUID()
                pendingPersist = PendingPersist(token: nextToken, task: nil)
                token = nextToken
            } else {
                token = nil
            }
            workLock.unlock()
            return token
        }

        private func schedulePreparedPersist(_ token: UUID?) {
            guard let token else { return }
            let task = persistenceSchedule(persistenceDelay) { [weak self] in
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
                observedAt: Date()
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
