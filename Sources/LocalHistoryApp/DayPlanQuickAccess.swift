#if os(macOS)
import SwiftUI

/// T-057 M1 (idées 1 et 4): « Plan du jour » and « Bilan » one click away.
/// The popover row and Activity's button open the same view (`DayPlanSheet`), on today's real plan.

/// One slot of the day as the plan view shows it.
struct DayPlanSlotRow: Identifiable, Equatable {
    let id: UUID
    let time: String
    let title: String
    let state: FocusAgendaSlot.State
}

/// What the popover row needs: the next step and the day's progress.
struct DayPlanSummary: Equatable {
    var nextTime: String?
    var nextTitle: String?
    var done: Int
    var total: Int
    var progressText: String { total == 0 ? "Rien de prévu" : "\(done) fait\(done > 1 ? "s" : "") sur \(total)" }
}

/// Today's plan, read from the Concentration plan. Pure: no storage, no timer.
enum DayPlanDigest {
    /// The slots of today's agenda, in time order (« À replacer » left out: they have no hour). Empty when the plan is
    /// for another day or has no agenda.
    static func slots(plan: FocusPlan, now: Date) -> [FocusAgendaSlot] {
        guard let agenda = plan.agenda, FocusDayPlanner.dayKey(at: now, timeZoneID: agenda.timeZoneID) == plan.day else { return [] }
        return agenda.slots.filter { $0.state != .unscheduled }
            .sorted { ($0.startMinute, $0.endMinute) < ($1.startMinute, $1.endMinute) }
    }

    static func rows(plan: FocusPlan, now: Date) -> [DayPlanSlotRow] {
        slots(plan: plan, now: now).map {
            DayPlanSlotRow(id: $0.id, time: "\(FocusDayUI.time($0.startMinute)) – \(FocusDayUI.time($0.endMinute))",
                           title: $0.title, state: $0.state)
        }
    }

    /// The popover row: nil (hidden) when today has no plan.
    static func summary(plan: FocusPlan, now: Date) -> DayPlanSummary? {
        let slots = slots(plan: plan, now: now)
        guard !slots.isEmpty else { return nil }
        let next = FocusDayPlanner.currentSlot(plan: plan, at: now) ?? FocusDayPlanner.nextSlot(plan: plan, at: now)
        return DayPlanSummary(nextTime: next.map { FocusDayUI.time($0.startMinute) }, nextTitle: next?.title,
                              done: slots.filter { $0.state == .done }.count, total: slots.count)
    }

    /// « Bilan » becomes the main button once the day is over: at the end of the plan's last slot, or at 18:00
    /// when today has no plan (Mathis, 2026-11-27, Q6).
    static func recapIsMain(plan: FocusPlan?, now: Date, calendar: Calendar = .current) -> Bool {
        if let plan, let agenda = plan.agenda, let last = slots(plan: plan, now: now).map(\.endMinute).max(),
           let end = FocusDayPlanner.date(day: plan.day, minute: last, timeZoneID: agenda.timeZoneID) {
            return now >= end
        }
        return calendar.component(.hour, from: now) >= 18
    }

