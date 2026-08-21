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
        private let computerHistoryStore = ComputerHistoryStore()

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

        /// Captures bounded Accessibility context linked to one concrete interaction.
        /// Before-state capture is intentionally shallow to keep the event tap responsive;
        /// the delayed settled phase receives the full tree budget.
        func captureInteractionContext(
            interactionID: String,
            phase: String,
            trigger: String,
            context explicitContext: ContextSnapshot? = nil
        ) {
            guard !interactionID.isEmpty else { return }
            guard let snapshot = explicitContext ?? currentContext?() else { return }
            let budget = semanticBudget(for: phase)
            _ = persistSemanticContext(
                snapshot: snapshot,
                maximumCharacters: budget.characters,
                maximumNodes: budget.nodes,
                deduplicate: false,
                metadata: [
                    ComputerHistoryMetadata.interactionID: interactionID,
                    ComputerHistoryMetadata.interactionPhase: phase,
                    ComputerHistoryMetadata.interactionTrigger: trigger,
                    "computer_history.capture_nodes": String(budget.nodes),
                ]
            )
        }

        /// Captures an event-driven semantic observation that is not tied to an input
        /// interaction, such as a programmatic value change or a short-lived window title.
        /// Fingerprint deduplication prevents Accessibility notification storms from
        /// producing duplicate local payloads.
        func captureObservedContext(
            trigger: String,
            context explicitContext: ContextSnapshot? = nil
        ) {
            guard let snapshot = explicitContext ?? currentContext?() else { return }
            _ = persistSemanticContext(
                snapshot: snapshot,
                maximumCharacters: 4_800,
                maximumNodes: 180,
                deduplicate: true,
                metadata: [
                    ComputerHistoryMetadata.interactionTrigger: "ax:\(trigger)",
                    "computer_history.capture_nodes": "180",
                ]
            )
        }

        func scheduleInteractionContext(
            interactionID: String,
            phase: String,
            trigger: String,
            delay: TimeInterval
        ) {
            guard !interactionID.isEmpty else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + Swift.max(0, delay)) { [weak self] in
                self?.captureInteractionContext(
                    interactionID: interactionID,
                    phase: phase,
                    trigger: trigger
                )
            }
        }

        private func semanticBudget(for phase: String) -> (characters: Int, nodes: Int) {
            switch phase {
            case ComputerHistoryMetadata.Phase.before:
                return (2_400, 72)
            case ComputerHistoryMetadata.Phase.after:
                return (4_800, 160)
            case ComputerHistoryMetadata.Phase.settled:
                return (6_000, 260)
            default:
                return (4_000, 140)
            }
        }

        private func captureRichContextIfNeeded() {
            guard ActivityAnalysisPreferences.richContextEnabled,
                let state,
                state.isCapturing,
                let snapshot = currentContext?(),
                snapshot.suppressionReason == nil,
                snapshot.focusedElement?.isSecure != true
            else { return }

            let interval = ActivityAnalysisPreferences.richContextIntervalSeconds
            guard Date().timeIntervalSince(lastRichContextCapture) >= interval else { return }
            lastRichContextCapture = Date()
            _ = persistSemanticContext(
                snapshot: snapshot,
                maximumCharacters: 6_000,
                maximumNodes: 260,
                deduplicate: true,
                metadata: [ComputerHistoryMetadata.interactionTrigger: "periodic"]
            )
        }

        @discardableResult
        private func persistSemanticContext(
            snapshot: ContextSnapshot,
            maximumCharacters: Int,
            maximumNodes: Int,
            deduplicate: Bool,
            metadata additionalMetadata: [String: String]
        ) -> SemanticContextReference? {
            guard ActivityAnalysisPreferences.richContextEnabled,
                let recorder,
                let state,
                state.isCapturing,
                snapshot.suppressionReason == nil,
                snapshot.focusedElement?.isSecure != true,
                let application = NSRunningApplication(
                    processIdentifier: snapshot.app.processIdentifier
                ),
                application.isTerminated == false,
                let capture = AXRichContextReader.capture(
                    processIdentifier: snapshot.app.processIdentifier,
                    maximumCharacters: maximumCharacters,
                    maximumNodes: maximumNodes
                )
            else { return nil }

            let contextKey = [
                snapshot.app.bundleIdentifier ?? "pid:\(snapshot.app.processIdentifier)",
                snapshot.url?.value ?? "",
                snapshot.window?.title ?? "",
            ].joined(separator: "|")
            if deduplicate {
                guard lastRichContextFingerprints[contextKey] != capture.fingerprint else {
                    return nil
                }
                lastRichContextFingerprints[contextKey] = capture.fingerprint
                if lastRichContextFingerprints.count > 256,
                    let firstKey = lastRichContextFingerprints.keys.first
                {
                    lastRichContextFingerprints.removeValue(forKey: firstKey)
                }
            }

            guard let semanticContextStore else { return nil }
            do {
                let reference = try semanticContextStore.append(
                    capture: capture,
                    context: snapshot
                )
                var metadata: [String: String] = [
                    ActivitySemanticMetadata.version: "4",
                    ActivitySemanticMetadata.source: capture.source,
                    ActivitySemanticMetadata.redacted: String(capture.redacted),
                    ActivitySemanticMetadata.truncated: String(capture.truncated),
                    ActivitySemanticMetadata.fingerprint: capture.fingerprint,
                    ActivitySemanticMetadata.characterCount: String(capture.text.count),
                    "semantic_storage": "separate_local_jsonl",
                ]
                for (key, value) in additionalMetadata { metadata[key] = value }
                recorder.record(
                    kind: .semanticSnapshot,
                    context: snapshot,
                    semanticContext: reference,
                    metadata: metadata
                )
                return reference
            } catch {
                Diagnostics.write("Semantic context persistence failed: \(error)")
                return nil
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
                    if !force,
                        self.lastAnalyzedModificationDates[key] == modificationDate
                    {
                        continue
                    }
                    do {
                        _ = try self.store.buildAndWrite(for: day)
                        _ = try self.memoryStore?.buildAndWrite(for: day)
                        _ = try self.computerHistoryStore.buildAndWrite(for: day)
                        self.lastAnalyzedModificationDates[key] = modificationDate
                    } catch {
                        Diagnostics.write(
                            "Activity analysis generation failed for \(key): \(error)"
                        )
                    }
                }
            }
        }
    }
#endif
