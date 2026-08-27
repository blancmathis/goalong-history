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
        static let sidebarBackground = Color(nsColor: .windowBackgroundColor)
        static let pageBackground = Color(nsColor: .underPageBackgroundColor)
        static let cardBackground = Color(nsColor: .controlBackgroundColor)
        static let elevatedBackground = Color(nsColor: .textBackgroundColor)
        static let separator = Color(nsColor: .separatorColor)
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
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(LHTheme.cardBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
                        )
                )
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
            HStack(alignment: .center, spacing: 20) {
                VStack(alignment: .leading, spacing: 5) {
                    if let eyebrow {
                        Text(eyebrow.uppercased())
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .tracking(0.7)
                            .foregroundStyle(.secondary)
                    }
                    Text(title)
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 16)
                trailing
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
                        .font(.system(size: 25, weight: .bold, design: .rounded))
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
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(tint.opacity(0.12), in: Capsule())
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

                DatePicker(
                    "Day",
                    selection: Binding(get: { date }, set: onChange),
                    in: ...Date(),
                    displayedComponents: .date
                )
                .labelsHidden()
                .datePickerStyle(.field)

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
                            .font(.system(size: 11))
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
