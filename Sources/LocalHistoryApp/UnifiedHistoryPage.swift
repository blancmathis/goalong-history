#if os(macOS)
    import AgentActivity
    import AppleScreenTime
    import SwiftUI

    struct UnifiedHistoryPage: View {
        @ObservedObject private var model: DashboardViewModel
        @ObservedObject private var agents: AgentActivityRuntime
        @StateObject private var screenTime: AppleScreenTimeDashboardModel
        @State private var source: HistorySource = .all

        init(model: DashboardViewModel) {
            _model = ObservedObject(wrappedValue: model)
            _agents = ObservedObject(wrappedValue: model.agentActivityRuntime)
            _screenTime = StateObject(
                wrappedValue: AppleScreenTimeDashboardModel(
                    rootDirectory: AppPaths.screenTimeDirectory,
                    deviceID: model.deviceID,
                    selectedDay: model.selectedDay
                )
            )
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                header

                Picker("History source", selection: $source) {
                    ForEach(HistorySource.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 620)
                .padding(.horizontal, 24)
                .padding(.bottom, 16)

                Divider()

                sourceView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(LHTheme.pageBackground)
            .onAppear {
                synchronizeSources(with: model.selectedDay)
                screenTime.setActive(model.dashboardIsVisible && source == .all)
                agents.scanNow(analyzeSelectedDay: true)
            }
            .onDisappear {
                screenTime.setActive(false)
            }
            .onChange(of: model.dashboardIsVisible) { visible in
                screenTime.setActive(visible && source == .all)
            }
            .onChange(of: model.selectedDay) { day in
                synchronizeSources(with: day)
            }
            .onChange(of: source) { next in
                screenTime.setActive(model.dashboardIsVisible && next == .all)
                if next == .conversations {
                    agents.scanNow(analyzeSelectedDay: true)
                }
            }
        }

        private var header: some View {
            PageHeader(
                eyebrow: Calendar.current.isDateInToday(model.selectedDay) ? "Today" : "Daily history",
                title: "History",
                subtitle: "Computer activity, Apple Screen Time and AI conversations in one place."
            ) {
                HStack(spacing: 10) {
                    DateSelectionControl(date: model.selectedDay, onChange: selectDay)
                    Button {
                        model.selectSection(.share)
                    } label: {
                        Label("Share day", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.bordered)
                    Button {
                        refresh()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isRefreshing || agents.isScanning || screenTime.isBusy)
                    .help("Refresh the selected day")
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 28)
            .padding(.bottom, 18)
        }

        @ViewBuilder private var sourceView: some View {
            switch source {
            case .all:
                allSourcesView
            case .computer:
                ActivityPage(
                    model: model,
                    initialMode: .computerHistory,
                    showsModePicker: false,
                    showsHeader: false
                )
            case .screenTime:
                GoalongScreenTimePage(model: model, showsHeader: false)
            case .conversations:
                AgentActivityPage(agents: agents, showsHeader: false)
            }
        }

        private var allSourcesView: some View {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    sourceSummary
                    combinedTimeline
                }
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .padding(.bottom, 40)
            }
        }

        private var sourceSummary: some View {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Day at a glance")
                        .font(.system(size: 16, weight: .semibold))
                    Spacer()
                    Text("All sources")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                HStack(alignment: .top, spacing: 22) {
                    summaryValue(
                        title: "COMPUTER HISTORY",
                        value: DashboardFormatters.duration(minutes: model.snapshot.activeMinutes),
                        detail: "\(model.snapshot.sessions.count) recorded sessions"
                    )
                    Divider().frame(height: 48)
                    summaryValue(
                        title: "SCREEN TIME",
                        value: screenTime.summary.map { duration($0.totalScreenOnDuration) } ?? "—",
                        detail: screenTime.summary.map {
                            "\($0.deviceSummaries.count) Apple device\($0.deviceSummaries.count == 1 ? "" : "s")"
                        } ?? screenTime.status.title
                    )
                    Divider().frame(height: 48)
                    summaryValue(
                        title: "AI CONVERSATIONS",
                        value: agents.overview.sessionCount.formatted(),
                        detail: "\(agents.overview.visibleMessageCount) useful messages"
                    )
                }

                if let applications = screenTime.summary?.topApplications, !applications.isEmpty {
                    Divider()
                    HStack(spacing: 8) {
                        Text("Most used")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                        ForEach(Array(applications.prefix(3))) { application in
                            Text("\(application.resolvedName) · \(duration(application.duration))")
                                .font(.system(size: 10, weight: .medium))
                                .lineLimit(1)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 5)
                                .background(Color.primary.opacity(0.05), in: Capsule())
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(18)
            .background(LHTheme.cardBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.primary.opacity(0.07), lineWidth: 1)
            )
        }

        private func summaryValue(title: String, value: String, detail: String) -> some View {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text(detail)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        private var combinedTimeline: some View {
            let entries = timelineEntries

            return VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Timeline")
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                    Spacer()
                    Text("\(entries.count) items")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                LHCard(padding: 0) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if entries.isEmpty {
                            VStack(spacing: 10) {
                                Image(systemName: "clock.badge.questionmark")
                                    .font(.system(size: 26, weight: .medium))
                                    .foregroundStyle(.secondary)
                                Text("No history for this day")
                                    .font(.system(size: 14, weight: .semibold))
                                Text("Use the source filters above to review setup or availability details.")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, minHeight: 220)
                            .padding(24)
                        } else {
                            ForEach(Array(entries.enumerated()), id: \.element.id) { index, item in
                                timelineRow(item)
                                if index < entries.count - 1 {
                                    Divider().padding(.leading, 72)
                                }
                            }
                        }
                    }
                }
            }
        }

        private func timelineRow(_ item: HistoryTimelineEntry) -> some View {
            HStack(alignment: .top, spacing: 14) {
                Text(Self.timeFormatter.string(from: item.date))
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(width: 42, alignment: .trailing)

                Image(systemName: item.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(item.tint)
                    .frame(width: 28, height: 28)
                    .background(item.tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Text(item.detail)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 13)
        }

        private var timelineEntries: [HistoryTimelineEntry] {
            let computer = model.snapshot.sessions.map { session in
                HistoryTimelineEntry(
                    id: "computer:\(session.id)",
                    date: session.start,
                    title: session.appName,
                    detail: [
                        session.windowTitle,
                        session.host,
                        duration(session.duration),
                    ]
                    .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: " · "),
                    symbol: "macwindow",
                    tint: LHTheme.teal
                )
            }

            let conversations = agents.overview.captures.compactMap { capture -> HistoryTimelineEntry? in
                let date = capture.summary.startedAt
                    ?? capture.index.conversationStartedAt
                    ?? capture.sourceModifiedAt
                    ?? capture.capturedAt
                guard Calendar.current.isDate(date, inSameDayAs: model.selectedDay) else { return nil }
                let title = capture.summary.title?.trimmingCharacters(in: .whitespacesAndNewlines)
                let resolvedTitle = title.flatMap { $0.isEmpty ? nil : $0 }
                    ?? "\(capture.provider.displayName) conversation"
                let messageCount = capture.summary.visibleMessages.count
                let availability = capture.availability == .available
                    ? nil
                    : capture.availability.displayName
                return HistoryTimelineEntry(
                    id: "agent:\(capture.id)",
                    date: date,
                    title: resolvedTitle,
                    detail: [
                        capture.provider.displayName,
                        messageCount > 0 ? "\(messageCount) useful messages" : "Indexed directly from source",
                        availability,
                    ]
                    .compactMap { $0 }
                    .joined(separator: " · "),
                    symbol: "bubble.left.and.bubble.right",
                    tint: LHTheme.accent
                )
            }

            return (computer + conversations)
                .sorted { lhs, rhs in
                    if lhs.date != rhs.date { return lhs.date > rhs.date }
                    return lhs.id < rhs.id
                }
        }

        private func selectDay(_ day: Date) {
            model.selectDay(day)
            synchronizeSources(with: day)
        }

        private func synchronizeSources(with day: Date) {
            if screenTime.selectedDay != day {
                screenTime.selectDay(day)
            }
            if agents.selectedDay != day {
                agents.selectDay(day)
            }
        }

        private func refresh() {
            model.refreshEverything()
            screenTime.refresh()
            agents.scanNow(analyzeSelectedDay: true)
        }

        private func duration(_ seconds: TimeInterval) -> String {
            let minutes = max(0, Int(seconds / 60))
            return DashboardFormatters.duration(minutes: minutes)
        }

        private static let timeFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.locale = .current
            formatter.dateFormat = "HH:mm"
            return formatter
        }()
    }

    private enum HistorySource: String, CaseIterable, Identifiable {
        case all
        case computer
        case screenTime
        case conversations

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: return "All"
            case .computer: return "Computer History"
            case .screenTime: return "Screen Time"
            case .conversations: return "AI conversations"
            }
        }
    }

    private struct HistoryTimelineEntry: Identifiable {
        let id: String
        let date: Date
        let title: String
        let detail: String
        let symbol: String
        let tint: Color
    }
#endif
