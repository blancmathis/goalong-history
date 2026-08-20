#if os(macOS)
    import AppKit
    import ApplicationServices
    import Combine
    import Foundation
    import LocalHistoryCore

    final class ActivityAnalysisRuntime {
        static let shared = ActivityAnalysisRuntime()

        private weak var recorder: EventRecorder?
        private weak var state: CaptureState?
        private weak var configManager: ConfigManager?
        private var currentContext: (() -> ContextSnapshot?)?
        private var semanticContextStore: SemanticContextStore?
        private var memoryStore: LocalActivityMemoryStore?

        private var richContextTimer: Timer?
        private var analysisTimer: Timer?
        private var lastRichContextFingerprints: [String: String] = [:]
        private var lastRichContextCapture = Date.distantPast
        private var lastAnalyzedModificationDates: [String: Date] = [:]
        private let analysisQueue = DispatchQueue(
            label: "ai.goalong.localhistory.activity-analysis",
            qos: .utility
        )
        private let store = ActivityAnalysisStore()

        private init() {}

        func start(
            recorder: EventRecorder,
            state: CaptureState,
            configManager: ConfigManager,
            currentContext: @escaping () -> ContextSnapshot?,
            semanticContextStore: SemanticContextStore,
            memoryStore: LocalActivityMemoryStore
        ) {
            stop()
            self.recorder = recorder
            self.state = state
            self.configManager = configManager
            self.currentContext = currentContext
            self.semanticContextStore = semanticContextStore
            self.memoryStore = memoryStore

            let richTimer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
                self?.captureRichContextIfNeeded()
            }
            let analysisTimer = Timer(timeInterval: 60.0, repeats: true) { [weak self] _ in
                self?.generateRecentAnalyses(force: false)
            }
            RunLoop.main.add(richTimer, forMode: .common)
            RunLoop.main.add(analysisTimer, forMode: .common)
            richContextTimer = richTimer
            self.analysisTimer = analysisTimer
            generateRecentAnalyses(force: true)
        }

        func stop() {
            richContextTimer?.invalidate()
            analysisTimer?.invalidate()
            richContextTimer = nil
            analysisTimer = nil
            currentContext = nil
            semanticContextStore = nil
            memoryStore = nil
        }

        private func captureRichContextIfNeeded() {
            guard ActivityAnalysisPreferences.richContextEnabled,
                let recorder,
                let state,
                state.isCapturing,
                let snapshot = currentContext?(),
                snapshot.suppressionReason == nil,
                snapshot.focusedElement?.isSecure != true
            else { return }

            let interval = ActivityAnalysisPreferences.richContextIntervalSeconds
            guard Date().timeIntervalSince(lastRichContextCapture) >= interval else { return }
            lastRichContextCapture = Date()

            guard let application = NSRunningApplication(processIdentifier: snapshot.app.processIdentifier),
                application.isTerminated == false,
                let capture = AXRichContextReader.capture(
                    processIdentifier: snapshot.app.processIdentifier,
                    maximumCharacters: 6_000
                )
            else { return }

            let contextKey = [
                snapshot.app.bundleIdentifier ?? "pid:\(snapshot.app.processIdentifier)",
                snapshot.url?.value ?? "",
                snapshot.window?.title ?? "",
            ].joined(separator: "|")
            guard lastRichContextFingerprints[contextKey] != capture.fingerprint else { return }
            lastRichContextFingerprints[contextKey] = capture.fingerprint
            if lastRichContextFingerprints.count > 256,
                let firstKey = lastRichContextFingerprints.keys.first
            {
                lastRichContextFingerprints.removeValue(forKey: firstKey)
            }

            guard let semanticContextStore else { return }
            do {
                let reference = try semanticContextStore.append(
                    capture: capture,
                    context: snapshot
                )
                recorder.record(
                    kind: .semanticSnapshot,
                    context: snapshot,
                    semanticContext: reference,
                    metadata: [
                        ActivitySemanticMetadata.version: "3",
                        ActivitySemanticMetadata.source: capture.source,
                        ActivitySemanticMetadata.redacted: String(capture.redacted),
                        ActivitySemanticMetadata.truncated: String(capture.truncated),
                        ActivitySemanticMetadata.fingerprint: capture.fingerprint,
                        ActivitySemanticMetadata.characterCount: String(capture.text.count),
                        "semantic_storage": "separate_local_jsonl",
                    ]
                )
            } catch {
                Diagnostics.write("Semantic context persistence failed: \(error)")
            }
        }

        private func generateRecentAnalyses(force: Bool) {
            let calendar = Calendar.current
            let today = calendar.startOfDay(for: Date())
            let yesterday = calendar.date(byAdding: .day, value: -1, to: today)
            let days = [today, yesterday].compactMap { $0 }

            analysisQueue.async { [weak self] in
                guard let self else { return }
                self.store.removeOrphanedAnalyses()
                for day in days {
                    let key = ActivityAnalysisPaths.dayString(day)
                    guard let modificationDate = self.store.eventModificationDate(for: day) else {
                        self.store.removeAnalysis(for: day)
                        self.lastAnalyzedModificationDates.removeValue(forKey: key)
                        continue
                    }
                    if !force, self.lastAnalyzedModificationDates[key] == modificationDate { continue }
                    do {
                        _ = try self.store.buildAndWrite(for: day)
                        _ = try self.memoryStore?.buildAndWrite(for: day)
                        self.lastAnalyzedModificationDates[key] = modificationDate
                    } catch {
                        Diagnostics.write("Activity analysis generation failed for \(key): \(error)")
                    }
                }
            }
        }
    }

#endif
