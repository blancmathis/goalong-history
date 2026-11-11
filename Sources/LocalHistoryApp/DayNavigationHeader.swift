#if os(macOS)
    import SwiftUI

    /// Stable day navigation shared by the two daily reading surfaces.
    struct DayNavigationHeader: View {
        let title: String
        let day: Date
        let isRefreshing: Bool
        let onSelectDay: (Date) -> Void
        let onShare: () -> Void
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
            // Lot 2b (3, 14): no refresh button (the page reads again on activation, ⌘R stays in the menu);
            // the reason the share button is grey is written under it.
            VStack(alignment: .trailing, spacing: 6) {
                Button(action: onShare) {
                    Label("Partager cette journée…", systemImage: "square.and.arrow.up")
                }
                .modifier(GoalongHeaderButtonState(enabled: sharingEnabled))
                .help(sharingEnabled ? "Partager cette journée. Rien n’est envoyé sans votre validation."
                      : sharingDisabledReason ?? "Les données fictives ne peuvent pas être partagées")
                if !sharingEnabled {
                    GoalongDisabledReason(text: sharingDisabledReason ?? "Les données fictives ne peuvent pas être partagées")
                        .accessibilityIdentifier("history-share-reason")
                }
            }
            .controlSize(.regular)
        }
    }

    /// Lot 2b (14): the short reason written beside a grey button, readable without hovering.
    struct GoalongDisabledReason: View {
        let text: String
        var body: some View {
            Text(text).font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                .multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 260, alignment: .trailing)
        }
    }

    /// UI-13B (13, 17): a header button that is off must still read (≥ 3:1, DESIGN §12). The secondary
    /// buttons share one disabled look (T-043 R-5): disabledText at full opacity on a dashed outline.
    struct GoalongHeaderButtonState: ViewModifier {
        let enabled: Bool

        func body(content: Content) -> some View {
            if enabled {
                content.buttonStyle(LHSecondaryButtonStyle())
            } else {
                content.buttonStyle(GoalongReadableDisabledButtonStyle()).disabled(true)
            }
        }
    }

    private struct GoalongReadableDisabledButtonStyle: ButtonStyle {
        @Environment(\.controlSize) private var controlSize
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .font(.system(size: GoalongControlMetrics.font(controlSize), weight: .medium))
                .lineLimit(1)
                .padding(.horizontal, GoalongControlMetrics.inset(controlSize))
                .frame(minHeight: GoalongControlMetrics.height(controlSize))
                // The shared disabled look of every button style (T-043 R-5).
                .foregroundStyle(LHTheme.disabledText)
                .background { GoalongDisabledControlSurface() }
        }
    }
#endif
