#if os(macOS)
import Foundation
import GoalongGuardCore
import SwiftUI

/// T-057 idées 5 et 6 (« simple et complet ») : one short line on the last `make perso` hand-off, with its phase
/// while it runs and the commit really relaunched once done; the bounded history opens on demand. Status only:
/// reads `PersoUpdate/history.json` (`PersoUpdateHistory`), never decides anything. Perso builds only.
enum PersoUpdateStatusText {
    /// The success path, for « étape n sur 5 ».
    static let successPath: [PersoUpdateHistory.Phase] = [.received, .verified, .closing, .relaunching, .done]

    static func line(_ entry: PersoUpdateHistory.Entry, runningCommit: String?, now: Date, calendar: Calendar = .current) -> String {
        let commit = entry.shortCommit.map { " \($0)" } ?? ""
        guard let phase = entry.phase, let updated = entry.updatedAt else { return "Mise à jour perso\(commit) : état inconnu." }
        let when = moment(Date(timeIntervalSince1970: updated), now: now, calendar: calendar)
        let reason = entry.reason.map { " : \($0)" } ?? ""
        switch phase {
        case .done:
            let took = entry.duration.map { " en \(seconds($0))" } ?? ""
            guard let short = entry.shortCommit else { return "Mise à jour perso terminée \(when)\(took)." }
            if let running = runningCommit, let full = entry.commit, running != full {
                return "Mise à jour perso terminée \(when) : \(short) installé, mais ce Goalong exécute \(String(running.prefix(8)))."
            }
            return "Mise à jour perso terminée \(when)\(took) : \(short) relancé et actif."
        case .restored: return "Mise à jour perso\(commit) annulée \(when), ancienne version restaurée\(reason)."
        case .failed: return "Mise à jour perso\(commit) en échec \(when), retour arrière impossible\(reason)."
        case .refused: return "Mise à jour perso\(commit) refusée \(when)\(reason)."
        case .received, .verified, .closing, .relaunching:
            if entry.isStale(now: now.timeIntervalSince1970) {
                return "Mise à jour perso\(commit) interrompue \(when), à l’étape « \(phase.label) »."
            }
            let step = (successPath.firstIndex(of: phase) ?? 0) + 1
            return "Mise à jour perso\(commit) en cours : \(phase.label)… (étape \(step) sur \(successPath.count))"
        }
    }

    /// History row: « 26 nov. 2026 à 14:05 · 1a2b3c4d · terminée ».
    static func title(_ entry: PersoUpdateHistory.Entry) -> String {
        let at = entry.startedAt.map { Date(timeIntervalSince1970: $0) }
        let parts = [at.map { "\(GoalongUIFormat.dayAbbreviated($0)) à \(GoalongUIFormat.time($0))" },
                     entry.shortCommit, entry.phase?.label]
        return parts.compactMap { $0 }.joined(separator: " · ")
    }

    /// The phases with their offset from the request: « demande reçue → vérifiée +3 s → … ».
    static func steps(_ entry: PersoUpdateHistory.Entry) -> String {
        guard let start = entry.startedAt else { return "" }
        return entry.steps.enumerated().map { index, step in
            let offset = step.at - start
            return index == 0 || !(0...3600).contains(offset) ? step.phase.label : "\(step.phase.label) +\(seconds(offset))"
        }.joined(separator: " → ")
    }

    static func seconds(_ value: TimeInterval) -> String {
        let total = Int(value.rounded())
        return total < 60 ? "\(total) s" : "\(total / 60) min \(String(format: "%02d", total % 60)) s"
    }

    static func moment(_ date: Date, now: Date, calendar: Calendar) -> String {
        calendar.isDate(date, inSameDayAs: now)
            ? "à \(GoalongUIFormat.time(date))"
            : "le \(GoalongUIFormat.dayAbbreviated(date)) à \(GoalongUIFormat.time(date))"
    }
}

@MainActor final class PersoUpdateStatusModel: ObservableObject {
    static let shared = PersoUpdateStatusModel(history: PersoUpdateHistory.standard)
    @Published private(set) var entries: [PersoUpdateHistory.Entry] = []
    private let history: PersoUpdateHistory

    init(history: PersoUpdateHistory) { self.history = history }

    func reload() {
        let fresh = history.entries()
        if fresh != entries { entries = fresh }
    }

    /// Reloads every 2 s while the last hand-off runs, so its phases show as they happen; idle otherwise.
    func follow() async {
        reload()
        while !Task.isCancelled, let last = entries.first, !last.isFinal, !last.isStale(now: GoalongToday.now.timeIntervalSince1970) {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            reload()
        }
    }
}

/// The one status line, under the build label of the update row.
@MainActor struct PersoUpdateStatusLine: View {
    @ObservedObject var model: PersoUpdateStatusModel
    let runningCommit: String?

    var body: some View {
        if let last = model.entries.first {
            Text(PersoUpdateStatusText.line(last, runningCommit: runningCommit, now: GoalongToday.now))
                .font(.system(size: 12)).foregroundStyle(tint(last))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("settings-perso-update-status")
        }
    }

    private func tint(_ entry: PersoUpdateHistory.Entry) -> Color {
        switch entry.phase {
        case .restored?, .failed?, .refused?: return LHTheme.warning
        default: return entry.isStale(now: GoalongToday.now.timeIntervalSince1970) ? LHTheme.warning : LHTheme.secondaryText
        }
    }
}

/// The bounded history, folded by default.
@MainActor struct PersoUpdateHistoryList: View {
    @ObservedObject var model: PersoUpdateStatusModel
    @State private var expanded: Bool

    init(model: PersoUpdateStatusModel, initiallyExpanded: Bool = false) {
        self.model = model
        _expanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        if !model.entries.isEmpty {
            GoalongDisclosureGroup("Historique des mises à jour perso", isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(model.entries, id: \.id) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(PersoUpdateStatusText.title(entry)).font(.system(size: 12, weight: .medium))
                            Text(PersoUpdateStatusText.steps(entry)).font(.system(size: 11)).foregroundStyle(LHTheme.secondaryText)
                            if let reason = entry.reason {
                                Text(reason).font(.system(size: 11)).foregroundStyle(LHTheme.secondaryText)
                            }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    }
                }
                .padding(.top, 6)
            }
            .collapsedSummary(GoalongUIFormat.count(model.entries.count, "installation"))
            .accessibilityIdentifier("settings-perso-update-history")
        }
    }
}
#endif
