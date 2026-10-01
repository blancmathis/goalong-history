#if os(macOS)
import AppKit
import Combine
import Foundation
import LocalHistoryCore

extension Notification.Name {
    static let goalongWorkVerdictsDidChange = Notification.Name("goalong.work.verdicts.changed")
}

/// Verdicts per context (application + site + window title), keyed by a hash: no title is
/// stored here, except in the corrections the user chose to teach. Agent verdicts belong to
/// one definition revision and are dropped when the definition changes; the user's own
/// corrections are kept. Journals are never rewritten.
@MainActor final class GoalongWorkStore: ObservableObject {
    static let shared = GoalongWorkStore()
    nonisolated static let fileName = "work-classification.json"
    static let maximumEntries = 20_000

    struct Entry: Codable, Equatable {
        var verdict: GoalongWorkVerdict
        var task: String?
        var byOwner: Bool
        /// yyyy-MM-dd of the last day this context was seen, used to prune the oldest.
        var seen: String
    }
    struct Correction: Codable, Equatable {
        var key: String
        var label: GoalongWorkContext.Label
        var verdict: GoalongWorkVerdict
        var task: String?
    }
    private struct Document: Codable, Equatable {
        var version = 1
        var revision = ""
        var automatic = true
        var entries: [String: Entry] = [:]
        var corrections: [Correction] = []
    }

    @Published private(set) var verdicts = GoalongWorkVerdicts()
    @Published private(set) var lastError: String?
    @Published var automatic: Bool {
        didSet { guard automatic != document.automatic else { return }; document.automatic = automatic; persist() }
    }
    private var document: Document
    private let fileURL: URL
    private let definitionSource: @MainActor () -> GoalongWorkDefinition
    private var observer: NSObjectProtocol?

