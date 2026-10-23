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
            case .identity: return "Afficher le nom"
            case .categoryOnly: return "Catégorie seulement"
            case .hidden: return "Masqué"
            }
        }

        var subtitle: String {
            switch self {
            case .identity: return "Partage le nom de l’app ou du site"
            case .categoryOnly: return "Partage seulement sa catégorie locale"
            case .hidden: return "Ne révèle aucun détail identifiant"
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
        private let fileURL: URL
        /// The file exists but cannot be read or decoded (truncated, no access, unknown value).
        /// Then nothing is shared by name: every app and site counts as hidden (fail-closed).
        private var damaged = false

        /// Defaults apply only when the file does not exist.
        init(fileURL: URL = AppPaths.sharingRulesFile) {
            self.fileURL = fileURL
            if let data = try? Data(contentsOf: fileURL),
                let decoded = try? JSONDecoder().decode(SharingRulesDocument.self, from: data)
            {
                document = decoded
            } else {
                document = SharingRulesDocument()
                // attributesOfItem does not follow a final symlink: a dangling link or an unreadable file counts as present.
                damaged = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)) != nil
            }
        }

        /// True while the rules file is present but unreadable. Senders must refuse to run.
        var isDamaged: Bool { lock.withValue { damaged } }

        var defaultVisibility: SharingVisibility {
            lock.withValue { document.defaultVisibility }
        }

        var rules: [String: SharingVisibility] {
            lock.withValue { document.rules }
        }

        /// True for a website the user hid in every share (explicit rule, or a hidden default).
        /// Reads the rules once, so callers can test many hosts cheaply.
        func hiddenWebsiteFilter() -> (String) -> Bool {
            let (rules, fallback, damaged) = lock.withValue { (document.rules, document.defaultVisibility, self.damaged) }
            if damaged { return { _ in true } }
            return { host in (rules[SharingSubjectKey.website(host: host)] ?? fallback) == .hidden }
        }

        /// True for an application the user hid in every share (explicit rule, or a hidden default).
        /// Arguments are the bundle identifier (or Screen Time id) and the display name.
        func hiddenApplicationFilter() -> (String?, String) -> Bool {
            let (rules, fallback, damaged) = lock.withValue { (document.rules, document.defaultVisibility, self.damaged) }
            if damaged { return { _, _ in true } }
            return { identifier, name in
                (rules[SharingSubjectKey.application(bundleIdentifier: identifier, name: name)] ?? fallback) == .hidden
            }
        }

        func visibility(for key: String) -> SharingVisibility {
            lock.withValue { damaged ? .hidden : document.rules[key] ?? document.defaultVisibility }
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
            // Keep the unreadable file (sharing-rules.damaged-<date>.json) before writing a new one.
            if damaged {
                try moveDamagedFileAsideLocked()
                damaged = false
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(document)
            try data.write(to: fileURL, options: [.atomic])
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
        }

        private func moveDamagedFileAsideLocked() throws {
            let fm = FileManager.default
            guard (try? fm.attributesOfItem(atPath: fileURL.path)) != nil else { return }
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let folder = fileURL.deletingLastPathComponent()
            let base = fileURL.deletingPathExtension().lastPathComponent
            var name = "\(base).damaged-\(stamp).json"
            var index = 1
            while (try? fm.attributesOfItem(atPath: folder.appendingPathComponent(name).path)) != nil {
                name = "\(base).damaged-\(stamp)-\(index).json"
                index += 1
            }
            let target = folder.appendingPathComponent(name, isDirectory: false)
            try fm.moveItem(at: fileURL, to: target)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
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
