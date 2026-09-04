#if os(macOS)
    import AppleScreenTime
    import SwiftUI

    struct GoalongScreenTimePage: View {
        @ObservedObject private var dashboard: DashboardViewModel
        @StateObject private var screenTime: AppleScreenTimeDashboardModel
        @ObservedObject private var consents = GoalongCapabilityConsentStore.shared
        @State private var search = ""
        @State private var showsAllUsage = false
        @State private var usageMode: UsageBreakdownMode = .websites
        @State private var expandedBrowserIDs = Set<String>()
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
                        selectedDay: model.selectedDay,
                        accessEnabled: GoalongCapabilityConsentStore.shared.isEnabled(.appleScreenTime)
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

                    screenTimeConsentCard

                    if consents.isEnabled(.appleScreenTime) {
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
                }
                .padding(.horizontal, 24)
                .padding(.top, showsHeader ? 28 : 18)
                .padding(.bottom, 48)
            }
            .background(LHTheme.pageBackground)
            .onAppear {
                screenTime.setAccessEnabled(consents.isEnabled(.appleScreenTime))
                screenTime.setActive(dashboard.dashboardIsVisible)
                if screenTime.selectedDay != dashboard.selectedDay {
                    screenTime.selectDay(dashboard.selectedDay)
                }
                dashboard.refreshEverything()
            }
            .onDisappear { screenTime.setActive(false) }
            .onChange(of: consents.document) { _ in
                screenTime.setAccessEnabled(consents.isEnabled(.appleScreenTime))
            }
            .onChange(of: dashboard.dashboardIsVisible) { screenTime.setActive($0) }
            .onChange(of: dashboard.selectedDay) { day in
                showsAllUsage = false
                expandedBrowserIDs.removeAll()
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

        private var screenTimeConsentCard: some View {
            LHCard {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "macbook.and.iphone")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(LHTheme.accent)
                        .frame(width: 42, height: 42)
                        .background(
                            LHTheme.accent.opacity(0.1),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                        )
                    VStack(alignment: .leading, spacing: 5) {
                        Text(consents.isEnabled(.appleScreenTime) ? "Apple Screen Time enabled" : "Apple Screen Time is off")
                            .font(.system(size: 13, weight: .semibold))
                        Text(
                            "When enabled, Goalong reads Apple’s local Screen Time stores in place. It does not copy the databases or send their contents. Full Disk Access is broad and remains controlled separately by macOS."
                        )
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 14)
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { consents.isEnabled(.appleScreenTime) },
                            set: {
                                _ = consents.set(.appleScreenTime, enabled: $0, surface: .settings)
                            }
                        )
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                }
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
            let breakdown = UsageBreakdownProjection.build(
                summary: screenTime.summary,
                trackedUsage: dashboard.snapshot.trackedUsage
            )
            let allItems = breakdown.items(for: usageMode)
            let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let matchingItems = query.isEmpty
                ? allItems
                : allItems.filter { $0.searchableText.contains(query) }
            let items = query.isEmpty
                ? UsageBreakdownProjection.presentedItems(
                    matchingItems,
                    showsAll: showsAllUsage
                )
                : matchingItems
            let hiddenCount = query.isEmpty ? max(0, allItems.count - items.count) : 0
            let shownSeconds = items.reduce(0) { $0 + $1.seconds }
            let hiddenSeconds = query.isEmpty
                ? UsageBreakdownProjection.hiddenSeconds(
                    totalSeconds: breakdown.totalSeconds,
                    presentedItems: items
                )
                : 0

            return LHCard(padding: 0) {
                LazyVStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Where your screen time went")
                                    .font(.system(size: 14, weight: .semibold))
                                Text(
                                    usageMode == .websites
                                        ? "Apps and sites share one ranking. Browser rows stay hidden."
                                        : "The same usage is grouped by browser. Expand a browser to see its sites."
                                )
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 12)
                            VStack(alignment: .trailing, spacing: 4) {
                                Toggle("Group sites by browser", isOn: groupsSitesByBrowser)
                                    .toggleStyle(.switch)
                                    .controlSize(.small)
                                    .accessibilityHint(
                                        "Changes only how the same usage is grouped. Off lists sites beside apps. On lists browsers that expand into sites."
                                    )
                                    .help(
                                        "Show the same Screen Time grouped into expandable browser rows instead of individual website rows."
                                    )

                                Text("Same usage and total; only the grouping changes.")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.trailing)
                                    .frame(maxWidth: 300, alignment: .trailing)
                            }
                        }

                        HStack(spacing: 8) {
                            Image(systemName: "magnifyingglass")
                                .foregroundStyle(.secondary)
                            TextField("Search apps, websites, or browsers", text: $search)
                                .textFieldStyle(.plain)
                            if !search.isEmpty {
                                Button {
                                    search = ""
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Clear search")
                            }
                            Text("\(matchingItems.count) result\(matchingItems.count == 1 ? "" : "s")")
                                .font(.system(size: 9, weight: .medium, design: .rounded))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 34)
                        .background(
                            Color.primary.opacity(0.04),
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                        )
                    }
                    .padding(14)

                    Divider()

                    screenTimeBreakdownRows(items, query: query, hasHiddenUsage: hiddenCount > 0)
                        .padding(.horizontal, 16)

                    if query.isEmpty, breakdown.totalSeconds > 0.5 {
                        Divider()
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 10) {
                                if hiddenSeconds > 0.5 {
                                    Text("Shown \(duration(shownSeconds))")
                                    Text("·")
                                    Text("More \(duration(hiddenSeconds))")
                                    Text("·")
                                    Text("Total \(duration(breakdown.totalSeconds))")
                                        .fontWeight(.semibold)
                                } else {
                                    Text("All \(duration(breakdown.totalSeconds)) shown")
                                        .fontWeight(.semibold)
                                }
                                Spacer()
                                if hiddenCount > 0 || showsAllUsage {
                                    Button {
                                        showsAllUsage.toggle()
                                    } label: {
                                        Label(
                                            showsAllUsage
                                                ? "Show less"
                                                : "Show \(hiddenCount) more · \(duration(hiddenSeconds))",
                                            systemImage: showsAllUsage ? "chevron.up" : "chevron.down"
                                        )
                                    }
                                    .buttonStyle(.bordered)
                                    .accessibilityValue(showsAllUsage ? "Expanded" : "Collapsed")
                                }
                            }
                            .font(.system(size: 9, design: .rounded))
                            .foregroundStyle(.secondary)

                            Text(
                                "Apple total across the selected devices. Simultaneous use on different devices may overlap. Website details currently cover this Mac only."
                            )
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(14)
                    }
                }
            }
        }

        private var groupsSitesByBrowser: Binding<Bool> {
            Binding(
                get: { usageMode == .browsers },
                set: { groups in
                    usageMode = groups ? .browsers : .websites
                    showsAllUsage = false
                    expandedBrowserIDs.removeAll()
                }
            )
        }

        @ViewBuilder private func screenTimeBreakdownRows(
            _ items: [UsageBreakdownItem],
            query: String,
            hasHiddenUsage: Bool
        ) -> some View {
            if items.isEmpty {
                EmptyStateView(
                    symbol: query.isEmpty ? "clock" : "magnifyingglass",
                    title: query.isEmpty ? "No active use for this day" : "No matching activity",
                    message: query.isEmpty
                        ? hasHiddenUsage
                            ? "No activity reached five minutes. Show more to include shorter use."
                            : screenTime.status.message
                        : "No app, website, or browser matches this search."
                )
                .frame(minHeight: 140)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        if item.kind == .browser {
                            DisclosureGroup(isExpanded: screenTimeBrowserBinding(item.id)) {
                                screenTimeBreakdownChildren(item.children)
                            } label: {
                                screenTimeBreakdownLabel(item)
                            }
                            .padding(.vertical, 10)
                        } else {
                            screenTimeBreakdownLabel(item)
                                .padding(.vertical, 10)
                        }

                        if index < items.count - 1 {
                            Divider().padding(.leading, 50)
                        }
                    }
                }
            }
        }

        private func screenTimeBreakdownLabel(_ item: UsageBreakdownItem) -> some View {
            HStack(spacing: 12) {
                screenTimeBreakdownIcon(item)
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.name)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Text(screenTimeBreakdownDetail(item))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Text(duration(item.seconds))
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .monospacedDigit()
            }
            .accessibilityElement(children: .combine)
        }

        @ViewBuilder private func screenTimeBreakdownIcon(
            _ item: UsageBreakdownItem
        ) -> some View {
            switch item.kind {
            case .application, .browser:
                AppIconView(
                    bundleIdentifier: item.bundleIdentifier,
                    appName: item.name,
                    size: 38
                )
            case .website:
                WebsiteIconView(host: item.host ?? item.name, size: 38)
            case .otherWeb, .otherActive:
                Image(systemName: item.kind == .otherWeb ? "globe.desk" : "clock")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 38, height: 38)
                    .background(
                        Color.primary.opacity(0.05),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
            }
        }

        private func screenTimeBreakdownDetail(_ item: UsageBreakdownItem) -> String {
            switch item.kind {
            case .application: return "Application"
            case .website: return "Website · This Mac"
            case .browser:
                let count = item.children.filter { $0.kind == .website }.count
                return count == 0
                    ? "Browser · no public site detail available"
                    : "Browser · expand for \(count) site\(count == 1 ? "" : "s")"
            case .otherWeb: return "Browser time without a public site detail"
            case .otherActive: return "Active time without an application attribution"
            }
        }

        private func screenTimeBrowserBinding(_ id: String) -> Binding<Bool> {
            Binding(
                get: { expandedBrowserIDs.contains(id) },
                set: { isExpanded in
                    if isExpanded { expandedBrowserIDs.insert(id) }
                    else { expandedBrowserIDs.remove(id) }
                }
            )
        }

        private func screenTimeBreakdownChildren(
            _ children: [UsageBreakdownChild]
        ) -> some View {
            VStack(spacing: 0) {
                ForEach(children) { child in
                    HStack(spacing: 10) {
                        if child.kind == .website {
                            WebsiteIconView(host: child.host ?? child.name, size: 26)
                        } else {
                            Image(systemName: "ellipsis")
                                .foregroundStyle(.secondary)
                                .frame(width: 26, height: 26)
                        }
                        Text(child.name)
                            .font(.system(size: 10, weight: .medium))
                            .lineLimit(1)
                        Spacer()
                        Text(duration(child.seconds))
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                    }
                    .padding(.leading, 50)
                    .padding(.vertical, 7)
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
                        Text("Export Screen Time source data")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Exports preserve the selected device scope and exact source provenance; private formats do not claim certified Settings parity.")
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
                            "Goalong reads Apple-owned ScreenTimeAgent, ScreenTime.AppUsage, knowledgeC and Biome data directly in the background only for the active day. It keeps one compact local day record, then reads that record forever after the day closes without reopening Apple history. It never opens or controls System Settings or sends mouse or keyboard events."
                        )
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    if screenTime.storageState == .completedDayStored {
                        Text("Stored completed day · Apple not re-read")
                            .font(.system(size: 8, weight: .semibold, design: .rounded))
                            .foregroundStyle(LHTheme.success)
                    } else if usesAppleAggregateStore {
                        Text(aggregateSourceLabel)
                            .font(.system(size: 8, weight: .semibold, design: .rounded))
                            .foregroundStyle(LHTheme.success)
                    } else {
                        VStack(alignment: .trailing, spacing: 3) {
                            Text("\(screenTime.screenTimeAppUsageIntervalCount) AppUsage intervals")
                            Text("\(screenTime.knowledgeIntervalCount) knowledgeC intervals")
                            Text("\(screenTime.biomeIntervalCount) Biome intervals")
                        }
                        .font(.system(size: 8, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }

        private var usesAppleAggregateStore: Bool {
            screenTime.summary?.provenance.usesScreenTimeAgentAggregateStore == true
        }

        private var aggregateSourceLabel: String {
            "Private Apple aggregate · background only"
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

    }
#endif