    init(fileURL: URL = AppPaths.applicationSupportDirectory.appendingPathComponent(GoalongWorkStore.fileName),
         definition: @escaping @MainActor () -> GoalongWorkDefinition = { GoalongWorkDefinition(JevWorkContextStore.shared.context) }) {
        self.fileURL = fileURL
        self.definitionSource = definition
        let loaded = Self.load(from: fileURL)
        document = loaded
        automatic = loaded.automatic
        reconcileDefinition()
        observer = NotificationCenter.default.addObserver(forName: .jevWorkContextDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcileDefinition() }
        }
    }

    var definition: GoalongWorkDefinition { definitionSource() }
    var corrections: [Correction] { document.corrections }
    var hasAgentVerdicts: Bool { document.entries.values.contains { !$0.byOwner } }

    /// Task names, most used first, so the agent keeps naming one task the same way.
    var knownTasks: [String] {
        var counts: [String: Int] = [:]
        for entry in document.entries.values { if let task = entry.task { counts[task, default: 0] += 1 } }
        return counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.map(\.key)
    }

    var examples: [GoalongWorkClassification.Example] {
        document.corrections.suffix(GoalongWorkClassification.maximumExamples).map {
            GoalongWorkClassification.Example(label: $0.label,
                assignment: GoalongWorkAssignment(verdict: $0.verdict, task: $0.task, byOwner: true))
        }
    }

    func entry(for key: String) -> Entry? { document.entries[key] }

    /// Saves one agent answer. A newer definition or an owner correction always wins.
    func merge(_ assignments: [String: GoalongWorkAssignment], revision: String, day: String) {
        guard revision == document.revision, !assignments.isEmpty else { return }
        for (key, assignment) in assignments where document.entries[key]?.byOwner != true {
            document.entries[key] = Entry(verdict: assignment.verdict, task: assignment.task, byOwner: false, seen: day)
        }
        prune()
        publish(); persist()
    }

    /// The user's own verdict for one context. `nil` removes the correction and lets the
    /// agent decide again.
    func correct(key: String, label: GoalongWorkContext.Label, verdict: GoalongWorkVerdict?, task: String?, day: String) {
        document.corrections.removeAll { $0.key == key }
        if let verdict {
            let assignment = GoalongWorkAssignment(verdict: verdict, task: task, byOwner: true)
            document.entries[key] = Entry(verdict: verdict, task: assignment.task, byOwner: true, seen: day)
            if verdict != .unclear {
                document.corrections.append(Correction(key: key, label: label, verdict: verdict, task: assignment.task))
                if document.corrections.count > GoalongWorkClassification.maximumExamples * 4 {
                    document.corrections.removeFirst(document.corrections.count - GoalongWorkClassification.maximumExamples * 4)
                }
            }
        } else {
            document.entries.removeValue(forKey: key)
        }
        publish(); persist()
    }

    /// Renames (or merges into an existing name) one task everywhere.
    func renameTask(_ old: String, to new: String) {
        guard let name = GoalongWorkClassification.cleanTask(new), name != old else { return }
        for (key, entry) in document.entries where entry.task == old { document.entries[key]?.task = name }
        for index in document.corrections.indices where document.corrections[index].task == old {
            document.corrections[index].task = name
        }
        publish(); persist()
    }

    /// Forgets the agent's verdicts (corrections stay) so every context is classified again.
    func forgetAgentVerdicts() {
        document.entries = document.entries.filter { $0.value.byOwner }
        publish(); persist()
    }

    func removeAll() {
        document.entries = [:]; document.corrections = []
        publish(); persist()
    }

    /// Re-reads the definition. A changed meaning invalidates the agent's verdicts.
    func reconcileDefinition() {
        let revision = definition.revision
        if revision != document.revision {
            let hadAgentVerdicts = document.entries.values.contains { !$0.byOwner }
            document.revision = revision
            document.entries = document.entries.filter { $0.value.byOwner }
            if hadAgentVerdicts || !FileManager.default.fileExists(atPath: fileURL.path) { persist() }
        }
        publish()
    }

    var revision: String { document.revision }

    private func publish() {
        let next = GoalongWorkVerdicts(document.entries.mapValues {
            GoalongWorkAssignment(verdict: $0.verdict, task: $0.task, byOwner: $0.byOwner)
        })
        guard next != verdicts else { return }
        verdicts = next
        NotificationCenter.default.post(name: .goalongWorkVerdictsDidChange, object: self)
    }

    private func prune() {
        guard document.entries.count > Self.maximumEntries else { return }
        let removable = document.entries.filter { !$0.value.byOwner }
            .sorted { $0.value.seen == $1.value.seen ? $0.key < $1.key : $0.value.seen < $1.value.seen }
        for (key, _) in removable.prefix(document.entries.count - Self.maximumEntries) {
            document.entries.removeValue(forKey: key)
        }
    }

    private func persist() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(document).write(to: fileURL, options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            lastError = nil
        } catch {
            SupportDiagnostics.shared.failure(error, component: .storage)
            lastError = "Le classement n’a pas pu être enregistré. Réessayez."
        }
    }

    private static func load(from url: URL) -> Document {
        guard let data = try? SupportDiagnostics.readPrivateFile(url, maximum: 16 * 1_024 * 1_024),
              let value = try? JSONDecoder().decode(Document.self, from: data), value.version == 1 else { return Document() }
        return value
    }
}

extension GoalongWorkStore {
    /// Former Travail / Hors travail choices per application or site, offered once as a
    /// starting point for the definition. The old file is read, never modified.
    nonisolated static func legacyDraft(root: URL = AppPaths.applicationSupportDirectory) -> (work: String, other: String)? {
        let url = root.appendingPathComponent("activity-classification.json")
        guard let data = try? SupportDiagnostics.readPrivateFile(url, maximum: 4 * 1_024 * 1_024),
              let rules = try? JSONDecoder().decode(GoalongUsageClassificationRules.self, from: data), !rules.isEmpty else { return nil }
        func names(_ verdict: GoalongUsageClass) -> String {
            let apps = rules.applications.filter { $0.value == verdict }.keys.map { key -> String in
                // The installed app's own name, never a raw bundle identifier.
                guard key.contains(".") else { return key }
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: key) {
                    return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
                }
                return key.split(separator: ".").last.map(String.init) ?? key
            }
            let sites = rules.websites.filter { $0.value == verdict }.keys.map {
                $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0
            }
            return Set(apps + sites).filter { $0.contains { $0.isLetter || $0.isNumber } }
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }.joined(separator: ", ")
        }
        let work = names(.work), other = names(.other)
        return work.isEmpty && other.isEmpty ? nil : (work, other)
    }
}
#endif
