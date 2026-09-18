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

        var body: some View {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 24) {
                    heading
                    Spacer(minLength: 8)
                    actions.fixedSize(horizontal: true, vertical: false)
                }
                VStack(alignment: .leading, spacing: 16) {
                    heading
                    actions
                }
            }
            .padding(.horizontal, LHTheme.pageInset)
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LHTheme.pageBackground)
        }

        private var heading: some View {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(LHTheme.pageTitleFont)
                    .tracking(-0.5)
                    .accessibilityAddTraits(.isHeader)
                Text(day.formatted(.dateTime.weekday(.wide).month(.wide).day().locale(Locale(identifier: "fr_FR"))))
                    .font(.system(size: 13))
                    .foregroundStyle(LHTheme.secondaryText)
            }
            .fixedSize(horizontal: true, vertical: false)
        }

        private var actions: some View {
            HStack(spacing: 8) {
                DateSelectionControl(date: day, onChange: onSelectDay)
                Divider().frame(height: 20).padding(.horizontal, 4)
                Button(action: onShare) {
                    Label("Envoyer à Goalong", systemImage: "square.and.arrow.up")
                }
                .disabled(!sharingEnabled)
                .help(sharingEnabled ? "Envoyer à Goalong" : "Les données fictives ne peuvent pas être envoyées")
                Button(action: onRefresh) {
                    Group {
                        if isRefreshing { ProgressView().controlSize(.small) }
                        else { Image(systemName: "arrow.clockwise") }
                    }
                    .frame(width: 20, height: 20)
                }
                .disabled(isRefreshing)
                .accessibilityLabel("Actualiser la journée")
                .help(isRefreshing ? "Actualisation…" : "Actualiser la journée")
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
        }
    }
#endif
