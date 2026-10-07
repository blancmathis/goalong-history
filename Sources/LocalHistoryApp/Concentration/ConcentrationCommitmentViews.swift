#if os(macOS)
import SwiftUI

// MARK: - Words

/// French wording of engagements, shared by the page, the editor, the evening review and the panel.
enum FocusCommitmentFormat {
    private static let locale = Locale(identifier: "fr_FR")

    static func amount(_ value: Double, kind: FocusCommitment.Kind) -> String {
        let whole = Int(value.rounded(.down))
        return kind == .work || kind == .task ? BlockingFormat.duration(minutes: whole) : "\(whole)"
    }

    /// « Travailler 7 h », « 3 h sur Goalong », « 4 séances », « Finir 3 tâches du plan ».
    static func sentence(kind: FocusCommitment.Kind, target: Int, task: String?) -> String {
        let task = task?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch kind {
        case .work: return "Travailler \(BlockingFormat.duration(minutes: target))"
        case .task: return "\(BlockingFormat.duration(minutes: target)) sur \(task.isEmpty ? "une tâche" : task)"
        case .sessions: return target == 1 ? "1 séance" : "\(target) séances"
        case .plan: return target == 1 ? "Finir 1 tâche du plan" : "Finir \(target) tâches du plan"
        }
    }

    static func sentence(_ value: FocusCommitment) -> String { sentence(kind: value.kind, target: value.target, task: value.task) }

    /// « 4 h 10 sur 7 h », « 2 sur 4 ». Without a work definition the measure is active time, and says so.
    static func progress(_ value: FocusCommitment, _ progress: FocusCommitmentProgress) -> String {
        let measured = amount(progress.measured, kind: value.kind), target = amount(Double(value.target), kind: value.kind)
        return value.kind == .work && progress.usesActiveTime ? "\(measured) d’activité sur \(target)" : "\(measured) sur \(target)"
    }

    /// « Hier : 6 h 10 de travail sur 7 h. »
    static func result(_ value: FocusCommitment, _ progress: FocusCommitmentProgress, now: Date) -> String {
        let label = period(value.period, now: now)
        let measured = amount(progress.measured, kind: value.kind), target = amount(Double(value.target), kind: value.kind)
        let count = Int(progress.measured.rounded(.down)), plural = count > 1 ? "s" : ""
        switch value.kind {
        case .work: return "\(label) : \(measured) \(progress.usesActiveTime ? "d’activité" : "de travail") sur \(target)."
        case .task: return "\(label) : \(measured) sur \(value.task ?? "la tâche"), objectif \(target)."
        case .sessions: return "\(label) : \(count) séance\(plural) sur \(target)."
        case .plan: return "\(label) : \(count) tâche\(plural) du plan finie\(plural) sur \(target)."
        }
    }

    /// « Aujourd’hui », « Hier », « Demain », « Cette semaine », « La semaine dernière »…
    static func period(_ value: FocusCommitmentPeriod, now: Date, calendar: Calendar = .current) -> String {
        func shifted(_ days: Int) -> Date { calendar.date(byAdding: .day, value: days, to: now) ?? now }
        switch value.kind {
        case .day:
            switch value.key {
            case FocusCalendar.dayKey(now, calendar: calendar): return "Aujourd’hui"
            case FocusCalendar.dayKey(shifted(-1), calendar: calendar): return "Hier"
            case FocusCalendar.dayKey(shifted(1), calendar: calendar): return "Demain"
            default:
                guard let start = value.interval(calendar: calendar)?.start else { return value.key }
                let day = BlockingFormat.day(start)
                return day.prefix(1).uppercased() + day.dropFirst()
            }
        case .week:
            switch value.key {
            case FocusCalendar.weekKey(now, calendar: calendar): return "Cette semaine"
            case FocusCalendar.weekKey(shifted(-7), calendar: calendar): return "La semaine dernière"
            case FocusCalendar.weekKey(shifted(7), calendar: calendar): return "La semaine prochaine"
            default:
                guard let start = value.interval(calendar: calendar)?.start else { return value.key }
                return "Semaine du \(format(start, "d MMMM"))"
            }
        }
    }

    /// « Réseaux sociaux et Vidéo ».
    static func lists(_ ids: [UUID], in lists: [BlockList]) -> String {
        let names = ids.compactMap { id in lists.first { $0.id == id }?.name }
        guard let last = names.last else { return "listes supprimées" }
        return names.count == 1 ? last : names.dropLast().joined(separator: ", ") + " et " + last
    }

    /// « 18:00 », or « minuit » for the end of a day.
    static func time(_ date: Date, calendar: Calendar = .current) -> String {
        date == calendar.startOfDay(for: date) ? "minuit" : BlockingFormat.time(date)
    }