    /// « Vendredi 27 novembre ».
    static func dayTitle(_ date: Date) -> String {
        let text = BlockingFormat.day(date)
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    static func message(_ error: Error) -> String {
        switch error as? FocusFailure {
        case .locked: return "Un blocage verrouillé empêche ce changement."
        case .conflict, .requestConflict: return "Le plan a changé entre-temps. Réessayez."
        case .notFound: return "Ce créneau n’existe plus."
        case .storageFailed: return "Goalong n’a pas pu enregistrer le plan."
        default: return "Ce créneau ne peut pas démarrer maintenant."
        }
    }
}

/// Asks the Activity page to show the plan (from the menu bar panel, which lives outside the dashboard).
@MainActor final class DayPlanPresentation: ObservableObject {
    static let shared = DayPlanPresentation()
    @Published var shown = false
}

/// One row of the menu bar panel: the next step of the day, and the way into the plan. Same target as Activity's button.
struct DayPlanRow: View {
    let summary: DayPlanSummary
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "list.bullet.below.rectangle").font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                    .frame(width: 14).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Plan du jour").font(.system(size: 13, weight: .medium))
                    Text(line).font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText).lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(LHTheme.secondaryText)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(hovered ? LHTheme.hoverBackground : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityLabel("Plan du jour. \(summary.nextTitle.map { "Prochain : \($0)" } ?? summary.progressText)")
        .accessibilityIdentifier("menubar-day-plan")
    }

    private var line: String {
        guard let title = summary.nextTitle else { return summary.progressText }
        return "\(summary.nextTime.map { $0 + " · " } ?? "")\(title) · \(summary.progressText)"
    }
}

/// The two entries under Activity's period controls, plus the end-of-day sentence once the day is done.
struct ActivityQuickAccessBar: View {
    var onPlan: (() -> Void)?
    var onRecap: (() -> Void)?
    /// « Journée terminée »: set at the end of the day only; « Bilan » is then the main button.
    var endOfDayHint: String? = nil

    var body: some View {
        HStack(spacing: 8) {
            if let onPlan {
                Button(action: onPlan) { Label("Plan du jour", systemImage: "list.bullet.below.rectangle") }
                    .buttonStyle(LHSecondaryButtonStyle()).accessibilityIdentifier("activity-day-plan")
            }
            if let onRecap {
                let recap = Button(action: onRecap) { Label("Bilan", systemImage: "text.badge.checkmark") }
                if endOfDayHint == nil {
                    recap.buttonStyle(LHSecondaryButtonStyle()).accessibilityIdentifier("activity-recap")
                } else {
                    recap.buttonStyle(LHPrimaryButtonStyle()).accessibilityIdentifier("activity-recap")
                }
            }
            if let endOfDayHint {
                Text(endOfDayHint).font(.system(size: 13)).foregroundStyle(LHTheme.secondaryText).lineLimit(1).padding(.leading, 4)
            }
            Spacer(minLength: 0)
        }
        .controlSize(.regular)
    }
}

/// The plan view on the real Concentration controller: « Commencer », « C’est fait », « Ajouter un créneau ».
struct DayPlanSheet: View {
    @ObservedObject var controller: ConcentrationController
    var onAdd: () -> Void
    var onRecap: () -> Void
    var onClose: () -> Void
    @State private var failure: String?

    var body: some View {
        let now = GoalongToday.now
        DayPlanView(dayTitle: DayPlanDigest.dayTitle(now), slots: DayPlanDigest.rows(plan: controller.plan, now: now),
                    recapIsMain: DayPlanDigest.recapIsMain(plan: controller.plan, now: now), failure: failure,
                    onStart: start, onDone: done, onAdd: onAdd, onRecap: onRecap, onClose: onClose)
            .frame(width: 640)
            .background(LHTheme.pageBackground)
    }

    private func start(_ slot: DayPlanSlotRow) {
        guard controller.currentSession == nil else { failure = "Une séance est déjà en cours. Terminez-la d’abord."; return }
        do { try controller.startAgendaSlot(slot.id); failure = nil; onClose() }
        catch { failure = DayPlanDigest.message(error) }
    }

    private func done(_ slot: DayPlanSlotRow) {
        do { try controller.finishAgendaSlot(slot.id); failure = nil }
        catch { failure = DayPlanDigest.message(error) }
    }
}

/// The view both entries open: the day as a list, the next step first, the recap one click away.
struct DayPlanView: View {
    let dayTitle: String
    let slots: [DayPlanSlotRow]
    var recapIsMain = false
    var failure: String? = nil
    var onStart: (DayPlanSlotRow) -> Void = { _ in }
    var onDone: (DayPlanSlotRow) -> Void = { _ in }
    var onAdd: () -> Void = {}
    var onRecap: () -> Void = {}
    var onClose: (() -> Void)? = nil

