#if os(macOS)
    import AppleScreenTime
    import Foundation
    import SwiftUI

    struct OverviewPage: View {
        @ObservedObject var model: DashboardViewModel
        @StateObject private var screenTime: AppleScreenTimeDashboardModel
        @ObservedObject private var recapRuntime: ChatGPTRecapRuntime
        @State private var includesInactiveSystemTime = false
        @State private var usageMode: OverviewUsageMode = .applications

        init(model: DashboardViewModel) {
            self.model = model
            _screenTime = StateObject(
                wrappedValue: AppleScreenTimeDashboardModel(
                    rootDirectory: AppPaths.screenTimeDirectory,
                    deviceID: model.deviceID,
                    selectedDay: model.selectedDay,
                    includesUnfilteredSummary: true
                )
            )
            _recapRuntime = ObservedObject(wrappedValue: ChatGPTRecapRuntime.shared)
        }

        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    PageHeader(
                        eyebrow: Calendar.current.isDateInToday(model.selectedDay) ? "Today" : "History",
                        title: DashboardFormatters.dayTitle.string(from: model.selectedDay),
                        subtitle: "One clear view of your day."
                    ) {
                        HStack(spacing: 10) {
                            DateSelectionControl(date: model.selectedDay, onChange: selectDay)
                            captureControl
                            Button {
                                model.selectSection(.share)
                            } label: {
                                Label("Share day", systemImage: "square.and.arrow.up")
                            }
                            .buttonStyle(.bordered)
                            Button {
                                refreshAll()
                            } label: {
                                Image(systemName: "arrow.clockwise")
                                    .frame(width: 28, height: 28)
                            }
                            .buttonStyle(.bordered)
                            .disabled(model.isRefreshing || screenTime.isBusy)
                            .help("Refresh")
                        }
                    }

                    dayCard
                    aiRecapCard
                }
                .padding(.horizontal, 24)
                .padding(.top, 28)
                .padding(.bottom, 40)
            }
            .background(LHTheme.pageBackground)
            .onAppear {
                screenTime.setActive(model.dashboardIsVisible)
                synchronizeSecondarySources(with: model.selectedDay)
            }
            .onDisappear { screenTime.setActive(false) }
            .onChange(of: model.dashboardIsVisible) { screenTime.setActive($0) }
            .onChange(of: model.selectedDay) { day in
                synchronizeSecondarySources(with: day)
            }
            .alert(item: $recapRuntime.alert) { item in
                Alert(
                    title: Text(item.title),
                    message: Text(item.message),
                    dismissButton: .default(Text("OK"))
                )
            }
        }

        @ViewBuilder private var captureControl: some View {
            switch model.runtime.state {
            case .permissionsMissing:
                Button("Finish setup") {
                    model.requestPermissions()
                }
                .buttonStyle(.borderedProminent)
            case .inputTapUnavailable:
                Button("Check input") {
                    model.beginCaptureValidation()
                }
                .buttonStyle(.borderedProminent)
            case .paused:
                Button {
                    model.togglePause()
                } label: {
                    Label("Resume", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
            default:
                StatusPill(
                    title: model.runtime.displayTitle,
                    symbol: model.runtime.displaySymbol,
                    tint: model.runtime.displayTint
                )
            }
        }

        private var dayCard: some View {
            LHCard(padding: 0) {
                VStack(spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: 16) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Your day")
                                .font(.system(size: 18, weight: .bold, design: .rounded))
                            Text("Apple Screen Time and Goalong observations shown side by side, never added together.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if screenTime.isBusy {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                    .padding(20)

                    Divider()

                    HStack(alignment: .top, spacing: 18) {
                        dayMetric(
                            title: "APPLE SCREEN TIME",
                            value: screenTimeValue,
                            detail: screenTimeDetail
                        )
                        Divider().frame(height: 48)
                        dayMetric(
                            title: "ACTIVE ON THIS MAC",
                            value: DashboardFormatters.duration(minutes: model.snapshot.activeMinutes),
                            detail: "Observed by Goalong"
                        )
                        Divider().frame(height: 48)
                        dayMetric(
                            title: "WORK",
                            value: DashboardFormatters.duration(minutes: model.snapshot.workMinutes),
                            detail: "Conservative local classification"
                        )
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 18)

                    if screenTime.needsFullDiskAccess {
                        Divider()
                        HStack(spacing: 10) {
                            Image(systemName: "macbook.and.iphone")
                                .foregroundStyle(LHTheme.warning)
                            Text("Enable Apple Screen Time to complete this view across your devices.")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Enable") {
                                screenTime.openFullDiskAccessSettings()
                            }
                            .buttonStyle(.bordered)
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                    }

                    Divider()
                    topUsageSection
                        .padding(20)

                    Divider()
                    timelineSection
                        .padding(20)

                    Divider()
                    HStack {
                        Button("Open History") {
                            model.selectSection(.history)
                        }
                        .buttonStyle(.link)
                        Spacer()
                        Text("Computer activity, Screen Time and AI conversations")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                }
            }
        }

        private func dayMetric(title: String, value: String, detail: String) -> some View {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .tracking(0.5)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 23, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text(detail)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        private var topUsageSection: some View {
            let applications = combinedAppUsage
            let websites = Array(topWebsiteUsage.prefix(6))

            return VStack(alignment: .leading, spacing: 13) {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Most used")
                            .font(.system(size: 15, weight: .semibold))
                        Text(usageMode.detail)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 8) {
                        Picker("Usage type", selection: $usageMode) {
                            ForEach(OverviewUsageMode.allCases) { item in
                                Text(item.title).tag(item)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 230)

                        if usageMode == .applications, hasHiddenInactiveSystemTime {
                            Toggle(
                                "Include login and lock-screen time",
                                isOn: $includesInactiveSystemTime
                            )
                                .toggleStyle(.switch)
                                .controlSize(.small)
                                .accessibilityHint(
                                    "Adds login screen, lock screen, and screen saver time Apple may report while the device is not actively being used."
                                )
                                .help(
                                    "Include Apple-reported login screen, lock screen, and screen saver time. This can increase Screen Time even when you were not actively using the device."
                                )
                            Text(
                                "Apple may record these periods while the device is not actively being used."
                            )
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 300, alignment: .trailing)
                            .fixedSize(horizontal: false, vertical: true)
                        } else if usageMode == .websites, !topWebsiteUsage.isEmpty {
                            Text("Top \(websites.count) of \(topWebsiteUsage.count) websites")
                                .font(.system(size: 9, weight: .medium, design: .rounded))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if usageMode == .applications {
                    applicationUsageRows(applications)
                } else {
                    websiteUsageRows(websites)
                }
            }
        }

        @ViewBuilder private func applicationUsageRows(_ applications: [DailyAppUsage]) -> some View {
            if applications.isEmpty {
                Text("Application usage will appear here as Screen Time or Goalong records the day.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 72, alignment: .center)
            } else {
                let maximum = max(1, applications.map(\.displaySeconds).max() ?? 1)
                LazyVStack(spacing: 0) {
                    ForEach(Array(applications.enumerated()), id: \.element.id) { index, usage in
                        HStack(spacing: 12) {
                            AppIconView(
                                bundleIdentifier: usage.bundleIdentifier,
                                appName: usage.name,
                                size: 34
                            )
                            VStack(alignment: .leading, spacing: 5) {
                                HStack(spacing: 12) {
                                    Text(usage.name)
                                        .font(.system(size: 11, weight: .semibold))
                                        .lineLimit(1)
                                    Spacer()
                                    Text(formattedDuration(usage.displaySeconds))
                                        .font(.system(size: 11, weight: .bold, design: .rounded))
                                        .monospacedDigit()
                                }
                                Text(usage.sourceDetail)
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                ProgressBar(
                                    value: usage.displaySeconds / maximum,
                                    tint: LHTheme.accent
                                )
                            }
                        }
                        .padding(.vertical, 8)

                        if index < applications.count - 1 {
                            Divider().padding(.leading, 46)
                        }
                    }
                }
            }
        }

        @ViewBuilder private func websiteUsageRows(_ websites: [TrackedUsageItem]) -> some View {
            if websites.isEmpty {
                Text("No public website URL was exposed by the active browsers for this day.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 72, alignment: .center)
            } else {
                let maximum = max(1, websites.map(\.foregroundSeconds).max() ?? 1)
                LazyVStack(spacing: 0) {
                    ForEach(Array(websites.enumerated()), id: \.element.id) { index, site in
                        HStack(spacing: 12) {
                            WebsiteIconView(host: site.host ?? site.name, size: 34)
                            VStack(alignment: .leading, spacing: 5) {
                                HStack(spacing: 12) {
                                    Text(site.host ?? site.name)
                                        .font(.system(size: 11, weight: .semibold))
                                        .lineLimit(1)
                                    Spacer()
                                    Text(formattedDuration(site.foregroundSeconds))
                                        .font(.system(size: 11, weight: .bold, design: .rounded))
                                        .monospacedDigit()
                                }
                                Text(websiteSourceDetail(site))
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                ProgressBar(
                                    value: site.foregroundSeconds / maximum,
                                    tint: LHTheme.teal
                                )
                            }
                        }
                        .padding(.vertical, 8)

                        if index < websites.count - 1 {
                            Divider().padding(.leading, 46)
                        }
                    }
                }
            }
        }

        private func websiteSourceDetail(_ site: TrackedUsageItem) -> String {
            [site.sourceApplicationLabel, "This Mac"]
                .compactMap { $0 }
                .joined(separator: " · ")
        }

        private var timelineSection: some View {
            VStack(alignment: .leading, spacing: 13) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Day activity")
                            .font(.system(size: 15, weight: .semibold))
                        Text("Goalong's local coverage through the day.")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    HStack(spacing: 12) {
                        timelineLegend(label: "Work", color: LHTheme.success)
                        timelineLegend(label: "Active", color: LHTheme.teal)
                        timelineLegend(label: "Private", color: LHTheme.privateTint)
                    }
                }

                if model.snapshot.timeline.isEmpty {
                    Text("No Goalong activity has been recorded for this day yet.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 54, alignment: .center)
                } else {
                    TimelineStrip(buckets: model.snapshot.timeline)
                }
            }
        }

        private var aiRecapCard: some View {
            LHCard(padding: 0) {
                VStack(spacing: 0) {
                    HStack(alignment: .center, spacing: 16) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Daily Activity")
                                .font(.system(size: 18, weight: .bold, design: .rounded))
                            Text(aiRecapSubtitle)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        Spacer()
                        recapAction
                    }
                    .padding(20)

                    Divider()

                    recapPreview
                        .padding(20)

                    Divider()

                    HStack(spacing: 12) {
                        Image(systemName: "sparkles")
                            .foregroundStyle(LHTheme.accent)
                        Text(
                            "Uses Computer History, Apple Screen Time and AI conversations read from their original local sources."
                        )
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        Spacer(minLength: 16)
                        Button(recapRuntime.recap == nil ? "Activity setup" : "Open Activity") {
                            model.selectSection(.chatGPTRecap)
                        }
                        .buttonStyle(.link)
                        .font(.system(size: 11, weight: .semibold))
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                }
            }
        }

        @ViewBuilder private var recapAction: some View {
            if recapRuntime.isGenerating {
                ProgressView()
                    .controlSize(.small)
            } else if aiRecapIsConnected {
                Button(recapRuntime.recap == nil ? "Analyze day" : "Analyze again") {
                    recapRuntime.generateRecap()
                }
                .buttonStyle(.borderedProminent)
            } else if case .checking = recapRuntime.connectionState {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button("Connect ChatGPT") {
                    model.selectSection(.chatGPTRecap)
                }
                .buttonStyle(.borderedProminent)
            }
        }

        @ViewBuilder private var recapPreview: some View {
            if recapRuntime.isGenerating {
                if recapRuntime.streamedMarkdown.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Combining your activity, Screen Time and AI conversations…")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
                } else {
                    markdownPreview(recapRuntime.streamedMarkdown)
                }
            } else if let recap = recapRuntime.recap {
                markdownPreview(recap.markdown)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text(aiRecapIsConnected ? "No Activity report for this day yet." : "Daily AI analysis is optional and currently unavailable.")
                        .font(.system(size: 13, weight: .semibold))
                    Text(
                        aiRecapIsConnected
                            ? "Generate it once to turn the day's activity and conversations into a concise narrative."
                            : "Set it up once, then Goalong can summarize the day from the sources shown above."
                    )
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
            }
        }

        private func markdownPreview(_ markdown: String) -> some View {
            Text(.init(markdown))
                .font(.system(size: 11))
                .lineSpacing(4)
                .lineLimit(16)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
        }

        private var aiRecapSubtitle: String {
            if recapRuntime.isGenerating {
                return "Building a concise account of the day."
            }
            if let recap = recapRuntime.recap {
                return "Updated \(recap.generatedAt.formatted(date: .abbreviated, time: .shortened))."
            }
            return "A concise optional synthesis of what happened and what comes next."
        }

        private var aiRecapIsConnected: Bool {
            if case .connected = recapRuntime.connectionState { return true }
            return false
        }

        private var screenTimeValue: String {
            guard let duration = displayedScreenTimeSummary?.totalScreenOnDuration else {
                return screenTime.unfilteredSummary == nil ? "—" : "0m"
            }
            return formattedDuration(duration)
        }

        private var screenTimeDetail: String {
            guard screenTime.unfilteredSummary != nil else { return "Apple data not available" }
            guard let summary = displayedScreenTimeSummary else { return "No active Apple device" }
            let count = summary.deviceSummaries.count
            let suffix = includesInactiveSystemTime && hasHiddenInactiveSystemTime
                ? " · login and lock-screen time included"
                : ""
            return "\(count) Apple device\(count == 1 ? "" : "s")\(suffix)"
        }

        private var displayedScreenTimeSummary: AppleScreenTimeDaySummary? {
            OverviewUsageProjection.summary(
                filtered: screenTime.summary,
                allReported: screenTime.unfilteredSummary,
                includesInactiveSystemTime: includesInactiveSystemTime
            )
        }

        private var hasHiddenInactiveSystemTime: Bool {
            OverviewUsageProjection.hasHiddenInactiveSystemTime(
                filtered: screenTime.summary,
                allReported: screenTime.unfilteredSummary
            )
        }

        private var combinedAppUsage: [DailyAppUsage] {
            OverviewUsageProjection.applications(
                filteredSummary: screenTime.summary,
                allReportedSummary: screenTime.unfilteredSummary,
                goalongUsage: model.snapshot.trackedUsage,
                currentMacDeviceID: screenTime.currentMacDeviceID,
                includesInactiveSystemTime: includesInactiveSystemTime
            )
        }

        private var topWebsiteUsage: [TrackedUsageItem] {
            OverviewUsageProjection.websites(model.snapshot.trackedUsage)
        }

        private func formattedDuration(_ seconds: TimeInterval) -> String {
            guard seconds > 0 else { return "0m" }
            return DashboardFormatters.duration(seconds: seconds)
        }

        private func selectDay(_ date: Date) {
            model.selectDay(date)
            screenTime.selectDay(date)
            recapRuntime.selectDay(date)
        }

        private func refreshAll() {
            model.refreshEverything()
            screenTime.refresh()
        }

        private func synchronizeSecondarySources(with date: Date) {
            let normalized = Calendar.current.startOfDay(for: date)
            if screenTime.selectedDay != normalized {
                screenTime.selectDay(normalized)
            }
            recapRuntime.selectDay(normalized)
        }

        private func timelineLegend(label: String, color: Color) -> some View {
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(label)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }

    struct DailyAppUsage: Identifiable, Equatable {
        let id: String
        var name: String
        var bundleIdentifier: String?
        var appleCurrentMacSeconds: TimeInterval
        var appleOtherDeviceSeconds: TimeInterval
        var goalongSeconds: TimeInterval

        var screenTimeSeconds: TimeInterval {
            appleCurrentMacSeconds + appleOtherDeviceSeconds
        }

        // Apple and Goalong can describe the same foreground period on this Mac.
        // Reconcile that overlap first, then add Apple usage from distinct devices.
        var displaySeconds: TimeInterval {
            appleOtherDeviceSeconds + max(appleCurrentMacSeconds, goalongSeconds)
        }

        var sourceDetail: String {
            if screenTimeSeconds > 0, goalongSeconds > 0 {
                return "Apple \(DashboardFormatters.duration(seconds: screenTimeSeconds)) · Goalong \(DashboardFormatters.duration(seconds: goalongSeconds)) observed on this Mac"
            }
            if screenTimeSeconds > 0 { return "Apple Screen Time" }
            return "Goalong observed foreground on this Mac"
        }
    }

    enum OverviewUsageMode: String, CaseIterable, Identifiable {
        case applications
        case websites

        var id: String { rawValue }

        var title: String {
            switch self {
            case .applications: return "Applications"
            case .websites: return "Websites"
            }
        }

        var detail: String {
            switch self {
            case .applications:
                return "All active-use apps, with Apple and Goalong reconciled without double counting. Login and lock-screen time is hidden by default."
            case .websites:
                return "Goalong-observed browser time on this Mac. Already included in app totals; Apple does not expose per-site iPhone or iPad detail."
            }
        }
    }

    enum OverviewUsageProjection {
        static func summary(
            filtered: AppleScreenTimeDaySummary?,
            allReported: AppleScreenTimeDaySummary?,
            includesInactiveSystemTime: Bool
        ) -> AppleScreenTimeDaySummary? {
            includesInactiveSystemTime ? (allReported ?? filtered) : filtered
        }

        static func hasHiddenInactiveSystemTime(
            filtered: AppleScreenTimeDaySummary?,
            allReported: AppleScreenTimeDaySummary?
        ) -> Bool {
            guard let allReported else { return false }
            let filteredDuration = filtered?.totalScreenOnDuration ?? 0
            if allReported.totalScreenOnDuration > filteredDuration + 0.5 { return true }

            let filteredIDs = Set(
                filtered?.deviceSummaries.flatMap(\.applications).map(\.id) ?? []
            )
            return allReported.deviceSummaries
                .flatMap(\.applications)
                .contains { !filteredIDs.contains($0.id) }
        }

        static func applications(
            filteredSummary: AppleScreenTimeDaySummary?,
            allReportedSummary: AppleScreenTimeDaySummary?,
            goalongUsage: [TrackedUsageItem],
            currentMacDeviceID: String,
            includesInactiveSystemTime: Bool
        ) -> [DailyAppUsage] {
            let selectedSummary = summary(
                filtered: filteredSummary,
                allReported: allReportedSummary,
                includesInactiveSystemTime: includesInactiveSystemTime
            )
            var merged: [String: DailyAppUsage] = [:]

            for deviceSummary in selectedSummary?.deviceSummaries ?? [] {
                for application in deviceSummary.applications {
                    let key = appKey(
                        name: application.resolvedName,
                        bundleIdentifier: application.bundleIdentifier
                    )
                    let isCurrentMac = deviceSummary.device.id == currentMacDeviceID
                    if var existing = merged[key] {
                        if isCurrentMac {
                            existing.appleCurrentMacSeconds += application.duration
                        } else {
                            existing.appleOtherDeviceSeconds += application.duration
                        }
                        merged[key] = existing
                    } else {
                        merged[key] = DailyAppUsage(
                            id: key,
                            name: application.resolvedName,
                            bundleIdentifier: application.bundleIdentifier,
                            appleCurrentMacSeconds: isCurrentMac ? application.duration : 0,
                            appleOtherDeviceSeconds: isCurrentMac ? 0 : application.duration,
                            goalongSeconds: 0
                        )
                    }
                }
            }

            for application in goalongUsage where application.kind == .application {
                if !includesInactiveSystemTime,
                   !AppleScreenTimeUsageFilter.countsTowardDeviceUsage(
                       bundleIdentifier: application.bundleIdentifier,
                       deviceKind: .mac
                   )
                {
                    continue
                }
                let key = appKey(
                    name: application.name,
                    bundleIdentifier: application.bundleIdentifier
                )
                if var existing = merged[key] {
                    existing.goalongSeconds = max(
                        existing.goalongSeconds,
                        application.foregroundSeconds
                    )
                    if existing.bundleIdentifier == nil {
                        existing.bundleIdentifier = application.bundleIdentifier
                    }
                    if existing.name == (existing.bundleIdentifier ?? "") {
                        existing.name = application.name
                    }
                    merged[key] = existing
                } else {
                    merged[key] = DailyAppUsage(
                        id: key,
                        name: application.name,
                        bundleIdentifier: application.bundleIdentifier,
                        appleCurrentMacSeconds: 0,
                        appleOtherDeviceSeconds: 0,
                        goalongSeconds: application.foregroundSeconds
                    )
                }
            }

            return merged.values.sorted { lhs, rhs in
                if lhs.displaySeconds != rhs.displaySeconds {
                    return lhs.displaySeconds > rhs.displaySeconds
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        }

        static func websites(_ trackedUsage: [TrackedUsageItem]) -> [TrackedUsageItem] {
            trackedUsage
                .filter {
                    $0.kind == .website
                        && $0.foregroundSeconds > 0
                        && SharingSubjectKey.displayableWebsiteHost($0.host ?? $0.name) != nil
                }
                .sorted { lhs, rhs in
                    if lhs.foregroundSeconds != rhs.foregroundSeconds {
                        return lhs.foregroundSeconds > rhs.foregroundSeconds
                    }
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
        }

        static func appleApplications(
            _ summary: AppleScreenTimeDaySummary?
        ) -> [AppleScreenTimeApplicationUsage] {
            var merged: [String: AppleScreenTimeApplicationUsage] = [:]
            for application in summary?.deviceSummaries.flatMap(\.applications) ?? [] {
                if let existing = merged[application.id] {
                    merged[application.id] = AppleScreenTimeApplicationUsage(
                        bundleIdentifier: existing.bundleIdentifier ?? application.bundleIdentifier,
                        displayName: existing.displayName ?? application.displayName,
                        duration: existing.duration + application.duration
                    )
                } else {
                    merged[application.id] = application
                }
            }
            return merged.values.sorted { lhs, rhs in
                if lhs.duration != rhs.duration { return lhs.duration > rhs.duration }
                return lhs.resolvedName.localizedCaseInsensitiveCompare(rhs.resolvedName)
                    == .orderedAscending
            }
        }

        private static func appKey(name: String, bundleIdentifier: String?) -> String {
            if let bundleIdentifier, !bundleIdentifier.isEmpty {
                return "bundle:\(bundleIdentifier.lowercased())"
            }
            let normalized = name
                .lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .joined()
            return "name:\(normalized)"
        }
    }

    private struct TimelineStrip: View {
        let buckets: [TimelineBucket]

        var body: some View {
            VStack(spacing: 7) {
                GeometryReader { proxy in
                    let spacing: CGFloat = 2
                    let totalSpacing = spacing * CGFloat(max(0, buckets.count - 1))
                    let width = max(2, (proxy.size.width - totalSpacing) / CGFloat(max(1, buckets.count)))
                    HStack(spacing: spacing) {
                        ForEach(buckets) { bucket in
                            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                                .fill(color(for: bucket.kind))
                                .frame(width: width)
                                .help(helpText(for: bucket))
                        }
                    }
                }
                .frame(height: 30)

                HStack {
                    Text("00:00")
                    Spacer()
                    Text("06:00")
                    Spacer()
                    Text("12:00")
                    Spacer()
                    Text("18:00")
                    Spacer()
                    Text("24:00")
                }
                .font(.system(size: 9, design: .rounded))
                .foregroundStyle(.tertiary)
            }
        }

        private func color(for kind: TimelineBucketKind) -> Color {
            switch kind {
            case .work: return LHTheme.success
            case .active: return LHTheme.teal
            case .privateOrSuppressed: return LHTheme.privateTint
            case .sealed: return Color.secondary.opacity(0.38)
            case .future: return Color.primary.opacity(0.025)
            case .noData: return Color.primary.opacity(0.075)
            }
        }

        private func helpText(for bucket: TimelineBucket) -> String {
            let range =
                "\(DashboardFormatters.shortTime.string(from: bucket.start))–\(DashboardFormatters.shortTime.string(from: bucket.end))"
            return
                "\(range) · \(bucket.activeMinutes)m active · \(bucket.workMinutes)m work · \(bucket.privateMinutes)m private"
        }
    }
#endif
