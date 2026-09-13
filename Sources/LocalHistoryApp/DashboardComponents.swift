#if os(macOS)
    import AppKit
    import SwiftUI
    import LocalHistoryCore

    enum LHTheme {
        static let accent = Color(red: 0.20, green: 0.48, blue: 0.96)
        static let success = Color(red: 0.16, green: 0.66, blue: 0.42)
        static let warning = Color(red: 0.94, green: 0.58, blue: 0.16)
        static let danger = Color(red: 0.91, green: 0.30, blue: 0.32)
        static let privateTint = Color(red: 0.48, green: 0.35, blue: 0.86)
        static let teal = Color(red: 0.12, green: 0.65, blue: 0.67)
        static let sidebarBackground = surface(light: 0.96, dark: 0.10)
        static let pageBackground = surface(light: 0.985, dark: 0.125)
        static let cardBackground = surface(light: 1.0, dark: 0.145)
        static let elevatedBackground = Color(nsColor: .textBackgroundColor)
        static let separator = Color(nsColor: .separatorColor)
        static let pageInset: CGFloat = 28

        private static func surface(light: CGFloat, dark: CGFloat) -> Color {
            Color(nsColor: NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                return NSColor(white: isDark ? dark : light, alpha: 1)
            })
        }
    }

    struct LHCard<Content: View>: View {
        private let padding: CGFloat
        private let content: Content

        init(padding: CGFloat = 18, @ViewBuilder content: () -> Content) {
            self.padding = padding
            self.content = content()
        }

        var body: some View {
            content
                .padding(padding)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(LHTheme.cardBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
                        )
                )
        }
    }

    /// Shared whole-row feedback for sidebar and Settings destinations.
    struct LHNavigationButtonStyle: ButtonStyle {
        var selected = false
        var cornerRadius: CGFloat = 7
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.isFocused) private var isFocused
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var isHovered = false

        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .background(
                    Color.primary.opacity(
                        !isEnabled ? 0 : configuration.isPressed ? 0.12
                            : selected ? 0.085 : isHovered ? 0.045 : 0
                    ),
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(isFocused ? LHTheme.accent : .clear, lineWidth: 2)
                )
                .opacity(isEnabled ? 1 : 0.45)
                .contentShape(Rectangle())
                .onHover { isHovered = $0 }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovered)
        }
    }

    struct SettingsBackBar: View {
        let onBack: () -> Void

        var body: some View {
            HStack {
                Button(action: onBack) {
                    Label("Back to Settings", systemImage: "chevron.left")
                }
                .buttonStyle(.borderless)
                .controlSize(.regular)
                .keyboardShortcut("[", modifiers: .command)
                .accessibilityHint("Return to the Settings overview")
                Spacer()
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, LHTheme.pageInset)
            .padding(.vertical, 12)
            .background(LHTheme.pageBackground)
            .overlay(alignment: .bottom) { Divider().opacity(0.5) }
        }
    }

    struct PageHeader<Trailing: View>: View {
        let eyebrow: String?
        let title: String
        let subtitle: String
        private let trailing: Trailing

        init(
            eyebrow: String? = nil,
            title: String,
            subtitle: String,
            @ViewBuilder trailing: () -> Trailing
        ) {
            self.eyebrow = eyebrow
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
                if let eyebrow {
                    Text(eyebrow)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Text(title)
                    .font(.system(size: 24, weight: .semibold))
                    .fixedSize(horizontal: true, vertical: false)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    extension PageHeader where Trailing == EmptyView {
        init(eyebrow: String? = nil, title: String, subtitle: String) {
            self.init(eyebrow: eyebrow, title: title, subtitle: subtitle) { EmptyView() }
        }
    }

    struct MetricCard: View {
        let title: String
        let value: String
        let detail: String
        let symbol: String
        let tint: Color

        var body: some View {
            LHCard(padding: 16) {
                VStack(alignment: .leading, spacing: 13) {
                    HStack {
                        Image(systemName: symbol)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(tint)
                            .frame(width: 30, height: 30)
                            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        Spacer()
                        Text(title)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    Text(value)
                        .font(.system(size: 25, weight: .semibold))
                        .monospacedDigit()
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    struct StatusPill: View {
        let title: String
        let symbol: String
        let tint: Color

        var body: some View {
            Label(title, systemImage: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(tint)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
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
                            .fill(LHTheme.accent.opacity(0.12))
                        Text(Self.initial(for: appName))
                            .font(.system(size: size * 0.45, weight: .bold, design: .rounded))
                            .foregroundStyle(LHTheme.accent)
                        Image(systemName: "app.fill")
                            .font(.system(size: size * 0.22, weight: .semibold))
                            .foregroundStyle(LHTheme.accent)
                            .padding(size * 0.07)
                            .background(.regularMaterial, in: Circle())
                            .offset(x: size * 0.05, y: size * 0.05)
                    }
                }
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.23, style: .continuous))
        }

        private static let cache = NSCache<NSString, NSImage>()

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
            guard let first = appName.trimmingCharacters(in: .whitespacesAndNewlines).first else {
                return "•"
            }
            return String(first).uppercased()
        }
    }

    struct EmptyStateView: View {
        let symbol: String
        let title: String
        let message: String
        var buttonTitle: String?
        var action: (() -> Void)?

        var body: some View {
            VStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 62, height: 62)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
                if let buttonTitle, let action {
                    Button(buttonTitle, action: action)
                        .buttonStyle(.borderedProminent)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(30)
        }
    }

    struct DateSelectionControl: View {
        let date: Date
        let onChange: (Date) -> Void
        @State private var showsCalendar = false
        @State private var calendarDate = Date()

        var body: some View {
            HStack(spacing: 8) {
                Button {
                    if let previous = Calendar.current.date(byAdding: .day, value: -1, to: date) {
                        onChange(previous)
                    }
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.borderless)
                .help("Previous day")
                .accessibilityLabel("Previous day")

                Button {
                    calendarDate = date
                    showsCalendar.toggle()
                } label: {
                    Text(date.formatted(.dateTime.day().month(.abbreviated).year()))
                        .font(.system(size: 13, weight: .medium))
                        .fixedSize()
                        .padding(.horizontal, 4)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Choose day")
                .accessibilityValue(date.formatted(date: .complete, time: .omitted))
                .help("Choose a day from the calendar")
                .popover(isPresented: $showsCalendar, arrowEdge: .bottom) {
                    VStack(alignment: .trailing, spacing: 12) {
                        DatePicker("Day", selection: $calendarDate, in: ...Date(), displayedComponents: .date)
                            .labelsHidden()
                            .datePickerStyle(.graphical)
                            .fixedSize()
                        Button("Show day") {
                            onChange(Calendar.current.startOfDay(for: calendarDate))
                            showsCalendar = false
                        }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                    }
                    .padding(12)
                }

                if !Calendar.current.isDateInToday(date) {
                    Button("Today") {
                        onChange(Date())
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("Return to today")
                }

                Button {
                    if let next = Calendar.current.date(byAdding: .day, value: 1, to: date), next <= Date() {
                        onChange(next)
                    }
                } label: {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.borderless)
                .disabled(Calendar.current.isDateInToday(date))
                .help("Next day")
                .accessibilityLabel("Next day")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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
                        .font(.system(size: 15, weight: .semibold))
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
        let isWork: Bool?

        var body: some View {
            let label = category.map(Self.prettyCategory) ?? "Unclassified"
            let tint =
                isWork == true
                ? LHTheme.success : (category?.contains("private") == true ? LHTheme.privateTint : LHTheme.accent)
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(tint.opacity(0.11), in: Capsule())
        }

        static func prettyCategory(_ raw: String) -> String {
            raw
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
                    Capsule().fill(Color.primary.opacity(0.07))
                    Capsule()
                        .fill(tint)
                        .frame(width: max(4, proxy.size.width * min(max(value, 0), 1)))
                }
            }
            .frame(height: 6)
        }
    }

    extension RuntimePresentation {
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
            if isBackgroundPrivacyRule { return "Recording locally" }
            switch state {
            case .recording: return "Recording locally"
            case .paused: return "Recording paused"
            case .permissionsMissing: return "Setup required"
            case .inputTapUnavailable: return "Input monitoring inactive"
            case .suppressed(let reason):
                switch reason {
                case .manualPause: return "Recording paused"
                case .sessionUnavailable: return "Mac session unavailable"
                case .accessibilityUnavailable: return "Browser context unavailable"
                case .privateBrowserWindow, .excludedApplication, .excludedDomain, .secureInput:
                    return "Recording locally"
                }
            }
        }

        var displayDetail: String {
            if isBackgroundPrivacyRule {
                return "Goalong keeps recording eligible activity while your monitoring and privacy rules run in the background. Manage them in Activity → Apps & websites."
            }
            switch state {
            case .recording:
                return
                    "Detailed activity stays on this Mac. Only opaque commitments are sent when verification is enabled."
            case .paused:
                return "No detailed activity is being captured until you resume. The gap remains visible in coverage."
            case .permissionsMissing:
                return "Accessibility and Input Monitoring are both required for reliable capture."
            case .inputTapUnavailable:
                return "macOS granted permissions, but the keyboard and mouse event monitor is not running yet."
            case .suppressed(let reason):
                switch reason {
                case .manualPause:
                    return "Capture is paused."
                case .sessionUnavailable:
                    return "The Mac is locked, asleep or otherwise unavailable."
                case .accessibilityUnavailable:
                    return "Goalong cannot safely inspect this browser window, so it records no details."
                case .privateBrowserWindow, .excludedApplication, .excludedDomain, .secureInput:
                    return "Goalong keeps recording eligible activity while your privacy rules run in the background."
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
            case .suppressed: return "eye.slash.fill"
            }
        }

        var displayTint: Color {
            if isBackgroundPrivacyRule { return LHTheme.success }
            switch state {
            case .recording: return LHTheme.success
            case .paused: return LHTheme.warning
            case .permissionsMissing, .inputTapUnavailable: return LHTheme.danger
            case .suppressed: return LHTheme.privateTint
            }
        }
    }

    enum DashboardFormatters {
        static let dayTitle: DateFormatter = {
            let formatter = DateFormatter()
            formatter.dateFormat = "EEEE, MMMM d"
            return formatter
        }()

        static let shortTime: DateFormatter = {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            return formatter
        }()

        static let fullTimestamp: DateFormatter = {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .medium
            return formatter
        }()

        static let byteCount: ByteCountFormatter = {
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            return formatter
        }()

        static func duration(minutes: Int) -> String {
            guard minutes > 0 else { return "0m" }
            let hours = minutes / 60
            let remainder = minutes % 60
            if hours == 0 { return "\(remainder)m" }
            if remainder == 0 { return "\(hours)h" }
            return "\(hours)h \(remainder)m"
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
