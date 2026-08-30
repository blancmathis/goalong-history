#if os(macOS)
    import Foundation
    import LocalHistoryCore

    enum SharingVisibility: String, Codable, CaseIterable, Identifiable {
        case identity
        case categoryOnly
        case hidden

        var id: String { rawValue }

        var title: String {
            switch self {
            case .identity: return "Show name"
            case .categoryOnly: return "Category only"
            case .hidden: return "Hidden"
            }
        }

        var subtitle: String {
            switch self {
            case .identity: return "Share the app or website name"
            case .categoryOnly: return "Share only its local category"
            case .hidden: return "Reveal no identifying details"
            }
        }

        var shareLevel: ShareLevel {
            switch self {
            case .identity: return .applicationOnly
            case .categoryOnly: return .categoryOnly
            case .hidden: return .privateOnly
            }
        }
    }

    enum TrackedSubjectKind: String, Codable {
        case application
        case website
    }

    enum SharingSubjectKey {
        static func application(bundleIdentifier: String?, name: String) -> String {
            let identity = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = (identity?.isEmpty == false ? identity! : name).lowercased()
            return "app:\(value)"
        }

        static func website(host: String) -> String {
            "site:\(normalizedHost(host))"
        }

        static func normalizedHost(_ host: String) -> String {
            var value = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            while value.hasSuffix(".") { value.removeLast() }
            if value.hasPrefix("www.") { value.removeFirst(4) }
            return value
        }

        static func displayableWebsiteHost(_ host: String?) -> String? {
            DailyWebsiteUsageAccumulator.displayableHost(host)
        }

        static func trackedWebsiteHost(from snapshot: URLSnapshot?) -> String? {
            DailyWebsiteUsageAccumulator.trackedHost(from: snapshot)
        }

        static func forEvent(_ event: HistoryEvent) -> String? {
            if let host = trackedWebsiteHost(from: event.url) {
                return website(host: host)
            }
            guard let app = event.app else { return nil }
            return application(bundleIdentifier: app.bundleIdentifier, name: app.name)
        }
    }

    struct SharingRulesDocument: Codable {
        var schemaVersion = 1
        var defaultVisibility: SharingVisibility = .categoryOnly
        var rules: [String: SharingVisibility] = [:]
    }

    final class SharingRulesStore {
        private let lock = NSLock()
        private var document: SharingRulesDocument

        init() {
            if let data = try? Data(contentsOf: AppPaths.sharingRulesFile),
                let decoded = try? JSONDecoder().decode(SharingRulesDocument.self, from: data)
            {
                document = decoded
            } else {
                document = SharingRulesDocument()
            }
        }

        var defaultVisibility: SharingVisibility {
            lock.withValue { document.defaultVisibility }
        }

        var rules: [String: SharingVisibility] {
            lock.withValue { document.rules }
        }

        func visibility(for key: String) -> SharingVisibility {
            lock.withValue { document.rules[key] ?? document.defaultVisibility }
        }

        @discardableResult
        func set(_ visibility: SharingVisibility, for key: String) throws -> [String: SharingVisibility] {
            try lock.withValue {
                document.rules[key] = visibility
                try persistLocked()
                return document.rules
            }
        }

        @discardableResult
        func setDefault(_ visibility: SharingVisibility) throws -> SharingRulesDocument {
            try lock.withValue {
                document.defaultVisibility = visibility
                try persistLocked()
                return document
            }
        }

        private func persistLocked() throws {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(document)
            try data.write(to: AppPaths.sharingRulesFile, options: [.atomic])
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: AppPaths.sharingRulesFile.path
            )
        }
    }

    private extension NSLock {
        func withValue<T>(_ body: () throws -> T) rethrows -> T {
            lock()
            defer { unlock() }
            return try body()
        }
    }
#endif