    /// « 09:30 » → « 9:30 », like every other time in the app.
    static func clock(_ value: String) -> String { value.hasPrefix("0") ? String(value.dropFirst()) : value }

    /// « jusqu’à 12:00 », « toute la journée ».
    static func until(_ value: String) -> String { value == "23:59" ? "toute la journée" : "jusqu’à \(clock(value))" }

    /// The day a missed period settles and its stake runs: « demain », « lundi ».
    static func stakeDay(_ value: FocusCommitmentPeriod, now: Date, calendar: Calendar = .current) -> String {
        guard let end = value.interval(calendar: calendar)?.end else { return "le lendemain" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: end)).day ?? 0
        if days == 1 { return "demain" }
        return format(end, days < 7 ? "EEEE" : "EEEE d MMMM")
    }

    /// Before the result: « Si non tenu : blocage de Réseaux sociaux demain jusqu’à 12:00. »
    static func stake(_ stake: FocusStake, period: FocusCommitmentPeriod, lists all: [BlockList], now: Date) -> String {
        "Si non tenu : blocage de \(lists(stake.listIds, in: all)) \(stakeDay(period, now: now)) \(until(stake.until))."
    }

    /// After the result: the outcome, then what became of the stake.
    static func outcome(_ card: FocusCommitmentCard, lists all: [BlockList], now: Date) -> String {
        guard let result = card.commitment.result else { return "" }
        var parts: [String] = []
        if result.declared { parts.append("Tenu, déclaré hors mesure.") }
        else if result.outcome == .held { parts.append(card.series > 1 ? "Tenu. \(card.series) de suite." : "Tenu.") }
        else if result.jokerAt != nil { parts.append("Joker utilisé : la série continue.") }
        else { parts.append("Non tenu.") }
        let names = card.commitment.stake.map { lists($0.listIds, in: all) } ?? ""
        let until = card.commitment.stake.map { clock($0.until) } ?? ""
        switch result.stake.state {
        case .applied:
            if let end = card.exitUntil, end > now { parts.append("Blocage de \(names) jusqu’à \(time(end)).") }
        case .cancelled: parts.append("Blocage levé.")
        case .skipped:
            switch result.stake.reason {
            case .late?: parts.append("Enjeu non appliqué : Goalong n’était pas ouvert avant \(until).")
            case .noList?: parts.append("Enjeu non appliqué : ses listes n’existent plus.")
            case .blockingOff?: parts.append("Enjeu non appliqué : Blocage est désactivé.")
            case nil: break
            }
        case .none: break
        }
        return parts.joined(separator: " ")
    }

    /// « jusqu’à 9:20 », « jusqu’à minuit », « jusqu’à lundi à 0:00 ».
    static func editUntil(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "jusqu’à \(BlockingFormat.time(date))" }
        if date == calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) { return "jusqu’à minuit" }
        return "jusqu’à \(BlockingFormat.moment(date, now: now, calendar: calendar))"
    }

    /// « Pris à 8:50 », « Pris dimanche à 21:40 ».
    static func taken(_ date: Date, now: Date) -> String {
        Calendar.current.isDate(date, inSameDayAs: now) ? "Pris à \(BlockingFormat.time(date))" : "Pris \(BlockingFormat.moment(date, now: now))"
    }

    static func error(_ error: Error) -> String {
        switch error as? FocusFailure {
        case .locked?: return "L’engagement peut seulement devenir plus exigeant."
        case .invalidArgument?: return "Vérifiez l’objectif : sa période, sa valeur et le nom de la tâche."
        case .notFound?: return "Une liste de l’enjeu n’existe plus."
        case .moduleDisabled?: return "Activez Blocage dans Réglages › Modules pour ajouter un enjeu."
        default: return FocusUIError.message(error)
        }
    }

    static func exitError(_ error: Error) -> String {
        switch error as? FocusFailure {
        case .locked?: return "Plus de joker ce mois-ci, ou le délai est passé."
        case .invalidArgument?: return "La déclaration demande du temps que Goalong n’a pas vu."
        default: return FocusUIError.message(error)
        }
    }

    private static func format(_ date: Date, _ pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}

// MARK: - Gauge

/// Measured against target, in the colour of work. Counts up to twelve are segments; a dotted
/// line is an engagement not taken (in « Le fil », dotted means unknown).
struct FocusCommitmentGauge: View {
    var measured: Double = 0
    var target = 0
    var kind: FocusCommitment.Kind = .work
    var empty = false

