#if os(macOS)
import AppKit
import Combine
import Foundation
import LocalHistoryCore

extension Notification.Name {
    static let goalongWorkVerdictsDidChange = Notification.Name("goalong.work.verdicts.changed")
    /// Concentration saved its commitments (one may have settled).
    static let goalongFocusCommitmentsDidChange = Notification.Name("goalong.focus.commitments.changed")
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
        var attempts: Int = 1
        var lastAskedDay: String? = nil
        /// Revision under which an agent verdict was kept, past a reclassification, only for an open « tâche »
        /// commitment: it goes once that commitment settles (T-045 D-154d).
        var keptFrom: String? = nil

        private enum CodingKeys: String, CodingKey { case verdict, task, byOwner, seen, attempts, lastAskedDay, keptFrom }
        init(verdict: GoalongWorkVerdict, task: String?, byOwner: Bool, seen: String,
             attempts: Int = 1, lastAskedDay: String? = nil) {
            self.verdict = verdict; self.task = task; self.byOwner = byOwner; self.seen = seen
            self.attempts = attempts; self.lastAskedDay = lastAskedDay
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            verdict = try c.decode(GoalongWorkVerdict.self, forKey: .verdict)
            task = try c.decodeIfPresent(String.self, forKey: .task)
            byOwner = try c.decode(Bool.self, forKey: .byOwner)
            seen = try c.decode(String.self, forKey: .seen)
            attempts = min(3, max(0, try c.decodeIfPresent(Int.self, forKey: .attempts) ?? (byOwner ? 0 : 1)))
            lastAskedDay = try c.decodeIfPresent(String.self, forKey: .lastAskedDay) ?? (byOwner ? nil : seen)
            keptFrom = try c.decodeIfPresent(String.self, forKey: .keptFrom)
        }
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
    /// Set once when the saved file could not be read: it was kept aside (or left in place,
    /// and nothing is written over it) instead of being silently replaced.
    @Published private(set) var storageNotice: String?
    @Published var automatic: Bool {
        didSet {
            guard automatic != document.automatic else { return }
            if writesBlocked { automaticChangedWhileBlocked = true }
            document.automatic = automatic; persist()
        }
    }
    private var document: Document
    private let fileURL: URL
    private let definitionSource: @MainActor () -> GoalongWorkDefinition
    /// Task names measured by an unsettled « tâche » commitment of Concentration (T-045 H3-02).
    /// Nil: its file is unreadable, so any agent verdict may still be measured.
    private let committedTasks: @MainActor () -> [String]?
    /// Called after a task rename or merge, so Plan du jour items linked to that project follow (T-045 H5-04).
    private let renamedTask: @MainActor (String, String) -> Void
    private var observer: NSObjectProtocol?
    private var commitmentObserver: NSObjectProtocol?
    /// True when an unreadable file could not be moved aside: writing would destroy it.
    private var writesBlocked = false
    /// The user switched automatic classification while the file was unreadable: a repaired file keeps that choice.
    private var automaticChangedWhileBlocked = false

