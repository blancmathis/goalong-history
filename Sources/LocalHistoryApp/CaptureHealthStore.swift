#if os(macOS)
    import Foundation
    import LocalHistoryCore

    final class CaptureHealthStore {
        let accumulator: CaptureHealthAccumulator

        private let fileURL: URL
        private let persistenceQueue = DispatchQueue(
            label: "ai.goalong.localhistory.capture-health",
            qos: .utility
        )
        private let workLock = NSLock()
        private var pendingPersist: DispatchWorkItem?

        init(
            permissions: PermissionManager,
            fileURL: URL = AppPaths.captureHealthFile
        ) {
            self.fileURL = fileURL
            let previous = Self.load(from: fileURL)
            let previousWorkingBuild = previous?.lastKnownWorkingBuild
                ?? (previous?.lastInputEventAt == nil ? nil : previous?.build)
            accumulator = CaptureHealthAccumulator(
                build: BuildIdentityReader.current(),
                lastKnownWorkingBuild: previousWorkingBuild,
                permissions: Self.observation(from: permissions.currentStatus),
                restoring: previous
            )
            persistImmediately()
        }

        var snapshot: CaptureHealthSnapshot {
            accumulator.snapshot()
        }

        var assessment: CaptureHealthAssessment {
            CaptureHealthEvaluator.assess(snapshot)
        }

        func updatePermissions(_ status: PermissionStatus) {
            accumulator.updatePermissions(Self.observation(from: status))
            schedulePersist()
        }

        func markTapCreationFailed(_ error: String) {
            accumulator.markTapCreationFailed(error)
            schedulePersist()
        }

        func markTapEnabled() {
            accumulator.markTapEnabled()
            schedulePersist()
        }

        func markTapDisabled(_ error: String?) {
            accumulator.markTapDisabled(error)
            schedulePersist()
        }

        func markInputCallback(at date: Date = Date()) {
            accumulator.markInputCallback(at: date)
            schedulePersist()
        }

        func markTapControlCallback(at date: Date = Date()) {
            accumulator.markTapControlCallback(at: date)
            schedulePersist()
        }

        func markRecordedEvent(_ kind: EventKind, at date: Date = Date()) {
            accumulator.markRecordedEvent(kind: kind, at: date)
            schedulePersist()
        }

        func markAXSuccess(urlAvailable: Bool, at date: Date = Date()) {
            accumulator.markAXSuccess(urlAvailable: urlAvailable, at: date)
            schedulePersist()
        }

        func markAXFailure(at date: Date = Date()) {
            accumulator.markAXFailure(at: date)
            schedulePersist()
        }

        func setSuppression(_ reason: SuppressionReason?, at date: Date = Date()) {
            accumulator.setSuppression(reason, at: date)
            schedulePersist()
        }

        func setPaused(_ value: Bool) {
            accumulator.setPaused(value)
            schedulePersist()
        }

        func beginControlledInputValidation() {
            accumulator.expectUserInput()
            persistImmediately()
        }

        func flush() {
            workLock.lock()
            pendingPersist?.cancel()
            pendingPersist = nil
            workLock.unlock()
            persistImmediately()
            // `persistImmediately` enqueues on this serial queue. Waiting for a
            // no-op guarantees every prior write reached the filesystem before
            // application termination continues.
            persistenceQueue.sync {}
        }

        private func schedulePersist() {
            workLock.lock()
            pendingPersist?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.persistImmediately()
            }
            pendingPersist = work
            workLock.unlock()
            persistenceQueue.asyncAfter(deadline: .now() + 0.5, execute: work)
        }

        private func persistImmediately() {
            let value = accumulator.snapshot()
            persistenceQueue.async { [fileURL] in
                do {
                    let encoder = JSONEncoder()
                    encoder.dateEncodingStrategy = .iso8601
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                    let data = try encoder.encode(value)
                    try data.write(to: fileURL, options: .atomic)
                    try? FileManager.default.setAttributes(
                        [.posixPermissions: 0o600],
                        ofItemAtPath: fileURL.path
                    )
                } catch {
                    Diagnostics.write("Capture-health persistence failed: \(error)")
                }
            }
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
