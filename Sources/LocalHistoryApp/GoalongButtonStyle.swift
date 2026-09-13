#if os(macOS)
    import AppKit
    import SwiftUI

    /// Keeps Button actions, roles and shortcuts with the site's ink-on-lime treatment.
    struct LHPrimaryButtonStyle: ButtonStyle {
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.isFocused) private var isFocused
        @Environment(\.controlSize) private var controlSize
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var isHovered = false

        private var height: CGFloat {
            switch controlSize {
            case .mini: return 24
            case .small: return 28
            case .large: return 38
            default: return 32
            }
        }

        func makeBody(configuration: Configuration) -> some View {
            let destructive = configuration.role == .destructive
            configuration.label
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 5)
                .frame(minHeight: height)
                .foregroundStyle(!isEnabled ? LHTheme.secondaryText : destructive ? .white : LHTheme.onAccent)
                .background(
                    !isEnabled ? LHTheme.elevatedBackground
                        : destructive ? Color(nsColor: LHTheme.rgb(0xA6352F))
                        : configuration.isPressed ? LHTheme.actionPressed
                        : isHovered ? LHTheme.actionHover : LHTheme.actionBackground,
                    in: RoundedRectangle(cornerRadius: LHTheme.controlRadius, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: LHTheme.controlRadius, style: .continuous)
                        .strokeBorder(isFocused ? LHTheme.text : .clear, lineWidth: 2)
                        .padding(-3)
                }
                .contentShape(RoundedRectangle(cornerRadius: LHTheme.controlRadius))
                .onHover { isHovered = $0 }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovered)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.10), value: configuration.isPressed)
        }
    }
#endif
