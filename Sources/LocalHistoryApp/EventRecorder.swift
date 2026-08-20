#if os(macOS)
    import Foundation
    import LocalHistoryCore

    final class EventRecorder {
        let sessionID = UUID().uuidString
        private let store: JSONLStore
        private let integrityJournal: IntegrityJournal
        private let minuteSealer: MinuteSealer
        private let captureHealth: CaptureHealthStore?

        init(
            store: JSONLStore,
            integrityJournal: IntegrityJournal,
            minuteSealer: MinuteSealer,
            captureHealth: CaptureHealthStore? = nil
        ) {
            self.store = store
            self.integrityJournal = integrityJournal
            self.minuteSealer = minuteSealer
            self.captureHealth = captureHealth
        }

        func record(
            kind: EventKind,
            context: ContextSnapshot? = nil,
            element: ElementSnapshot? = nil,
            pointer: PointerSnapshot? = nil,
            keyboard: KeyboardSnapshot? = nil,
            scroll: ScrollSnapshot? = nil,
            inputOrigin: InputOriginSnapshot? = nil,
            semanticContext: SemanticContextReference? = nil,
            suppressionReason: SuppressionReason? = nil,
            message: String? = nil,
            metadata: [String: String]? = nil,
            timestamp: Date = Date()
        ) {
            let base = HistoryEvent(
                schemaVersion: 4,
                sessionID: sessionID,
                timestamp: timestamp,
                kind: kind,
                app: context?.app,
                window: context?.window,
                element: element ?? context?.focusedElement,
                url: context?.url,
                pointer: pointer,
                keyboard: keyboard,
                scroll: scroll,
                inputOrigin: inputOrigin,
                semanticContext: semanticContext,
                classification: LocalClassifier.classify(
                    app: context?.app,
                    url: context?.url,
                    suppressionReason: suppressionReason ?? context?.suppressionReason
                ),
                suppressionReason: suppressionReason ?? context?.suppressionReason,
                message: message,
                metadata: metadata,
                integrity: nil
            )
            let violations = PrivacyBoundaryValidator.violations(in: base)
            guard violations.isEmpty else {
                Diagnostics.write(
                    "Refused unsafe event \(kind.rawValue): " + violations.map(\.rawValue).joined(separator: ",")
                )
                return
            }
            let event = integrityJournal.commit(base)
            store.append(event)
            minuteSealer.receive(event)
            captureHealth?.markRecordedEvent(kind, at: timestamp)
        }

        func flush() {
            store.flush()
        }

        func close() {
            store.close()
        }
    }
#endif
