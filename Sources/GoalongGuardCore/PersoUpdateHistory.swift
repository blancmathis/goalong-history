import Darwin
import Foundation

/// T-057 (idées 5 et 6) : what each `make perso` hand-off went through, kept after the script removes its request
/// folder. Status only: no install decision ever reads this file. The app writes received → verified → closing
/// (or refused); the relauncher writes relaunching → done, restored or failed. Bounded: the last `maximumEntries`
/// requests, each with at most one step per phase. `PersoUpdate/history.json`, written atomically under a lock.
public struct PersoUpdateHistory: Sendable {
    public static let maximumEntries = 20
    /// A request still without a final phase after this is shown as interrupted, not as running.
    public static let staleAfter: TimeInterval = 300

    public enum Phase: String, Codable, CaseIterable, Sendable {
        case received, verified, closing, relaunching, done, restored, refused
        /// Rolled back, but putting the old app back failed too.
        case failed

        public var isFinal: Bool { [.done, .restored, .refused, .failed].contains(self) }

        /// French label, used by the app and mirrored by `scripts/local_try.sh`.
        public var label: String {
            switch self {
            case .received: return "demande reçue"
            case .verified: return "vérifiée"
            case .closing: return "fermeture"
            case .relaunching: return "redémarrage"
            case .done: return "terminée"
            case .restored: return "ancienne version restaurée"
            case .refused: return "refusée"
            case .failed: return "échec, retour arrière impossible"
            }
        }
    }

    public struct Step: Codable, Equatable, Sendable {
        public var phase: Phase
        /// Wall clock, seconds since 1970: for display only.
        public var at: TimeInterval
        public init(phase: Phase, at: TimeInterval) { self.phase = phase; self.at = at }
    }

    public struct Entry: Codable, Equatable, Sendable {
        public var id: String
        public var commit: String?
        public var steps: [Step]
        public var reason: String?
        public init(id: String, commit: String? = nil, steps: [Step] = [], reason: String? = nil) {
            self.id = id; self.commit = commit; self.steps = steps; self.reason = reason
        }

        public var phase: Phase? { steps.last?.phase }
        public var startedAt: TimeInterval? { steps.first?.at }
        public var updatedAt: TimeInterval? { steps.last?.at }
        public var isFinal: Bool { phase?.isFinal == true }
        public var shortCommit: String? { commit.map { String($0.prefix(8)) } }

        /// Not final and no news for `staleAfter` (either clock direction): the hand-off stopped somewhere.
        public func isStale(now: TimeInterval) -> Bool {
            guard !isFinal, let updatedAt else { return false }
            return abs(now - updatedAt) > PersoUpdateHistory.staleAfter
        }

        /// Seconds from the request to its final phase; nil while running or when the clock jumped.
        public var duration: TimeInterval? {
            guard isFinal, let startedAt, let updatedAt else { return nil }
            let value = updatedAt - startedAt
            return (0...3600).contains(value) ? value : nil
        }
    }

    public let file: URL
    public init(root: URL) { file = root.appendingPathComponent("history.json") }
    public static var standard: PersoUpdateHistory { PersoUpdateHistory(root: PersoUpdateFiles.standard.root) }

    /// Newest first. An unreadable file reads as empty.
    public func entries() -> [Entry] {
        guard let data = try? Data(contentsOf: file),
              let list = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        return list.sorted { ($0.startedAt ?? 0) > ($1.startedAt ?? 0) }
    }

    /// Adds `phase` to request `id`. A final entry never changes again; a phase is recorded once.
    /// Never throws: a failed write only loses this status line.
    public func record(_ id: String, _ phase: Phase, commit: String? = nil, reason: String? = nil,
                       now: TimeInterval = Date().timeIntervalSince1970) {
        guard PersoUpdate.isValidRequestID(id) else { return }
        let root = file.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lock = open(root.appendingPathComponent("history.lock").path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        if lock >= 0 { flock(lock, LOCK_EX) }
        defer { if lock >= 0 { flock(lock, LOCK_UN); close(lock) } }
        var list = entries()
        var entry = list.first { $0.id == id } ?? Entry(id: id)
        list.removeAll { $0.id == id }
        Self.apply(&entry, phase, commit: commit, reason: reason, now: now)
        list.insert(entry, at: 0)
        list.sort { ($0.startedAt ?? 0) > ($1.startedAt ?? 0) }
        guard let data = try? JSONEncoder().encode(Array(list.prefix(Self.maximumEntries))) else { return }
        try? data.write(to: file, options: .atomic)
    }

    static func apply(_ entry: inout Entry, _ phase: Phase, commit: String?, reason: String?, now: TimeInterval) {
        guard !entry.isFinal, !entry.steps.contains(where: { $0.phase == phase }) else { return }
        entry.steps.append(Step(phase: phase, at: now))
        if entry.commit == nil, let commit, !commit.isEmpty { entry.commit = commit }
        if let reason, !reason.isEmpty { entry.reason = String(reason.prefix(300)) }
    }
}
