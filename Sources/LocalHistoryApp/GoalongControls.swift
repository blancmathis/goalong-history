#if os(macOS)
    import AppKit
    import SwiftUI

    /// Goalong's own control chrome, so forms read as one product instead of stock grey
    /// AppKit bezels on forest surfaces. Actions, roles, focus and accessibility stay native.

    /// The one manipulable surface: a tonal fill and a single hairline. No gradient, no rim,
    /// no shadow; depth comes from tone alone.
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
        }
    }

    /// Shared control heights so a primary and a secondary button always sit on one line.
    enum GoalongControlMetrics {
        static func height(_ size: ControlSize) -> CGFloat {
            switch size {
            case .mini: return 22
            case .small: return 26
            case .large: return 36
            default: return 30
            }
        }
        static func font(_ size: ControlSize) -> CGFloat {
            switch size {
            case .mini: return 11
            case .small: return 12
            case .large: return 14
            default: return 13
            }
        }
        static func inset(_ size: ControlSize) -> CGFloat {
            switch size {
            case .mini: return 8
            case .small: return 10
            case .large: return 18
            default: return 13
            }
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

        func makeBody(configuration: Configuration) -> some View {
            let destructive = configuration.role == .destructive
            let shape = RoundedRectangle(cornerRadius: LHTheme.controlRadius, style: .continuous)
            configuration.label
                .font(.system(size: GoalongControlMetrics.font(controlSize), weight: .medium))
                .lineLimit(1)
                .padding(.horizontal, GoalongControlMetrics.inset(controlSize))
                .frame(minHeight: GoalongControlMetrics.height(controlSize))
                .foregroundStyle(!isEnabled ? LHTheme.secondaryText : destructive ? LHTheme.danger : LHTheme.text)
                .background {
                    GoalongSurface(corner: LHTheme.controlRadius,
                                   fill: configuration.isPressed && isEnabled ? LHTheme.pressedBackground
                                       : isHovered && isEnabled ? LHTheme.hoverBackground : LHTheme.controlBackground,
                                   increased: contrast == .increased, highlighted: true)
                }
                .overlay {
                    shape.strokeBorder(isFocused ? LHTheme.accent : .clear, lineWidth: 2).padding(-3)
                }
                .opacity(isEnabled ? 1 : 0.5)
                .scaleEffect(configuration.isPressed && isEnabled && !reduceMotion ? 0.97 : 1)
                .contentShape(shape)
                .onHover { isHovered = $0 }
                .animation(reduceMotion ? nil : LHTheme.hover, value: isHovered)
                .animation(reduceMotion ? nil : LHTheme.press, value: configuration.isPressed)
        }
    }

    /// Third-rank actions ("Corriger", "Voir les 12 usages"): ink text, no chrome at rest, so lime stays
    /// the one action color of a screen.
    /// The hover fill bleeds outside the layout bounds so the label stays on the text column.
    struct LHQuietButtonStyle: ButtonStyle {
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.isFocused) private var isFocused
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var isHovered = false

        func makeBody(configuration: Configuration) -> some View {
            let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
            configuration.label
                .fontWeight(.medium)
                .foregroundStyle(!isEnabled ? LHTheme.secondaryText
                                 : configuration.role == .destructive ? LHTheme.danger : LHTheme.text)
                .padding(.horizontal, 7).padding(.vertical, 4)
                .background(configuration.isPressed && isEnabled ? LHTheme.pressedBackground
                            : isHovered && isEnabled ? LHTheme.hoverBackground : .clear, in: shape)
                .overlay { shape.strokeBorder(isFocused ? LHTheme.accent : .clear, lineWidth: 2) }
                .contentShape(shape)
                .padding(.horizontal, -7).padding(.vertical, -4)
                .opacity(isEnabled ? 1 : 0.6)
                .onHover { isHovered = $0 }
                .animation(reduceMotion ? nil : LHTheme.hover, value: isHovered)
        }
    }

    /// One field chrome for single-line, multi-line and search inputs.
    struct GoalongFieldStyle: TextFieldStyle {
        /// A font and its line height, for a field whose text is not the standard 13 pt system text.
        /// Each case's `lineHeight` is the default line height of its `nsFont` and the height of an AppKit field in that
        /// font: a unit test checks every case. 15 and 16 pt system text fail (a 19 pt field for an 18 pt line).
        enum TextFont: CaseIterable {
            /// Type-to-stop challenge: 14 pt monospaced.
            case monospaced14
            /// Block list name: 14 pt semibold (15 pt drew its text half a point off).
            case semibold14
            /// Focus intent « Je fais… »: 17 pt medium.
            case medium17

            var font: Font {
                switch self {
                case .monospaced14: return .system(size: 14, design: .monospaced)
                case .semibold14: return .system(size: 14, weight: .semibold)
                case .medium17: return .system(size: 17, weight: .medium)
                }
            }

            /// The AppKit font that draws the same text.
            var nsFont: NSFont {
                switch self {
                case .monospaced14: return .monospacedSystemFont(ofSize: 14, weight: .regular)
                case .semibold14: return .systemFont(ofSize: 14, weight: .semibold)
                case .medium17: return .systemFont(ofSize: 17, weight: .medium)
                }
            }

            var lineHeight: CGFloat {
                switch self {
                case .monospaced14: return 17
                case .semibold14: return 17
                case .medium17: return 20
                }
            }
        }

        var textFont: TextFont?

        init(textFont: TextFont? = nil) { self.textFont = textFont }

        // swiftlint:disable:next identifier_name
        func _body(configuration: TextField<Self._Label>) -> some View {
            // The field keeps its own text height: a layout pass that offered it less (15 pt for 16) moved its text
            // half a point off, from one launch to the next (C final UI check).
            GoalongFieldChrome(textFont: textFont) { configuration.textFieldStyle(.plain).fixedSize(horizontal: false, vertical: true) }
        }
    }

    /// Wraps one focusable input (TextField, TextEditor) and draws its focus.
    struct GoalongFieldChrome<Content: View>: View {
        @FocusState private var focused: Bool
        private let content: Content
        private let textFont: GoalongFieldStyle.TextFont?

        init(textFont: GoalongFieldStyle.TextFont? = nil, @ViewBuilder content: () -> Content) {
            self.textFont = textFont
            self.content = content()
        }

        var body: some View {
            content
                .focused($focused)
                .modifier(GoalongFieldSurface(focused: focused, focus: { focused = true }, textFont: textFont))
        }
    }

    /// Sunken field surface: hairline border, lime ring and halo when focused.
    struct GoalongFieldSurface: ViewModifier {
        var focused = false
        /// Clicks on the padding focus the field; clicks on the text stay with the field itself.
        var focus: () -> Void = {}
        /// Replaces the standard text font; the field's padding then fits that line height on whole points.
        var textFont: GoalongFieldStyle.TextFont?
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.controlSize) private var controlSize
        @Environment(\.colorSchemeContrast) private var contrast
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var hovered = false

        func body(content: Content) -> some View {
            let shape = RoundedRectangle(cornerRadius: LHTheme.controlRadius, style: .continuous)
            let small = controlSize == .small || controlSize == .mini
            let minHeight: CGFloat = small ? 26 : 34
            let top: CGFloat = small ? 5 : 8
            // A custom font keeps the top padding; the bottom takes what is left, so top + line + bottom fills the height.
            let bottom: CGFloat = textFont.map { max(top, minHeight - top - $0.lineHeight) } ?? (small ? 6 : 8)
            content
                .font(textFont?.font ?? .system(size: small ? 12 : 13))
                .padding(.horizontal, small ? 9 : 11)
                // A small field's line is 15 pt high: 5 + 15 + 6 fills its 26 pt, so the text starts on a whole point.
                // Centred, it started on a half point and drew half a point off from one launch to the next.
                .padding(.top, top).padding(.bottom, bottom)
                .frame(minHeight: minHeight)
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

    extension View {
        /// A placeholder drawn by Goalong, in the placeholder colour, because the system one is
        /// not always told apart from typed text. Put it on a field that has the Goalong field style.
        func goalongPlaceholder(_ placeholder: String, isEmpty: Bool, alignment: Alignment = .leading,
                                font: Font = .system(size: 13), top: CGFloat = 0,
                                textFont: GoalongFieldStyle.TextFont? = nil) -> some View {
            // A field with a custom text font starts its line 8 pt from the top: the placeholder starts there too,
            // so typed text and placeholder share the same x and baseline.
            overlay(alignment: textFont == nil ? alignment : .topLeading) {
                if isEmpty && !placeholder.isEmpty {
                    Text(placeholder).font(textFont?.font ?? font).foregroundStyle(LHTheme.placeholder)
                        .padding(.horizontal, 11).padding(.top, textFont == nil ? top : 8)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
            }
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
                    // Its own text height, as in GoalongFieldStyle: a layout pass that offers 17 pt for a 16 pt line sizes the field from another font.
                    .fixedSize(horizontal: false, vertical: true)
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

    /// Brand switch: the same corner family as buttons and fields, lime track and ink knob
    /// when on, quiet forest track when off. A real Button underneath keeps keyboard focus
    /// and Space activation.
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
        }
    }

    private struct GoalongSwitchButtonStyle: ButtonStyle {
        let isOn: Bool
        let small: Bool
        @Environment(\.isFocused) private var isFocused
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.colorSchemeContrast) private var contrast
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var hovered = false

        func makeBody(configuration: Configuration) -> some View {
            let width: CGFloat = small ? 30 : 36, height: CGFloat = small ? 18 : 22
            let knob = height - 6
            let radius = height * 0.32
            let track = RoundedRectangle(cornerRadius: radius, style: .continuous)
            // The knob stretches toward its destination while pressed, like a finger pushing it.
            let stretch: CGFloat = configuration.isPressed && !reduceMotion ? 4 : 0
            ZStack(alignment: isOn ? .trailing : .leading) {
                track.fill(isOn ? (hovered && isEnabled ? LHTheme.actionHover : LHTheme.actionBackground)
                           : (hovered && isEnabled ? LHTheme.switchTrackHover : LHTheme.switchTrack))
                    .opacity(isEnabled ? 1 : 0.6)
                if !isOn || contrast == .increased {
                    // The off track keeps a 3:1 edge (WCAG 1.4.11); a disabled switch is dashed and locked.
                    track.strokeBorder(LHTheme.strongSeparator,
                                       style: StrokeStyle(lineWidth: 1, dash: isEnabled ? [] : [3, 2]))
                }
                RoundedRectangle(cornerRadius: radius - 2.5, style: .continuous)
                    .fill(isOn ? LHTheme.onAccent : LHTheme.switchKnob)
                    .frame(width: knob + stretch, height: knob)
                    .padding(.horizontal, 3)
                    .opacity(isEnabled ? 1 : 0.6)
                    .overlay {
                        if !isEnabled {
                            Image(systemName: "lock.fill").font(.system(size: small ? 7 : 8, weight: .bold))
                                .foregroundStyle(isOn ? LHTheme.actionBackground : LHTheme.secondaryText)
                                .accessibilityHidden(true)
                        }
                    }
            }
            .frame(width: width, height: height)
            .overlay { RoundedRectangle(cornerRadius: radius + 3, style: .continuous)
                .strokeBorder(isFocused ? LHTheme.accent : .clear, lineWidth: 2).padding(-3) }
            .contentShape(track)
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

    /// Checkbox in the control family: a small sunken box, lime with an ink check when on.
    /// The whole label toggles it; assistive technologies see a native toggle.
    struct GoalongCheckboxStyle: ToggleStyle {
        func makeBody(configuration: Configuration) -> some View {
            Button { configuration.isOn.toggle() } label: { configuration.label }
                .buttonStyle(GoalongCheckboxButtonStyle(isOn: configuration.isOn))
                .accessibilityRepresentation {
                    Toggle(isOn: configuration.$isOn) { configuration.label }
                }
        }
    }

    private struct GoalongCheckboxButtonStyle: ButtonStyle {
        let isOn: Bool
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.isFocused) private var isFocused
        @Environment(\.colorSchemeContrast) private var contrast
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var hovered = false

        func makeBody(configuration: Configuration) -> some View {
            let box = RoundedRectangle(cornerRadius: 4.5, style: .continuous)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                ZStack {
                    box.fill(isOn ? (hovered && isEnabled ? LHTheme.actionHover : LHTheme.actionBackground) : LHTheme.fieldBackground)
                    if !isOn {
                        box.strokeBorder(contrast == .increased || hovered ? LHTheme.strongSeparator : LHTheme.controlBorder)
                    } else {
                        GoalongCheckShape()
                            .stroke(LHTheme.onAccent, style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                            .padding(4)
                    }
                }
                .frame(width: 16, height: 16)
                .overlay { RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(isFocused ? LHTheme.accent : .clear, lineWidth: 2).padding(-3) }
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.9 : 1)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }
                configuration.label.fixedSize(horizontal: false, vertical: true)
            }
            .opacity(isEnabled ? 1 : 0.5)
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
            .animation(reduceMotion ? nil : LHTheme.press, value: configuration.isPressed)
            .animation(reduceMotion ? nil : LHTheme.hover, value: isOn)
        }
    }

    extension ToggleStyle where Self == GoalongCheckboxStyle {
        static var goalongCheckbox: GoalongCheckboxStyle { GoalongCheckboxStyle() }
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

    /// A field with its own label, an optional one-line help, and a longer explanation
    /// kept behind an info button rather than printed under the label.
    struct GoalongFormField<Field: View>: View {
        let title: String
        var detail: String?
        var help: String?
        @ViewBuilder var field: () -> Field

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(title).font(.system(size: 13, weight: .medium))
                        if let help { GoalongHelpButton(text: help) }
                    }
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

    /// A standing explanation at the top of a tool page: neutral glyph, a title, one or two
    /// sentences and an optional trailing control. Same quiet block as `GoalongNote`.
    struct GoalongBanner<Trailing: View>: View {
        let symbol: String
        let title: String
        let detail: String
        @ViewBuilder var trailing: () -> Trailing

        var body: some View {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol).font(.system(size: 14, weight: .medium)).foregroundStyle(LHTheme.secondaryText)
                    .frame(width: 22, height: 18).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(detail).font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                trailing()
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(LHTheme.insetBackground, in: RoundedRectangle(cornerRadius: LHTheme.controlRadius, style: .continuous))
        }
    }

    extension GoalongBanner where Trailing == EmptyView {
        init(symbol: String, title: String, detail: String) {
            self.init(symbol: symbol, title: title, detail: detail) { EmptyView() }
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

    private struct GoalongDateFieldModifier: ViewModifier {
        let label: String?
        func body(content: Content) -> some View {
            HStack(spacing: 8) {
                if let label { Text(label).font(.system(size: 13)) }
                content.labelsHidden().datePickerStyle(.field).fixedSize().modifier(GoalongFieldSurface())
            }
        }
    }

    /// Pop-up menu for one choice among several, drawn on the Goalong control surface instead of the AppKit bezel.
    struct GoalongMenuPicker<Value: Hashable>: View {
        let title: String
        @Binding var selection: Value
        let options: [(Value, String)]
        @Environment(\.isEnabled) private var isEnabled

        init(_ title: String, selection: Binding<Value>, options: [(Value, String)]) {
            self.title = title
            self._selection = selection
            self.options = options
        }

        var body: some View {
            Menu {
                ForEach(options.indices, id: \.self) { index in
                    let option = options[index]
                    Button { selection = option.0 } label: {
                        if option.0 == selection { Label(option.1, systemImage: "checkmark") } else { Text(option.1) }
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Text(options.first { $0.0 == selection }?.1 ?? title).font(.system(size: 13)).lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(LHTheme.secondaryText).accessibilityHidden(true)
                }
                .padding(.horizontal, 10).frame(minHeight: 28)
                .goalongControlSurface()
                .opacity(isEnabled ? 1 : 0.5)
                .contentShape(Rectangle())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel(title)
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

        /// Date or time field in the Goalong field surface. The label, when given, sits left of the field; without one the
        /// picker keeps its title for VoiceOver only.
        func goalongDateField(label: String? = nil) -> some View { modifier(GoalongDateFieldModifier(label: label)) }

        /// Goalong control chrome for a window, sheet or panel root. Explicit styles still win.
        func goalongControls() -> some View {
            buttonStyle(LHSecondaryButtonStyle())
                .toggleStyle(.goalongCheckbox)
                .textFieldStyle(GoalongFieldStyle())
                .environment(\.locale, GoalongUIFormat.locale)
        }
    }
#endif
