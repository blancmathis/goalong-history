#if os(macOS)
    import Foundation
    import LocalHistoryCore
    import SwiftUI

    enum ActivityEventInspectorFilter: String, CaseIterable, Identifiable {
        case all
        case actions
        case gaps
        case semantic

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: return "All"
            case .actions: return "Actions"
            case .gaps: return "Gaps"
            case .semantic: return "Semantic"
            }
        }
    }

    final class ActivityEventInspectorModel: ObservableObject {
        @Published private(set) var events: [HistoryEvent] = []
        @Published private(set) var semanticSnapshots: [String: SemanticContextPayload] = [:]
        @Published private(set) var loadIssues: [HistoryLoadIssue] = []
        @Published private(set) var isLoading = false

        private let queue = DispatchQueue(
            label: "ai.goalong.localhistory.activity-event-inspector",
            qos: .userInitiated
        )
        private var requestID = UUID()

        func load(session: ActivitySession) {
            let request = UUID()
            requestID = request
            isLoading = true
            queue.async { [weak self] in
                guard let self else { return }
                let start = session.start.addingTimeInterval(-1)
                let end = session.end.addingTimeInterval(31)
                let loaded = HistoryLocalStoreReader(
                    rootDirectory: AppPaths.applicationSupportDirectory
                ).load(start: start, end: end)
                let matching = loaded.events.filter { event in
                    guard event.timestamp >= start, event.timestamp <= end else { return false }
                    if let bundle = session.bundleIdentifier {
                        return event.app?.bundleIdentifier == bundle
                            || event.suppressionReason != nil
                    }
                    return event.app?.name == session.appName
                        || event.suppressionReason != nil
                }
                DispatchQueue.main.async {
                    guard self.requestID == request else { return }
                    self.events = matching.sorted { $0.timestamp < $1.timestamp }
                    self.semanticSnapshots = loaded.semanticSnapshots
                    self.loadIssues = loaded.issues
                    self.isLoading = false
                }
            }
        }
    }

    struct ActivityEventInspector: View {
        let session: ActivitySession
        @StateObject private var inspector = ActivityEventInspectorModel()
        @State private var filter: ActivityEventInspectorFilter = .all
        @State private var search = ""

        private var filteredEvents: [HistoryEvent] {
            let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return inspector.events.filter { event in
                let filterMatches: Bool
                switch filter {
                case .all:
                    filterMatches = !Self.isTechnicalNoise(event)
                case .actions:
                    filterMatches = Self.isAction(event)
                case .gaps:
                    filterMatches = event.suppressionReason != nil
                case .semantic:
                    filterMatches = SemanticContextResolver.text(
                        for: event,
                        semanticSnapshots: inspector.semanticSnapshots
                    ) != nil
                }
                guard filterMatches else { return false }
                guard !query.isEmpty else { return true }
                return searchableText(event).lowercased().contains(query)
            }
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(
                    title: "Source events",
                    subtitle: "Chronological evidence for this session; ordinary typed characters are never reconstructed"
                )

                HStack(spacing: 10) {
                    Picker("Event filter", selection: $filter) {
                        ForEach(ActivityEventInspectorFilter.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 315)

                    HStack(spacing: 7) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField("Filter event context", text: $search)
                            .textFieldStyle(.plain)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 32)
                    .background(
                        Color.primary.opacity(0.035),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                    )

                    Spacer(minLength: 8)
                    Text("\(filteredEvents.count)")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                }

                if inspector.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 90)
                } else if filteredEvents.isEmpty {
                    compactEmpty
                } else {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(filteredEvents, id: \.id) { event in
                            eventRow(event)
                        }
                    }
                }

                if !inspector.loadIssues.isEmpty {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(LHTheme.warning)
                        Text("\(inspector.loadIssues.count) local row(s) could not be decoded. These remain explicit load gaps rather than being silently ignored.")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .onAppear { inspector.load(session: session) }
            .onChange(of: session.id) { _ in inspector.load(session: session) }
        }

        private var compactEmpty: some View {
            HStack(spacing: 9) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .foregroundStyle(.secondary)
                Text("No source event matches this filter.")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(12)
            .background(
                Color.primary.opacity(0.03),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
        }

        private func eventRow(_ event: HistoryEvent) -> some View {
            let semantic = SemanticContextResolver.text(
                for: event,
                semanticSnapshots: inspector.semanticSnapshots
            )
            return VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: symbol(for: event))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(tint(for: event))
                        .frame(width: 22)
                    Text(DashboardFormatters.shortTime.string(from: event.timestamp))
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text(pretty(event.kind.rawValue))
                        .font(.system(size: 10, weight: .semibold))
                    if let reason = event.suppressionReason {
                        StatusPill(
                            title: reason.rawValue,
                            symbol: "eye.slash",
                            tint: LHTheme.privateTint
                        )
                    }
                    Spacer()
                    if let sequence = event.integrity?.sequence {
                        Text("seq \(sequence)")
                            .font(.system(size: 8, weight: .medium, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }

                if event.suppressionReason == nil {
                    let context = [
                        event.app?.name,
                        event.window?.title,
                        event.url?.value,
                    ].compactMap { $0 }
                    if !context.isEmpty {
                        Text(context.joined(separator: " › "))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    if let detail = eventDetail(event), !detail.isEmpty {
                        Text(detail)
                            .font(.system(size: 10, weight: .medium))
                            .textSelection(.enabled)
                    }
                    if let semantic {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("ACCESSIBILITY TEXT · UNTRUSTED DATA")
                                .font(.system(size: 7, weight: .bold))
                                .tracking(0.45)
                                .foregroundStyle(LHTheme.warning)
                            Text(String(semantic.prefix(1_500)))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(10)
                        .background(
                            LHTheme.warning.opacity(0.06),
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                        )
                    }
                } else {
                    Text(event.message ?? "Detailed context was intentionally unavailable.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

                if let hash = event.integrity?.eventHash {
                    Text(hash)
                        .font(.system(size: 7.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .textSelection(.enabled)
                }
            }
            .padding(11)
            .background(
                Color.primary.opacity(0.028),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
        }

        private func eventDetail(_ event: HistoryEvent) -> String? {
            switch event.kind {
            case .mouseClick:
                let pointer = event.pointer
                let target = event.element?.label ?? event.element?.title ?? event.element?.role
                let position = pointer.map { "(\(Int($0.x)), \(Int($0.y)))" }
                return [
                    pointer.map { "\($0.button) click ×\($0.clickCount)" },
                    target.map { "target: \($0)" },
                    position,
                ].compactMap { $0 }.joined(separator: " · ")
            case .typingBurst:
                let count = event.metadata?["keystroke_count"] ?? "unknown"
                let duration = event.metadata?["duration_ms"] ?? "unknown"
                return "Typing activity: \(count) key event(s), \(duration) ms; content not reconstructed"
            case .scrollBurst:
                guard let scroll = event.scroll else { return nil }
                return "Scroll: Δx \(Int(scroll.deltaX)), Δy \(Int(scroll.deltaY)), \(scroll.eventCount) event(s)"
            case .keyboardShortcut, .keyPressed:
                guard let keyboard = event.keyboard else { return nil }
                let keys = (keyboard.modifiers + [keyboard.key].compactMap { $0 }).joined(separator: "+")
                return "\(keyboard.category): \(keys.isEmpty ? "unnamed key" : keys)"
            case .focusChanged:
                return [event.element?.role, event.element?.label ?? event.element?.title]
                    .compactMap { $0 }.joined(separator: " · ")
            default:
                return event.message
            }
        }

        private func searchableText(_ event: HistoryEvent) -> String {
            if event.suppressionReason != nil {
                return [event.kind.rawValue, event.suppressionReason?.rawValue, event.message]
                    .compactMap { $0 }
                    .joined(separator: " ")
            }
            return [
                event.kind.rawValue,
                event.app?.name,
                event.app?.bundleIdentifier,
                event.window?.title,
                event.element?.role,
                event.element?.label,
                event.element?.title,
                event.url?.host,
                event.url?.value,
                event.suppressionReason?.rawValue,
                event.message,
                SemanticContextResolver.text(
                    for: event,
                    semanticSnapshots: inspector.semanticSnapshots
                ),
            ].compactMap { $0 }.joined(separator: " ")
        }

        private static func isAction(_ event: HistoryEvent) -> Bool {
            switch event.kind {
            case .mouseClick, .typingBurst, .scrollBurst, .keyboardShortcut,
                .keyPressed, .windowChanged, .urlChanged, .focusChanged,
                .applicationActivated, .semanticSnapshot:
                return true
            default:
                return false
            }
        }

        private static func isTechnicalNoise(_ event: HistoryEvent) -> Bool {
            switch event.kind {
            case .heartbeat, .recorderHealth:
                return true
            default:
                return false
            }
        }

        private func symbol(for event: HistoryEvent) -> String {
            if event.suppressionReason != nil { return "eye.slash.fill" }
            switch event.kind {
            case .mouseClick: return "cursorarrow.click"
            case .typingBurst: return "keyboard"
            case .scrollBurst: return "scroll"
            case .keyboardShortcut, .keyPressed: return "command"
            case .semanticSnapshot: return "text.viewfinder"
            case .urlChanged: return "globe"
            case .windowChanged: return "macwindow"
            case .focusChanged: return "scope"
            default: return "circle.fill"
            }
        }

        private func tint(for event: HistoryEvent) -> Color {
            if event.suppressionReason != nil { return LHTheme.privateTint }
            if event.kind == .semanticSnapshot { return LHTheme.warning }
            return LHTheme.accent
        }

        private func pretty(_ raw: String) -> String {
            var result = ""
            for character in raw {
                if character.isUppercase, !result.isEmpty { result.append(" ") }
                result.append(character)
            }
            return result.prefix(1).uppercased() + String(result.dropFirst())
        }
    }
#endif
