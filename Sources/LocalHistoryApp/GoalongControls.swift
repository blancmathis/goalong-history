#if os(macOS)
    import AppKit
    import SwiftUI

    /// Goalong's own control chrome, so forms read as one product instead of stock grey
    /// AppKit bezels on forest surfaces. Actions, roles, focus and accessibility stay native.

    /// Card material: tonal fill, hairline edge and a faint lit rim along the top,
    /// so surfaces read as layered rather than outlined.
    struct GoalongSurface: View {
        var corner: CGFloat = LHTheme.cardRadius
        var fill: Color = LHTheme.cardBackground
        var increased = false
        var highlighted = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
            shape.fill(fill)
                .overlay(shape.strokeBorder(increased ? LHTheme.strongSeparator
                                            : highlighted ? LHTheme.controlBorder : LHTheme.separator, lineWidth: 1))
                .overlay(
                    shape.strokeBorder(LinearGradient(colors: [LHTheme.rimLight.opacity(highlighted ? 0.9 : 0.55), .clear],
                                                      startPoint: .top, endPoint: .init(x: 0.5, y: 0.22)), lineWidth: 1)
                )
        }
    }

    /// Quiet companion to `LHPrimaryButtonStyle`: raised forest surface, hairline border.
    struct LHSecondaryButtonStyle: ButtonStyle {
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.isFocused) private var isFocused
        @Environment(\.controlSize) private var controlSize
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.colorSchemeContrast) private var contrast
        @State private var isHovered = false

        private var metrics: (height: CGFloat, font: CGFloat, inset: CGFloat) {
            switch controlSize {
            case .mini: return (22, 11, 8)
            case .small: return (26, 12, 10)
            case .large: return (38, 14, 16)
            default: return (30, 13, 13)
            }
        }

        func makeBody(configuration: Configuration) -> some View {
            let destructive = configuration.role == .destructive
            let shape = RoundedRectangle(cornerRadius: LHTheme.controlRadius, style: .continuous)
            configuration.label
                .font(.system(size: metrics.font, weight: .medium))
                .lineLimit(1)
                .padding(.horizontal, metrics.inset)
                .frame(minHeight: metrics.height)
                .foregroundStyle(!isEnabled ? LHTheme.secondaryText : destructive ? LHTheme.danger : LHTheme.text)
                .background {
                    GoalongSurface(corner: LHTheme.controlRadius,
                                   fill: configuration.isPressed && isEnabled ? LHTheme.pressedBackground
                                       : isHovered && isEnabled ? LHTheme.hoverBackground : LHTheme.controlBackground,
                                   increased: contrast == .increased, highlighted: isHovered && isEnabled)
                }
                .overlay {
                    shape.strokeBorder(isFocused ? LHTheme.accent : .clear, lineWidth: 2).padding(-3)
                }
                .opacity(isEnabled ? 1 : 0.6)
                .scaleEffect(configuration.isPressed && isEnabled && !reduceMotion ? 0.97 : 1)
                .contentShape(shape)
                .onHover { isHovered = $0 }
                .animation(reduceMotion ? nil : LHTheme.hover, value: isHovered)
                .animation(reduceMotion ? nil : LHTheme.press, value: configuration.isPressed)
        }
    }

    /// One field chrome for single-line, multi-line and search inputs.
    struct GoalongFieldStyle: TextFieldStyle {
        // swiftlint:disable:next identifier_name
        func _body(configuration: TextField<Self._Label>) -> some View {
            GoalongFieldChrome { configuration.textFieldStyle(.plain) }
        }
    }

    /// Wraps one focusable input (TextField, TextEditor) and draws its focus.
    struct GoalongFieldChrome<Content: View>: View {
        @FocusState private var focused: Bool
        private let content: Content

        init(@ViewBuilder content: () -> Content) { self.content = content() }

        var body: some View {
            content
                .focused($focused)
                .modifier(GoalongFieldSurface(focused: focused, focus: { focused = true }))
        }
    }

    /// Sunken field surface: hairline border, lime ring and halo when focused.
    struct GoalongFieldSurface: ViewModifier {
        var focused = false
        /// Clicks on the padding focus the field; clicks on the text stay with the field itself.
        var focus: () -> Void = {}
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.controlSize) private var controlSize
        @Environment(\.colorSchemeContrast) private var contrast
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var hovered = false

        func body(content: Content) -> some View {
            let shape = RoundedRectangle(cornerRadius: LHTheme.controlRadius, style: .continuous)
            let small = controlSize == .small || controlSize == .mini
            content
                .font(.system(size: small ? 12 : 13))
                .padding(.horizontal, small ? 9 : 11)
                .padding(.vertical, small ? 5 : 8)
                .frame(minHeight: small ? 26 : 34)
                .background {
                    shape.fill(LHTheme.fieldBackground).onTapGesture(perform: focus)
                }
                .overlay {
                    shape.strokeBorder(focused ? LHTheme.accent
                                       : contrast == .increased || hovered ? LHTheme.strongSeparator : LHTheme.controlBorder,
                                       lineWidth: focused ? 1.5 : 1)
                        .allowsHitTesting(false)
                }
                .background { shape.fill(LHTheme.accent.opacity(focused ? 0.16 : 0)).padding(-3).allowsHitTesting(false) }
                .opacity(isEnabled ? 1 : 0.55)
                .contentShape(shape)
                .onHover { hovered = $0 }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: focused)
        }
    }

    /// TextEditor with the same chrome and an in-field placeholder.
    struct GoalongTextArea: View {
        @Binding var text: String
        var placeholder = ""
        var minHeight: CGFloat = 72

        var body: some View {
            GoalongFieldChrome {
                TextEditor(text: $text)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, -5)
                    .padding(.vertical, -1)
                    .frame(minHeight: minHeight)
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty && !placeholder.isEmpty {
                            Text(placeholder).foregroundStyle(LHTheme.placeholder)
                                .padding(.top, 1).allowsHitTesting(false).accessibilityHidden(true)
                        }
                    }
            }
        }
    }

    /// Search input: glass, field and a clear button once something is typed.
    struct GoalongSearchField: View {
        let prompt: String
        @Binding var text: String
        var accessibilityLabel: String?
        var identifier: String?
        var trailing: String?
        @FocusState private var focused: Bool

        init(_ prompt: String, text: Binding<String>, accessibilityLabel: String? = nil,
             identifier: String? = nil, trailing: String? = nil) {
            self.prompt = prompt
            _text = text
            self.accessibilityLabel = accessibilityLabel
            self.identifier = identifier
            self.trailing = trailing
        }

        var body: some View {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .medium))
                    .foregroundStyle(LHTheme.secondaryText).accessibilityHidden(true)
                TextField(prompt, text: $text).textFieldStyle(.plain).focused($focused)
                    .accessibilityLabel(accessibilityLabel ?? prompt)
                    .accessibilityIdentifier(identifier ?? "")
                if !text.isEmpty {
                    Button { text = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(LHTheme.secondaryText)
                    }.buttonStyle(.plain).accessibilityLabel("Effacer la recherche")
                }
                if let trailing {
                    Text(trailing).font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText).fixedSize()
                }
            }
            .modifier(GoalongFieldSurface(focused: focused, focus: { focused = true }))
        }
    }

    /// Brand switch: lime track and ink knob when on, quiet forest track when off.
    /// A real Button underneath keeps keyboard focus and Space activation.
    struct GoalongSwitch: View {
        @Binding var isOn: Bool
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.controlSize) private var controlSize
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            Button {
                withAnimation(reduceMotion ? nil : LHTheme.press) { isOn.toggle() }
            } label: { EmptyView() }
                .buttonStyle(GoalongSwitchButtonStyle(isOn: isOn, small: controlSize == .small || controlSize == .mini))
                .opacity(isEnabled ? 1 : 0.45)
        }
    }

    private struct GoalongSwitchButtonStyle: ButtonStyle {
        let isOn: Bool
        let small: Bool
        @Environment(\.isFocused) private var isFocused
        @Environment(\.colorSchemeContrast) private var contrast
        @State private var hovered = false

        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        func makeBody(configuration: Configuration) -> some View {
            let width: CGFloat = small ? 30 : 38, height: CGFloat = small ? 18 : 22
            let knob = height - 6
            // The knob stretches toward its destination while pressed, like a finger pushing it.
            let stretch: CGFloat = configuration.isPressed && !reduceMotion ? 5 : 0
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule().fill(isOn ? (hovered ? LHTheme.actionHover : LHTheme.actionBackground)
                               : (hovered ? LHTheme.hoverBackground : LHTheme.switchTrack))
                if isOn {
                    Capsule().fill(LinearGradient(colors: [.white.opacity(0.22), .clear], startPoint: .top, endPoint: .center))
                } else {
                    Capsule().strokeBorder(contrast == .increased ? LHTheme.strongSeparator : LHTheme.controlBorder)
                }
                Capsule().fill(isOn ? LHTheme.onAccent : LHTheme.switchKnob)
                    .frame(width: knob + stretch, height: knob)
                    .shadow(color: .black.opacity(isOn ? 0.12 : 0.22), radius: 1.5, y: 0.5)
                    .padding(.horizontal, 3)
            }
            .frame(width: width, height: height)
            .overlay { Capsule().strokeBorder(isFocused ? LHTheme.accent : .clear, lineWidth: 2).padding(-3) }
            .contentShape(Capsule())
            .onHover { hovered = $0 }
            .animation(reduceMotion ? nil : LHTheme.press, value: configuration.isPressed)
            .animation(reduceMotion ? nil : LHTheme.hover, value: hovered)
        }
    }

    enum GoalongSwitchLayout { case row, inline, switchOnly }

    /// `.row`: label on the leading edge, switch on a shared trailing edge (settings rows).
    /// `.inline`: label then switch. `.switchOnly`: the label only names it for accessibility.
    struct GoalongSwitchStyle: ToggleStyle {
        var layout: GoalongSwitchLayout = .row
        func makeBody(configuration: Configuration) -> some View {
            GoalongSwitchToggle(configuration: configuration, layout: layout)
        }
    }

    private struct GoalongSwitchToggle: View {
        let configuration: ToggleStyleConfiguration
        let layout: GoalongSwitchLayout
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            Group {
                switch layout {
                case .switchOnly:
                    GoalongSwitch(isOn: configuration.$isOn)
                case .inline:
                    HStack(spacing: 8) {
                        label
                        GoalongSwitch(isOn: configuration.$isOn)
                    }
                case .row:
                    HStack(alignment: .center, spacing: 16) {
                        label.frame(maxWidth: .infinity, alignment: .leading)
                        GoalongSwitch(isOn: configuration.$isOn)
                    }
                }
            }
            .accessibilityRepresentation {
                Toggle(isOn: configuration.$isOn) { configuration.label }
            }
        }

        private var label: some View {
            configuration.label
                .fixedSize(horizontal: false, vertical: true)
                .opacity(isEnabled ? 1 : 0.55)
                .contentShape(Rectangle())
                .onTapGesture { if isEnabled { configuration.isOn.toggle() } }
        }
    }

    extension ToggleStyle where Self == GoalongSwitchStyle {
        static var goalongSwitch: GoalongSwitchStyle { GoalongSwitchStyle() }
        static var goalongSwitchInline: GoalongSwitchStyle { GoalongSwitchStyle(layout: .inline) }
        static var goalongSwitchOnly: GoalongSwitchStyle { GoalongSwitchStyle(layout: .switchOnly) }
    }

    /// Segmented choice drawn in Goalong's surfaces; the selected segment is raised.
    struct GoalongSegmentedControl<Value: Hashable>: View {
        let label: String
        @Binding var selection: Value
        let options: [Value]
        let title: (Value) -> String
        var fills = false

        init(_ label: String, selection: Binding<Value>, options: [Value], fills: Bool = false,
             title: @escaping (Value) -> String) {
            self.label = label
            _selection = selection
            self.options = options
            self.fills = fills
            self.title = title
        }

        @Namespace private var pill
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            HStack(spacing: 2) {
                ForEach(options, id: \.self) { option in
                    let selected = selection == option
                    Button {
                        withAnimation(reduceMotion ? nil : LHTheme.settle) { selection = option }
                    } label: {
                        Text(title(option)).lineLimit(1)
                            .frame(maxWidth: fills ? .infinity : nil)
                    }
                    .buttonStyle(GoalongSegmentStyle(selected: selected))
                    // The raised pill slides between segments instead of jumping.
                    .background {
                        if selected {
                            GoalongSurface(corner: LHTheme.controlRadius - 2, fill: LHTheme.segmentSelected, highlighted: true)
                                .matchedGeometryEffect(id: "selection", in: pill)
                        }
                    }
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(2)
            .background(LHTheme.insetBackground, in: RoundedRectangle(cornerRadius: LHTheme.controlRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: LHTheme.controlRadius, style: .continuous).strokeBorder(LHTheme.controlBorder))
            .fixedSize(horizontal: !fills, vertical: true)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(label)
        }
    }

    private struct GoalongSegmentStyle: ButtonStyle {
        let selected: Bool
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.controlSize) private var controlSize
        @Environment(\.isFocused) private var isFocused
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var hovered = false

        func makeBody(configuration: Configuration) -> some View {
            let shape = RoundedRectangle(cornerRadius: LHTheme.controlRadius - 2, style: .continuous)
            let small = controlSize == .small || controlSize == .mini
            configuration.label
                .font(.system(size: small ? 12 : 13, weight: selected ? .semibold : .medium))
                .padding(.horizontal, small ? 10 : 14)
                .frame(minHeight: small ? 22 : 26)
                .foregroundStyle(selected ? LHTheme.text : hovered && isEnabled ? LHTheme.text.opacity(0.85) : LHTheme.secondaryText)
                .background(!selected && hovered && isEnabled ? LHTheme.hoverBackground.opacity(0.6) : .clear, in: shape)
                .overlay { shape.strokeBorder(isFocused ? LHTheme.accent : .clear, lineWidth: 2) }
                .opacity(isEnabled ? 1 : 0.5)
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
                .contentShape(shape)
                .onHover { hovered = $0 }
                .animation(reduceMotion ? nil : LHTheme.hover, value: hovered)
                .animation(reduceMotion ? nil : LHTheme.press, value: configuration.isPressed)
        }
    }

    /// A field with its own label and an optional one-line help, laid out consistently.
    struct GoalongFormField<Field: View>: View {
        let title: String
        var detail: String?
        @ViewBuilder var field: () -> Field

        var body: some View {
            VStack(alignment: .leading, spacing: 7) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    if let detail {
                        Text(detail).font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                field()
            }
        }
    }

    /// Secondary information (privacy, scope, limits) as one deliberate, quiet block
    /// instead of loose paragraphs of fine print.
    struct GoalongNote: View {
        enum Tone { case neutral, privacy, warning }
        let text: String
        var symbol: String?
        var tone: Tone = .neutral

        init(_ text: String, symbol: String? = nil, tone: Tone = .neutral) {
            self.text = text
            self.symbol = symbol
            self.tone = tone
        }

        private var tint: Color {
            switch tone {
            case .neutral: return LHTheme.secondaryText
            case .privacy: return LHTheme.accent
            case .warning: return LHTheme.warning
            }
        }

        var body: some View {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Image(systemName: symbol ?? (tone == .privacy ? "lock" : tone == .warning ? "exclamationmark.triangle" : "info.circle"))
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(tint)
                    .frame(width: 14).accessibilityHidden(true)
                Text(text).font(.system(size: 12)).foregroundStyle(tone == .warning ? LHTheme.warning : LHTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(tone == .warning ? LHTheme.warning.opacity(0.08) : LHTheme.insetBackground,
                        in: RoundedRectangle(cornerRadius: LHTheme.controlRadius, style: .continuous))
        }
    }

    private struct GoalongControlSurface: ViewModifier {
        @Environment(\.colorSchemeContrast) private var contrast
        func body(content: Content) -> some View {
            content
                .background(LHTheme.controlBackground, in: RoundedRectangle(cornerRadius: LHTheme.controlRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: LHTheme.controlRadius, style: .continuous)
                    .strokeBorder(contrast == .increased ? LHTheme.strongSeparator : LHTheme.controlBorder))
        }
    }

    private struct RowHoveredKey: EnvironmentKey { static let defaultValue = false }
    extension EnvironmentValues {
        /// Set by row buttons so their chevron can lean toward where the row leads.
        var goalongRowHovered: Bool {
            get { self[RowHoveredKey.self] }
            set { self[RowHoveredKey.self] = newValue }
        }
    }

    /// Trailing chevron of a navigation row; it steps forward while the row is hovered.
    struct GoalongRowChevron: View {
        var size: CGFloat = 11
        @Environment(\.goalongRowHovered) private var hovered
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            Image(systemName: "chevron.right").font(.system(size: size, weight: .semibold))
                .foregroundStyle(hovered ? LHTheme.accent : LHTheme.secondaryText)
                .offset(x: hovered && !reduceMotion ? 3 : 0)
                .animation(reduceMotion ? nil : LHTheme.press, value: hovered)
                .accessibilityHidden(true)
        }
    }

    private struct NumericTransition: ViewModifier {
        func body(content: Content) -> some View {
            if #available(macOS 14.0, *) { content.contentTransition(.numericText()) } else { content }
        }
    }

    extension View {
        /// Figures roll to their new value instead of blinking when the day changes.
        func goalongNumericTransition() -> some View { modifier(NumericTransition()) }

        /// Raised surface shared by grouped controls (day stepper, segmented groups).
        func goalongControlSurface() -> some View { modifier(GoalongControlSurface()) }

        /// Goalong control chrome for a window, sheet or panel root. Explicit styles still win.
        func goalongControls() -> some View {
            buttonStyle(LHSecondaryButtonStyle())
                .textFieldStyle(GoalongFieldStyle())
        }
    }
#endif
