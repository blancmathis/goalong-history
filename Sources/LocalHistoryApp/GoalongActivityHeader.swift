#if os(macOS)
import SwiftUI

struct GoalongActivityHeader: View {
    let selection: GoalongActivityNavigation
    let isPreview: Bool
    let isRefreshing: Bool
    /// Nil while sharing makes sense; otherwise why the day cannot be shared.
    var shareBlockedReason: String? = nil
    var onDay: (Date) -> Void
    var onPeriod: (Int) -> Void
    var onStep: (Int) -> Void
    var onToday: () -> Void
    var onReturn: () -> Void
    var onRefresh: () -> Void
    var onShare: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(isPreview ? "Activité, aperçu" : "Activité").goalongPageTitle()
                    Text(rangeLabel).font(.system(size: 13)).foregroundStyle(LHTheme.secondaryText)
                        .accessibilityIdentifier("activity-date-range")
                }
                Spacer(minLength: 8)
                actions
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    period
                    Spacer(minLength: 8)
                    dateControls
                }
                VStack(alignment: .leading, spacing: 12) {
                    period
                    dateControls
                }
            }
            if let previous = selection.returnContext {
                Button(action: onReturn) {
                    Label("Retour aux \(GoalongUIFormat.count(previous.period, "jour"))", systemImage: "arrow.uturn.backward")
                }.buttonStyle(LHQuietButtonStyle()).font(.system(size: 13))
                    .accessibilityIdentifier("activity-return-period")
            }
        }
        .padding(.horizontal, LHTheme.pageInset).padding(.top, 28).padding(.bottom, 16)
        .background(LHTheme.pageBackground)
        .accessibilityIdentifier("activity-header")
    }

    private var period: some View {
        GoalongSegmentedControl("Période", selection: Binding(get: { selection.period }, set: onPeriod),
                                options: [1, 7, 28]) { $0 == 1 ? "Jour" : GoalongUIFormat.count($0, "jour") }
            .accessibilityIdentifier("analytics-period")
    }

    private var dateControls: some View {
        HStack(spacing: 8) {
            DateSelectionControl(date: selection.day, onChange: onDay, onStep: onStep,
                                 previousLabel: selection.period == 1 ? "Jour précédent" : "Période précédente",
                                 nextLabel: selection.period == 1 ? "Jour suivant" : "Période suivante",
                                 identifierPrefix: "activity", showsToday: false,
                                 dateLabel: selection.period == 1 ? nil : periodLabel)
            // A period ending today already shows today: the button goes grey, as for the day itself.
            Button("Aujourd’hui", action: onToday)
                .modifier(GoalongHeaderButtonState(enabled: !GoalongToday.isToday(selection.day)))
                .accessibilityIdentifier("activity-today")
        }
        .controlSize(.regular)
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button(action: onRefresh) {
                Group {
                    if isRefreshing { ProgressView().controlSize(.small) }
                    else { Image(systemName: "arrow.clockwise") }
                }.frame(width: 16, height: 16)
            }
            .modifier(GoalongHeaderButtonState(enabled: !isRefreshing)).accessibilityIdentifier("activity-refresh")
            .accessibilityLabel("Actualiser").help("Actualiser")
            // Always present, grey when there is nothing to share: the same rule on every page.
            Button(action: onShare) {
                Label(selection.period == 1 ? "Partager cette journée…" : "Partager cette période…", systemImage: "square.and.arrow.up")
            }
            .modifier(GoalongHeaderButtonState(enabled: !isPreview && shareReason == nil))
            .help(shareReason ?? "Partager la journée du \(shortDate(selection.day)). Rien n’est envoyé sans votre validation.")
            .accessibilityHint(shareReason ?? "")
        }
        .controlSize(.regular)
    }

    /// A period is shared day by day; the page says why the button is grey.
    private var shareReason: String? {
        selection.period == 1 ? shareBlockedReason : "Le partage se fait par journée : choisissez « Jour » pour partager un jour."
    }

    private var periodLabel: String {
        let format = Date.FormatStyle.dateTime.locale(Locale(identifier: "fr_FR")).day().month(.abbreviated)
        return "\(selection.interval().start.formatted(format)) – \(selection.day.formatted(format))"
    }

    private var rangeLabel: String {
        if selection.period == 1 {
            return GoalongToday.isToday(selection.day)
                ? "Aujourd’hui"
                : GoalongUIFormat.day(selection.day)
        }
        return "\(shortDate(selection.interval().start)) – \(shortDate(selection.day))"
    }

    private func shortDate(_ day: Date) -> String {
        day.formatted(.dateTime.locale(Locale(identifier: "fr_FR")).day().month(.abbreviated).year())
    }
}
#endif