    var body: some View {
        Group {
            if empty {
                GeometryReader { proxy in
                    Path { path in
                        path.move(to: CGPoint(x: 1, y: 3)); path.addLine(to: CGPoint(x: proxy.size.width - 1, y: 3))
                    }
                    .stroke(LHTheme.tertiaryText.opacity(0.7), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [0.5, 6]))
                }
            } else if kind == .sessions || kind == .plan, (1...12).contains(target) {
                HStack(spacing: 3) {
                    ForEach(0..<target, id: \.self) { index in
                        Capsule().fill(Double(index) < measured.rounded(.down) ? LHTheme.workData : LHTheme.insetBackground)
                    }
                }
            } else {
                GeometryReader { proxy in
                    let fraction = min(1, max(0, measured / Double(max(1, target))))
                    ZStack(alignment: .leading) {
                        Capsule().fill(LHTheme.insetBackground)
                        if fraction > 0 { Capsule().fill(LHTheme.workData).frame(width: max(6, proxy.size.width * fraction)) }
                    }
                }
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}

// MARK: - Page

struct FocusCommitmentEditRequest: Identifiable {
    let id = UUID()
    /// Creation offers these periods; an edit has only its own.
    var periods: [FocusCommitmentPeriod]
    var existing: FocusCommitment?
}

/// « Engagements »: results whose exits are still open, then today and this week side by side.
@MainActor struct FocusCommitmentsSection: View {
    @ObservedObject var controller: ConcentrationController
    let now: Date
    var onEdit: (FocusCommitmentEditRequest) -> Void

    private var calendar: Calendar { .current }
    private func day(_ offset: Int) -> FocusCommitmentPeriod {
        .init(kind: .day, key: FocusCalendar.dayKey(calendar.date(byAdding: .day, value: offset, to: now) ?? now, calendar: calendar))
    }
    private func week(_ offset: Int) -> FocusCommitmentPeriod {
        .init(kind: .week, key: FocusCalendar.weekKey(calendar.date(byAdding: .day, value: 7 * offset, to: now) ?? now, calendar: calendar))
    }
    private func card(_ period: FocusCommitmentPeriod) -> FocusCommitmentCard? {
        controller.commitmentCards.first { $0.commitment.period == period }
    }
    private var openResults: [FocusCommitmentCard] {
        controller.commitmentCards.filter { card in
            card.commitment.result != nil && (card.canUseJoker || card.canDeclare) && (card.exitUntil.map { $0 > now } ?? false)
        }
    }

    var body: some View {
        GoalongSection(title: "Engagements") {
            VStack(alignment: .leading, spacing: 12) {
                if !openResults.isEmpty {
                    LHCard(padding: 0) {
                        VStack(spacing: 0) {
                            ForEach(openResults) { card in
                                FocusCommitmentResultView(card: card, lists: controller.blockLists, now: now, compact: true,
                                                          onJoker: { exit { try controller.useCommitmentJoker(period: card.commitment.period) } },
                                                          onDeclare: { exit { try controller.declareCommitmentHeld(period: card.commitment.period) } })
                                    .padding(.horizontal, LHTheme.cardInset).padding(.vertical, 14)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                if card.id != openResults.last?.id { GoalongRowDivider(inset: LHTheme.cardInset + 40) }
                            }
                        }
                    }
                }
                if controller.commitmentCards.isEmpty {
                    // Nothing taken yet: one sentence and one button, not two empty cards.
                    HStack(spacing: 12) {
                        Text("Un objectif que Goalong mesure, avec un enjeu si vous voulez.")
                            .font(.system(size: 13)).foregroundStyle(LHTheme.secondaryText)
                        Spacer(minLength: 8)
                        Button("Prendre un engagement") { onEdit(.init(periods: [day(0), day(1), week(0), week(1)])) }
                            .accessibilityIdentifier("concentration-commitment-create")
                    }
                } else {
                HStack(alignment: .top, spacing: 16) {
                    periodCard("Aujourd’hui", current: day(0), next: day(1), nextTitle: "Prévoir demain",
                               series: controller.commitmentSeries.day, jokers: controller.commitmentJokersLeft.day)
                    periodCard("Cette semaine", current: week(0), next: week(1), nextTitle: "Prévoir la semaine prochaine",
                               series: controller.commitmentSeries.week, jokers: controller.commitmentJokersLeft.week)
                }
                .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityIdentifier("concentration-commitments")
    }

    private func periodCard(_ title: String, current: FocusCommitmentPeriod, next: FocusCommitmentPeriod, nextTitle: String,
                            series: Int, jokers: Int) -> some View {
        let currentCard = card(current), nextCard = card(next)
        let free = [current, next].filter { card($0) == nil }
        return FocusCommitmentCardView(title: title, card: currentCard, next: nextCard, nextTitle: nextTitle,
                                       series: series, jokersLeft: jokers, lists: controller.blockLists, now: now,
                                       onCreate: { first in onEdit(.init(periods: [first] + free.filter { $0 != first })) },
                                       onEdit: { value in onEdit(.init(periods: [value.period], existing: value)) },
                                       currentPeriod: current, nextPeriod: next)
    }

    private func exit(_ action: () throws -> Void) {
        do { try action() } catch { controller.error = FocusCommitmentFormat.exitError(error) }
    }
}

/// One period on the page: the sentence, measured against target, the stake, then what can still change.
@MainActor struct FocusCommitmentCardView: View {
    let title: String
    let card: FocusCommitmentCard?
    let next: FocusCommitmentCard?
    let nextTitle: String
    let series: Int
    let jokersLeft: Int
    let lists: [BlockList]
    let now: Date
    var onCreate: (FocusCommitmentPeriod) -> Void
    var onEdit: (FocusCommitment) -> Void
    let currentPeriod: FocusCommitmentPeriod
    let nextPeriod: FocusCommitmentPeriod

    var body: some View {
        LHCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(LHTheme.secondaryText)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 8)
                    // The series lives here only, never as a title.
                    if card != nil || series > 0 {
                        Text(facts).font(.system(size: 12).monospacedDigit()).foregroundStyle(LHTheme.tertiaryText)
                    }
                }
                if let card { filled(card) } else { empty }
                Spacer(minLength: 0)
                footer
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .accessibilityElement(children: .contain)
    }

    private var facts: String {
        let jokers = jokersLeft == 0 ? "plus de joker ce mois-ci" : jokersLeft == 1 ? "1 joker ce mois-ci" : "\(jokersLeft) jokers ce mois-ci"
        return series > 0 ? "Série \(series) · \(jokers)" : jokers.prefix(1).uppercased() + jokers.dropFirst()
    }

    @ViewBuilder private func filled(_ card: FocusCommitmentCard) -> some View {
        let value = card.commitment
        VStack(alignment: .leading, spacing: 8) {
            Text(FocusCommitmentFormat.sentence(value)).font(.system(size: 17, weight: .semibold)).tracking(-0.2)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            FocusCommitmentGauge(measured: card.progress.measured, target: value.target, kind: value.kind)
            HStack(spacing: 6) {
                Text(FocusCommitmentFormat.progress(value, card.progress))
                    .font(.system(size: 12).monospacedDigit()).foregroundStyle(LHTheme.secondaryText)
                if card.progress.measured >= Double(value.target) {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(LHTheme.accent)
                        .accessibilityLabel("Objectif atteint")
                }
            }
            .help(card.progress.usesActiveTime ? "Sans définition du travail, Goalong compte le temps actif." : "")
        }
        if let limit = card.limitHours {
            Text("Au-dessus de votre limite de \(limit) h par \(value.period.kind == .day ? "jour" : "semaine").")
                .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
        }
        if let stake = value.stake {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "lock").font(.system(size: 11, weight: .medium)).accessibilityHidden(true)
                Text(FocusCommitmentFormat.stake(stake, period: value.period, lists: lists, now: now))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
        }
        HStack(spacing: 8) {
            Text(card.editMode == "free" ? "Modifiable \(FocusCommitmentFormat.editUntil(card.editUntil, now: now))"
                                         : "\(FocusCommitmentFormat.taken(value.createdAt, now: now)) · seulement plus exigeant")
                .font(.system(size: 12)).foregroundStyle(LHTheme.tertiaryText).lineLimit(1)
            Spacer(minLength: 8)
            editButton(card)
        }
    }

    @ViewBuilder private var empty: some View {
        VStack(alignment: .leading, spacing: 10) {
            FocusCommitmentGauge(empty: true)
            Text("Un objectif que Goalong mesure, avec un enjeu si vous voulez.")
                .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText).fixedSize(horizontal: false, vertical: true)
        }
        Button("Prendre un engagement") { onCreate(currentPeriod) }
            .buttonStyle(LHQuietButtonStyle())
            .accessibilityIdentifier("concentration-commitment-create")
    }

    /// The next period: its engagement in one line, or a way to plan it once this one is taken.
    @ViewBuilder private var footer: some View {
        if let next {
            VStack(alignment: .leading, spacing: 10) {
                GoalongRowDivider(inset: 0)
                HStack(spacing: 6) {
                    Text("\(FocusCommitmentFormat.period(next.commitment.period, now: now)) : \(FocusCommitmentFormat.sentence(next.commitment))")
                        .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText).lineLimit(1)
                    if next.commitment.stake != nil {
                        Image(systemName: "lock").font(.system(size: 10, weight: .medium)).foregroundStyle(LHTheme.tertiaryText)
                            .accessibilityLabel("avec enjeu")
                    }
                    Spacer(minLength: 8)
                    editButton(next)
                }
            }
        } else if card != nil {
            Button { onCreate(nextPeriod) } label: {
                Label(nextTitle, systemImage: "plus").font(.system(size: 12, weight: .medium)).foregroundStyle(LHTheme.secondaryText)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder private func editButton(_ card: FocusCommitmentCard) -> some View {
        if card.editMode != "locked" {
            Button(card.editMode == "free" ? "Modifier" : "Relever") { onEdit(card.commitment) }
                .buttonStyle(LHQuietButtonStyle())
                .help(card.editMode == "free" ? "" : "L’engagement peut seulement devenir plus exigeant.")
        }
    }
}

/// A settled period: the measured fact, the outcome and the stake, then the exits still open.
@MainActor struct FocusCommitmentResultView: View {
    let card: FocusCommitmentCard
    let lists: [BlockList]
    let now: Date
    /// On the page: one row, exits on the right, no gauge (the panel keeps it).
    var compact = false
    var onJoker: () -> Void
    var onDeclare: () -> Void

    private var open: Bool { (card.canUseJoker || card.canDeclare) && (card.exitUntil.map { $0 > now } ?? false) }

    var body: some View {
        if compact { row } else { full }
    }

    private var held: Bool { card.commitment.result?.outcome == .held }

    private var mark: some View {
        Image(systemName: held ? "checkmark.circle" : "xmark.circle").font(.system(size: compact ? 16 : 18, weight: .medium))
            .foregroundStyle(held ? LHTheme.accent : LHTheme.secondaryText).frame(width: 26).accessibilityHidden(true)
    }

    private var row: some View {
        HStack(alignment: .top, spacing: 14) {
            mark
            VStack(alignment: .leading, spacing: 3) {
                Text(FocusCommitmentFormat.result(card.commitment, card.progress, now: now)).font(.system(size: 13, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(open ? "\(FocusCommitmentFormat.outcome(card, lists: lists, now: now)) \(exitFacts)." : FocusCommitmentFormat.outcome(card, lists: lists, now: now))
                    .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if open { exits }
        }
        .accessibilityElement(children: .contain)
    }

    private var exits: some View {
        HStack(spacing: 8) {
            if card.canDeclare {
                Button("J’ai tenu, hors mesure", action: onDeclare)
                    .help("Lève l’enjeu sans joker. Seulement si vous avez vraiment tenu.")
                    .accessibilityIdentifier("concentration-commitment-declare")
            }
            if card.canUseJoker {
                Button("Utiliser un joker", action: onJoker)
                    .accessibilityIdentifier("concentration-commitment-joker")
            }
        }
        .fixedSize()
    }

    private var full: some View {
        let value = card.commitment
        return HStack(alignment: .top, spacing: 14) {
            mark
            VStack(alignment: .leading, spacing: 8) {
                Text(FocusCommitmentFormat.result(value, card.progress, now: now)).font(.system(size: 14, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                FocusCommitmentGauge(measured: card.progress.measured, target: value.target, kind: value.kind)
                Text(FocusCommitmentFormat.outcome(card, lists: lists, now: now))
                    .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText).fixedSize(horizontal: false, vertical: true)
                if open {
                    Text(exitFacts).font(.system(size: 12)).foregroundStyle(LHTheme.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    exits.padding(.top, 2)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// « 1 h non vue par Goalong · 2 jokers ce mois-ci · jusqu’à 18:00 ».
    private var exitFacts: String {
        var parts: [String] = []
        let value = card.commitment
        if card.canDeclare, value.kind == .work || value.kind == .task, card.progress.unmeasuredMinutes >= 1 {
            parts.append("\(BlockingFormat.duration(minutes: Int(card.progress.unmeasuredMinutes.rounded(.down)))) non vue par Goalong")
        }
        parts.append(card.jokersLeft == 0 ? "plus de joker ce mois-ci" : card.jokersLeft == 1 ? "1 joker ce mois-ci" : "\(card.jokersLeft) jokers ce mois-ci")
        if let end = card.exitUntil { parts.append("possible jusqu’à \(FocusCommitmentFormat.time(end))") }
        let line = parts.joined(separator: " · ")
        return compact ? line : line.prefix(1).uppercased() + line.dropFirst()
    }
}

// MARK: - Panel

/// At settle time, once: each result of the refresh, then « Fermer ». A day and a week share one panel.
struct FocusCommitmentPanelView: View {
    let cards: [FocusCommitmentCard]
    let lists: [BlockList]
    let now: Date
    var onJoker: (FocusCommitmentPeriod) -> Void
    var onDeclare: (FocusCommitmentPeriod) -> Void
    var onClose: () -> Void

    var body: some View {
        FocusPanelSurface {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(cards) { card in
                    FocusCommitmentResultView(card: card, lists: lists, now: now,
                                              onJoker: { onJoker(card.commitment.period) },
                                              onDeclare: { onDeclare(card.commitment.period) })
                    if card.id != cards.last?.id { GoalongRowDivider(inset: 40) }
                }
                HStack {
                    Spacer()
                    Button("Fermer", action: onClose)
                }
            }
        }
        .accessibilityIdentifier("concentration-commitment-panel")
    }
}

// MARK: - Editor

/// What the editor and the evening review edit before saving.
struct FocusCommitmentDraft: Equatable {
    var period: FocusCommitmentPeriod
    var kind: FocusCommitment.Kind = .work
    var target = 360
    var task = ""
    var stakeLists: [UUID] = []
    var until = "12:00"

    init(period: FocusCommitmentPeriod, existing: FocusCommitment? = nil) {
        self.period = existing?.period ?? period
        if let existing {
            kind = existing.kind; target = existing.target; task = existing.task ?? ""
            stakeLists = existing.stake?.listIds ?? []; until = existing.stake?.until ?? "12:00"
        } else {
            target = Self.defaultTarget(.work, period.kind)
        }
    }

    static func defaultTarget(_ kind: FocusCommitment.Kind, _ period: FocusCommitmentPeriod.Kind) -> Int {
        switch (kind, period) {
        case (.work, .day): return 360
        case (.work, .week): return 1_800
        case (.task, .day): return 120
        case (.task, .week): return 600
        case (.sessions, .day): return 3
        case (.sessions, .week): return 12
        case (.plan, .day): return 3
        case (.plan, .week): return 10
        }
    }

    /// Same bounds as `FocusCommitment.validTarget`.
    static func range(_ kind: FocusCommitment.Kind, _ period: FocusCommitmentPeriod.Kind) -> ClosedRange<Int> {
        switch (kind, period) {
        case (.work, .day): return 30...960
        case (.work, .week): return 60...4_800
        case (.task, .day): return 15...960
        case (.task, .week): return 30...4_800
        case (.sessions, .day): return 1...12
        case (.sessions, .week): return 1...60
        case (.plan, .day): return 1...10
        case (.plan, .week): return 1...70
        }
    }

    /// Durations move by 15 minutes a day, by the hour a week; still multiples of 15.
    static func step(_ kind: FocusCommitment.Kind, _ period: FocusCommitmentPeriod.Kind) -> Int {
        kind == .work || kind == .task ? (period == .day ? 15 : 60) : 1
    }

    var stake: FocusStake? { stakeLists.isEmpty ? nil : FocusStake(listIds: stakeLists, until: until) }
    var trimmedTask: String? { kind == .task ? task.trimmingCharacters(in: .whitespacesAndNewlines) : nil }
    var complete: Bool { kind != .task || trimmedTask?.isEmpty == false }

    /// The edited value as the commit rule sees it.
    func applied(to old: FocusCommitment) -> FocusCommitment {
        var value = old
        value.kind = kind; value.target = target; value.task = trimmedTask; value.stake = stake
        return value
    }
}

/// The fields of an engagement: the sentence it makes first, then each choice on its own line.
@MainActor struct FocusCommitmentForm: View {
    @Binding var draft: FocusCommitmentDraft
    var periods: [FocusCommitmentPeriod] = []
    var old: FocusCommitment?
    var harderOnly = false
    let lists: [BlockList]
    let limits: FocusLimits
    let now: Date
    /// Inside the evening review the sentence stays below the sheet title.
    var compact = false

    private static let untilChoices = ["10:00", "12:00", "18:00", "23:59"]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(FocusCommitmentFormat.sentence(kind: draft.kind, target: draft.target, task: draft.task))
                .font(.system(size: compact ? 15 : 22, weight: .semibold)).tracking(compact ? -0.2 : -0.4)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            if periods.count > 1 {
                row("Quand") {
                    GoalongSegmentedControl("Période", selection: $draft.period, options: periods) {
                        FocusCommitmentFormat.period($0, now: now)
                    }
                    .fixedSize()
                }
            }
            row("Objectif") {
                GoalongSegmentedControl("Objectif", selection: kind, options: [.work, .task, .sessions, .plan]) {
                    switch $0 {
                    case .work: return "Travail"
                    case .task: return "Une tâche"
                    case .sessions: return "Séances"
                    case .plan: return "Plan"
                    }
                }
                .fixedSize()
                .disabled(harderOnly)
            }
            if draft.kind == .task {
                row("Tâche") {
                    TextField("Son nom dans « Mon travail »", text: $draft.task)
                        .textFieldStyle(GoalongFieldStyle()).frame(maxWidth: 300)
                        .disabled(harderOnly)
                        .accessibilityIdentifier("concentration-commitment-task")
                }
            }
            row("Au moins") {
                VStack(alignment: .leading, spacing: 4) {
                    Stepper(value: $draft.target, in: targetRange, step: FocusCommitmentDraft.step(draft.kind, draft.period.kind)) {
                        Text(amount).monospacedDigit()
                    }
                    .fixedSize().frame(height: 32)
                    if let limitLine {
                        Text(limitLine).font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                    }
                }
            }
            if !lists.isEmpty || BlockingRuntime.shared.controller != nil { stakeRow }
        }
    }

    private var kind: Binding<FocusCommitment.Kind> {
        Binding(get: { draft.kind }, set: { value in
            guard value != draft.kind else { return }
            draft.kind = value; draft.target = FocusCommitmentDraft.defaultTarget(value, draft.period.kind)
        })
    }

    private var targetRange: ClosedRange<Int> {
        let range = FocusCommitmentDraft.range(draft.kind, draft.period.kind)
        guard harderOnly, let old else { return range }
        return min(max(old.target, range.lowerBound), range.upperBound)...range.upperBound
    }

    private var amount: String {
        let value = FocusCommitmentFormat.amount(Double(draft.target), kind: draft.kind), plural = draft.target > 1 ? "s" : ""
        switch draft.kind {
        case .work, .task: return value
        case .sessions: return "\(value) séance\(plural)"
        case .plan: return "\(value) tâche\(plural)"
        }
    }

    private var limitLine: String? {
        let limit = draft.period.kind == .day ? limits.dailyHours : limits.weeklyHours
        guard let limit, draft.kind == .work || draft.kind == .task, draft.target > limit * 60 else { return nil }
        return "Au-dessus de votre limite de \(limit) h par \(draft.period.kind == .day ? "jour" : "semaine")."
    }

    private var stakeRow: some View {
        row("Enjeu") {
            VStack(alignment: .leading, spacing: 10) {
                BlockingFlow(spacing: 8) {
                    ForEach(lists) { list in
                        let kept = harderOnly && old?.stake?.listIds.contains(list.id) == true
                        BlockingListChip(list: list, selected: draft.stakeLists.contains(list.id)) { toggle(list.id) }
                            .disabled(kept)
                            .help(kept ? "Déjà dans l’enjeu : il ne peut pas être réduit." : "")
                    }
                    BlockingNewListChip { toggle($0) }
                }
                if let stake = draft.stake {
                    HStack(spacing: 10) {
                        Text("jusqu’à").foregroundStyle(LHTheme.secondaryText)
                        GoalongSegmentedControl("Jusqu’à", selection: $draft.until, options: untilOptions) {
                            $0 == "23:59" ? "Toute la journée" : FocusCommitmentFormat.clock($0)
                        }
                        .fixedSize()
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "lock").font(.system(size: 11, weight: .medium)).accessibilityHidden(true)
                        Text(FocusCommitmentFormat.stake(stake, period: draft.period, lists: lists, now: now))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                } else {
                    Text("Facultatif. Une liste de Blocage, appliquée seulement si l’engagement n’est pas tenu.")
                        .font(.system(size: 12)).foregroundStyle(LHTheme.tertiaryText).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var untilOptions: [String] {
        var values = Self.untilChoices
        if !values.contains(draft.until) { values.append(draft.until); values.sort() }
        guard harderOnly, let minimum = old?.stake?.minute else { return values }
        return values.filter { (FocusStake(listIds: [], until: $0).minute ?? 0) >= minimum }
    }

    private func toggle(_ id: UUID) {
        if let index = draft.stakeLists.firstIndex(of: id) { draft.stakeLists.remove(at: index) } else { draft.stakeLists.append(id) }
    }

    /// The label sits on the centre line of the first row of controls (32 points high).
    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Text(label).font(.system(size: 13, weight: .medium)).foregroundStyle(LHTheme.secondaryText)
                .frame(width: 72, height: 32, alignment: .leading)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Take or change an engagement. After its window, only harder: the controls that would ease it are off.
@MainActor struct FocusCommitmentEditor: View {
    @ObservedObject var controller: ConcentrationController
    let request: FocusCommitmentEditRequest
    let now: Date
    var onClose: () -> Void
    @State private var draft: FocusCommitmentDraft
    @State private var error: String?

    init(controller: ConcentrationController, request: FocusCommitmentEditRequest, now: Date,
         draft: FocusCommitmentDraft? = nil, onClose: @escaping () -> Void) {
        self.controller = controller
        self.request = request
        self.now = now
        self.onClose = onClose
        let period = request.periods.first ?? .init(kind: .day, key: FocusCalendar.dayKey(now))
        _draft = State(initialValue: draft ?? FocusCommitmentDraft(period: period, existing: request.existing))
    }

    private var harderOnly: Bool {
        guard let old = request.existing else { return false }
        return controller.commitCheck(old, replacing: old) != .free
    }

    private var lockedReason: String? {
        guard let old = request.existing, case .locked(let reason) = controller.commitCheck(draft.applied(to: old), replacing: old) else { return nil }
        return reason
    }

    private var changed: Bool { request.existing.map { draft.applied(to: $0) != $0 } ?? true }

    private var ruleLine: String {
        if harderOnly { return "Engagé : l’objectif peut seulement monter, l’enjeu seulement s’étendre." }
        let created = request.existing?.createdAt ?? now
        let start = draft.period.interval()?.start ?? now
        return "Modifiable \(FocusCommitmentFormat.editUntil(max(created.addingTimeInterval(600), start), now: now)), puis seulement plus exigeant."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 4) {
                Text(draft.period.kind == .day ? "Engagement du jour" : "Engagement de la semaine")
                    .font(LHTheme.sheetTitleFont).tracking(-0.4)
                Text(ruleLine).font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            FocusCommitmentForm(draft: $draft, periods: request.existing == nil ? request.periods : [],
                                old: request.existing, harderOnly: harderOnly,
                                lists: controller.blockLists, limits: controller.settings.limits, now: now)
            if let message = error ?? (changed ? lockedReason : nil) {
                Text(message).font(.system(size: 12)).foregroundStyle(LHTheme.warning)
            }
            HStack(spacing: 8) {
                if let existing = request.existing, !harderOnly {
                    Button("Supprimer", role: .destructive) { delete(existing) }.buttonStyle(LHQuietButtonStyle())
                }
                Spacer()
                Button("Annuler", action: onClose).keyboardShortcut(.cancelAction)
                Button(request.existing == nil ? "M’engager" : "Enregistrer", action: save)
                    .buttonStyle(LHPrimaryButtonStyle())
                    .disabled(!draft.complete || !changed || lockedReason != nil)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("concentration-commitment-save")
            }
        }
        .padding(28).frame(width: 600)
        .background(LHTheme.pageBackground)
    }

    private func save() {
        do {
            try controller.setCommitment(period: draft.period, kind: draft.kind, target: draft.target,
                                         task: draft.trimmedTask, stake: draft.stake)
            onClose()
        } catch { self.error = FocusCommitmentFormat.error(error) }
    }

    private func delete(_ value: FocusCommitment) {
        do { try controller.deleteCommitment(period: value.period); onClose() } catch { self.error = FocusCommitmentFormat.error(error) }
    }
}

// MARK: - Evening review

/// In the evening review: today's engagement as facts only, then tomorrow's, optional.
@MainActor struct FocusReviewCommitmentPart: View {
    @ObservedObject var controller: ConcentrationController
    let day: String
    @Binding var commit: Bool
    @Binding var draft: FocusCommitmentDraft
    let now: Date

    var body: some View {
        let today = controller.commitmentCards.first { $0.commitment.period == .init(kind: .day, key: day) }
        let tomorrow = controller.commitmentCards.first { $0.commitment.period == draft.period }
        VStack(alignment: .leading, spacing: 12) {
            Text("Engagements").font(.system(size: 13, weight: .medium)).accessibilityAddTraits(.isHeader)
            if let today {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Aujourd’hui : \(FocusCommitmentFormat.sentence(today.commitment))").font(.system(size: 13))
                        Spacer(minLength: 12)
                        Text(FocusCommitmentFormat.progress(today.commitment, today.progress))
                            .font(.system(size: 12).monospacedDigit()).foregroundStyle(LHTheme.secondaryText)
                    }
                    FocusCommitmentGauge(measured: today.progress.measured, target: today.commitment.target, kind: today.commitment.kind)
                }
                .accessibilityElement(children: .combine)
            }
            if let tomorrow {
                Text("Demain : \(FocusCommitmentFormat.sentence(tomorrow.commitment))\(tomorrow.commitment.stake == nil ? "" : ", avec enjeu").")
                    .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
            } else {
                Toggle("Prendre un engagement pour demain", isOn: $commit).toggleStyle(.goalongCheckbox)
                    .accessibilityIdentifier("concentration-review-commit")
                if commit {
                    FocusCommitmentForm(draft: $draft, lists: controller.blockLists, limits: controller.settings.limits, now: now, compact: true)
                        .padding(.leading, 26)
                }
            }
        }
    }
}
#endif
