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
            let shape = RoundedRectangle(cornerRadius: LHTheme.controlRadius, style: .continuous)
            let base: Color = destructive ? Color(nsColor: LHTheme.rgb(0xA6352F))
                : configuration.isPressed ? LHTheme.actionPressed
                : isHovered ? LHTheme.actionHover : LHTheme.actionBackground
            configuration.label
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 15)
                .padding(.vertical, 5)
                .frame(minHeight: height)
                .foregroundStyle(!isEnabled ? LHTheme.secondaryText : destructive ? .white : LHTheme.onAccent)
                .background {
                    if isEnabled {
                        // Sunlit lime: a touch brighter at the top, crisp rim, soft glow on hover.
                        shape.fill(base)
                            .overlay(shape.fill(LinearGradient(colors: [.white.opacity(0.22), .clear],
                                                               startPoint: .top, endPoint: .center)))
                            .overlay(shape.strokeBorder(Color.black.opacity(0.18), lineWidth: 0.5))
                            .shadow(color: (destructive ? Color.red : LHTheme.actionBackground)
                                        .opacity(isHovered && !configuration.isPressed ? 0.32 : 0), radius: 10, y: 2)
                    } else {
                        GoalongSurface(corner: LHTheme.controlRadius, fill: LHTheme.controlBackground)
                    }
                }
                .overlay {
                    shape.strokeBorder(isFocused ? LHTheme.text : .clear, lineWidth: 2)
                        .padding(-3)
                }
                .opacity(isEnabled ? 1 : 0.7)
                .scaleEffect(configuration.isPressed && isEnabled && !reduceMotion ? 0.97 : 1)
                .contentShape(shape)
                .onHover { isHovered = $0 }
                .animation(reduceMotion ? nil : LHTheme.hover, value: isHovered)
                .animation(reduceMotion ? nil : LHTheme.press, value: configuration.isPressed)
        }
    }
#endif
