#if os(macOS)
import Foundation
import SwiftUI
import LocalHistoryCore

/// Words for what accompanied active minutes. They describe the Mac, never attention.
enum GoalongActivityTexture {
    static let order: [GoalongActivityBreakdown.Mode] = [.keyboard, .pointer, .reading, .call, .media, .display]

    static func title(_ mode: GoalongActivityBreakdown.Mode) -> String {
        switch mode {
        case .keyboard: return "Au clavier"
        case .pointer: return "Souris ou trackpad"
        case .reading: return "Sans saisie"
        case .call: return "En appel"
        case .media: return "Média en lecture"
        case .display: return "Écran gardé allumé"
        }
    }

    static func detail(_ mode: GoalongActivityBreakdown.Mode) -> String {
        switch mode {
        case .keyboard: return "Frappe ou raccourci dans la minute"
        case .pointer: return "Clic ou défilement, sans frappe"
        case .reading: return "Fenêtre visible, sans clavier ni souris"
        case .call: return "Une app d’appel au premier plan"
        case .media: return "Son ou vidéo lu au premier plan"
        case .display: return "L’app au premier plan garde l’écran allumé"
        }
    }

    /// « 2 h 10 au clavier »: the form used in captions and in the hour list.
    static func phrase(_ mode: GoalongActivityBreakdown.Mode, seconds: TimeInterval) -> String {
        let value = GoalongAnalyticsFormatting.duration(seconds)
        switch mode {
        case .keyboard: return "\(value) au clavier"
        case .pointer: return "\(value) à la souris"
        case .reading: return "\(value) sans saisie"
        case .call: return "\(value) en appel"
        case .media: return "\(value) de média"
        case .display: return "\(value) écran allumé"
        }
    }

    /// The two largest parts, for the caption in « Explorer ».
    static func caption(_ breakdown: GoalongActivityBreakdown) -> String {
        let parts = breakdown.secondsByMode.filter { $0.value >= 60 }
            .sorted { $0.value == $1.value ? $0.key.rawValue > $1.key.rawValue : $0.value > $1.value }.prefix(2)
        guard !parts.isEmpty else { return "Ce qui accompagnait chaque minute active" }
        return parts.map { phrase($0.key, seconds: $0.value) }.joined(separator: ", ")
    }
}

/// Hidden and unobserved time between the first and the last activity of a day. Time before
/// the first trace or after the last one is the day's edge, not a gap in it.
struct GoalongActivityGaps: Equatable {
    var unobserved: [GoalongCoverageReason: TimeInterval] = [:]
    var concealed: [GoalongCoverageReason: TimeInterval] = [:]
    var unobservedSeconds: TimeInterval { unobserved.values.reduce(0, +) }
    var concealedSeconds: TimeInterval { concealed.values.reduce(0, +) }

    init() {}

    init(day: GoalongLocalAnalytics.Day, from start: Date, to end: Date) {
        for segment in day.segments where segment.kind == .unobserved || segment.kind == .concealed {
            let overlap = min(segment.end, end).timeIntervalSince(max(segment.start, start))
            guard overlap > 0 else { continue }
            let reason = segment.coverageReason ?? .gap
            if segment.kind == .concealed { concealed[reason, default: 0] += overlap }
            else { unobserved[reason, default: 0] += overlap }
        }
    }

    mutating func add(_ other: GoalongActivityGaps) {
        unobserved.merge(other.unobserved, uniquingKeysWith: +)
        concealed.merge(other.concealed, uniquingKeysWith: +)
    }

    static func title(_ reason: GoalongCoverageReason) -> String {
        switch reason {
        case .beforeFirstObservation: return "Avant la première observation"
        case .afterLastObservation: return "Après la dernière observation"
        case .gap: return "Plus de 2 min entre deux observations"
        case .observationGap: return "Collecte interrompue"
        case .recorderStopped: return "Goalong arrêté"
        case .paused: return "Enregistrement en pause"
        case .sleep: return "Mac en veille"
        case .locked: return "Session verrouillée"
        case .accessibility: return "Accessibilité non autorisée"
        case .sessionUnavailable: return "Session inactive"
        case .noVisibleForeground: return "Aucune fenêtre au premier plan"
        case .privateBrowsing: return "Navigation privée"
        case .excludedApplication: return "App exclue"
        case .excludedDomain: return "Site exclu"
        case .secureInput: return "Saisie sécurisée"
        case .historyCleared: return "Historique effacé"
        case .notRecorded: return "Jour sans enregistrement"
        case .unreadable: return "Journal illisible"
        case .purgedWithoutSummary: return "Détail effacé, sans résumé"
        }
    }

    static func help(_ reason: GoalongCoverageReason) -> String? {
        switch reason {
        case .gap: return "Aucune trace pendant plus de deux minutes : Goalong ne prolonge pas l’activité au-delà."
        case .observationGap: return "Le Mac a signalé un trou dans la collecte, par exemple après un ralentissement."
        case .sessionUnavailable: return "Écran de connexion, économiseur d’écran ou autre utilisateur."
        case .secureInput: return "Un champ de mot de passe était actif : rien n’est lu pendant ce temps."
        case .excludedApplication, .excludedDomain: return "Exclu dans Réglages › Confidentialité."
        case .accessibility: return "Sans l’accès Accessibilité, Goalong ne voit pas la fenêtre au premier plan."
        default: return nil
        }
    }
}

