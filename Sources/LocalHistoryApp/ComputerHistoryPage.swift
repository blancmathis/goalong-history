#if os(macOS)
    import AppKit
    import Combine
    import LocalHistoryCore
    import SwiftUI

    enum ComputerHistorySourceStatus: Equatable {
        case unverified
        case checking
        case available
        case absent
        case inaccessible(String)
    }

    final class ComputerHistoryPageModel: ObservableObject {
        @Published private(set) var memory: ComputerHistoryDayMemory?
        @Published private(set) var answer: ComputerHistoryAnswer?
        @Published private(set) var isLoading = false
        @Published private(set) var isAnswering = false
        @Published private(set) var errorMessage: String?
        @Published private(set) var sourceStatus: ComputerHistorySourceStatus = .unverified
        @Published var question = ""

        private let store: ComputerHistoryStore
        private let refreshRuntime: ActivityAnalysisRefreshServing
        private let storedMemoryLoader: (Date) -> ComputerHistoryDayMemory?
        private let queue = DispatchQueue(
            label: "ai.goalong.localhistory.computer-history-page",
            qos: .userInitiated
        )
        private var refreshRequestID = UUID()

        init(
            store: ComputerHistoryStore = ComputerHistoryStore(),
            refreshRuntime: ActivityAnalysisRefreshServing = ActivityAnalysisRuntime.shared,
            storedMemoryLoader: ((Date) -> ComputerHistoryDayMemory?)? = nil
        ) {
            self.store = store
            self.refreshRuntime = refreshRuntime
            self.storedMemoryLoader = storedMemoryLoader ?? { store.loadStored(for: $0) }
        }

        func refresh(day: Date, forceRebuild: Bool = false) {
            let normalized = Calendar.current.startOfDay(for: day)
            let requestID = UUID()
            refreshRequestID = requestID
            errorMessage = nil
            let retainedMemory = storedMemoryLoader(normalized)
            if !forceRebuild, let retainedMemory {
                // Display the bounded derived view immediately, but still verify the
                // source revision asynchronously. An exact cache hit performs no body
                // read and lets the UI distinguish retained data from a live source.
                memory = retainedMemory
                isLoading = false
            } else {
                isLoading = true
            }
            sourceStatus = .checking
            refreshRuntime.refresh(day: normalized, force: forceRebuild) { [weak self] result in
                let publish = { [weak self] in
                    guard let self, self.refreshRequestID == requestID else { return }
                    switch result {
                    case .success(let cycleResult):
                        self.memory = self.storedMemoryLoader(normalized) ?? retainedMemory
                        self.sourceStatus = cycleResult.sourceAbsent ? .absent : .available
                    case .failure(let error):
                        if Self.wasInvalidatedByHistoryClear(error) {
                            self.memory = nil
                            self.sourceStatus = .unverified
                        } else {
                            self.memory = self.storedMemoryLoader(normalized) ?? retainedMemory
                            self.sourceStatus = Self.sourceStatus(for: error)
                        }
                        self.errorMessage = error.localizedDescription
                    }
                    self.isLoading = false
                }
                if Thread.isMainThread {
                    publish()
                } else {
                    DispatchQueue.main.async(execute: publish)
                }
            }
        }

        private static func sourceStatus(for error: Error) -> ComputerHistorySourceStatus {
            guard let cycleError = error as? ActivityAnalysisCycleError else {
                return .unverified
            }
            switch cycleError {
            case .sourceInaccessible, .sourceChangedDuringRead, .oversizedJSONLine,
                .reentrantCycle:
                return .inaccessible(error.localizedDescription)
            }
        }

        private static func wasInvalidatedByHistoryClear(_ error: Error) -> Bool {
            guard let refreshError = error as? ActivityAnalysisRefreshError else {
                return false
            }
            switch refreshError {
            case .temporarilySuspended, .invalidatedByHistoryClear:
                return true
            case .runtimeUnavailable:
                return false
            }
        }

        func ask() {
            let query = question.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty, !isAnswering else { return }
            isAnswering = true
            errorMessage = nil
            queue.async { [weak self] in
                guard let self else { return }
                let answer = self.store.answer(query, maximumDays: 30)
                DispatchQueue.main.async {
                    self.answer = answer
                    self.isAnswering = false
                }
            }
        }

        func clearAnswer() {
            answer = nil
        }

        func open(_ resource: ComputerHistoryResourceReference) {
            if let localPath = resource.localPath {
                NSWorkspace.shared.open(URL(fileURLWithPath: localPath))
                return
            }
            if let raw = resource.canonicalURI, let url = URL(string: raw) {
                NSWorkspace.shared.open(url)
            }
        }

        func revealMemoryFiles(for day: Date) {
            let directory = AppPaths.applicationSupportDirectory
                .appendingPathComponent("computer-history", isDirectory: true)
            let files = store.memoryFileURLs(for: day)
                .filter { FileManager.default.fileExists(atPath: $0.path) }
            if files.isEmpty {
                NSWorkspace.shared.open(directory)
            } else {
                NSWorkspace.shared.activateFileViewerSelecting(files)
            }
        }
    }

    struct ComputerHistoryTenMinuteGroup: Identifiable {
        struct AppSlice: Identifiable {
            let id: String
            let name: String
            let bundleIdentifier: String?
            let activeSeconds: TimeInterval
        }

        struct SessionSlice: Identifiable {
            let id: String
            let start: Date
            let end: Date
            let appName: String
            let bundleIdentifier: String?
            let context: String
            let isSuppressed: Bool
            let sourceSessionCount: Int

            var duration: TimeInterval { end.timeIntervalSince(start) }
        }

        let id: Date
        let start: Date
        let end: Date
        let activeSeconds: TimeInterval
        let apps: [AppSlice]
        let sessions: [SessionSlice]
        let appChangeCount: Int
        let recordedEventCount: Int
        let inputEventCount: Int

        static func build(
            sessions: [ActivitySession],
            day: Date,
            calendar: Calendar = .current
        ) -> [ComputerHistoryTenMinuteGroup] {
            let dayStart = calendar.startOfDay(for: day)
            guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else {
                return []
            }

            var segmentsByWindow: [Date: [Segment]] = [:]
            for session in sessions {
                let clippedStart = max(session.start, dayStart)
                let clippedEnd = min(session.end.addingTimeInterval(30), dayEnd)
                guard clippedEnd > clippedStart else { continue }

                var windowStart = tenMinuteStart(for: clippedStart, calendar: calendar)
                while windowStart < clippedEnd {
                    guard let windowEnd = calendar.date(
                        byAdding: .minute,
                        value: 10,
                        to: windowStart
                    ) else { break }
                    let segmentStart = max(clippedStart, windowStart)
                    let segmentEnd = min(clippedEnd, windowEnd)
                    if segmentEnd > segmentStart {
                        let normalizedAppName = session.appName
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            .lowercased()
                        let appKey = "name:\(normalizedAppName)"
                        segmentsByWindow[windowStart, default: []].append(
                            Segment(
                                session: session,
                                appKey: appKey,
                                start: segmentStart,
                                end: segmentEnd
                            )
                        )
                    }
                    windowStart = windowEnd
                }
            }

            return segmentsByWindow.keys.sorted(by: >).compactMap { windowStart in
                guard
                    let windowEnd = calendar.date(
                        byAdding: .minute,
                        value: 10,
                        to: windowStart
                    ),
                    let windowSegments = segmentsByWindow[windowStart]
                else { return nil }

                let ordered = windowSegments.sorted {
                    if $0.start == $1.start { return $0.end < $1.end }
                    return $0.start < $1.start
                }
                let groupedApps = Dictionary(grouping: ordered, by: \.appKey)
                let exclusiveDurations = exclusiveDurationByApp(ordered)
                let apps = groupedApps.compactMap { key, appSegments -> AppSlice? in
                    guard let representative = appSegments.first else { return nil }
                    return AppSlice(
                        id: key,
                        name: representative.session.appName,
                        bundleIdentifier: representative.session.bundleIdentifier,
                        activeSeconds: exclusiveDurations[key] ?? 0
                    )
                }
                .sorted {
                    if $0.activeSeconds == $1.activeSeconds {
                        return $0.name.localizedCaseInsensitiveCompare($1.name)
                            == .orderedAscending
                    }
                    return $0.activeSeconds > $1.activeSeconds
                }

                let startingSessions = ordered.filter {
                    $0.session.start >= windowStart && $0.session.start < windowEnd
                }
                var sessionSlices: [SessionSlice] = []
                var previousAppKey: String?
                for segment in ordered {
                    let suppressed = segment.session.suppressionReason != nil
                    let context = suppressed
                        ? "Private or suppressed activity"
                        : segment.session.windowTitle
                            ?? segment.session.host
                            ?? segment.session.category.map(CategoryBadge.prettyCategory)
                            ?? "No detailed context recorded"
                    if
                        previousAppKey == segment.appKey,
                        let previous = sessionSlices.last,
                        segment.start <= previous.end.addingTimeInterval(30)
                    {
                        sessionSlices[sessionSlices.count - 1] = SessionSlice(
                            id: previous.id,
                            start: previous.start,
                            end: max(previous.end, segment.end),
                            appName: previous.appName,
                            bundleIdentifier: previous.bundleIdentifier
                                ?? segment.session.bundleIdentifier,
                            context: previous.isSuppressed || suppressed
                                ? "Private or suppressed activity"
                                : context,
                            isSuppressed: previous.isSuppressed || suppressed,
                            sourceSessionCount: previous.sourceSessionCount + 1
                        )
                    } else {
                        sessionSlices.append(
                            SessionSlice(
                                id: "\(segment.session.id)-\(windowStart.timeIntervalSince1970)",
                                start: segment.start,
                                end: segment.end,
                                appName: segment.session.appName,
                                bundleIdentifier: segment.session.bundleIdentifier,
                                context: context,
                                isSuppressed: suppressed,
                                sourceSessionCount: 1
                            )
                        )
                    }
                    previousAppKey = segment.appKey
                }

                var appChangeCount = 0
                for index in sessionSlices.indices.dropFirst()
                where sessionSlices[index - 1].appName.caseInsensitiveCompare(
                    sessionSlices[index].appName
                ) != .orderedSame {
                    appChangeCount += 1
                }

                return ComputerHistoryTenMinuteGroup(
                    id: windowStart,
                    start: windowStart,
                    end: windowEnd,
                    activeSeconds: unionDuration(ordered),
                    apps: apps,
                    sessions: sessionSlices,
                    appChangeCount: appChangeCount,
                    recordedEventCount: startingSessions.reduce(0) {
                        $0 + $1.session.eventCount
                    },
                    inputEventCount: startingSessions.reduce(0) {
                        $0 + $1.session.inputEventCount
                    }
                )
            }
        }

        private struct Segment {
            let session: ActivitySession
            let appKey: String
            let start: Date
            let end: Date
        }

        private static func tenMinuteStart(for date: Date, calendar: Calendar) -> Date {
            var components = calendar.dateComponents(
                [.era, .year, .month, .day, .hour, .minute],
                from: date
            )
            components.minute = ((components.minute ?? 0) / 10) * 10
            components.second = 0
            components.nanosecond = 0
            return calendar.date(from: components) ?? date
        }

        private static func unionDuration(_ segments: [Segment]) -> TimeInterval {
            guard let first = segments.sorted(by: { $0.start < $1.start }).first else {
                return 0
            }
            let sorted = segments.sorted {
                if $0.start == $1.start { return $0.end < $1.end }
                return $0.start < $1.start
            }
            var total: TimeInterval = 0
            var currentStart = first.start
            var currentEnd = first.end
            for segment in sorted.dropFirst() {
                if segment.start <= currentEnd {
                    currentEnd = max(currentEnd, segment.end)
                } else {
                    total += currentEnd.timeIntervalSince(currentStart)
                    currentStart = segment.start
                    currentEnd = segment.end
                }
            }
            return total + currentEnd.timeIntervalSince(currentStart)
        }

        private static func exclusiveDurationByApp(
            _ segments: [Segment]
        ) -> [String: TimeInterval] {
            let boundaries = Set(segments.flatMap { [$0.start, $0.end] }).sorted()
            guard boundaries.count >= 2 else { return [:] }

            var durations: [String: TimeInterval] = [:]
            for index in 0 ..< boundaries.count - 1 {
                let intervalStart = boundaries[index]
                let intervalEnd = boundaries[index + 1]
                guard intervalEnd > intervalStart else { continue }

                let activeSegments = segments.filter {
                    $0.start < intervalEnd && $0.end > intervalStart
                }
                guard let foreground = activeSegments.max(by: {
                    if $0.start == $1.start { return $0.end < $1.end }
                    return $0.start < $1.start
                }) else { continue }
                durations[foreground.appKey, default: 0] += intervalEnd.timeIntervalSince(
                    intervalStart
                )
            }
            return durations
        }
    }

    final class ComputerHistoryTimelineModel: ObservableObject {
        typealias BuildGroups = ([ActivitySession], Date) -> [ComputerHistoryTenMinuteGroup]

        @Published private(set) var groups: [ComputerHistoryTenMinuteGroup] = []
        @Published private(set) var isLoading = false

        private let queue: DispatchQueue
        private let buildGroups: BuildGroups
        private struct SourceRevision: Equatable {
            let generation: UInt64
            let day: Date
            let sessionCount: Int
        }

        private var currentSourceRevision: SourceRevision?
        private var pendingSourceRevision: SourceRevision?
        private var pendingToken: RequestToken?
        private var pendingWorkItem: DispatchWorkItem?

        init(
            queue: DispatchQueue = DispatchQueue(
                label: "ai.goalong.localhistory.computer-history-timeline",
                qos: .utility
            ),
            buildGroups: @escaping BuildGroups = { sessions, day in
                ComputerHistoryTenMinuteGroup.build(sessions: sessions, day: day)
            }
        ) {
            self.queue = queue
            self.buildGroups = buildGroups
        }

        func refresh(sessions: [ActivitySession], day: Date, revision: UInt64) {
            let normalizedDay = Calendar.current.startOfDay(for: day)
            let sourceRevision = SourceRevision(
                generation: revision,
                day: normalizedDay,
                sessionCount: sessions.count
            )
            if currentSourceRevision == sourceRevision { return }
            if pendingSourceRevision == sourceRevision { return }

            pendingToken?.cancel()
            pendingWorkItem?.cancel()
            let token = RequestToken()
            pendingToken = token
            pendingSourceRevision = sourceRevision
            isLoading = true
            if let currentSourceRevision, currentSourceRevision.day != normalizedDay {
                groups = []
            }

            let buildGroups = self.buildGroups
            let workItem = DispatchWorkItem { [weak self] in
                guard !token.isCancelled else { return }
                let groups = buildGroups(sessions, normalizedDay)
                guard !token.isCancelled else { return }
                DispatchQueue.main.async { [weak self] in
                    guard
                        let self,
                        self.pendingToken === token,
                        !token.isCancelled
                    else { return }
                    self.groups = groups
                    self.currentSourceRevision = sourceRevision
                    self.pendingSourceRevision = nil
                    self.pendingToken = nil
                    self.pendingWorkItem = nil
                    self.isLoading = false
                }
            }
            pendingWorkItem = workItem
            queue.asyncAfter(deadline: .now() + .milliseconds(30), execute: workItem)
        }

        func clear() {
            pendingToken?.cancel()
            pendingToken = nil
            pendingWorkItem?.cancel()
            pendingWorkItem = nil
            currentSourceRevision = nil
            pendingSourceRevision = nil
            isLoading = false
            groups = []
        }

        private final class RequestToken {
            private let lock = NSLock()
            private var cancelled = false

            var isCancelled: Bool {
                lock.lock()
                defer { lock.unlock() }
                return cancelled
            }

            func cancel() {
                lock.lock()
                cancelled = true
                lock.unlock()
            }
        }
    }

    struct ComputerHistoryPage: View {
        @ObservedObject var model: ComputerHistoryPageModel
        @StateObject private var timelineModel = ComputerHistoryTimelineModel()
        let day: Date
        let snapshot: DashboardDaySnapshot
        let snapshotGeneration: UInt64
        let isSnapshotLoading: Bool
        let fullContextEnabled: Bool
        let openSourceJSON: () -> Void
        let deleteEpisode: (ComputerHistoryEpisode) -> Void
        @State private var episodePendingDeletion: ComputerHistoryEpisode?

        private let metricColumns = [
            GridItem(.adaptive(minimum: 165, maximum: 250), spacing: 12)
        ]

        var body: some View {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    recordingStateCard
                    sourceStatusCard
                    historySection
                }
                .padding(.bottom, 8)
            }
            .alert(item: $episodePendingDeletion) { episode in
                Alert(
                    title: Text("Delete this Computer History item?"),
                    message: Text(
                        "Goalong will resolve this item against its original local journal, delete only its exact source events and linked semantic snapshots, then rebuild the affected day. Minute seals, receipts, Screen Time and Agent Activity remain."
                    ),
                    primaryButton: .destructive(Text("Delete item")) {
                        deleteEpisode(episode)
                    },
                    secondaryButton: .cancel()
                )
            }
            .task(id: timelineRefreshID) {
                refreshTimeline()
            }
            .onDisappear(perform: timelineModel.clear)
        }

        private struct TimelineRefreshID: Hashable {
            let selectedDay: Date
            let snapshotDay: Date
            let snapshotGeneration: UInt64
            let sessionCount: Int
            let isSnapshotLoading: Bool
        }

        private var timelineRefreshID: TimelineRefreshID {
            TimelineRefreshID(
                selectedDay: Calendar.current.startOfDay(for: day),
                snapshotDay: Calendar.current.startOfDay(for: snapshot.day),
                snapshotGeneration: snapshotGeneration,
                sessionCount: snapshot.sessions.count,
                isSnapshotLoading: isSnapshotLoading
            )
        }

        private var tenMinuteGroups: [ComputerHistoryTenMinuteGroup] {
            timelineModel.groups
        }

        private func refreshTimeline() {
            guard Calendar.current.isDate(snapshot.day, inSameDayAs: day) else {
                timelineModel.clear()
                return
            }
            timelineModel.refresh(
                sessions: snapshot.sessions,
                day: day,
                revision: snapshotGeneration
            )
        }

        private var recordingStateCard: some View {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    Circle()
                        .fill(LHTheme.success.opacity(0.14))
                        .frame(width: 34, height: 34)
                    Circle()
                        .fill(LHTheme.success)
                        .frame(width: 9, height: 9)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Recorded locally")
                        .font(.system(size: 13, weight: .semibold))
                    Text(recordingSummary)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 16)
                StatusPill(
                    title: fullContextEnabled ? "Detailed context" : "Activity metadata",
                    symbol: fullContextEnabled ? "text.viewfinder" : "rectangle.dashed",
                    tint: fullContextEnabled ? LHTheme.success : LHTheme.teal
                )
            }
            .padding(.horizontal, 17)
            .padding(.vertical, 14)
            .background(
                LHTheme.cardBackground,
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.primary.opacity(0.07), lineWidth: 1)
            )
        }

        private var recordingSummary: String {
            let events = snapshot.eventCount.formatted()
            if isPreparingTimeline {
                return "Preparing factual 10-minute windows from \(events) source events."
            }
            let windows = tenMinuteGroups.count.formatted()
            return "\(events) source events shown as \(windows) factual 10-minute windows. No AI summary is generated."
        }

        private var historySection: some View {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 9) {
                    Text("History")
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                    Image(systemName: "info.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .help(
                            "Durations are observed foreground intervals. They do not prove attention, identity, authorship or productivity."
                        )
                    Spacer(minLength: 12)
                    if isPreparingTimeline {
                        ProgressView()
                            .controlSize(.small)
                            .help("Grouping recorded activity")
                    } else {
                        Text("\(tenMinuteGroups.count) windows")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    Button(action: openSourceJSON) {
                        Label("Reveal source JSONL", systemImage: "curlybraces")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .help("Reveal the original read-only event journal for this day in Finder")
                }

                timelineCard
            }
        }

        private var timelineCard: some View {
            LHCard(padding: 0) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text(
                            Calendar.current.isDateInToday(day)
                                ? "Today"
                                : DashboardFormatters.dayTitle.string(from: day)
                        )
                        .font(.system(size: 14, weight: .semibold))
                        Spacer()
                        Text(DashboardFormatters.duration(minutes: snapshot.activeMinutes))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 17)

                    Divider()

                    if isPreparingTimeline {
                        VStack(spacing: 11) {
                            ProgressView()
                                .controlSize(.regular)
                            Text("Grouping recorded activity…")
                                .font(.system(size: 14, weight: .semibold))
                            Text("This runs locally only when a new daily snapshot is available.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 240)
                        .padding(24)
                    } else if tenMinuteGroups.isEmpty {
                        VStack(spacing: 11) {
                            Image(systemName: "clock.badge.questionmark")
                                .font(.system(size: 28, weight: .medium))
                                .foregroundStyle(.secondary)
                            Text("No recorded activity for this day")
                                .font(.system(size: 14, weight: .semibold))
                            Text("Keep Goalong History running, then refresh this page after using an app.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 240)
                        .padding(24)
                    } else {
                        ForEach(Array(tenMinuteGroups.enumerated()), id: \.element.id) {
                            index, group in
                            ComputerHistoryTenMinuteRow(
                                group: group,
                                isLast: index == tenMinuteGroups.count - 1
                            )
                        }
                    }
                }
            }
        }

        private var isPreparingTimeline: Bool {
            tenMinuteGroups.isEmpty && (isSnapshotLoading || timelineModel.isLoading)
        }

        @ViewBuilder private var sourceStatusCard: some View {
            switch model.sourceStatus {
            case .absent:
                sourceStatusNotice(
                    title: "Source journal absent",
                    message: model.memory == nil
                        ? "No raw event journal exists for this day. "
                            + "There is no retained Computer History to show."
                        : "The raw event journal for this day is no longer present. "
                            + "The last known-good Computer History remains available and was not deleted.",
                    symbol: "doc.badge.ellipsis",
                    tint: LHTheme.warning
                )
            case .inaccessible(let message):
                sourceStatusNotice(
                    title: "Source journal inaccessible",
                    message: model.memory == nil
                        ? "Goalong could not safely read the raw event journal: \(message)"
                        : "Showing the last known-good Computer History. "
                            + "Goalong could not safely read the raw event journal: \(message)",
                    symbol: "exclamationmark.lock.fill",
                    tint: LHTheme.warning
                )
            case .unverified, .checking, .available:
                EmptyView()
            }
        }

        private func sourceStatusNotice(
            title: String,
            message: String,
            symbol: String,
            tint: Color
        ) -> some View {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                    Text(message)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(15)
            .background(
                tint.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
        }

        private var contextStateCard: some View {
            Group {
                if fullContextEnabled {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "brain.head.profile.fill")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(LHTheme.success)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Full causal context is enabled")
                                .font(.system(size: 12, weight: .semibold))
                            Text(
                                "Eligible interactions can be linked as prior context → action → after → settled. Near-event context is never mislabeled as guaranteed pre-action state. Private browsing, exclusions, Secure Input and protected fields remain suppressed."
                            )
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        sourceReadinessPill
                    }
                    .padding(15)
                    .background(
                        LHTheme.success.opacity(0.07),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                    )
                } else {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(LHTheme.warning)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Metadata-only analysis is active")
                                .font(.system(size: 12, weight: .semibold))
                            Text(
                                "Apps, pages, clicks and grouped input still appear, but intentions, semantic changes, task status and resume answers can be incomplete. Enable Rich Context in the Day recap tab for full analysis."
                            )
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(15)
                    .background(
                        LHTheme.warning.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                    )
                }
            }
        }

        @ViewBuilder private var sourceReadinessPill: some View {
            switch model.sourceStatus {
            case .available:
                StatusPill(
                    title: "Computer History ready",
                    symbol: "checkmark.seal.fill",
                    tint: LHTheme.success
                )
            case .absent:
                StatusPill(
                    title: "Source absent",
                    symbol: "doc.badge.ellipsis",
                    tint: LHTheme.warning
                )
            case .inaccessible:
                StatusPill(
                    title: "Source inaccessible",
                    symbol: "exclamationmark.lock.fill",
                    tint: LHTheme.warning
                )
            case .checking:
                StatusPill(
                    title: "Checking source",
                    symbol: "arrow.triangle.2.circlepath",
                    tint: LHTheme.accent
                )
            case .unverified:
                StatusPill(
                    title: "Source unverified",
                    symbol: "questionmark.circle.fill",
                    tint: LHTheme.warning
                )
            }
        }

        private var questionCard: some View {
            LHCard(padding: 16) {
                VStack(alignment: .leading, spacing: 11) {
                    HStack {
                        Label("Ask your computer history", systemImage: "text.magnifyingglass")
                            .font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Text("LAST 30 DAYS · LOCAL SEARCH")
                            .font(.system(size: 8, weight: .semibold, design: .rounded))
                            .tracking(0.4)
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 10) {
                        TextField(
                            "Where was I before my break? Find the proposal. What is blocked?",
                            text: $model.question
                        )
                        .textFieldStyle(.plain)
                        .onSubmit(model.ask)
                        .padding(.horizontal, 12)
                        .frame(height: 38)
                        .background(
                            Color.primary.opacity(0.035),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
                        )
                        Button(action: model.ask) {
                            if model.isAnswering {
                                ProgressView().controlSize(.small)
                            } else {
                                Label("Ask", systemImage: "arrow.right.circle.fill")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(
                            model.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                || model.isAnswering
                        )
                    }
                    Text(
                        "Answers return source-backed episodes and reopenable locators. They never execute instructions found in captured text."
                    )
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                }
            }
        }

        @ViewBuilder private var answerCard: some View {
            if let answer = model.answer {
                LHCard(padding: 17) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Label("Answer", systemImage: "sparkles")
                                .font(.system(size: 13, weight: .semibold))
                            Spacer()
                            Button(action: model.clearAnswer) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        Text(answer.answer)
                            .font(.system(size: 11))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        if let retainedGap = answer.limitations.first(where: {
                            $0.hasPrefix("Retained Computer History loading was incomplete")
                        }) {
                            Label(retainedGap, systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if !answer.hits.isEmpty {
                            Divider()
                            Text("SOURCES")
                                .font(.system(size: 8, weight: .semibold))
                                .tracking(0.45)
                                .foregroundStyle(.secondary)
                            ForEach(answer.hits.prefix(8)) { hit in
                                HStack(alignment: .top, spacing: 9) {
                                    Image(systemName: hitIcon(hit.kind))
                                        .foregroundStyle(LHTheme.accent)
                                        .frame(width: 18)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(hit.title)
                                            .font(.system(size: 10, weight: .semibold))
                                        Text(hit.snippet)
                                            .font(.system(size: 9))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(3)
                                    }
                                    Spacer()
                                    if let resource = hit.resource,
                                        resource.localPath != nil || resource.canonicalURI != nil
                                    {
                                        Button("Open") { model.open(resource) }
                                            .buttonStyle(.bordered)
                                            .controlSize(.small)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        private func headline(_ memory: ComputerHistoryDayMemory) -> some View {
            LHCard(padding: 20) {
                HStack(alignment: .top, spacing: 16) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(LHTheme.privateTint)
                        .frame(width: 56, height: 56)
                        .background(
                            LHTheme.privateTint.opacity(0.10),
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                        )
                    VStack(alignment: .leading, spacing: 6) {
                        Text(memory.title)
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                        Text(memory.executiveSummary)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    Button("Reveal memory files") {
                        model.revealMemoryFiles(for: day)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }

        private func coverage(_ memory: ComputerHistoryDayMemory) -> some View {
            LazyVGrid(columns: metricColumns, alignment: .leading, spacing: 12) {
                MetricCard(
                    title: "EPISODES",
                    value: "\(memory.coverage.episodeCount)",
                    detail: episodeCoverageDetail(memory),
                    symbol: "list.bullet.rectangle.portrait.fill",
                    tint: LHTheme.accent
                )
                MetricCard(
                    title: "INTERACTIONS",
                    value: "\(memory.coverage.linkedInteractionCount)",
                    detail: "No representative-minute collapse",
                    symbol: "cursorarrow.motionlines.click",
                    tint: LHTheme.teal
                )
                MetricCard(
                    title: "BEFORE / AFTER",
                    value: semanticPairValue(memory.coverage),
                    detail: "Interactions with both semantic states",
                    symbol: "arrow.left.and.right.square.fill",
                    tint: LHTheme.success
                )
                MetricCard(
                    title: "SOURCES",
                    value: "\(memory.coverage.resourceCount)",
                    detail: resourceCoverageDetail(memory),
                    symbol: "link.circle.fill",
                    tint: LHTheme.privateTint
                )
            }
        }

        private func episodeCoverageDetail(_ memory: ComputerHistoryDayMemory) -> String {
            guard let retained = memory.coverage.retainedEpisodeCount,
                retained < memory.coverage.episodeCount
            else {
                return "Task-shaped chronological work"
            }
            return "\(retained) representative episodes retained"
        }

        private func resourceCoverageDetail(_ memory: ComputerHistoryDayMemory) -> String {
            guard let retained = memory.coverage.retainedResourceCount else {
                return "Files, pages, conversations and issues"
            }
            return "\(retained) representative source links retained"
        }

        private func episodes(_ memory: ComputerHistoryDayMemory) -> some View {
            let resourcesByID = Dictionary(
                uniqueKeysWithValues: memory.resources.map { ($0.id, $0) }
            )
            return VStack(alignment: .leading, spacing: 10) {
                SectionTitle(
                    title: "Causal timeline",
                    subtitle: "Every retained action stays chronological and source-backed"
                )
                if memory.episodes.isEmpty {
                    compactEmpty("No causal episode could be reconstructed")
                } else {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(memory.episodes) { episode in
                            ComputerHistoryEpisodeCard(
                                episode: episode,
                                resources: resourcesByID,
                                openResource: model.open,
                                requestDeletion: {
                                    episodePendingDeletion = episode
                                }
                            )
                        }
                    }
                }
            }
        }

        private func sources(_ memory: ComputerHistoryDayMemory) -> some View {
            LHCard(padding: 17) {
                VStack(alignment: .leading, spacing: 12) {
                    SectionTitle(
                        title: "Source index",
                        subtitle: "Likely original resources with confidence and reopenable locators"
                    )
                    if memory.resources.isEmpty {
                        compactEmpty("No stable source locator was exposed")
                    } else {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 260), spacing: 10)],
                            alignment: .leading,
                            spacing: 10
                        ) {
                            ForEach(memory.resources) { resource in
                                Button {
                                    model.open(resource)
                                } label: {
                                    HStack(alignment: .top, spacing: 10) {
                                        Image(systemName: resourceIcon(resource.kind))
                                            .foregroundStyle(LHTheme.accent)
                                            .frame(width: 28, height: 28)
                                            .background(
                                                LHTheme.accent.opacity(0.09),
                                                in: RoundedRectangle(cornerRadius: 8)
                                            )
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(resource.title)
                                                .font(.system(size: 10, weight: .semibold))
                                                .lineLimit(2)
                                            Text(
                                                resource.localPath
                                                    ?? resource.canonicalURI
                                                    ?? "Locator unavailable"
                                            )
                                            .font(.system(size: 8, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                            Text(resourceConfidenceLabel(resource))
                                                .font(.system(size: 8, weight: .medium))
                                                .foregroundStyle(.tertiary)
                                        }
                                        Spacer(minLength: 0)
                                    }
                                    .padding(11)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(
                                        Color.primary.opacity(0.03),
                                        in: RoundedRectangle(cornerRadius: 11)
                                    )
                                }
                                .buttonStyle(.plain)
                                .disabled(resource.localPath == nil && resource.canonicalURI == nil)
                            }
                        }
                    }
                }
            }
        }

        @ViewBuilder private func suggestions(_ memory: ComputerHistoryDayMemory) -> some View {
            if !memory.suggestions.isEmpty {
                LHCard(padding: 17) {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionTitle(
                            title: "Suggested skills and automations",
                            subtitle: "Only repeated, source-backed action sequences appear here"
                        )
                        ForEach(memory.suggestions) { suggestion in
                            HStack(alignment: .top, spacing: 11) {
                                Image(
                                    systemName: suggestion.kind == .automation
                                        ? "gearshape.2.fill"
                                        : "wand.and.stars"
                                )
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(
                                    suggestion.kind == .automation
                                        ? LHTheme.warning
                                        : LHTheme.privateTint
                                )
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(suggestion.title)
                                        .font(.system(size: 11, weight: .semibold))
                                    Text(suggestion.rationale)
                                        .font(.system(size: 9))
                                        .foregroundStyle(.secondary)
                                    Text(suggestion.suggestedPrompt)
                                        .font(.system(size: 9, design: .monospaced))
                                        .textSelection(.enabled)
                                        .padding(8)
                                        .background(
                                            Color.primary.opacity(0.035),
                                            in: RoundedRectangle(cornerRadius: 8)
                                        )
                                }
                                Spacer(minLength: 0)
                                Text("\(Int((suggestion.confidence * 100).rounded()))%")
                                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }

        private func evidence(_ memory: ComputerHistoryDayMemory) -> some View {
            LHCard(padding: 15) {
                HStack(alignment: .top, spacing: 11) {
                    Image(systemName: "checkmark.shield.fill")
                        .foregroundStyle(LHTheme.success)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Evidence and uncertainty")
                            .font(.system(size: 11, weight: .semibold))
                        Text(
                            "\(memory.coverage.sourceEventCount) source events · \(memory.coverage.semanticSnapshotCount) semantic snapshots · \(memory.coverage.suppressedEventCount) suppressed events. Episode statuses are bounded interpretations; foreground presence never proves attention, identity, authorship, productivity or completion."
                        )
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }

        private var loadingState: some View {
            LHCard {
                VStack(spacing: 13) {
                    ProgressView()
                    Text("Reconstructing causal episodes…")
                        .font(.system(size: 12, weight: .semibold))
                    Text(
                        "Goalong is linking actions, semantic changes, resources, statuses and provenance locally."
                    )
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 300)
            }
        }

        private var emptyState: some View {
            LHCard {
                EmptyStateView(
                    symbol: "point.3.connected.trianglepath.dotted",
                    title: "No causal history yet",
                    message: model.errorMessage
                        ?? "Keep Goalong running and interact with eligible apps. The causal memory is rebuilt automatically as events arrive.",
                    buttonTitle: "Build again",
                    action: { model.refresh(day: day) }
                )
                .frame(minHeight: 320)
            }
        }

        private func compactEmpty(_ title: String) -> some View {
            HStack(spacing: 9) {
                Image(systemName: "tray")
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(11)
            .background(
                Color.primary.opacity(0.03),
                in: RoundedRectangle(cornerRadius: 9)
            )
        }

        private func semanticPairValue(_ coverage: ComputerHistoryCoverage) -> String {
            guard let ratio = coverage.semanticPairCoverage else { return "—" }
            return "\(Int((ratio * 100).rounded()))%"
        }

        private func hitIcon(_ kind: ComputerHistorySearchHitKind) -> String {
            switch kind {
            case .episode: return "list.bullet.rectangle"
            case .resource: return "link"
            case .suggestion: return "wand.and.stars"
            }
        }

        private func resourceIcon(_ kind: ComputerHistoryResourceKind) -> String {
            switch kind {
            case .file: return "doc.fill"
            case .webPage: return "globe"
            case .conversation: return "bubble.left.and.bubble.right.fill"
            case .issue: return "exclamationmark.bubble.fill"
            case .document: return "doc.text.fill"
            case .terminalSession: return "terminal.fill"
            case .application: return "app.fill"
            case .unknown: return "questionmark.square.fill"
            }
        }

        private func resourceConfidenceLabel(
            _ resource: ComputerHistoryResourceReference
        ) -> String {
            let percentage = Int((resource.locatorConfidence * 100).rounded())
            return "\(resource.kind.rawValue) · \(percentage)% confidence"
        }
    }

    private struct ComputerHistoryTenMinuteRow: View {
        let group: ComputerHistoryTenMinuteGroup
        let isLast: Bool
        @State private var expanded = false

        var body: some View {
            HStack(alignment: .top, spacing: 0) {
                Text(DashboardFormatters.shortTime.string(from: group.start))
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .frame(width: 78, alignment: .trailing)
                    .padding(.top, 22)
                    .padding(.trailing, 13)

                VStack(spacing: 0) {
                    Circle()
                        .fill(Color.secondary)
                        .frame(width: 8, height: 8)
                        .padding(.top, 26)
                    if !isLast {
                        Rectangle()
                            .fill(Color.secondary.opacity(0.22))
                            .frame(width: 1)
                            .frame(maxHeight: .infinity)
                    }
                }
                .frame(width: 20)

                VStack(alignment: .leading, spacing: 11) {
                    Button {
                        withAnimation(.easeOut(duration: 0.18)) {
                            expanded.toggle()
                        }
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(headline)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Text(factSummary)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 12)
                            Image(systemName: expanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.top, 3)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 13) {
                            ForEach(group.apps) { app in
                                HStack(spacing: 7) {
                                    AppIconView(
                                        bundleIdentifier: app.bundleIdentifier,
                                        appName: app.name,
                                        size: 23
                                    )
                                    Text(app.name)
                                        .lineLimit(1)
                                    Text(durationLabel(app.activeSeconds))
                                        .foregroundStyle(.secondary)
                                }
                                .font(.system(size: 10, weight: .medium))
                                .accessibilityElement(children: .combine)
                            }
                        }
                    }

                    if expanded {
                        Divider()
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(group.sessions) { session in
                                HStack(alignment: .top, spacing: 10) {
                                    AppIconView(
                                        bundleIdentifier: session.bundleIdentifier,
                                        appName: session.appName,
                                        size: 26
                                    )
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack(spacing: 7) {
                                            Text(session.appName)
                                                .font(.system(size: 11, weight: .semibold))
                                            if session.isSuppressed {
                                                Image(systemName: "eye.slash.fill")
                                                    .font(.system(size: 8))
                                                    .foregroundStyle(LHTheme.privateTint)
                                            }
                                        }
                                        Text(session.context)
                                            .font(.system(size: 10))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                        Text(
                                            sessionDetailSummary(session)
                                        )
                                        .font(.system(size: 9, weight: .medium, design: .rounded))
                                        .foregroundStyle(.tertiary)
                                    }
                                    Spacer(minLength: 0)
                                }
                            }
                        }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .padding(.leading, 14)
                .padding(.trailing, 20)
                .padding(.vertical, 20)
            }
            .accessibilityElement(children: .contain)
        }

        private var headline: String {
            let names = group.apps.map(\.name)
            switch names.count {
            case 0:
                return "Recorded activity"
            case 1:
                return names[0]
            case 2:
                return "\(names[0]) and \(names[1])"
            default:
                return "\(names[0]), \(names[1]) and \(names.count - 2) more"
            }
        }

        private var factSummary: String {
            var facts = [
                "\(durationLabel(group.activeSeconds)) observed",
                "\(group.apps.count) \(group.apps.count == 1 ? "app" : "apps")",
                "\(group.appChangeCount) app \(group.appChangeCount == 1 ? "change" : "changes")",
            ]
            if group.inputEventCount > 0 {
                facts.append("\(group.inputEventCount.formatted()) inputs")
            } else if group.recordedEventCount > 0 {
                facts.append("\(group.recordedEventCount.formatted()) source events")
            }
            return facts.joined(separator: " · ")
        }

        private func durationLabel(_ seconds: TimeInterval) -> String {
            guard seconds >= 60 else { return "<1m" }
            let roundedMinutes = Int((seconds / 60).rounded())
            return DashboardFormatters.duration(minutes: max(1, roundedMinutes))
        }

        private func sessionDetailSummary(
            _ session: ComputerHistoryTenMinuteGroup.SessionSlice
        ) -> String {
            let interval =
                "\(DashboardFormatters.shortTime.string(from: session.start))–"
                + DashboardFormatters.shortTime.string(from: session.end)
            let details = session.sourceSessionCount == 1
                ? "1 source detail"
                : "\(session.sourceSessionCount) source details"
            return "\(interval) · \(durationLabel(session.duration)) · \(details)"
        }
    }

    private struct ComputerHistoryEpisodeCard: View {
        let episode: ComputerHistoryEpisode
        let resources: [String: ComputerHistoryResourceReference]
        let openResource: (ComputerHistoryResourceReference) -> Void
        let requestDeletion: () -> Void
        @State private var expanded = false

        var body: some View {
            LHCard(padding: 16) {
                VStack(alignment: .leading, spacing: 11) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
                    } label: {
                        HStack(alignment: .top, spacing: 11) {
                            VStack(alignment: .leading, spacing: 5) {
                                HStack(spacing: 8) {
                                    Text(episode.title)
                                        .font(.system(size: 13, weight: .semibold))
                                    StatusPill(
                                        title: episode.status.rawValue,
                                        symbol: statusSymbol,
                                        tint: statusTint
                                    )
                                }
                                Text(
                                    episodeMetrics
                                )
                                .font(.system(size: 9, weight: .medium, design: .rounded))
                                .foregroundStyle(.secondary)
                                Text(episode.summary)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(expanded ? nil : 3)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 10)
                            Image(systemName: expanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    let episodeResources = episode.resourceIDs.compactMap { resources[$0] }
                    if !episodeResources.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 7) {
                                ForEach(episodeResources) { resource in
                                    Button {
                                        openResource(resource)
                                    } label: {
                                        Label(resource.title, systemImage: "link")
                                            .font(.system(size: 9, weight: .medium))
                                            .lineLimit(1)
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .disabled(
                                        resource.localPath == nil
                                            && resource.canonicalURI == nil
                                    )
                                }
                            }
                        }
                    }

                    if expanded {
                        Divider()
                        if !episode.requestsOrIntentions.isEmpty {
                            detailSection(
                                title: "REQUESTS OR INTENTIONS",
                                values: episode.requestsOrIntentions
                            )
                        }
                        if !episode.observableOutcomes.isEmpty {
                            detailSection(
                                title: "OBSERVABLE OUTCOMES",
                                values: episode.observableOutcomes
                            )
                        }
                        VStack(alignment: .leading, spacing: 7) {
                            Text("ACTION SEQUENCE")
                                .font(.system(size: 8, weight: .semibold))
                                .tracking(0.45)
                                .foregroundStyle(.secondary)
                            ForEach(episode.interactions) { interaction in
                                HStack(alignment: .top, spacing: 9) {
                                    Text(timeFormatter.string(from: interaction.start))
                                        .font(.system(size: 8, design: .monospaced))
                                        .foregroundStyle(.tertiary)
                                        .frame(width: 56, alignment: .leading)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(interaction.label)
                                            .font(.system(size: 9, weight: .medium))
                                        if !interaction.semanticDelta.isEmpty {
                                            Text(
                                                "Change: "
                                                    + interaction.semanticDelta.prefix(3)
                                                    .joined(separator: " · ")
                                            )
                                            .font(.system(size: 8))
                                            .foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                        }
                                    }
                                }
                            }
                        }
                        Text(
                            "Evidence: \(episode.provenance.sourceEventIDs.count) event IDs · \(episode.provenance.sourceSequences.count) integrity sequences · status confidence \(Int((episode.statusConfidence * 100).rounded()))%"
                        )
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                        HStack {
                            Spacer()
                            Button(role: .destructive, action: requestDeletion) {
                                Label("Delete this item…", systemImage: "trash")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
            }
        }

        private var episodeMetrics: String {
            let interval =
                "\(timeFormatter.string(from: episode.start))–\(timeFormatter.string(from: episode.end))"
            let interactions: String
            if episode.totalInteractionCount > episode.interactions.count {
                interactions =
                    "\(episode.totalInteractionCount) interactions "
                    + "(\(episode.interactions.count) representative)"
            } else {
                interactions = "\(episode.totalInteractionCount) interactions"
            }
            return "\(interval) · \(interactions) · \(episode.eventCount) source events"
        }

        private func detailSection(title: String, values: [String]) -> some View {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 8, weight: .semibold))
                    .tracking(0.45)
                    .foregroundStyle(.secondary)
                ForEach(values, id: \.self) { value in
                    Text("• \(value)")
                        .font(.system(size: 9))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }

        private var statusSymbol: String {
            switch episode.status {
            case .completed: return "checkmark.circle.fill"
            case .blocked: return "exclamationmark.octagon.fill"
            case .waiting: return "hourglass"
            case .planned: return "calendar.badge.clock"
            case .inProgress: return "arrow.triangle.2.circlepath"
            case .unknown: return "questionmark.circle"
            }
        }

        private var statusTint: Color {
            switch episode.status {
            case .completed: return LHTheme.success
            case .blocked: return LHTheme.danger
            case .waiting: return LHTheme.warning
            case .planned: return LHTheme.accent
            case .inProgress: return LHTheme.teal
            case .unknown: return .secondary
            }
        }

        private let timeFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.locale = Locale.current
            formatter.timeZone = .current
            formatter.dateStyle = .none
            formatter.timeStyle = .short
            return formatter
        }()
    }
#endif
