#if os(macOS)
    import Combine
    import Foundation

    enum GoalongCapability: String, Codable, CaseIterable, Identifiable {
        case localComputerHistory
        case appleScreenTime
        case aiConversations
        case chatGPTAnalysis
        case remoteVerification
        case automaticUpdates
        case launchAtLogin

        var id: String { rawValue }

        var title: String {
            switch self {
            case .localComputerHistory: return "Computer History"
            case .appleScreenTime: return "Apple Screen Time"
            case .aiConversations: return "AI conversations"
            case .chatGPTAnalysis: return "ChatGPT analysis"
            case .remoteVerification: return "External verification"
            case .automaticUpdates: return "Automatic update checks"
            case .launchAtLogin: return "Launch at login"
            }
        }
    }

    enum GoalongConsentSurface: String, Codable {
        case onboarding
        case settings
        case menuBar
        case migration
    }

    struct GoalongCapabilityConsent: Codable, Equatable {
        var enabled: Bool
        var changedAt: Date?
        var surface: GoalongConsentSurface?

        static let disabled = GoalongCapabilityConsent(
            enabled: false,
            changedAt: nil,
            surface: nil
        )
    }

    struct GoalongConsentDocument: Codable, Equatable {
        static let currentSchemaVersion = 1
        static let currentPolicyVersion = 1

        var schemaVersion: Int
        var policyVersion: Int
        var capabilities: [String: GoalongCapabilityConsent]

        static let disabledByDefault = GoalongConsentDocument(
            schemaVersion: currentSchemaVersion,
            policyVersion: currentPolicyVersion,
            capabilities: Dictionary(
                uniqueKeysWithValues: GoalongCapability.allCases.map {
                    ($0.rawValue, GoalongCapabilityConsent.disabled)
                }
            )
        )

        func consent(for capability: GoalongCapability) -> GoalongCapabilityConsent {
            capabilities[capability.rawValue] ?? .disabled
        }

        func isEnabled(_ capability: GoalongCapability) -> Bool {
            consent(for: capability).enabled
        }

        func normalized() -> GoalongConsentDocument {
            var output = self
            output.schemaVersion = Self.currentSchemaVersion
            output.policyVersion = Self.currentPolicyVersion
            for capability in GoalongCapability.allCases where output.capabilities[capability.rawValue] == nil {
                output.capabilities[capability.rawValue] = .disabled
            }
            output.capabilities = output.capabilities.filter { key, _ in
                GoalongCapability(rawValue: key) != nil
            }
            return output
        }
    }

    extension Notification.Name {
        static let goalongCapabilityConsentDidChange = Notification.Name(
            "ai.goalong.localhistory.capability-consent-did-change"
        )
    }

    /// Goalong's own consent gate. macOS permission state never implies consent here:
    /// both the relevant Goalong capability and the operating-system permission must be on.
    /// A missing, unreadable or future-version file fails closed to every capability off.
    final class GoalongCapabilityConsentStore: ObservableObject {
        static let shared = GoalongCapabilityConsentStore(fileURL: AppPaths.capabilityConsentFile)

        @Published private(set) var document: GoalongConsentDocument

        private let fileURL: URL
        private let fileManager: FileManager
        private let encoder: JSONEncoder

        init(fileURL: URL, fileManager: FileManager = .default) {
            self.fileURL = fileURL
            self.fileManager = fileManager
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            self.encoder = encoder
            self.document = .disabledByDefault
            reload()
        }

        func isEnabled(_ capability: GoalongCapability) -> Bool {
            document.isEnabled(capability)
        }

        @discardableResult
        func set(
            _ capability: GoalongCapability,
            enabled: Bool,
            surface: GoalongConsentSurface
        ) -> Bool {
            var next = document.normalized()
            let previous = next.consent(for: capability)
            guard previous.enabled != enabled else { return true }
            next.capabilities[capability.rawValue] = GoalongCapabilityConsent(
                enabled: enabled,
                changedAt: Date(),
                surface: surface
            )
            do {
                try persist(next)
                document = next
                NotificationCenter.default.post(
                    name: .goalongCapabilityConsentDidChange,
                    object: self,
                    userInfo: ["capability": capability.rawValue, "enabled": enabled]
                )
                return true
            } catch {
                Diagnostics.write(
                    "Capability consent could not be saved for \(capability.rawValue): \(error)"
                )
                return false
            }
        }

        func reload() {
            guard fileManager.fileExists(atPath: fileURL.path) else {
                document = .disabledByDefault
                return
            }
            do {
                let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
                let decoded = try JSONDecoder.goalongConsentDecoder.decode(
                    GoalongConsentDocument.self,
                    from: data
                )
                guard decoded.schemaVersion == GoalongConsentDocument.currentSchemaVersion,
                    decoded.policyVersion == GoalongConsentDocument.currentPolicyVersion
                else {
                    document = .disabledByDefault
                    Diagnostics.write("Capability consent version is unsupported; all capabilities are off")
                    return
                }
                document = decoded.normalized()
                try? fileManager.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: fileURL.path
                )
            } catch {
                document = .disabledByDefault
                Diagnostics.write("Capability consent is unreadable; all capabilities are off: \(error)")
            }
        }

        private func persist(_ value: GoalongConsentDocument) throws {
            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: fileURL.deletingLastPathComponent().path
            )
            let data = try encoder.encode(value.normalized())
            try data.write(to: fileURL, options: .atomic)
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
        }
    }

    private extension JSONDecoder {
        static var goalongConsentDecoder: JSONDecoder {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return decoder
        }
    }
#endif
