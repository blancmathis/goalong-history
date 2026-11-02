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

    /// One presentation lifetime spans snapshot reading, grouping and source verification.
    /// A retained-memory cache hit can be checking even when isLoading is false.
    enum ComputerHistoryDayLoadingPhase: Equatable {
        case idle, preparing, verifying
        static func resolve(preparing: Bool, loading: Bool, source: ComputerHistorySourceStatus) -> Self {
            if preparing { return .preparing }
            if loading || source == .checking { return .verifying }
            return .idle
        }
        var isActive: Bool { self != .idle }
    }

    final class ComputerHistoryPageModel: ObservableObject {
        @Published private(set) var memory: ComputerHistoryDayMemory?
        @Published private(set) var answer: ComputerHistoryAnswer?
        @Published private(set) var isLoading = false
        @Published private(set) var isAnswering = false
        @Published private(set) var errorMessage: String?
        @Published private(set) var sourceStatus: ComputerHistorySourceStatus = .unverified
        /// The journal is readable but the day outgrew the analysis ceiling: the memory
        /// shown is the last one that fitted, so it stops before the end of the day.
        @Published private(set) var isAnalysisPartial = false
        @Published var question = ""

        private let store: ComputerHistoryStore
        private let refreshRuntime: ActivityAnalysisRefreshServing
        private let storedMemoryLoader: (Date) -> ComputerHistoryDayMemory?
        private let queue = DispatchQueue(
            label: "ai.goalong.localhistory.computer-history-page",
            qos: .userInitiated
        )
        /// Serial: a retained view is always published before its verified successor.
        private let loadQueue = DispatchQueue(
            label: "ai.goalong.localhistory.computer-history-page.load",
            qos: .userInitiated
        )
        private var refreshRequestID = UUID()
        /// Refreshes asked and not yet published, all pages together (main thread). The gallery waits for 0 before
        /// it captures the page, so « Vérification de la journée » never lands in an image by chance.
        private(set) static var refreshesInFlight = 0

        init(
            store: ComputerHistoryStore = ComputerHistoryStore(),
            refreshRuntime: ActivityAnalysisRefreshServing = ActivityAnalysisRuntime.shared,
            storedMemoryLoader: ((Date) -> ComputerHistoryDayMemory?)? = nil
        ) {
            self.store = store
            self.refreshRuntime = refreshRuntime
            // The page never shows the markdown rendering of a day.
            self.storedMemoryLoader = storedMemoryLoader ?? { store.loadStored(for: $0, renderMarkdown: false) }
        }

        func refresh(day: Date, forceRebuild: Bool = false) {
            let normalized = Calendar.current.startOfDay(for: day)
            let requestID = UUID()
            refreshRequestID = requestID
            Self.refreshesInFlight += 1
            errorMessage = nil
            isLoading = true
            sourceStatus = .checking
            // Decoding a stored day takes hundreds of milliseconds on a busy day, so it
            // runs on this serial queue: the retained view is published first, then the
            // verified one, never on the main thread.
            let load = storedMemoryLoader
            let queue = loadQueue
            let retained = RetainedMemory()
            queue.async { [weak self] in
                retained.value = load(normalized)
                guard !forceRebuild, let memory = retained.value else { return }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.refreshRequestID == requestID else { return }
                    // Display the bounded derived view at once, but still verify the
                    // source revision asynchronously. An exact cache hit performs no body
                    // read and lets the UI distinguish retained data from a live source.
                    self.memory = memory
                    self.isLoading = false
                }
            }
            refreshRuntime.refresh(day: normalized, force: forceRebuild) { [weak self] result in
                queue.async { [weak self] in
                    let invalidated: Bool
                    let memory: ComputerHistoryDayMemory?
                    switch result {
                    case .success(let cycleResult) where cycleResult.derivedViewsWritten == 0:
                        invalidated = false
                        memory = retained.value ?? load(normalized)
                    case .success:
                        invalidated = false
                        memory = load(normalized) ?? retained.value
                    case .failure(let error):
                        invalidated = Self.wasInvalidatedByHistoryClear(error)
                        memory = invalidated ? nil : load(normalized) ?? retained.value
                    }
                    DispatchQueue.main.async { [weak self] in
                        Self.refreshesInFlight -= 1
                        guard let self, self.refreshRequestID == requestID else { return }
                        self.memory = memory
                        self.isAnalysisPartial = Self.exceededAnalysisCeiling(result)
                        switch result {
                        case .success(let cycleResult):
                            self.sourceStatus = cycleResult.sourceAbsent ? .absent : .available
                        case .failure where self.isAnalysisPartial:
                            self.sourceStatus = .available
                        case .failure(let error):
                            self.sourceStatus = invalidated ? .unverified : Self.sourceStatus(for: error)
                            self.errorMessage = Self.displayMessage(for: error)
                        }
                        self.isLoading = false
                    }
                }
            }
        }

        /// Written and read only on `loadQueue`.
        private final class RetainedMemory {
            var value: ComputerHistoryDayMemory?
        }

        static func displayMessage(for error: Error) -> String {
            if let cycleError = error as? ActivityAnalysisCycleError { return cycleError.frenchDescription }
            if let refreshError = error as? ActivityAnalysisRefreshError { return refreshError.frenchDescription }
            return GoalongUserFacingError.message(error)
        }

        private static func sourceStatus(for error: Error) -> ComputerHistorySourceStatus {
            guard let cycleError = error as? ActivityAnalysisCycleError else {
                return .unverified
            }
            switch cycleError {
            case .sourceInaccessible, .sourceChangedDuringRead, .oversizedJSONLine,
                .reentrantCycle:
                // « Détails techniques » shows the real cause; errorMessage carries the French sentence.
                return .inaccessible(cycleError.errorDescription ?? cycleError.frenchDescription)
            case .retainedEvidenceBudgetExceeded:
                return .available
            }
        }

        private static func exceededAnalysisCeiling(
            _ result: Result<ActivityAnalysisCycleResult, Error>
        ) -> Bool {
            guard case .failure(let error) = result,
                case .retainedEvidenceBudgetExceeded? = error as? ActivityAnalysisCycleError
            else { return false }
            return true
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
                GoalongWorkspaceOpenPolicy.open(
                    URL(fileURLWithPath: localPath),
                    purpose: .localFile
                )
                return
            }
            if let raw = resource.canonicalURI, let url = URL(string: raw) {
                GoalongWorkspaceOpenPolicy.open(url, purpose: .observedWebsite)
            }
        }

        func revealMemoryFiles(for day: Date) {
            let directory = AppPaths.applicationSupportDirectory
                .appendingPathComponent("computer-history", isDirectory: true)
            let files = store.memoryFileURLs(for: day)
                .filter { FileManager.default.fileExists(atPath: $0.path) }
            if files.isEmpty {
                GoalongWorkspaceOpenPolicy.open(directory, purpose: .localFile)
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
            let contexts: [String]
            let isSuppressed: Bool
            let sourceSessionCount: Int

            var duration: TimeInterval { end.timeIntervalSince(start) }
            var context: String { contexts.joined(separator: " → ") }
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
            calendar: Calendar = .current,
            now: Date = GoalongToday.now
        ) -> [ComputerHistoryTenMinuteGroup] {
            let dayStart = calendar.startOfDay(for: day)
            guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else {
                return []
            }

            var segmentsByWindow: [Date: [Segment]] = [:]
            for session in sessions {
                let clippedStart = max(session.start, dayStart)
                // The 30 s tolerance counts toward active time, but never opens a slot
                // nor moves a shown end past what was recorded.
                let clippedEnd = min(session.end.addingTimeInterval(30), dayEnd, max(now, session.end))
                let recordedEnd = min(session.end, dayEnd)
                guard clippedEnd > clippedStart else { continue }

                let firstWindowStart = tenMinuteStart(for: clippedStart, calendar: calendar)
                var windowStart = firstWindowStart
                while windowStart < clippedEnd,
                    windowStart == firstWindowStart || windowStart < recordedEnd
                {
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
                        let appKey = session.bundleIdentifier.map {
                            "bundle:\($0.lowercased())"
                        } ?? "name:\(normalizedAppName)"
                        segmentsByWindow[windowStart, default: []].append(
                            Segment(
                                session: session,
                                appKey: appKey,
                                start: segmentStart,
                                end: segmentEnd,
                                shownEnd: max(segmentStart, min(segmentEnd, recordedEnd))
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
                // Merging still allows for the 30 s tolerance hidden from `shownEnd`.
                var previousToleratedEnd = Date.distantPast
                for segment in ordered {
                    let suppressed = segment.session.suppressionReason != nil
                    let context = suppressed
                        ? "Activité privée ou masquée"
                        : segment.session.windowTitle
                            ?? segment.session.host
                            ?? segment.session.category.map(CategoryBadge.prettyCategory)
                            ?? "Aucun contexte détaillé enregistré"
                    if
                        previousAppKey == segment.appKey,
                        let previous = sessionSlices.last,
                        segment.start <= previousToleratedEnd.addingTimeInterval(30)
                    {
                        previousToleratedEnd = max(previousToleratedEnd, segment.end)
                        sessionSlices[sessionSlices.count - 1] = SessionSlice(
                            id: previous.id,
                            start: previous.start,
                            end: max(previous.end, segment.shownEnd),
                            appName: previous.appName,
                            bundleIdentifier: previous.bundleIdentifier
                                ?? segment.session.bundleIdentifier,
                            contexts: mergedContexts(
                                previous.contexts,
                                adding: context,
                                isSuppressed: previous.isSuppressed || suppressed
                            ),
                            isSuppressed: previous.isSuppressed || suppressed,
                            sourceSessionCount: previous.sourceSessionCount + 1
                        )
                    } else {
                        previousToleratedEnd = segment.end
                        sessionSlices.append(
                            SessionSlice(
                                id: "\(segment.session.id)-\(windowStart.timeIntervalSince1970)",
                                start: segment.start,
                                end: segment.shownEnd,
                                appName: segment.session.appName,
                                bundleIdentifier: segment.session.bundleIdentifier,
                                contexts: [context],
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

        private static func mergedContexts(
            _ existing: [String],
            adding value: String,
            isSuppressed: Bool
        ) -> [String] {
            if isSuppressed { return ["Activité privée ou masquée"] }
            var values = existing
            if !values.contains(where: {
                $0.localizedCaseInsensitiveCompare(value) == .orderedSame
            }) {
                values.append(value)
            }
            guard values.count > 4 else { return values }
            return Array(values.prefix(3)) + [values[values.count - 1]]
        }

        private struct Segment {
            let session: ActivitySession
            let appKey: String
            let start: Date
            /// Includes the 30 s tolerance; counts toward active time.
            let end: Date
            /// Never after the recorded end; shown to the user.
            let shownEnd: Date
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

    /// Pure display strings of the Computer History page, kept testable.
    enum ComputerHistoryPageCopy {
        /// "12 périodes", or "3 sur 12 périodes" while a search filters the timeline.
        static func periodCountLabel(visible: Int, total: Int, searching: Bool) -> String {
            let totalLabel = total <= 1 ? "\(total) période" : "\(total) périodes"
            return searching ? "\(visible) sur \(totalLabel)" : totalLabel
        }

        /// « Page web » rather than the Swift identifier « webPage ».
        static func resourceKindLabel(_ kind: ComputerHistoryResourceKind) -> String {
            switch kind {
            case .file: return "Fichier"
            case .webPage: return "Page web"
            case .conversation: return "Conversation"
            case .issue: return "Ticket"
            case .document: return "Document"
            case .terminalSession: return "Session de terminal"
            case .application: return "Application"
            case .unknown: return "Ressource inconnue"
            }
        }

        /// The count already sits beside « Chronologie »: the banner only says what to do with a period.
        static let openPeriodHint = "Ouvrez une période de dix minutes pour voir ses détails."

        static func retainedEpisodesLabel(_ count: Int) -> String {
            GoalongUIFormat.count(count, "épisode représentatif conservé", plural: "épisodes représentatifs conservés")
        }

        static func retainedResourcesLabel(_ count: Int) -> String {
            GoalongUIFormat.count(count, "lien source représentatif conservé", plural: "liens sources représentatifs conservés")
        }

        static func provenanceLabel(events: Int, sequences: Int, confidence: Int) -> String {
            "Preuves : \(GoalongUIFormat.count(events, "identifiant d’événement", plural: "identifiants d’événements")), "
                + "\(GoalongUIFormat.count(sequences, "séquence d’intégrité", plural: "séquences d’intégrité")), "
                + "confiance \(GoalongUIFormat.percent(confidence))"
        }

        /// With an empty timeline, one place explains why. The timeline card does it for a day without
        /// data; the status card does it when it also offers « Réessayer ».
        static func timelineExplainsEmptyDay(_ status: ComputerHistorySourceStatus) -> Bool {
            switch status {
            case .available, .absent, .checking: return true
            case .inaccessible, .unverified: return false
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
        @State private var timelineSearch = ""
        @State private var newestFirst = true
        @State private var hasRetried = false
        @Environment(\.goalongRecordingModel) private var recordingModel

        var body: some View {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    if !timelineAloneExplainsDay { recordingStateCard }
                    historySection
                }
                .padding(.bottom, 8)
            }
            .task(id: timelineRefreshID) {
                refreshTimeline()
            }
            .onDisappear(perform: timelineModel.clear)
            .onChange(of: day) { _ in
                timelineSearch = ""
                hasRetried = false
            }
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

        private var visibleTimelineGroups: [ComputerHistoryTenMinuteGroup] {
            let query = timelineSearch.trimmingCharacters(in: .whitespacesAndNewlines)
            let groups = query.isEmpty ? tenMinuteGroups : tenMinuteGroups.filter { group in
                group.apps.contains { $0.name.localizedStandardContains(query) }
                    || group.sessions.contains { $0.context.localizedStandardContains(query) }
            }
            return newestFirst ? groups : groups.reversed()
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

        private var dayLoadingPhase: ComputerHistoryDayLoadingPhase {
            .resolve(preparing: isPreparingTimeline, loading: model.isLoading, source: model.sourceStatus)
        }

        private var recordingStateCard: some View {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Group {
                        if dayLoadingPhase.isActive {
                            ProgressView()
                                .progressViewStyle(GoalongProgressViewStyle())
                                .controlSize(.small)
                                .accessibilityIdentifier("history-day-verification-motion")
                                .accessibilityHidden(true)
                        } else {
                            Image(systemName: recordingStateSymbol)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(recordingStateTint)
                        }
                    }
                    .frame(width: 28, height: 20)
                    .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(recordingStateTitle)
                            .font(.system(size: 13, weight: .semibold))
                        if showsRecordingSummary {
                            Text(recordingSummary)
                                .font(.system(size: 12))
                                .foregroundStyle(LHTheme.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 12)
                    if needsRetry {
                        Button(hasRetried ? "Réessayer encore" : "Réessayer") {
                            hasRetried = true
                            model.refresh(day: day, forceRebuild: true)
                        }
                            .buttonStyle(LHSecondaryButtonStyle())
                            .disabled(model.isLoading || isSnapshotLoading)
                            .help("Relire l’historique de cette journée")
                    }
                }
                if let diagnostic = sourceDiagnostic {
                    GoalongDisclosureGroup("Détails techniques") {
                        Text(diagnostic)
                            .font(.system(size: 12))
                            .foregroundStyle(LHTheme.secondaryText)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 6)
                    }
                    .font(.system(size: 12))
                    .padding(.leading, 30)
                }
            }
            .padding(14)
            .background(LHTheme.cardBackground, in: RoundedRectangle(cornerRadius: 10))
        }

        private var needsRetry: Bool {
            switch model.sourceStatus {
            case .inaccessible, .unverified: return true
            case .available, .absent, .checking: return false
            }
        }

        private var sourceDiagnostic: String? {
            if case .inaccessible(let message) = model.sourceStatus { return message }
            return nil
        }

        private var recordingStateTitle: String {
            if isPreparingTimeline { return "Préparation de la journée" }
            switch model.sourceStatus {
            case .checking:
                return "Vérification de la journée"
            case .available where model.isAnalysisPartial:
                return "Analyse partielle"
            case .available:
                return snapshot.eventCount > 0 || !tenMinuteGroups.isEmpty
                    ? "Enregistré sur ce Mac"
                    : "Aucune activité chargée"
            case .absent:
                return model.memory == nil
                    ? "Aucune source pour cette date"
                    : "Historique local conservé"
            case .inaccessible:
                return "Actualisation impossible"
            case .unverified:
                return "Historique à vérifier"
            }
        }

        private var recordingStateSymbol: String {
            if isPreparingTimeline { return "clock.arrow.circlepath" }
            switch model.sourceStatus {
            case .checking:
                return "arrow.triangle.2.circlepath"
            case .available where model.isAnalysisPartial:
                return "clock.badge.exclamationmark"
            case .available:
                return snapshot.eventCount > 0 || !tenMinuteGroups.isEmpty
                    ? "checkmark"
                    : "minus"
            case .absent:
                return model.memory == nil ? "doc.badge.ellipsis" : "archivebox.fill"
            case .inaccessible:
                return "exclamationmark.circle"
            case .unverified:
                return "questionmark"
            }
        }

        private var recordingStateTint: Color {
            if isPreparingTimeline { return LHTheme.accent }
            switch model.sourceStatus {
            case .available where model.isAnalysisPartial:
                return LHTheme.warning
            case .available:
                return snapshot.eventCount > 0 || !tenMinuteGroups.isEmpty
                    ? LHTheme.success
                    : LHTheme.teal
            case .checking:
                return LHTheme.accent
            case .absent, .inaccessible, .unverified:
                return LHTheme.warning
            }
        }

        private var showsRecordingSummary: Bool {
            isPreparingTimeline || !tenMinuteGroups.isEmpty || model.isAnalysisPartial
                || !ComputerHistoryPageCopy.timelineExplainsEmptyDay(model.sourceStatus)
        }

        private var recordingSummary: String {
            let events = snapshot.eventCount
            if isPreparingTimeline {
                return "Préparation des tranches de 10 minutes à partir de \(GoalongUIFormat.count(events, "événement"))."
            }
            switch model.sourceStatus {
            case .checking:
                return "Vérification des nouveautés. L’activité déjà chargée reste visible."
            case .absent:
                return model.memory == nil
                    ? "Aucune activité pour cette date. Choisissez une autre journée."
                    : "Le journal original est indisponible. L’historique déjà enregistré est conservé."
            case .inaccessible:
                if hasRetried {
                    let nextStep = "Nouvel échec de l’actualisation. Choisissez une autre date ou consultez les détails techniques."
                    return tenMinuteGroups.isEmpty ? nextStep : nextStep + " L’activité déjà chargée reste visible."
                }
                return !tenMinuteGroups.isEmpty
                    ? "L’activité chargée précédemment est affichée ci-dessous. Réessayez pour la mettre à jour."
                    : "L’historique de cette journée n’a pas pu être chargé. Réessayez ou choisissez une autre date."
            case .unverified:
                return "Réessayez pour vérifier l’activité enregistrée ce jour-là."
            case .available:
                break
            }
            let summary = ComputerHistoryPageCopy.openPeriodHint
            return model.isAnalysisPartial ? partialAnalysisNotice + " " + summary : summary
        }

        private var partialAnalysisNotice: String {
            guard let end = model.memory?.episodes.map(\.end).max() else {
                return "Journée très chargée : elle dépasse ce que l’analyse de ce Mac garde en mémoire."
            }
            return "Journée très chargée : l’analyse de ce Mac s’arrête à \(GoalongUIFormat.time(end))."
        }

        private var historySection: some View {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 9) {
                    Text("Chronologie")
                        .font(.system(size: 20, weight: .semibold))
                    Image(systemName: "info.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(LHTheme.secondaryText)
                        .help(
                            "Les durées correspondent aux périodes observées au premier plan. Elles ne prouvent ni l’attention, ni l’identité, ni l’auteur, ni la productivité."
                        )
                    Spacer(minLength: 12)
                    if isPreparingTimeline {
                        Text("Préparation…")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(LHTheme.secondaryText)
                    } else if !tenMinuteGroups.isEmpty {
                        Text(ComputerHistoryPageCopy.periodCountLabel(
                            visible: visibleTimelineGroups.count,
                            total: tenMinuteGroups.count,
                            searching: !timelineSearch.isEmpty
                        ))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(LHTheme.secondaryText)
                    }
                    Button(action: openSourceJSON) {
                        Label("Ouvrir le journal", systemImage: "doc.text")
                    }
                    .buttonStyle(LHSecondaryButtonStyle())
                    .controlSize(.regular)
                    .disabled(!canRevealSourceData)
                    .help(sourceDataHelp)
                }

                HStack(spacing: 12) {
                    GoalongSearchField("Rechercher une application ou un contexte", text: $timelineSearch, accessibilityLabel: "Rechercher dans la chronologie")
                    GoalongMenuPicker("Ordre de la chronologie", selection: $newestFirst,
                                      options: [(true, "Plus récent d’abord"), (false, "Plus ancien d’abord")])
                }
                .font(.system(size: 12))

                timelineCard
            }
        }

        /// An empty day is a page state, not a card: thread, title, sentence and one action.
        @ViewBuilder private var timelineCard: some View {
            if tenMinuteGroups.isEmpty && !isPreparingTimeline {
                GoalongEmptyState(
                    title: emptyTimelineTitle,
                    message: storageStopTitle != nil || ComputerHistoryPageCopy.timelineExplainsEmptyDay(model.sourceStatus)
                        ? emptyTimelineMessage : "Les activités apparaîtront ici dès qu’elles seront enregistrées.") {
                    if !needsRetry {
                        Button("Actualiser") { model.refresh(day: day) }
                            .buttonStyle(LHSecondaryButtonStyle())
                            .disabled(model.isLoading || isSnapshotLoading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)
                .accessibilityIdentifier("history-empty-day")
            } else {
                timelineList
            }
        }

        private var timelineList: some View {
            LHCard(padding: 0) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text(
                            GoalongToday.isToday(day)
                                ? "Aujourd’hui"
                                : DashboardFormatters.dayTitle.string(from: day)
                        )
                        .font(.system(size: 14, weight: .semibold))
                        Spacer()
                        if snapshot.eventCount > 0 {
                            Text("\(DashboardFormatters.duration(minutes: snapshot.activeMinutes)) d’activité")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(LHTheme.secondaryText)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 17)

                    Divider()

                    if isPreparingTimeline {
                        VStack(spacing: 11) {
                            // The verification card owns the only primary animation.
                            Text("Préparation de la chronologie…")
                                .font(.system(size: 14, weight: .semibold))
                            Text("Préparation locale de la journée.")
                                .font(.system(size: 12))
                                .foregroundStyle(LHTheme.secondaryText)
                        }
                        .frame(maxWidth: .infinity, minHeight: 240)
                        .padding(24)
                    } else if visibleTimelineGroups.isEmpty {
                        GoalongEmptyState(title: "Aucune activité correspondante",
                                          message: "Essayez un autre nom d’app ou un mot du contexte enregistré.") {
                            Button("Effacer la recherche") { timelineSearch = "" }
                                .buttonStyle(LHSecondaryButtonStyle())
                        }
                        .frame(maxWidth: .infinity, minHeight: 180, alignment: .topLeading)
                    } else {
                        ForEach(Array(visibleTimelineGroups.enumerated()), id: \.element.id) {
                            index, group in
                            ComputerHistoryTenMinuteRow(
                                group: group,
                                isLast: index == visibleTimelineGroups.count - 1
                            )
                        }
                    }
                }
            }
        }

        private var isPreparingTimeline: Bool {
            tenMinuteGroups.isEmpty && (isSnapshotLoading || timelineModel.isLoading)
        }

        private var canRevealSourceData: Bool {
            switch model.sourceStatus {
            case .absent, .inaccessible:
                return false
            case .unverified, .checking, .available:
                return true
            }
        }

        private var sourceDataHelp: String {
            canRevealSourceData
                ? "Afficher le journal original de cette journée dans le Finder"
                : "Le journal original de cette journée est indisponible"
        }

        /// A day without any journal is one fact: the timeline's empty state says it, the card above does not repeat it.
        private var timelineAloneExplainsDay: Bool {
            guard case .absent = model.sourceStatus, model.memory == nil else { return false }
            return !isPreparingTimeline && tenMinuteGroups.isEmpty
        }

        /// Writes refused today: the empty day has a known cause and a start time.
        private var storageStopTitle: String? {
            guard GoalongToday.isToday(day), let runtime = recordingModel?.runtime, runtime.storageFailure != nil else { return nil }
            return runtime.storageInterruptedSince.map { "Enregistrement interrompu depuis \(GoalongUIFormat.time($0))" }
                ?? "Enregistrement interrompu"
        }

        private var emptyTimelineTitle: String {
            if let storageStopTitle, tenMinuteGroups.isEmpty { return storageStopTitle }
            switch model.sourceStatus {
            case .inaccessible:
                return "Chargement impossible"
            case .absent:
                return model.memory == nil
                    ? "Aucun journal pour cette date"
                    : "Détails de la journée indisponibles"
            case .available where GoalongToday.isToday(day):
                return "Aucune activité enregistrée aujourd’hui"
            case .available:
                return "Aucune activité trouvée"
            case .checking:
                return "Vérification de l’activité"
            case .unverified:
                return "Source à vérifier"
            }
        }

        private var emptyTimelineMessage: String {
            if storageStopTitle != nil, let kind = recordingModel?.runtime.storageFailure {
                return kind == .diskFull
                    ? "Rien n’est enregistré tant que le disque est plein. La reprise est automatique et la coupure restera indiquée ici."
                    : "Rien n’est enregistré tant que le dossier de l’historique refuse l’écriture. La reprise est automatique et la coupure restera indiquée ici."
            }
            switch model.sourceStatus {
            case .inaccessible:
                return model.memory == nil
                    ? "Goalong n’a pas pu lire le journal d’origine en toute sécurité. Réessayez plus tard ou choisissez un autre jour."
                    : "Le dernier historique valide a été conservé. Le journal d’origine n’a pas pu être lu en toute sécurité."
            case .absent:
                return model.memory == nil
                    ? "Goalong n’a rien enregistré sur ce Mac ce jour-là, ou ce jour a été effacé."
                    : "Le journal d’origine est absent, mais l’historique conservé n’a pas été supprimé."
            case .available where GoalongToday.isToday(day):
                return "L’activité apparaît ici lorsque Goalong enregistre une application autorisée."
            case .available:
                return "Choisissez une autre date. Un historique vide ne prouve pas une absence d’activité."
            case .checking:
                return "Goalong vérifie le journal local d’origine avant d’afficher ce jour."
            case .unverified:
                return "Goalong n’a pas pu vérifier le journal local d’origine. Choisissez un autre jour ou réessayez plus tard."
            }
        }

    }

    private struct ComputerHistoryTenMinuteRow: View {
        let group: ComputerHistoryTenMinuteGroup
        let isLast: Bool
        @State private var expanded = false
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            HStack(alignment: .top, spacing: 0) {
                Text(windowTimeLabel)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(LHTheme.secondaryText)
                    .monospacedDigit()
                    .lineLimit(1)
                    .frame(width: 84, alignment: .trailing)
                    .padding(.top, 14)
                    .padding(.trailing, 8)

                VStack(spacing: 0) {
                    Circle()
                        .fill(Color.secondary)
                        .frame(width: 8, height: 8)
                        .padding(.top, 20)
                    if !isLast {
                        Rectangle()
                            .fill(Color.secondary.opacity(0.22))
                            .frame(width: 1)
                            .frame(maxHeight: .infinity)
                    }
                }
                .frame(width: 16)

                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                            expanded.toggle()
                        }
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: "chevron.right").rotationEffect(.degrees(expanded ? 90 : 0))
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(LHTheme.secondaryText)
                                .frame(width: 12).accessibilityHidden(true)
                            Text(headline)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Spacer(minLength: 12)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(LHNavigationButtonStyle())
                    .accessibilityValue(expanded ? "Développé" : "Replié")
                    .accessibilityLabel(
                        expanded
                            ? "Masquer les détails de \(windowTimeLabel)"
                            : "Afficher les détails de \(windowTimeLabel)"
                    )

                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 18) {
                            ForEach(group.apps) { app in appDuration(app) }
                        }
                        .fixedSize(horizontal: true, vertical: false)
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 170), spacing: 14, alignment: .leading)],
                            alignment: .leading, spacing: 8
                        ) {
                            ForEach(group.apps) { app in appDuration(app) }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if expanded {
                        Divider()
                        Text(factSummary)
                            .font(.system(size: 12))
                            .foregroundStyle(LHTheme.secondaryText)
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
                                                .font(.system(size: 12, weight: .semibold))
                                            if session.isSuppressed {
                                                Image(systemName: "eye.slash.fill")
                                                    .font(.system(size: 10))
                                                    .foregroundStyle(LHTheme.privateTint)
                                            }
                                        }
                                        Text(session.context)
                                            .font(.system(size: 12))
                                            .foregroundStyle(LHTheme.secondaryText)
                                            .lineLimit(2)
                                        Text(
                                            sessionDetailSummary(session)
                                        )
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(LHTheme.secondaryText)
                                    }
                                    Spacer(minLength: 0)
                                }
                            }
                        }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .padding(.leading, 10)
                .padding(.trailing, 20)
                .padding(.vertical, 14)
            }
            .accessibilityElement(children: .contain)
        }

        private func appDuration(_ app: ComputerHistoryTenMinuteGroup.AppSlice) -> some View {
            HStack(spacing: 6) {
                AppIconView(bundleIdentifier: app.bundleIdentifier, appName: app.name, size: 20)
                Text(app.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text(durationLabel(app.activeSeconds))
                    .font(.system(size: 12))
                    .foregroundStyle(LHTheme.secondaryText)
                    .monospacedDigit()
                    .fixedSize()
            }
            .accessibilityElement(children: .combine)
        }

        private var headline: String {
            let names = group.apps.map(\.name)
            switch names.count {
            case 0:
                return "Activité enregistrée"
            case 1:
                return names[0]
            case 2:
                return "\(names[0]) et \(names[1])"
            default:
                return "\(names[0]), \(names[1]) et \(names.count - 2) \(names.count - 2 > 1 ? "autres" : "autre")"
            }
        }

        private var factSummary: String {
            var facts = [
                "\(durationLabel(group.activeSeconds)) enregistrées",
                "\(group.apps.count) app\(group.apps.count > 1 ? "s" : "")",
                "\(group.appChangeCount) changement\(group.appChangeCount > 1 ? "s" : "") d’app",
            ]
            if group.inputEventCount > 0 {
                facts.append("\(GoalongUIFormat.number(group.inputEventCount)) interaction\(group.inputEventCount > 1 ? "s" : "")")
            } else if group.recordedEventCount > 0 {
                facts.append("\(GoalongUIFormat.number(group.recordedEventCount)) événement\(group.recordedEventCount > 1 ? "s" : "")")
            }
            return facts.joined(separator: ", ")
        }

        /// One line: a range cut before its dash read as two times, the second one starting with « – ».
        private var windowTimeLabel: String {
            GoalongUIFormat.time(group.start) + "–" + GoalongUIFormat.time(group.end)
        }

        private func durationLabel(_ seconds: TimeInterval) -> String {
            guard seconds >= 60 else { return "<\u{00A0}1\u{00A0}min" }
            let roundedMinutes = Int((seconds / 60).rounded())
            return DashboardFormatters.duration(minutes: max(1, roundedMinutes))
        }

        private func sessionDetailSummary(
            _ session: ComputerHistoryTenMinuteGroup.SessionSlice
        ) -> String {
            let interval =
                "\(GoalongUIFormat.time(session.start))–"
                + GoalongUIFormat.time(session.end)
            let details = session.sourceSessionCount == 1
                ? "1 segment enregistré"
                : "\(session.sourceSessionCount) segments enregistrés"
            return "\(interval), \(durationLabel(session.duration)), \(details)"
        }
    }
#endif
