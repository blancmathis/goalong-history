#if os(macOS)
    import AppKit
    import SwiftUI
    import LocalHistoryCore

    /// The group surface: only for what is manipulated (a list of settings, a form, a
    /// clickable list). What is simply read sits on the page, in a `GoalongSection`.
    struct LHCard<Content: View>: View {
        @Environment(\.colorSchemeContrast) private var contrast
        private let padding: CGFloat
        private let content: Content

        init(padding: CGFloat = LHTheme.cardInset, @ViewBuilder content: () -> Content) {
            self.padding = padding
            self.content = content()
        }

        var body: some View {
            content
                .padding(padding)
                .background(GoalongSurface(corner: LHTheme.cardRadius, increased: contrast == .increased))
                // Full-bleed rows keep their hover inside the rounded corners.
                .clipShape(RoundedRectangle(cornerRadius: LHTheme.cardRadius, style: .continuous))
        }
    }

    /// Content that is read, set directly on the page: a title, an optional quiet action,
    /// then the content with no frame around it.
    struct GoalongSection<Trailing: View, Content: View>: View {
        let title: String
        var subtitle: String?
        @ViewBuilder var trailing: () -> Trailing
        @ViewBuilder var content: () -> Content

        var body: some View {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title).font(LHTheme.sectionTitleFont).tracking(-0.2)
                            .accessibilityAddTraits(.isHeader)
                        if let subtitle {
                            Text(subtitle).font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 8)
                    trailing()
                }
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    extension GoalongSection where Trailing == EmptyView {
        init(title: String, subtitle: String? = nil, @ViewBuilder content: @escaping () -> Content) {
            self.init(title: title, subtitle: subtitle, trailing: { EmptyView() }, content: content)
        }
    }

    extension View {
        /// The one title of a page.
        func goalongPageTitle() -> some View {
            font(LHTheme.pageTitleFont).tracking(LHTheme.pageTitleTracking)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
        }
    }

    /// Whole-row feedback; selection also has a shape cue, not just color.
    struct LHNavigationButtonStyle: ButtonStyle {
        var selected = false
        var cornerRadius: CGFloat = LHTheme.controlRadius
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.isFocused) private var isFocused
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var isHovered = false

        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .environment(\.goalongRowHovered, isHovered && isEnabled)
                .background(
                    !isEnabled ? Color.clear : configuration.isPressed ? LHTheme.pressedBackground
                        : selected ? LHTheme.selectionBackground : isHovered ? LHTheme.hoverBackground : .clear,
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
                .overlay(alignment: .leading) {
                    if selected {
                        Capsule().fill(LHTheme.accent)
                            .frame(width: 3, height: 16).padding(.leading, 4)
                            .accessibilityHidden(true)
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(isFocused ? LHTheme.accent : .clear, lineWidth: 2)
                }
                .opacity(isEnabled ? 1 : 0.45)
                .contentShape(Rectangle())
                .onHover { isHovered = $0 }
                .animation(reduceMotion ? nil : LHTheme.hover, value: isHovered)
                .animation(reduceMotion ? nil : LHTheme.hover, value: configuration.isPressed)
        }
    }

    struct SettingsBackBar: View {
        var title = "Retour aux réglages"
        let onBack: () -> Void

        var body: some View {
            HStack {
                Button(action: onBack) {
                    Label(title, systemImage: "chevron.left")
                        .foregroundStyle(LHTheme.secondaryText)
                        .padding(.horizontal, 8).frame(minHeight: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(LHNavigationButtonStyle(cornerRadius: 6))
                .padding(.leading, -8)
                .keyboardShortcut("[", modifiers: .command)
                .accessibilityHint("Revenir à la page précédente")
                .accessibilityIdentifier("settings-back")
                Spacer()
            }
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, LHTheme.pageInset)
            .padding(.vertical, 8)
            .background(LHTheme.pageBackground)
            // An explicit rule: a Divider in an overlay inherits the root HStack's axis
            // and was drawn as a vertical line across the bar.
            .overlay(alignment: .bottom) { Rectangle().fill(LHTheme.separator).frame(height: 1).opacity(0.5) }
        }
    }

    struct PageHeader<Trailing: View>: View {
        let title: String
        let subtitle: String
        private let trailing: Trailing

        init(title: String, subtitle: String, @ViewBuilder trailing: () -> Trailing) {
            self.title = title
            self.subtitle = subtitle
            self.trailing = trailing()
        }

        var body: some View {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 24) {
                    heading
                    Spacer(minLength: 16)
                    trailing.fixedSize(horizontal: true, vertical: false)
                }
                VStack(alignment: .leading, spacing: 16) {
                    heading
                    trailing
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        private var heading: some View {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).goalongPageTitle()
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(LHTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    extension PageHeader where Trailing == EmptyView {
        init(title: String, subtitle: String) {
            self.init(title: title, subtitle: subtitle) { EmptyView() }
        }
    }

    /// A figure with its label: the label names it, a neutral glyph hints at its kind.
    struct MetricCard: View {
        let title: String
        let value: String
        let detail: String
        let symbol: String
        let tint: Color

        var body: some View {
            LHCard(padding: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: symbol).font(.system(size: 11, weight: .medium)).accessibilityHidden(true)
                        Text(title).font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(LHTheme.secondaryText)
                    Text(value)
                        .font(LHTheme.figureFont(22)).tracking(-0.4)
                        .monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(LHTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .combine)
        }
    }

    /// A state in one glance: the glyph carries the colour, the words stay in ink.
    struct StatusPill: View {
        let title: String
        let symbol: String
        let tint: Color

        var body: some View {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 10, weight: .semibold)).foregroundStyle(tint)
                    .accessibilityHidden(true)
                Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(LHTheme.text)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(LHTheme.insetBackground, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }

    struct AppIconView: View {
        let bundleIdentifier: String?
        let appName: String
        var size: CGFloat = 34

        var body: some View {
            Group {
                if let image = Self.icon(bundleIdentifier: bundleIdentifier) {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                } else {
                    ZStack(alignment: .bottomTrailing) {
                        RoundedRectangle(cornerRadius: size * 0.23, style: .continuous)
                            .fill(LHTheme.insetBackground)
                        RoundedRectangle(cornerRadius: size * 0.23, style: .continuous)
                            .strokeBorder(LHTheme.separator)
                        Text(Self.initial(for: appName))
                            .font(.system(size: size * 0.45, weight: .semibold))
                            .foregroundStyle(LHTheme.secondaryText)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.23, style: .continuous))
        }

        private static let cache: NSCache<NSString, NSImage> = {
            let cache = NSCache<NSString, NSImage>()
            cache.countLimit = 256
            return cache
        }()

        private static func icon(bundleIdentifier: String?) -> NSImage? {
            guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return nil }
            let key = bundleIdentifier as NSString
            if let cached = cache.object(forKey: key) { return cached }

            let aliases: [String: String] = [
                "com.apple.mobilesafari": "com.apple.Safari",
                "com.apple.mobilemail": "com.apple.mail",
                "com.apple.preferences": "com.apple.systempreferences",
                "com.apple.appstore": "com.apple.AppStore",
            ]
            let candidates = [bundleIdentifier, aliases[bundleIdentifier.lowercased()]].compactMap { $0 }
            for candidate in candidates {
                guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: candidate) else {
                    continue
                }
                let icon = NSWorkspace.shared.icon(forFile: url.path)
                cache.setObject(icon, forKey: key)
                return icon
            }
            return nil
        }

        private static func initial(for appName: String) -> String {
            guard let first = GoalongActivityPresentation.displayName(appName).first else {
                return "•"
            }
            return String(first).uppercased()
        }
    }

    /// Centered empty state for a whole pane or list: the thread that has not started,
    /// what is missing, and the one action that helps.
    struct EmptyStateView: View {
        let symbol: String
        let title: String
        let message: String
        var buttonTitle: String?
        var action: (() -> Void)?

        var body: some View {
            VStack(spacing: 10) {
                GoalongThreadPlaceholder(width: 72).padding(.bottom, 6)
                Label(title, systemImage: symbol)
                    .font(LHTheme.cardTitleFont)
                    .multilineTextAlignment(.center)
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(LHTheme.secondaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
                if let buttonTitle, let action {
                    Button(buttonTitle, action: action)
                        .buttonStyle(LHPrimaryButtonStyle())
                        .padding(.top, 6)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(28)
        }
    }

    struct DateSelectionControl: View {
        let date: Date
        let onChange: (Date) -> Void
        /// Steps by a whole period (7 or 28 days in Activité); nil steps one day.
        var onStep: ((Int) -> Void)?
        var previousLabel = "Jour précédent"
        var nextLabel = "Jour suivant"
        var identifierPrefix: String?
        var showsToday = true

        var body: some View {
            HStack(spacing: 8) {
                stepper
                if showsToday && !Calendar.current.isDateInToday(date) {
                    Button("Aujourd’hui") {
                        onChange(Date())
                    }
                    .controlSize(.small)
                    .help("Revenir à aujourd’hui")
                }
            }
        }

        private var stepper: some View {
            HStack(spacing: 2) {
                stepButton(-1, symbol: "chevron.left", label: previousLabel, identifier: "previous-period")
                GoalongCalendarButton(date: date, onChange: onChange)
                    .accessibilityIdentifier(identifierPrefix.map { "\($0)-date-picker" } ?? "")
                stepButton(1, symbol: "chevron.right", label: nextLabel, identifier: "next-period")
                    .disabled(Calendar.current.isDateInToday(date))
            }
            .padding(.horizontal, 3)
            .frame(minHeight: 30)
            .goalongControlSurface()
        }

        private func stepButton(_ direction: Int, symbol: String, label: String, identifier: String) -> some View {
            Button {
                if let onStep { onStep(direction) }
                else if let day = Calendar.current.date(byAdding: .day, value: direction, to: date), day <= Date() { onChange(day) }
            } label: {
                Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).frame(width: 26, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(LHNavigationButtonStyle(cornerRadius: 6))
            .help(label)
            .accessibilityLabel(label)
            .accessibilityIdentifier(identifierPrefix.map { "\($0)-\(identifier)" } ?? "")
        }
    }

    /// The day itself; opens a calendar so any day is two clicks away.
    struct GoalongCalendarButton: View {
        let date: Date
        let onChange: (Date) -> Void
        @State private var showsCalendar = false
        @State private var calendarDate = Date()

        var body: some View {
            Button {
                calendarDate = date
                showsCalendar.toggle()
            } label: {
                Text(date.formatted(.dateTime.day().month(.abbreviated).year().locale(GoalongUIFormat.locale)))
                    .font(.system(size: 13, weight: .medium)).monospacedDigit()
                    .fixedSize()
                    .padding(.horizontal, 8).frame(height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(LHNavigationButtonStyle(cornerRadius: 6))
            .accessibilityLabel("Choisir un jour")
            .accessibilityValue(date.formatted(.dateTime.weekday(.wide).day().month(.wide).year().locale(GoalongUIFormat.locale)))
            .help("Choisir un jour dans le calendrier")
            .popover(isPresented: $showsCalendar, arrowEdge: .bottom) {
                VStack(alignment: .trailing, spacing: 12) {
                    DatePicker("Jour", selection: $calendarDate, in: ...Date(), displayedComponents: .date)
                        .labelsHidden()
                        .datePickerStyle(.graphical)
                        .environment(\.locale, GoalongUIFormat.locale)
                        .fixedSize()
                    Button("Afficher le jour") {
                        onChange(Calendar.current.startOfDay(for: calendarDate))
                        showsCalendar = false
                    }
                    .buttonStyle(LHPrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                }
                .padding(12)
            }
        }
    }

    struct SectionTitle: View {
        let title: String
        let subtitle: String?
        var trailing: AnyView? = nil

        var body: some View {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(LHTheme.cardTitleFont)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                trailing
            }
        }
    }

    struct CategoryBadge: View {
        let category: String?

        var body: some View {
            let label = category.map(Self.prettyCategory) ?? "Non classé"
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(LHTheme.secondaryText)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(LHTheme.insetBackground, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }

        private static let frenchCategories: [String: String] = [
            "software_development": "Développement", "web": "Web", "research": "Recherche",
            "media": "Médias", "document_productivity": "Documents", "design": "Design",
            "communication": "Communication", "other": "Autre", "private_browsing": "Navigation privée",
            "secure_input": "Saisie sécurisée", "excluded": "Exclu", "paused": "En pause",
            "session_unavailable": "Session inactive", "accessibility_unavailable": "Non accessible",
        ]

        static func prettyCategory(_ raw: String) -> String {
            if let french = frenchCategories[raw] { return french }
            return raw
                .split(separator: "_")
                .map { word in
                    let lower = word.lowercased()
                    return lower.prefix(1).uppercased() + lower.dropFirst()
                }
                .joined(separator: " ")
        }
    }

    struct ProgressBar: View {
        let value: Double
        let tint: Color

        var body: some View {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2).fill(LHTheme.separator)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(tint)
                        .frame(width: max(4, proxy.size.width * min(max(value, 0), 1)))
                }
            }
            .frame(height: 4)
        }
    }

    extension RuntimePresentation {
        /// True when the user needs to act or should know that nothing is being recorded.
        var needsAttention: Bool {
            switch state {
            case .permissionsMissing, .inputTapUnavailable, .storageUnavailable: return true
            default: return false
            }
        }

        var storageFailure: CaptureStorageFailureKind? {
            if case .storageUnavailable(let kind) = state { return kind }
            return nil
        }

        private var isBackgroundPrivacyRule: Bool {
            switch state {
            case .suppressed(.privateBrowserWindow), .suppressed(.excludedApplication),
                 .suppressed(.excludedDomain), .suppressed(.secureInput):
                return true
            default:
                return false
            }
        }

        var displayTitle: String {
            if isBackgroundPrivacyRule { return "Suivi local actif" }
            switch state {
            case .recording: return "Suivi local actif"
            case .paused: return "Suivi en pause"
            case .permissionsMissing: return "Accès à configurer"
            case .inputTapUnavailable: return "Interactions indisponibles"
            case .storageUnavailable(.diskFull): return "Disque plein"
            case .storageUnavailable: return "Suivi interrompu"
            case .suppressed(let reason):
                switch reason {
                case .manualPause: return "Suivi en pause"
                case .sessionUnavailable: return "Session Mac inactive"
                case .accessibilityUnavailable: return "Navigateur non accessible"
                case .privateBrowserWindow, .excludedApplication, .excludedDomain, .secureInput:
                    return "Suivi local actif"
                }
            }
        }

        var displayDetail: String {
            if isBackgroundPrivacyRule {
                return "Le suivi respecte vos exclusions. Modifiez-les dans Réglages → Apps et sites."
            }
            switch state {
            case .recording:
                return
                    "L’activité détaillée reste sur ce Mac. Les envois et analyses nécessitent des choix séparés."
            case .paused:
                return "L’enregistrement détaillé est arrêté jusqu’à la reprise."
            case .permissionsMissing:
                return "Vérifiez les accès macOS nécessaires aux enregistrements choisis."
            case .inputTapUnavailable:
                return "Les interactions clavier et souris ne sont pas encore disponibles."
            case .storageUnavailable(.diskFull):
                return "Le disque est plein : rien n’est enregistré pour l’instant. Libérez de l’espace, l’enregistrement reprendra tout seul et la coupure sera signalée dans l’historique."
            case .storageUnavailable(.permissionDenied):
                return "macOS refuse l’écriture dans le dossier d’historique. Goalong réessaie automatiquement ; envoyez un diagnostic si cela persiste."
            case .storageUnavailable:
                return "L’historique ne peut pas être écrit pour l’instant. Goalong réessaie automatiquement ; envoyez un diagnostic si cela persiste."
            case .suppressed(let reason):
                switch reason {
                case .manualPause:
                    return "L’enregistrement est en pause."
                case .sessionUnavailable:
                    return "Le Mac est verrouillé, en veille ou indisponible."
                case .accessibilityUnavailable:
                    return "Goalong ne peut pas lire cette fenêtre de navigateur en toute sécurité : aucun détail n’est enregistré."
                case .privateBrowserWindow, .excludedApplication, .excludedDomain, .secureInput:
                    return "Goalong continue d’enregistrer l’activité autorisée pendant que vos règles de confidentialité s’appliquent."
                }
            }
        }

        var displaySymbol: String {
            if isBackgroundPrivacyRule { return "record.circle.fill" }
            switch state {
            case .recording: return "record.circle.fill"
            case .paused: return "pause.circle.fill"
            case .permissionsMissing: return "exclamationmark.triangle.fill"
            case .inputTapUnavailable: return "keyboard.badge.ellipsis"
            case .storageUnavailable: return "externaldrive.badge.exclamationmark"
            case .suppressed: return "eye.slash.fill"
            }
        }

        var displayTint: Color {
            if isBackgroundPrivacyRule { return LHTheme.success }
            switch state {
            case .recording: return LHTheme.success
            case .paused: return LHTheme.warning
            case .permissionsMissing, .inputTapUnavailable, .storageUnavailable: return LHTheme.danger
            case .suppressed: return LHTheme.privateTint
            }
        }
    }

    enum DashboardFormatters {
        static let dayTitle: DateFormatter = {
            let formatter = DateFormatter()
            formatter.locale = GoalongUIFormat.locale
            formatter.setLocalizedDateFormatFromTemplate("EEEEMMMMd")
            return formatter
        }()

        static let shortTime: DateFormatter = {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            return formatter
        }()

        static let fullTimestamp: DateFormatter = {
            let formatter = DateFormatter()
            formatter.locale = GoalongUIFormat.locale
            formatter.dateStyle = .medium
            formatter.timeStyle = .medium
            return formatter
        }()

        static let byteCount: ByteCountFormatter = {
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            return formatter
        }()

        /// French notation with non-breaking spaces: « 42 min », « 2 h », « 5 h 07 ».
        static func duration(minutes: Int) -> String {
            guard minutes > 0 else { return "0\u{00A0}min" }
            let hours = minutes / 60
            let remainder = minutes % 60
            if hours == 0 { return "\(remainder)\u{00A0}min" }
            if remainder == 0 { return "\(hours)\u{00A0}h" }
            return "\(hours)\u{00A0}h\u{00A0}" + String(format: "%02d", remainder)
        }

        static func duration(seconds: TimeInterval) -> String {
            duration(minutes: max(1, Int(round(seconds / 60))))
        }

        static func percentage(_ numerator: Int, _ denominator: Int) -> String {
            guard denominator > 0 else { return "0%" }
            return "\(Int((Double(numerator) / Double(denominator) * 100).rounded()))%"
        }
    }
#endif
