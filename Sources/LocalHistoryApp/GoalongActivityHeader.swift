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
                VStack(alignment: .leading, spacing: 6) {
                    Text(isPreview ? "Activité · aperçu" : "Activité")
                        .font(LHTheme.pageTitleFont).tracking(-0.3)
                        .accessibilityAddTraits(.isHeader)
                    Text(rangeLabel).font(.system(size: 13)).foregroundStyle(.secondary)
                        .accessibilityIdentifier("activity-date-range")
                }
                Spacer(minLength: 8)
                GoalongSegmentedControl("Période", selection: Binding(get: { selection.period }, set: onPeriod),
                                        options: [1, 7, 28]) { $0 == 1 ? "Jour" : "\($0) jours" }
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
            if let previous = selection.returnContext {
                Button(action: onReturn) {
                    Label("Retour aux \(previous.period) jours", systemImage: "arrow.uturn.backward")
                }.buttonStyle(.borderless).font(.system(size: 12))
                    .accessibilityIdentifier("activity-return-period")
            }
        }
        .padding(.horizontal, LHTheme.pageInset).padding(.vertical, 18)
        .goalongPageBackground().clipped()
        .accessibilityIdentifier("activity-header")
    }

    private var dateControls: some View {
        HStack(spacing: 8) {
            DateSelectionControl(date: selection.day, onChange: onDay, onStep: onStep,
                                 previousLabel: selection.period == 1 ? "Jour précédent" : "Période précédente",
                                 nextLabel: selection.period == 1 ? "Jour suivant" : "Période suivante",
                                 identifierPrefix: "activity", showsToday: false)
            Button("Aujourd’hui", action: onToday)
                .disabled(selection.period == 1 && Calendar.current.isDateInToday(selection.day))
                .accessibilityIdentifier("activity-today")
        }
        .controlSize(.regular)
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
        .controlSize(.regular)
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