    private var next: DayPlanSlotRow? { slots.first { $0.state == .active } ?? slots.first { $0.state == .planned } }
    private var done: Int { slots.filter { $0.state == .done }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Plan du jour").goalongPageTitle()
                    Text(slots.isEmpty ? dayTitle : "\(dayTitle) · \(done) fait\(done > 1 ? "s" : "") sur \(slots.count)")
                        .font(.system(size: 13)).foregroundStyle(LHTheme.secondaryText)
                }
                Spacer(minLength: 8)
                Button("Ajouter un créneau", action: onAdd).buttonStyle(LHSecondaryButtonStyle())
                    .accessibilityIdentifier("day-plan-add")
            }
            if slots.isEmpty {
                Text("Rien de prévu aujourd’hui. Ajoutez un créneau pour savoir quoi faire et quand.")
                    .font(.system(size: 13)).foregroundStyle(LHTheme.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                    .background(RoundedRectangle(cornerRadius: LHTheme.cardRadius, style: .continuous).fill(LHTheme.elevatedBackground))
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(slots.enumerated()), id: \.element.id) { index, slot in
                        if index > 0 { Rectangle().fill(LHTheme.separator).frame(height: 1) }
                        row(slot)
                    }
                }
                .background(RoundedRectangle(cornerRadius: LHTheme.cardRadius, style: .continuous).fill(LHTheme.elevatedBackground))
                .overlay(RoundedRectangle(cornerRadius: LHTheme.cardRadius, style: .continuous).strokeBorder(LHTheme.separator))
            }
            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(LHTheme.warning)
                    .accessibilityIdentifier("day-plan-failure")
            }
            HStack {
                let recap = Button(action: onRecap) { Label("Bilan de la journée", systemImage: "text.badge.checkmark") }
                    .accessibilityIdentifier("day-plan-recap")
                if recapIsMain { recap.buttonStyle(LHPrimaryButtonStyle()) } else { recap.buttonStyle(LHQuietButtonStyle()) }
                Spacer(minLength: 0)
                if let onClose {
                    Button("Fermer", action: onClose).buttonStyle(LHSecondaryButtonStyle()).keyboardShortcut(.cancelAction)
                }
            }
        }
        .padding(LHTheme.pageInset)
    }

    private func row(_ slot: DayPlanSlotRow) -> some View {
        let isNext = slot.id == next?.id
        return HStack(spacing: 12) {
            Image(systemName: slot.state == .done ? "checkmark.circle.fill" : slot.state == .active ? "circle.inset.filled" : "circle")
                .font(.system(size: 14)).foregroundStyle(slot.state == .done ? LHTheme.success : LHTheme.secondaryText)
                .accessibilityHidden(true)
            Text(slot.time).font(.system(size: 13).monospacedDigit()).foregroundStyle(LHTheme.secondaryText).frame(width: 96, alignment: .leading)
            Text(slot.title).font(.system(size: 14, weight: isNext ? .semibold : .regular))
                .foregroundStyle(slot.state.isFinished ? LHTheme.secondaryText : LHTheme.text).lineLimit(1)
            Spacer(minLength: 8)
            if isNext {
                if slot.state == .active {
                    Button("C’est fait") { onDone(slot) }.buttonStyle(LHPrimaryButtonStyle()).controlSize(.small)
                        .accessibilityIdentifier("day-plan-done")
                } else {
                    Button("Commencer") { onStart(slot) }.buttonStyle(LHPrimaryButtonStyle()).controlSize(.small)
                        .accessibilityIdentifier("day-plan-start")
                }
            } else {
                Text(slot.state.title).font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
            }
        }
        .padding(.horizontal, 14).frame(minHeight: 44)
        .accessibilityElement(children: .contain)
    }
}
#endif
