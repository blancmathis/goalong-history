#if os(macOS)
import SwiftUI

struct GoalongActivityHeader: View {
    let selection: GoalongActivityNavigation
    let isPreview: Bool
    let isRefreshing: Bool
    var onDay: (Date) -> Void
    var onPeriod: (Int) -> Void
    var onStep: (Int) -> Void
    var onToday: () -> Void
    var onReturn: () -> Void
    var onRefresh: () -> Void
    var onShare: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 16) {
                Text(isPreview ? "Activité · aperçu" : "Activité")
                    .font(.system(size: 24, weight: .semibold)).tracking(-0.5)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                Picker("Période", selection: Binding(get: { selection.period }, set: onPeriod)) {
                    Text("Jour").tag(1)
                    Text("7 jours").tag(7)
                    Text("28 jours").tag(28)
                }
                .labelsHidden().pickerStyle(.segmented).frame(width: 224)
                .accessibilityIdentifier("analytics-period")
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    dateControls
                    Spacer(minLength: 8)
                    actions
                }
                VStack(alignment: .leading, spacing: 12) {
                    dateControls
                    HStack { Spacer(); actions }
                }
            }
            HStack(spacing: 12) {
                Text(rangeLabel).font(.system(size: 13, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("activity-date-range")
                Spacer(minLength: 0)
                if let previous = selection.returnContext {
                    Button(action: onReturn) {
                        Label("Retour aux \(previous.period) jours", systemImage: "arrow.uturn.backward")
                    }
                    .buttonStyle(.borderless).font(.system(size: 12))
                    .accessibilityIdentifier("activity-return-period")
                }
            }
        }
        .padding(.horizontal, LHTheme.pageInset).padding(.vertical, 18)
        .background(LHTheme.pageBackground)
        .accessibilityIdentifier("activity-header")
    }

    private var dateControls: some View {
        HStack(spacing: 8) {
            Button { onStep(-1) } label: {
                Label(selection.period == 1 ? "Jour précédent" : "Période précédente", systemImage: "chevron.left")
            }.labelStyle(.iconOnly).accessibilityIdentifier("activity-previous-period")
            DatePicker(selection.period == 1 ? "Date" : "Dernier jour de la période",
                       selection: Binding(get: { selection.day }, set: onDay),
                       in: ...Date(), displayedComponents: .date)
                .labelsHidden().datePickerStyle(.field).fixedSize()
                .accessibilityIdentifier("activity-date-picker")
            Button { onStep(1) } label: {
                Label(selection.period == 1 ? "Jour suivant" : "Période suivante", systemImage: "chevron.right")
            }
            .labelStyle(.iconOnly).disabled(Calendar.current.isDateInToday(selection.day))
            .accessibilityIdentifier("activity-next-period")
            Button("Aujourd’hui", action: onToday)
                .disabled(selection.period == 1 && Calendar.current.isDateInToday(selection.day))
                .accessibilityIdentifier("activity-today")
        }
        .controlSize(.small)
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button(action: onRefresh) {
                HStack(spacing: 6) {
                    if isRefreshing { ProgressView().controlSize(.mini) }
                    else { Image(systemName: "arrow.clockwise") }
                    Text("Actualiser")
                }
            }.disabled(isRefreshing).accessibilityIdentifier("activity-refresh")
            Menu {
                Button("Partager la journée du \(shortDate(selection.day))", action: onShare)
                    .disabled(isPreview)
            } label: {
                Label("Partager", systemImage: "square.and.arrow.up")
            }
            .fixedSize().disabled(isPreview)
            .help("Le partage porte sur la journée sélectionnée et demande votre validation.")
        }
        .controlSize(.small)
    }

    private var rangeLabel: String {
        if selection.period == 1 {
            return Calendar.current.isDateInToday(selection.day)
                ? "Aujourd’hui · \(shortDate(selection.day))"
                : GoalongUIFormat.day(selection.day)
        }
        return "\(shortDate(selection.interval().start)) – \(shortDate(selection.day))"
    }

    private func shortDate(_ day: Date) -> String {
        day.formatted(.dateTime.locale(Locale(identifier: "fr_FR")).day().month(.abbreviated).year())
    }
}
#endif
