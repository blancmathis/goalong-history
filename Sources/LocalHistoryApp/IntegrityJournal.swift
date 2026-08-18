#if os(macOS)
    import Foundation
    import LocalHistoryCore
    import Security

    final class IntegrityJournal {
        private let stateStore: IntegrityStateStore
        private let encoder: JSONEncoder
        private let lock = NSLock()

        init(stateStore: IntegrityStateStore) {
            self.stateStore = stateStore
            encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        }

        func commit(_ baseEvent: HistoryEvent) -> HistoryEvent {
            lock.lock()
            defer { lock.unlock() }

            let position = stateStore.takeEventPosition()
            let classification = baseEvent.classification ?? LocalClassifier.classify(
                app: baseEvent.app,
                url: baseEvent.url,
                suppressionReason: baseEvent.suppressionReason
            )
            let event = HistoryEvent(
                schemaVersion: max(3, baseEvent.schemaVersion),
                id: baseEvent.id,
                sessionID: baseEvent.sessionID,
                timestamp: baseEvent.timestamp,
                kind: baseEvent.kind,
                app: baseEvent.app,
                window: baseEvent.window,
                element: baseEvent.element,
                url: baseEvent.url,
                pointer: baseEvent.pointer,
                keyboard: baseEvent.keyboard,
                scroll: baseEvent.scroll,
                inputOrigin: baseEvent.inputOrigin,
                classification: classification,
                suppressionReason: baseEvent.suppressionReason,
                message: baseEvent.message,
                metadata: baseEvent.metadata,
                integrity: nil
            )

            let fields = makeFieldCommitments(for: event)
            let byName = Dictionary(uniqueKeysWithValues: fields.map { ($0.name, $0.commitmentHex) })
            let fieldOrder = IntegrityDomains.eventFieldOrder(for: event.schemaVersion)
            let leaves = fieldOrder.compactMap { name -> (String, String)? in
                guard let value = byName[name] else { return nil }
                return (name, value)
            }
            let eventRoot = MerkleTree.root(labeledHexValues: leaves)
            let eventHash = ChainHash.event(
                sequence: position.sequence,
                previous: position.previousHash,
                eventRoot: eventRoot
            )
            let integrity = EventIntegrity(
                sequence: position.sequence,
                previousEventHash: position.previousHash,
                eventRoot: eventRoot,
                eventHash: eventHash,
                fieldCommitments: fields
            )
            stateStore.commitEvent(sequence: position.sequence, eventHash: eventHash)
            return event.replacingIntegrity(integrity)
        }

        private func makeFieldCommitments(for event: HistoryEvent) -> [LocalFieldCommitment] {
            let time = [
                "event_id": event.id,
                "session_id": event.sessionID,
                "timestamp": Self.iso8601(event.timestamp),
            ]

            var application: [String: String] = [:]
            if let app = event.app {
                application = [
                    "name": app.name,
                    "bundle_id": app.bundleIdentifier ?? "",
                    "pid": String(app.processIdentifier),
                ]
            }

            var context: [String: String] = [:]
            if let window = event.window {
                context["window_title"] = window.title ?? ""
                context["window_role"] = window.role ?? ""
                context["window_subrole"] = window.subrole ?? ""
            }
            if let element = event.element {
                context["element_role"] = element.role ?? ""
                context["element_subrole"] = element.subrole ?? ""
                context["element_title"] = element.title ?? ""
                context["element_label"] = element.label ?? ""
                context["element_identifier"] = element.identifier ?? ""
                context["element_secure"] = String(element.isSecure)
            }
            if let url = event.url {
                context["url"] = url.value
                context["url_host"] = url.host ?? ""
                context["url_redacted"] = String(url.redactionApplied)
            }

            let website: [String: String] = {
                guard let url = event.url else { return [:] }
                return [
                    "host": url.host ?? "",
                    "redacted": String(url.redactionApplied),
                ]
            }()

            var activity: [String: String] = ["kind": event.kind.rawValue]
            if let pointer = event.pointer {
                activity["pointer_button"] = pointer.button
                activity["pointer_x"] = Self.stableDouble(pointer.x)
                activity["pointer_y"] = Self.stableDouble(pointer.y)
                activity["pointer_click_count"] = String(pointer.clickCount)
            }
            if let keyboard = event.keyboard {
                activity["keyboard_category"] = keyboard.category
                activity["keyboard_key"] = keyboard.key ?? ""
                activity["keyboard_modifiers"] = keyboard.modifiers.joined(separator: ",")
                activity["keyboard_repeat"] = String(keyboard.isRepeat)
            }
            if let scroll = event.scroll {
                activity["scroll_x"] = Self.stableDouble(scroll.deltaX)
                activity["scroll_y"] = Self.stableDouble(scroll.deltaY)
                activity["scroll_count"] = String(scroll.eventCount)
            }
            if let message = event.message { activity["message"] = message }
            for (key, value) in event.metadata ?? [:] {
                activity["meta:\(key)"] = value
            }
            if let origin = event.inputOrigin {
                activity["origin_pid"] = origin.sourceProcessIdentifier.map(String.init) ?? ""
                activity["origin_uid"] = origin.sourceUserIdentifier.map(String.init) ?? ""
                activity["origin_state"] = origin.sourceStateID.map(String.init) ?? ""
                activity["origin_process"] = origin.sourceProcessName ?? ""
                activity["origin_bundle"] = origin.sourceBundleIdentifier ?? ""
            }

            let cls = event.classification ?? LocalClassifier.classify(
                app: event.app,
                url: event.url,
                suppressionReason: event.suppressionReason
            )
            let classification = [
                "category": cls.category,
                "is_work": cls.isWork.map(String.init) ?? "unknown",
                "confidence": Self.stableDouble(cls.confidence),
                "classifier_version": cls.classifierVersion,
            ]

            let coverage = [
                "state": event.suppressionReason?.rawValue ?? "captured",
            ]

            let trust = [
                "input_assessment": event.inputOrigin?.assessment.rawValue ?? "unknown",
            ]

            let rawDigest: String = {
                guard let data = try? encoder.encode(event.replacingIntegrity(nil)) else { return "encoding-error" }
                return SHA256Digest.hashHex(data)
            }()

            var groups: [(String, [String: String])] = [
                ("time", time),
                ("application", application),
            ]
            if event.schemaVersion >= 3 {
                groups.append(("website", website))
            }
            groups.append(contentsOf: [
                ("context", context),
                ("activity", activity),
                ("classification", classification),
                ("coverage", coverage),
                ("trust", trust),
                ("raw_digest", ["sha256": rawDigest]),
            ])

            return groups.map { name, values in
                CommitmentBuilder.make(name: name, fields: values, salt: Self.randomBytes(count: 32))
            }
        }

        private static func randomBytes(count: Int) -> Data {
            var bytes = [UInt8](repeating: 0, count: count)
            let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
            if status == errSecSuccess { return Data(bytes) }
            // This branch is only a last-resort failure mode. It is recorded diagnostically.
            Diagnostics.write("SecRandomCopyBytes failed with status \(status)")
            return Data((0..<count).map { _ in UInt8.random(in: 0...255) })
        }

        private static func iso8601(_ date: Date) -> String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.string(from: date)
        }

        private static func stableDouble(_ value: Double) -> String {
            String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), value)
        }
    }
#endif
