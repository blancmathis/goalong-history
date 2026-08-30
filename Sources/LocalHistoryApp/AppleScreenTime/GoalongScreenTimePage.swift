#if os(macOS)
    import AppleScreenTime
    import SwiftUI

    struct GoalongScreenTimePage: View {
        @ObservedObject private var dashboard: DashboardViewModel
        @StateObject private var screenTime: AppleScreenTimeDashboardModel
        @State private var mode: UsageMode = .applications
        @State private var search = ""
        private let showsHeader: Bool

        init(
            model: DashboardViewModel,
            screenTimeModel: AppleScreenTimeDashboardModel? = nil,
            showsHeader: Bool = true
        ) {
            _dashboard = ObservedObject(wrappedValue: model)
            self.showsHeader = showsHeader
            _screenTime = StateObject(
                wrappedValue: screenTimeModel
                    ?? AppleScreenTimeDashboardModel(
                        rootDirectory: AppPaths.screenTimeDirectory,
                        deviceID: model.deviceID,
                        selectedDay: model.selectedDay
                    )
            )
        }

        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if showsHeader {
                        PageHeader(
                            eyebrow: "Apple system data",
                            title: "Apple Screen Time",
                            subtitle:
                                "See what you used first. Apple application totals stay separate from Goalong's locally observed website history."
                        ) {
                            HStack(spacing: 10) {
                                DateSelectionControl(date: screenTime.selectedDay, onChange: selectDay)
                                Button {
                                    dashboard.refreshEverything()
                                    screenTime.refresh()
                                } label: {
                                    Image(systemName: "arrow.clockwise")
                                        .frame(width: 28, height: 28)
                                }
                                .buttonStyle(.bordered)
                                .disabled(screenTime.isBusy)
                            }
                        }
                    }

                    statusBanner

                    if let summary = screenTime.summary {
                        dayOverview(summary)
                    }

                    usageCard
                    deviceScopeCard
                    deviceUsageCard
                    shareCard
                    sourceCard
                }
                .padding(.horizontal, 24)
                .padding(.top, showsHeader ? 28 : 18)
                .padding(.bottom, 48)
            }
            .background(LHTheme.pageBackground)
            .onAppear {
                screenTime.setActive(dashboard.dashboardIsVisible)
                if screenTime.selectedDay != dashboard.selectedDay {
                    screenTime.selectDay(dashboard.selectedDay)
                }
                dashboard.refreshEverything()
            }
            .onDisappear { screenTime.setActive(false) }
            .onChange(of: dashboard.dashboardIsVisible) { screenTime.setActive($0) }
            .onChange(of: dashboard.selectedDay) { day in
                if screenTime.selectedDay != day {
                    screenTime.selectDay(day)
                }
            }
            .alert(item: $screenTime.alert) { item in
                Alert(
                    title: Text(item.title),
                    message: Text(item.message),
                    dismissButton: .default(Text("OK"))
                )
            }
        }

        private var statusBanner: some View {
            HStack(alignment: .top, spacing: 13) {
                Image(systemName: statusSymbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(statusTint)
                    .frame(width: 40, height: 40)
                    .background(statusTint.opacity(0.10), in: RoundedRectangle(cornerRadius: 11, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text(screenTime.status.title)
                        .font(.system(size: 12, weight: .semibold))
                    Text(screenTime.status.message)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 16)
                if screenTime.isBusy { ProgressView().controlSize(.small) }

                if screenTime.needsFullDiskAccess {
                    Button("Open Full Disk Access") {
                        screenTime.openFullDiskAccessSettings()
                    }
                    .buttonStyle(.borderedProminent)
                } else if screenTime.status.kind == .localOnly || screenTime.status.kind == .noAppleData {
                    Button("Screen Time settings") {
                        screenTime.openScreenTimeSettings()
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(14)
            .background(statusTint.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(statusTint.opacity(0.14), lineWidth: 1)
            )
        }

        private var usageCard: some View {
            LHCard(padding: 0) {
                LazyVStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 12) {
                            Picker("Usage", selection: $mode) {
                                ForEach(UsageMode.allCases) { item in
                                    Text(item.title).tag(item)
                                }
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 300)

                            HStack(spacing: 8) {
                                Image(systemName: "magnifyingglass")
                                    .foregroundStyle(.secondary)
                                TextField(mode.searchPlaceholder, text: $search)
                                    .textFieldStyle(.plain)
                                if !search.isEmpty {
                                    Button {
                                        search = ""
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 10)
                            .frame(height: 34)
                            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

                            Spacer()
                            Text(usageCountText)
                                .font(.system(size: 10, weight: .medium, design: .rounded))
                                .foregroundStyle(.secondary)
                        }

                        Text(mode.detail)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(14)

                    Divider()

                    if mode == .applications {
                        applicationRows
                    } else {
                        websiteRows
                    }
                }
            }
        }

        @ViewBuilder private var applicationRows: some View {
            let apps = filteredApplications
            if apps.isEmpty {
                EmptyStateView(
                    symbol: "square.grid.2x2",
                    title: "No application usage",
                    message: screenTime.summary == nil
                        ? screenTime.status.message
                        : "No Apple application matches this search."
                )
                .frame(minHeight: 230)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(Array(apps.enumerated()), id: \.element.id) { index, app in
                        HStack(spacing: 12) {
                            AppIconView(
                                bundleIdentifier: app.bundleIdentifier,
                                appName: app.resolvedName,
                                size: 38
                            )
                            VStack(alignment: .leading, spacing: 3) {
                                Text(app.resolvedName)
                                    .font(.system(size: 12, weight: .semibold))
                                    .lineLimit(1)
                                if let bundleIdentifier = app.bundleIdentifier {
                                    Text(bundleIdentifier)
                                        .font(.system(size: 8, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                            Text(duration(app.duration))
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                .monospacedDigit()
                        }
                        .padding(.horizontal, 16)
                        .frame(minHeight: 62)

                        if index < apps.count - 1 {
                            Divider().padding(.leading, 66)
                        }
                    }
                }
            }
        }

        @ViewBuilder private var websiteRows: some View {
            let sites = filteredWebsites
            if sites.isEmpty {
                EmptyStateView(
                    symbol: "globe",
                    title: search.isEmpty ? "No website activity" : "No matching website",
                    message: search.isEmpty
                        ? "No public website URL was exposed by the active browsers for this day. iPhone and iPad website detail is not available from Apple's local Screen Time stores."
                        : "No locally observed website matches this search."
                )
                .frame(minHeight: 230)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(sites.enumerated()), id: \.element.id) { index, site in
                        HStack(spacing: 12) {
                            WebsiteIconView(host: site.host ?? site.name, size: 38)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(site.host ?? site.name)
                                    .font(.system(size: 12, weight: .semibold))
                                    .lineLimit(1)
                                Text(websiteDetail(site))
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Text(DashboardFormatters.duration(seconds: site.foregroundSeconds))
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                .monospacedDigit()
                        }
                        .padding(.horizontal, 16)
                        .frame(minHeight: 62)

                        if index < sites.count - 1 {
                            Divider().padding(.leading, 66)
                        }
                    }
                }
            }
        }

        private func dayOverview(_ summary: AppleScreenTimeDaySummary) -> some View {
            LHCard(padding: 0) {
                VStack(spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: 16) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Day overview")
                                .font(.system(size: 14, weight: .semibold))
                            Text("Apple Screen Time for the selected day and device scope.")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(scopeDescription)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)

                    Divider()

                    HStack(spacing: 0) {
                        overviewMetric(
                            title: "TOTAL SCREEN TIME",
                            value: duration(summary.totalScreenOnDuration),
                            detail: totalScreenTimeDetail(summary),
                            symbol: "hourglass",
                            isPrimary: true,
                            accessibilityIdentifier: "screen-time-day-total"
                        )
                        overviewDivider
                        overviewMetric(
                            title: "APPLICATIONS",
                            value: String(OverviewUsageProjection.appleApplications(summary).count),
                            detail: "Apps with recorded use",
                            symbol: "square.grid.2x2.fill",
                            accessibilityIdentifier: "screen-time-day-applications"
                        )
                        overviewDivider
                        overviewMetric(
                            title: "DEVICES",
                            value: String(summary.deviceSummaries.count),
                            detail: "Included in this total",
                            symbol: "macbook.and.iphone",
                            accessibilityIdentifier: "screen-time-day-devices"
                        )
                        overviewDivider
                        overviewMetric(
                            title: "APPLE UPDATE",
                            value: screenTime.latestAppleUpdate.map(relativeDate) ?? "—",
                            detail: screenTime.selectedDayIsToday
                                ? "Automatic every 30 seconds"
                                : "Latest stored Apple event",
                            symbol: "icloud.and.arrow.down",
                            accessibilityIdentifier: "screen-time-day-update"
                        )
                    }
                    .padding(.vertical, 15)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("screen-time-day-overview")
        }

        private var deviceScopeCard: some View {
            LHCard {
                VStack(alignment: .leading, spacing: 13) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Devices included")
                                .font(.system(size: 14, weight: .semibold))
                            Text("Apple devices detected on this Mac stay selectable even when Apple reports no usage for the selected day.")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Picker(
                            "Device scope",
                            selection: Binding(
                                get: { screenTime.configuration.scope.mode },
                                set: { screenTime.setScopeMode($0) }
                            )
                        ) {
                            Text("This Mac").tag(AppleScreenTimeScopeMode.macOnly)
                            Text("All devices").tag(AppleScreenTimeScopeMode.allDevices)
                            Text("Selected devices").tag(AppleScreenTimeScopeMode.selectedDevices)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 350)
                    }

                    if screenTime.configuration.scope.mode == .selectedDevices {
                        Divider()
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 9)], spacing: 9) {
                            ForEach(screenTime.availableDevices) { device in
                                Button {
                                    screenTime.toggleDevice(device)
                                } label: {
                                    HStack(spacing: 9) {
                                        Image(systemName: deviceSymbol(device.kind))
                                            .frame(width: 18)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(device.displayName)
                                                .font(.system(size: 11, weight: .semibold))
                                                .lineLimit(1)
                                            Text(deviceDetail(device))
                                                .font(.system(size: 9))
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                        Spacer()
                                        Image(systemName: screenTime.selectedDeviceIDs.contains(device.id) ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(screenTime.selectedDeviceIDs.contains(device.id) ? LHTheme.accent : Color.secondary)
                                    }
                                    .padding(10)
                                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }

        private var deviceUsageCard: some View {
            LHCard {
                VStack(alignment: .leading, spacing: 13) {
                    SectionTitle(
                        title: "Usage by device",
                        subtitle: "The raw Apple peer ID is kept internally; the UI shows a stable readable device label."
                    )

                    if let summaries = screenTime.summary?.deviceSummaries, !summaries.isEmpty {
                        VStack(spacing: 0) {
                            ForEach(Array(summaries.enumerated()), id: \.element.id) { index, item in
                                HStack(spacing: 11) {
                                    Image(systemName: deviceSymbol(item.device.kind))
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(LHTheme.teal)
                                        .frame(width: 30, height: 30)
                                        .background(LHTheme.teal.opacity(0.09), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.device.displayName)
                                            .font(.system(size: 11, weight: .semibold))
                                        Text(deviceDetail(item.device))
                                            .font(.system(size: 9))
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(duration(item.screenOnDuration))
                                        .font(.system(size: 11, weight: .bold, design: .rounded))
                                        .monospacedDigit()
                                }
                                .padding(.vertical, 8)
                                if index < summaries.count - 1 { Divider().padding(.leading, 42) }
                            }
                        }
                    } else {
                        Text("No device usage is available for the current scope.")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }

        private var shareCard: some View {
            LHCard {
                HStack(spacing: 14) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(LHTheme.accent)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Export Apple Screen Time")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Exports preserve the selected device scope and Apple system-store provenance.")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker(
                        "Disclosure",
                        selection: Binding(
                            get: { screenTime.configuration.shareLevel },
                            set: { screenTime.setShareLevel($0) }
                        )
                    ) {
                        ForEach(AppleScreenTimeShareLevel.allCases, id: \.self) { level in
                            Text(level.displayName).tag(level)
                        }
                    }
                    .frame(width: 210)
                    Button("Export…") {
                        screenTime.exportSharePayload()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(screenTime.summary == nil || screenTime.isBusy)
                }
            }
        }

        private var sourceCard: some View {
            LHCard {
                HStack(alignment: .top, spacing: 13) {
                    Image(systemName: "apple.logo")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(LHTheme.success)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Data sources")
                            .font(.system(size: 12, weight: .semibold))
                        Text(
                            "Application and device totals come from Apple's local knowledgeC /app/usage database and iCloud-synchronized Biome App.InFocus streams. Explicit lock-screen and screen-saver intervals are excluded. Websites come only from Goalong's local Mac recorder and are already part of the browser application time; they are never added to Apple Screen Time."
                        )
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 3) {
                        Text("\(screenTime.knowledgeIntervalCount) knowledgeC intervals")
                        Text("\(screenTime.biomeIntervalCount) Biome intervals")
                    }
                    .font(.system(size: 8, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                }
            }
        }

        private var filteredApplications: [AppleScreenTimeApplicationUsage] {
            let values = OverviewUsageProjection.appleApplications(screenTime.summary)
            let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !query.isEmpty else { return values }
            return values.filter {
                [$0.resolvedName, $0.bundleIdentifier]
                    .compactMap { $0 }
                    .joined(separator: " ")
                    .lowercased()
                    .contains(query)
            }
        }

        private var filteredWebsites: [TrackedUsageItem] {
            let values = OverviewUsageProjection.websites(dashboard.snapshot.trackedUsage)
            let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !query.isEmpty else { return values }
            return values.filter { $0.searchableText.contains(query) }
        }

        private var usageCountText: String {
            switch mode {
            case .applications: return "\(filteredApplications.count) apps"
            case .websites: return "\(filteredWebsites.count) websites"
            }
        }

        private var scopeDescription: String {
            switch screenTime.configuration.scope.mode {
            case .macOnly: return "This Mac only"
            case .allDevices: return "All active Apple devices"
            case .selectedDevices: return "Selected active devices"
            }
        }

        private var statusTint: Color {
            switch screenTime.status.kind {
            case .ready: return LHTheme.success
            case .localOnly: return LHTheme.teal
            case .fullDiskAccessRequired, .noAppleData, .partial: return LHTheme.warning
            }
        }

        private var statusSymbol: String {
            switch screenTime.status.kind {
            case .ready: return "checkmark.icloud.fill"
            case .localOnly: return "laptopcomputer"
            case .fullDiskAccessRequired: return "lock.fill"
            case .noAppleData: return "icloud.slash"
            case .partial: return "exclamationmark.icloud.fill"
            }
        }

        private var overviewDivider: some View {
            Divider()
                .frame(height: 62)
        }

        private func overviewMetric(
            title: String,
            value: String,
            detail: String,
            symbol: String,
            isPrimary: Bool = false,
            accessibilityIdentifier: String
        ) -> some View {
            VStack(alignment: .leading, spacing: 6) {
                Label(title, systemImage: symbol)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: isPrimary ? 23 : 19, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .accessibilityIdentifier(accessibilityIdentifier)
                Text(detail)
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        private func totalScreenTimeDetail(_ summary: AppleScreenTimeDaySummary) -> String {
            if summary.deviceSummaries.count > 1 {
                return "Sum across \(summary.deviceSummaries.count) devices · simultaneous use may overlap · lock time excluded"
            }
            return "Active-use intervals · lock time excluded"
        }

        private func websiteDetail(_ site: TrackedUsageItem) -> String {
            [site.sourceApplicationLabel, "This Mac only"]
                .compactMap { $0 }
                .joined(separator: " · ")
        }

        private func deviceSymbol(_ kind: AppleScreenTimeDeviceKind) -> String {
            switch kind {
            case .mac: return "laptopcomputer"
            case .iPhone: return "iphone"
            case .iPad: return "ipad"
            case .iPod: return "ipod"
            case .appleWatch: return "applewatch"
            case .appleTV: return "appletv"
            case .homePod: return "homepod"
            case .visionPro: return "visionpro"
            case .unknown: return "display"
            }
        }

        private func deviceDetail(_ device: AppleScreenTimeDevice) -> String {
            if device.id == screenTime.currentMacDeviceID { return "This Mac" }
            return "\(device.kind.displayName) · \(screenTime.sourceLabel(for: device))"
        }

        private func duration(_ seconds: TimeInterval) -> String {
            let total = max(0, Int(seconds.rounded()))
            let hours = total / 3_600
            let minutes = (total % 3_600) / 60
            if hours > 0 { return "\(hours)h \(minutes)m" }
            if minutes > 0 { return "\(minutes)m" }
            return "\(total)s"
        }

        private func relativeDate(_ date: Date) -> String {
            if abs(date.timeIntervalSinceNow) < 60 {
                return "Just now"
            }
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .abbreviated
            return formatter.localizedString(for: date, relativeTo: Date())
        }

        private func selectDay(_ date: Date) {
            dashboard.selectDay(date)
            screenTime.selectDay(date)
        }

        private enum UsageMode: String, CaseIterable, Identifiable {
            case applications
            case websites

            var id: String { rawValue }
            var title: String {
                switch self {
                case .applications: return "Applications"
                case .websites: return "Websites"
                }
            }

            var searchPlaceholder: String {
                switch self {
                case .applications: return "Search applications"
                case .websites: return "Search websites"
                }
            }

            var detail: String {
                switch self {
                case .applications:
                    return "All active-use applications for the selected device scope. Login, lock-screen, and screen-saver time is excluded."
                case .websites:
                    return "Goalong-observed browser time on this Mac only. It is already included in browser app totals; changing the Apple device scope does not change this list. Apple does not expose reliable per-site iPhone or iPad detail here."
                }
            }
        }
    }
#endif
