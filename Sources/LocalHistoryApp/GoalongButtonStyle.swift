#if os(macOS)
    import AppKit
    import SwiftUI

    /// Keeps Button actions, roles and shortcuts with the site's ink-on-lime treatment.
    /// A flat fill: the colour is the emphasis, so one per group of actions.
    struct LHPrimaryButtonStyle: ButtonStyle {
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.isFocused) private var isFocused
        @Environment(\.controlSize) private var controlSize
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var isHovered = false

        func makeBody(configuration: Configuration) -> some View {
            let destructive = configuration.role == .destructive
            let shape = RoundedRectangle(cornerRadius: LHTheme.controlRadius, style: .continuous)
            let base: Color = destructive ? Color(nsColor: LHTheme.rgb(configuration.isPressed ? 0x8E2A25 : isHovered ? 0xB83C35 : 0xA6352F))
                : configuration.isPressed ? LHTheme.actionPressed
                : isHovered ? LHTheme.actionHover : LHTheme.actionBackground
            configuration.label
                .font(.system(size: GoalongControlMetrics.font(controlSize), weight: .semibold))
                .lineLimit(1)
                .padding(.horizontal, GoalongControlMetrics.inset(controlSize) + 2)
                .frame(minHeight: GoalongControlMetrics.height(controlSize))
                .foregroundStyle(!isEnabled ? LHTheme.secondaryText : destructive ? .white : LHTheme.onAccent)
                .background {
                    if isEnabled {
                        shape.fill(base)
                    } else {
                        GoalongSurface(corner: LHTheme.controlRadius, fill: LHTheme.controlBackground, highlighted: true)
                    }
                }
                .overlay {
                    shape.strokeBorder(isFocused ? LHTheme.text : .clear, lineWidth: 2)
                        .padding(-3)
                }
                .opacity(isEnabled ? 1 : 0.5)
                .scaleEffect(configuration.isPressed && isEnabled && !reduceMotion ? 0.97 : 1)
                .contentShape(shape)
                .onHover { isHovered = $0 }
                .animation(reduceMotion ? nil : LHTheme.hover, value: isHovered)
                .animation(reduceMotion ? nil : LHTheme.press, value: configuration.isPressed)
        }
    }
#endif