/// « Écriture, lecture et appels »: the same active time, split by its strongest signal per minute.
struct GoalongActivityTextureSection: View {
    let period: GoalongLocalAnalytics.Period

    var body: some View {
        let breakdown = period.breakdown
        let total = breakdown.totalSeconds
        let rows = GoalongActivityTexture.order.map { ($0, breakdown.seconds($0)) }
            .filter { $0.1 >= 1 }.sorted { $0.1 > $1.1 }
        GoalongSection(title: "Écriture, lecture et appels",
                       subtitle: "Le même temps actif, réparti selon ce que le Mac observait à chaque minute") {
            VStack(alignment: .leading, spacing: 14) {
                if rows.isEmpty {
                    Text("Aucune minute active sur cette période.")
                        .font(.system(size: 13)).foregroundStyle(LHTheme.secondaryText)
                }
                ForEach(rows, id: \.0) { mode, seconds in
                    row(mode, seconds: seconds, total: total)
                }
                if period.days.count == 1, breakdown.hours.contains(where: { $0.totalSeconds >= 60 }) {
                    hours(breakdown)
                }
                Text("Chaque minute active prend le signal le plus fort : appel, média, écran gardé allumé, clavier, puis souris. Sans aucun de ces signaux, elle compte comme sans saisie. Ces signaux décrivent le Mac, pas votre attention.")
                    .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.accessibilityIdentifier("activity-texture")
    }

    private func row(_ mode: GoalongActivityBreakdown.Mode, seconds: TimeInterval, total: TimeInterval) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(GoalongActivityTexture.title(mode)).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(GoalongActivityTexture.detail(mode)).font(.system(size: 12))
                    .foregroundStyle(LHTheme.secondaryText).lineLimit(1)
                Spacer(minLength: 8)
                Text(GoalongAnalyticsFormatting.duration(seconds)).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                Text(percent(seconds / max(1, total))).font(.system(size: 12)).monospacedDigit()
                    .foregroundStyle(LHTheme.secondaryText).frame(width: 42, alignment: .trailing)
            }
            GoalongShareBar(share: seconds / max(1, total), color: LHTheme.secondaryText)
        }
        .accessibilityElement(children: .combine)
    }

    private func hours(_ breakdown: GoalongActivityBreakdown) -> some View {
        GoalongDisclosureGroup("Heure par heure") {
            VStack(spacing: 8) {
                ForEach(breakdown.hours.filter { $0.totalSeconds >= 60 }, id: \.start) { hour in
                    let main = GoalongActivityTexture.order.max { hour.seconds($0) < hour.seconds($1) }
                    HStack {
                        Text("\(GoalongSummaryFormat.time(hour.start))–\(GoalongSummaryFormat.time(hour.end))").monospacedDigit()
                        Spacer()
                        Text(GoalongAnalyticsFormatting.duration(hour.totalSeconds) + " actives")
                        if let main, hour.seconds(main) > 0 {
                            Text("dont " + GoalongActivityTexture.phrase(main, seconds: hour.seconds(main)))
                                .foregroundStyle(LHTheme.secondaryText)
                        }
                    }.font(.system(size: 12)).accessibilityElement(children: .combine)
                }
            }.padding(.top, 10)
        }.font(.system(size: 13))
    }

    private func percent(_ share: Double) -> String { "\(Int((max(0, min(1, share)) * 100).rounded()))\u{00A0}%" }
}

/// One source of the page, as « Couverture et sources » lists it: what it is, its state, one action.
struct GoalongSourceRow: Identifiable {
    enum State {
        case ready, partial, off, needsPermission, unavailable, noData, failed
        var word: String {
            switch self {
            case .ready: return "Prête"
            case .partial: return "Partielle"
            case .off: return "Désactivée"
            case .needsPermission: return "Autorisation requise"
            case .unavailable: return "Indisponible"
            case .noData: return "Aucune donnée"
            case .failed: return "Lecture impossible"
            }
        }
        var symbol: String {
            switch self {
            case .ready: return "checkmark"
            case .partial, .noData: return "circle.lefthalf.filled"
            case .off: return "circle"
            case .needsPermission, .failed: return "exclamationmark.triangle"
            case .unavailable: return "minus"
            }
        }
        var tint: Color {
            switch self {
            case .ready: return LHTheme.success
            case .needsPermission, .failed: return LHTheme.warning
            default: return LHTheme.secondaryText
            }
        }
    }

    let id: String
    let title: String
    let state: State
    let detail: String
    var actionTitle: String?
    var action: () -> Void = {}
}

/// « Couverture et sources »: why some hours have no observation, then the state of each source.
struct GoalongActivityCoverageSection: View {
    let period: GoalongLocalAnalytics.Period
    /// First and last activity of each day, as the summary measures them.
    let bounds: [Date: (start: Date, end: Date)]
    var sources: [GoalongSourceRow] = []
    var isPreview = false

