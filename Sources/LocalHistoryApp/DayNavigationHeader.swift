#if os(macOS)
    import SwiftUI

    /// Stable day navigation shared by the two daily reading surfaces.
    struct DayNavigationHeader: View {
        let title: String
        let day: Date
        let isRefreshing: Bool
        let onSelectDay: (Date) -> Void
        let onShare: () -> Void
        let onRefresh: () -> Void
        var sharingEnabled = true
        /// Why sharing is grey; nil keeps the preview wording.
        var sharingDisabledReason: String? = nil

        /// Same order as Activité: Actualiser then Partager beside the title, the day on the line below.
        var body: some View {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    heading
                    Spacer(minLength: 8)
                    actions
                }
                DateSelectionControl(date: day, onChange: onSelectDay)
                    .controlSize(.regular)
            }
            .padding(.horizontal, LHTheme.pageInset)
            .padding(.top, 28).padding(.bottom, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LHTheme.pageBackground).clipped()
        }

        private var heading: some View {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).goalongPageTitle()
                Text(day.formatted(.dateTime.weekday(.wide).locale(Locale(identifier: "fr_FR"))).capitalized(with: Locale(identifier: "fr_FR")))
                    .font(.system(size: 13))
                    .foregroundStyle(LHTheme.secondaryText)
            }
            .fixedSize(horizontal: true, vertical: false)
        }

        private var actions: some View {
            HStack(spacing: 8) {
                Button(action: onRefresh) {
                    Group {
                        if isRefreshing { ProgressView().controlSize(.small) }
                        else { Image(systemName: "arrow.clockwise") }
                    }
                    .frame(width: 16, height: 16)
                }
                .disabled(isRefreshing)
                .accessibilityLabel("Actualiser la journée")
                .help(isRefreshing ? "Actualisation…" : "Actualiser la journée")
                Button(action: onShare) {
                    Label("Partager cette journée…", systemImage: "square.and.arrow.up")
                }
                .disabled(!sharingEnabled)
                .help(sharingEnabled ? "Partager cette journée. Rien n’est envoyé sans votre validation."
                      : sharingDisabledReason ?? "Les données fictives ne peuvent pas être partagées")
            }
            .controlSize(.regular)
        }
    }
#endif