    init(fileURL: URL = AppPaths.applicationSupportDirectory.appendingPathComponent(GoalongWorkStore.fileName),
         definition: @escaping @MainActor () -> GoalongWorkDefinition = { GoalongWorkDefinition(JevWorkContextStore.shared.context) },
         committedTasks: @escaping @MainActor () -> [String]? = {
             GoalongWorkStore.openTaskNames(controller: ConcentrationRuntime.shared.controller, store: .standard)
         },
         renamedTask: @escaping @MainActor (String, String) -> Void = { old, new in
             if let controller = ConcentrationRuntime.shared.controller { controller.renamePlanProject(from: old, to: new) }
             else { _ = try? FocusStore.standard.renamePlanProject(from: old, to: new) }
         }) {
        self.renamedTask = renamedTask
        self.fileURL = fileURL
        self.definitionSource = definition
        self.committedTasks = committedTasks
        let loaded: Document
        switch Self.load(from: fileURL) {
        case .missing: loaded = Document()
        case .loaded(let value): loaded = value
        case .unreadable:
            loaded = Document()
            if let name = try? Self.moveDamagedFileAside(fileURL) {
                storageNotice = "Le classement enregistré était illisible. Il a été mis de côté (\(name)) et vos corrections Travail / Hors travail repartent de zéro."
            } else {
                writesBlocked = true
                storageNotice = "Le classement enregistré est illisible. Rien ne sera enregistré par-dessus tant qu’il n’est pas réparé ou supprimé."
            }
        }
        document = loaded
        automatic = loaded.automatic
        reconcileDefinition()
        observer = NotificationCenter.default.addObserver(forName: .jevWorkContextDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcileDefinition() }
        }
        commitmentObserver = NotificationCenter.default.addObserver(forName: .goalongFocusCommitmentsDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.releaseSettledVerdicts() }
        }
    }

    /// Task names of the open « tâche » commitments. With Concentration off (no controller) they are read
    /// from its saved file: they still settle, from this history, once it is on again (T-045 D-154d).
    /// Nil when that file cannot be read.
    static func openTaskNames(controller: ConcentrationController?, store: @autoclosure () -> FocusStore) -> [String]? {
        openCommitments(controller: controller, store: store()).map(FocusCommitmentRules.openTaskNames)
    }

    /// Concentration's commitments, read from disk when Concentration is off. Nil: its file is unreadable.
    static func openCommitments(controller: ConcentrationController?, store: @autoclosure () -> FocusStore) -> [FocusCommitment]? {
        if let controller { return controller.commitments }
        return try? store().commitments()
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
    /// Returns the verdicts actually stored (none for an older definition).
    @discardableResult
    func merge(_ assignments: [String: GoalongWorkAssignment], revision: String, day: String) -> [String: GoalongWorkAssignment] {
        guard revision == document.revision, !assignments.isEmpty else { return [:] }
        var applied: [String: GoalongWorkAssignment] = [:]
        for (key, assignment) in assignments where document.entries[key]?.byOwner != true {
            let previous = document.entries[key]
            let attempts = min(3, (previous?.attempts ?? 0) + (previous?.lastAskedDay == day ? 0 : 1))
            document.entries[key] = Entry(verdict: assignment.verdict, task: assignment.task, byOwner: false,
                seen: day, attempts: attempts, lastAskedDay: day)
            applied[key] = assignment
        }
        prune()
        publish(); persist()
        return applied
    }

    /// Persist a re-ask before dispatch: a failed answer still counts as an automatic attempt.
    /// A first request records nothing here, so a failure leaves the context unclassified.
    /// Returns false only if a needed record could not be saved.
    @discardableResult func markAsked(_ keys: [String], revision: String, day: String) -> Bool {
        guard revision == document.revision else { return true }
        var changed = false
        for key in keys {
            guard var entry = document.entries[key], !entry.byOwner, entry.verdict == .unclear else { continue }
            if entry.lastAskedDay != day { entry.attempts = min(3, entry.attempts + 1) }
            entry.lastAskedDay = day; entry.seen = day; document.entries[key] = entry; changed = true
        }
        guard changed else { return true }
        prune(); publish(); persist()
        return lastError == nil
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

    /// Renames (or merges into an existing name) one task everywhere. Returns why it refused, if it did:
    /// an open « tâche » commitment finds its task by name and would measure 0 after the rename.
    /// Unknown commitments (unreadable file) refuse too: one of them may measure this task.
    @discardableResult func renameTask(_ old: String, to new: String) -> String? {
        guard let name = GoalongWorkClassification.cleanTask(new), name != old else { return nil }
        if name.localizedCaseInsensitiveCompare(old) != .orderedSame {
            guard let committed = committedTasks() else {
                return "Les engagements Concentration n’ont pas pu être lus : l’un d’eux suit peut-être « \(old) » par son nom. Réessayez plus tard ; si le message revient, supprimez les données Concentration (Réglages › Modules), puis renommez la tâche."
            }
            if committed.contains(where: { $0.localizedCaseInsensitiveCompare(old) == .orderedSame }) {
                return "« \(old) » a un engagement Concentration en cours, qui suit la tâche par son nom. Renommez-la une fois l’engagement réglé."
            }
        }
        for (key, entry) in document.entries where entry.task == old { document.entries[key]?.task = name }
        for index in document.corrections.indices where document.corrections[index].task == old {
            document.corrections[index].task = name
        }
        publish(); persist()
        renamedTask(old, name)
        return nil
    }

    /// Forgets the agent's verdicts (corrections stay) so every context is classified again.
    /// Contexts filed under the task of an open « tâche » commitment stay: the agent could file them
    /// under another name, and the commitment, which finds its task by name, would measure 0.
    /// Those kept are marked, so they are classified again once the commitment settles.
    func forgetAgentVerdicts() {
        document.entries = Self.marked(keptAcrossReclassification(document.entries, committed: committedTasks()), keptFrom: document.revision)
        publish(); persist()
    }

    /// Owner corrections, plus the agent verdicts filed under the task of an open « tâche » commitment:
    /// that commitment finds its task by name and would measure 0 if they were classified again.
    /// With unknown commitments (nil), every verdict stays.
    private func keptAcrossReclassification(_ entries: [String: Entry], committed: [String]?) -> [String: Entry] {
        guard let committed else { return entries }
        return entries.filter { _, entry in
            entry.byOwner || entry.task.map { task in
                committed.contains { $0.localizedCaseInsensitiveCompare(task) == .orderedSame }
            } == true
        }
    }

    #if DEBUG
    /// Test gallery: back to the file on disk (gone with the gallery HOME data) between two images.
    /// An unreadable file reads as empty here; the write block and notices of the last image go.
    func resetForTesting() {
        if case .loaded(let saved) = Self.load(from: fileURL) { document = saved } else { document = Document() }
        writesBlocked = false; automaticChangedWhileBlocked = false
        storageNotice = nil; lastError = nil
        automatic = document.automatic
        reconcileDefinition()
    }
    #endif

    /// Full clear: the saved file is rewritten without any title, and the unreadable copies
    /// (kept aside or left in place) go too, since they hold the same titles.
    func removeAll() {
        document.entries = [:]; document.corrections = []
        if writesBlocked { try? FileManager.default.removeItem(at: fileURL) }
        liftWriteBlock(keepingSavedCorrections: false)
        publish(); persist()
        removeDamagedCopies()
    }

    /// Re-reads the definition. A changed meaning invalidates the agent's verdicts, except those an
    /// open « tâche » commitment measures, until it is settled (T-045 D-154b).
    func reconcileDefinition() {
        let revision = definition.revision
        if revision != document.revision {
            let hadAgentVerdicts = document.entries.values.contains { !$0.byOwner }
            document.entries = Self.marked(keptAcrossReclassification(document.entries, committed: committedTasks()),
                                           keptFrom: document.revision)
            document.revision = revision
            if hadAgentVerdicts || !FileManager.default.fileExists(atPath: fileURL.path) { persist() }
        }
        releaseSettledVerdicts()
    }

    /// Drops the agent verdicts of an older definition once no open commitment measures their task:
    /// nothing asks the agent again about a context that already has a verdict.
    func releaseSettledVerdicts() {
        let stale = document.entries.filter { !$0.value.byOwner && $0.value.keptFrom != nil }
        if !stale.isEmpty, let committed = committedTasks() {
            let kept = keptAcrossReclassification(stale, committed: committed)
            let released = stale.keys.filter { kept[$0] == nil }
            if !released.isEmpty {
                for key in released { document.entries.removeValue(forKey: key) }
                persist()
            }
        }
        publish()
    }

    private static func marked(_ entries: [String: Entry], keptFrom revision: String) -> [String: Entry] {
        entries.mapValues { entry in
            var entry = entry
            if !entry.byOwner, entry.keptFrom == nil { entry.keptFrom = revision }
            return entry
        }
    }

    var revision: String { document.revision }

    private func publish() {
        let next = GoalongWorkVerdicts(document.entries.mapValues {
            GoalongWorkAssignment(verdict: $0.verdict, task: $0.task, byOwner: $0.byOwner)
        }, retries: document.entries.mapValues { GoalongWorkRetryState(attempts: $0.attempts, lastAskedDay: $0.lastAskedDay) })
        guard next != verdicts else { return }
        verdicts = next
        NotificationCenter.default.post(name: .goalongWorkVerdictsDidChange, object: self)
    }

    /// Drops the oldest agent verdicts past the limit; those an open « tâche » commitment measures stay.
    /// With unknown commitments, nothing goes until they can be read again.
    private func prune() {
        guard document.entries.count > Self.maximumEntries else { return }
        let kept = keptAcrossReclassification(document.entries, committed: committedTasks())
        let removable = document.entries.filter { kept[$0.key] == nil }
            .sorted { $0.value.seen == $1.value.seen ? $0.key < $1.key : $0.value.seen < $1.value.seen }
        for (key, _) in removable.prefix(document.entries.count - Self.maximumEntries) {
            document.entries.removeValue(forKey: key)
        }
    }

    /// The unreadable file was left in place. Once it is deleted, repaired or can be moved
    /// aside, writing resumes. A repaired file keeps its corrections unless the user changed
    /// the same context meanwhile, or asked for a full clear.
    private func liftWriteBlock(keepingSavedCorrections: Bool) {
        guard writesBlocked else { return }
        switch Self.load(from: fileURL) {
        case .missing:
            storageNotice = nil
        case .loaded(let saved):
            if keepingSavedCorrections { adopt(saved) }
            storageNotice = nil
        case .unreadable:
            guard let name = try? Self.moveDamagedFileAside(fileURL) else { return }
            storageNotice = "Le classement enregistré était illisible. Il a été mis de côté (\(name)) et vos corrections Travail / Hors travail repartent de zéro."
        }
        writesBlocked = false
        automaticChangedWhileBlocked = false
    }

    /// Merges a repaired file under the changes made while it was unreadable. An owner correction
    /// always wins over an agent verdict, as in `merge`: the agent saw an empty file meanwhile.
    private func adopt(_ saved: Document) {
        var entries = saved.revision == document.revision ? saved.entries
            : Self.marked(keptAcrossReclassification(saved.entries, committed: committedTasks()), keptFrom: saved.revision)
        entries.merge(document.entries) { kept, current in current.byOwner || !kept.byOwner ? current : kept }
        let changed = Set(document.entries.filter { $0.value.byOwner }.keys)
        var corrections = saved.corrections.filter { !changed.contains($0.key) }
        corrections.append(contentsOf: document.corrections)
        let limit = GoalongWorkClassification.maximumExamples * 4
        if corrections.count > limit { corrections.removeFirst(corrections.count - limit) }
        document.entries = entries; document.corrections = corrections
        if !automaticChangedWhileBlocked {
            document.automatic = saved.automatic
            automatic = saved.automatic
        }
        prune(); publish()
    }

    /// Deletes the `work-classification.damaged-*` copies next to the saved file.
    private func removeDamagedCopies() {
        let fm = FileManager.default
        let folder = fileURL.deletingLastPathComponent()
        let prefix = fileURL.deletingPathExtension().lastPathComponent + ".damaged-", suffix = "." + fileURL.pathExtension
        guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { return }
        var failed = false
        for name in names where name.hasPrefix(prefix) && name.hasSuffix(suffix) {
            do { try fm.removeItem(at: folder.appendingPathComponent(name, isDirectory: false)) } catch { failed = true }
        }
        if failed {
            if lastError == nil { lastError = "Une copie illisible du classement n’a pas pu être effacée. Supprimez-la dans le dossier de Goalong." }
        } else if !writesBlocked {
            storageNotice = nil
        }
    }

    private func persist() {
        liftWriteBlock(keepingSavedCorrections: true)
        guard !writesBlocked else {
            lastError = "Le classement n’a pas été enregistré : le fichier existant est illisible."
            return
        }
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

    enum LoadOutcome<Value> { case missing, loaded(Value), unreadable }

    /// A missing file is a fresh start. A file that exists but cannot be read, is too large,
    /// or has another version is unreadable: it must not be overwritten silently.
    private static func load(from url: URL) -> LoadOutcome<Document> {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        guard let data = try? SupportDiagnostics.readPrivateFile(url, maximum: 16 * 1_024 * 1_024),
              let value = try? JSONDecoder().decode(Document.self, from: data), value.version == 1 else { return .unreadable }
        return .loaded(value)
    }

    /// Keeps the user's unreadable file next to the original, under a dated name.
    nonisolated static func moveDamagedFileAside(_ url: URL) throws -> String {
        let fm = FileManager.default
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let folder = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
        var name = "\(base).damaged-\(stamp).\(ext)"
        var index = 1
        while fm.fileExists(atPath: folder.appendingPathComponent(name).path) {
            name = "\(base).damaged-\(stamp)-\(index).\(ext)"
            index += 1
        }
        let target = folder.appendingPathComponent(name, isDirectory: false)
        try fm.moveItem(at: url, to: target)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        return name
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
