#if os(macOS)
import SwiftUI

/// T-057 M1 (mockup, idées 1 et 4): « Plan du jour » and « Bilan » one click away.
/// Rendering only: the closures are not wired to the real plan or recap yet. Fixture data in the tests.
struct DayPlanSlotPreview: Identifiable, Equatable {
    let id: Int
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
    /// « Journée terminée · 6 h 12 de travail »: set at the end of the day only.
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

/// The view both entries open: the day as a list, the next step first, the recap one click away.
struct DayPlanView: View {
    let dayTitle: String
    let slots: [DayPlanSlotPreview]
    var onStart: (DayPlanSlotPreview) -> Void = { _ in }
    var onAdd: () -> Void = {}
    var onRecap: () -> Void = {}

    private var next: DayPlanSlotPreview? { slots.first { $0.state == .active } ?? slots.first { $0.state == .planned } }
    private var done: Int { slots.filter { $0.state == .done }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Plan du jour").goalongPageTitle()
                    Text("\(dayTitle) · \(done) fait\(done > 1 ? "s" : "") sur \(slots.count)")
                        .font(.system(size: 13)).foregroundStyle(LHTheme.secondaryText)
                }
                Spacer(minLength: 8)
                Button("Ajouter un créneau", action: onAdd).buttonStyle(LHSecondaryButtonStyle())
            }
            VStack(spacing: 0) {
                ForEach(Array(slots.enumerated()), id: \.element.id) { index, slot in
                    if index > 0 { Rectangle().fill(LHTheme.separator).frame(height: 1) }
                    row(slot)
                }
            }
            .background(RoundedRectangle(cornerRadius: LHTheme.cardRadius, style: .continuous).fill(LHTheme.elevatedBackground))
            .overlay(RoundedRectangle(cornerRadius: LHTheme.cardRadius, style: .continuous).strokeBorder(LHTheme.separator))
            HStack {
                Button(action: onRecap) { Label("Bilan de la journée", systemImage: "text.badge.checkmark") }
                    .buttonStyle(LHQuietButtonStyle())
                Spacer(minLength: 0)
            }
        }
        .padding(LHTheme.pageInset)
    }

    private func row(_ slot: DayPlanSlotPreview) -> some View {
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
                Button(slot.state == .active ? "C’est fait" : "Commencer") { onStart(slot) }.buttonStyle(LHPrimaryButtonStyle()).controlSize(.small)
            } else {
                Text(slot.state.title).font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
            }
        }
        .padding(.horizontal, 14).frame(minHeight: 44)
        .accessibilityElement(children: .combine)
    }
}
#endif