    private var isDay: Bool { period.days.count == 1 }

    private var gaps: GoalongActivityGaps {
        var total = GoalongActivityGaps()
        for day in period.days {
            guard let range = bounds[day.date] else { continue }
            total.add(GoalongActivityGaps(day: day, from: range.start, to: range.end))
        }
        return total
    }

    var body: some View {
        let gaps = self.gaps
        VStack(alignment: .leading, spacing: LHTheme.sectionSpacing) {
            GoalongSection(title: "Couverture", subtitle: lead(gaps)) {
                VStack(alignment: .leading, spacing: 18) {
                    if !gaps.unobserved.isEmpty { reasons("Sans observation", gaps.unobserved) }
                    if !gaps.concealed.isEmpty { reasons("Masqué", gaps.concealed) }
                    ForEach(dayNotes, id: \.self) { note in GoalongNote(note) }
                    Text("Une heure sans observation n’est ni du travail ni du repos : Goalong ne la compte nulle part. Avant la première trace et après la dernière, rien n’est compté non plus.")
                        .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }.accessibilityIdentifier("activity-coverage")
            if !sources.isEmpty {
                GoalongSection(title: "Sources", subtitle: "Chaque source reste séparée : aucune ne s’additionne au temps actif.") {
                    VStack(spacing: 0) {
                        ForEach(Array(sources.enumerated()), id: \.element.id) { index, source in
                            if index > 0 { Divider().padding(.leading, 6) }
                            sourceRow(source)
                        }
                    }
                }.accessibilityIdentifier("activity-sources")
            }
        }
    }

    private func lead(_ gaps: GoalongActivityGaps) -> String {
        let observed = GoalongAnalyticsFormatting.duration(period.observedSeconds)
        guard period.observedSeconds > 0 else { return "Aucune observation sur cette période." }
        let missing = gaps.unobservedSeconds
        let days = period.daysWithObservations
        let total = isDay ? "\(observed) observées" : "\(observed) observées sur \(days) jour\(days > 1 ? "s" : "")"
        let span = isDay ? "entre la première et la dernière activité" : "entre la première et la dernière activité de chaque jour"
        return missing >= 60
            ? "\(total), dont \(GoalongAnalyticsFormatting.duration(missing)) sans observation \(span)."
            : "\(total), sans trou \(span)."
    }

    private func reasons(_ title: String, _ values: [GoalongCoverageReason: TimeInterval]) -> some View {
        let rows = values.filter { $0.value >= 1 }.sorted { $0.value == $1.value ? $0.key.rawValue < $1.key.rawValue : $0.value > $1.value }
        return VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 13, weight: .semibold))
            ForEach(rows, id: \.key) { reason, seconds in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(GoalongActivityGaps.title(reason)).font(.system(size: 13))
                    Spacer(minLength: 8)
                    Text(GoalongAnalyticsFormatting.duration(seconds)).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                }
                .help(GoalongActivityGaps.help(reason) ?? GoalongActivityGaps.title(reason))
                .accessibilityElement(children: .combine)
            }
        }
    }

    /// Days whose detail is gone, unreadable or never recorded: said once, in words.
    private var dayNotes: [String] {
        var notes: [String] = []
        let restored = period.days.filter { $0.observedSeconds > 0 && !$0.hasDetailedSource }.count
        if restored > 0 {
            notes.append(isDay
                ? "Détail effacé après la durée de conservation : cette journée est relue depuis son résumé (durées, apps et sites, sans titres de fenêtre)."
                : "\(restored) jour\(restored > 1 ? "s" : "") relu\(restored > 1 ? "s" : "") depuis leur résumé : le détail a été effacé après la durée de conservation.")
        }
        let purged = period.days.filter { $0.dayReason == .purgedWithoutSummary }.count
        if purged > 0 {
            notes.append("\(purged) jour\(purged > 1 ? "s" : "") effacé\(purged > 1 ? "s" : "") après la durée de conservation, avant que Goalong garde un résumé de chaque journée.")
        }
        let unrecorded = period.days.filter { $0.dayReason == .notRecorded }.count
        if !isDay, unrecorded > 0 {
            notes.append("\(unrecorded) jour\(unrecorded > 1 ? "s" : "") sans enregistrement : ils ne comptent pas comme des journées à zéro.")
        }
        return notes
    }

    private func sourceRow(_ source: GoalongSourceRow) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(source.title).font(.system(size: 13, weight: .medium))
                    StatusPill(title: source.state.word, symbol: source.state.symbol, tint: source.state.tint)
                }
                Text(source.detail).font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let title = source.actionTitle {
                Button(title, action: source.action).buttonStyle(LHQuietButtonStyle()).font(.system(size: 13))
                    .disabled(isPreview)
            }
        }
        .padding(.vertical, 10).padding(.horizontal, 6)
        .frame(minHeight: 44)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("activity-source-\(source.id)")
    }
}
#endif
