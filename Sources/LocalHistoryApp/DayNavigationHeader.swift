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

        var body: some View {
            HStack(alignment: .center, spacing: 24) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(title)
                        .font(.system(size: 24, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text(day.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                HStack(spacing: 8) {
                    DateSelectionControl(date: day, onChange: onSelectDay)
                    Divider().frame(height: 20).padding(.horizontal, 4)
                    Button(action: onShare) {
                        Label("Share day", systemImage: "square.and.arrow.up")
                    }
                    Button(action: onRefresh) {
                        Group {
                            if isRefreshing { ProgressView().controlSize(.small) }
                            else { Image(systemName: "arrow.clockwise") }
                        }
                        .frame(width: 20, height: 20)
                    }
                    .disabled(isRefreshing)
                    .accessibilityLabel("Refresh selected day")
                    .help(isRefreshing ? "Refreshing selected day…" : "Refresh selected day")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }
            .padding(.horizontal, LHTheme.pageInset)
            .padding(.vertical, 22)
            .background(LHTheme.pageBackground)
        }
    }
#endif
