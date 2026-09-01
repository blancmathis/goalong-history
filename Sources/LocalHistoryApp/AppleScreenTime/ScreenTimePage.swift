#if os(macOS)
    import AppleScreenTime
    import Foundation
    import SwiftUI

    struct ScreenTimePage: View {
        @ObservedObject private var dashboard: DashboardViewModel
        @StateObject private var screenTime: AppleScreenTimeDashboardModel

        init(model: DashboardViewModel) {
            _dashboard = ObservedObject(wrappedValue: model)
            _screenTime = StateObject(
                wrappedValue: AppleScreenTimeDashboardModel(
                    rootDirectory: AppPaths.screenTimeDirectory,
                    deviceID: model.deviceID,
                    selectedDay: model.selectedDay
                )
            )
        }

        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    PageHeader(
                        eyebrow: "Apple system data",
                        title: "Apple Screen Time",
                        subtitle:
                            "Read the Screen Time activity Apple stores on this Mac and synchronizes from your other devices through iCloud. Goalong History’s own recorder is not used for these numbers."
                    ) {
                        HStack(spacing: 10) {
                            DateSelectionControl(date: screenTime.selectedDay, onChange: screenTime.selectDay)
                            Button {
                                screenTime.refresh()
                            } label: {
                                Image(systemName: "arrow.clockwise")
                                    .frame(width: 28, height: 28)
                            }
                            .buttonStyle(.bordered)
                            .disabled(screenTime.isBusy)
                        }
                    }

                    appleStatusBanner
                    scopeCard

                    if let summary = screenTime.summary {
                        metrics(for: summary)
                        HStack(alignment: .top, spacing: 14) {
                            deviceCard(summary)
                            applicationCard(summary)
                        }
                        shareCard(summary)
                    } else {
                        emptyCard
                    }

                    sourceCard
                    storageCard
                }
                .padding(.horizontal, 24)
                .padding(.top, 28)
                .padding(.bottom, 50)
            }
            .background(LHTheme.pageBackground)
            .onAppear { screenTime.setActive(dashboard.dashboardIsVisible) }
            .onDisappear { screenTime.setActive(false) }
            .onChange(of: dashboard.dashboardIsVisible) { screenTime.setActive($0) }
            .alert(item: $screenTime.alert) { item in
                Alert(
                    title: Text(item.title),
                    message: Text(item.message),
                    dismissButton: .default(Text("OK"))
                )
            }
        }

        private var appleStatusBanner: some View {
            HStack(alignment: .top, spacing: 13) {
                featureIcon(statusSymbol, tint: statusTint)
                VStack(alignment: .leading, spacing: 4) {
                    Text(screenTime.status.title)
                        .font(.system(size: 12, weight: .semibold))
                    Text(screenTime.status.message)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if screenTime.status.kind == .ready || screenTime.status.kind == .localOnly {
                        Text("Freshness is controlled by Apple’s local/iCloud synchronization, not by a Goalong server.")
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 16)
                if screenTime.isBusy {
                    ProgressView()
                        .controlSize(.small)
                }
                statusAction
                StatusPill(
                    title: statusPillTitle,
                    symbol: statusSymbol,
                    tint: statusTint
                )
            }
            .padding(14)
            .background(statusTint.opacity(0.055), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(statusTint.opacity(0.14), lineWidth: 1)
            )
        }

        @ViewBuilder private var statusAction: some View {
            switch screenTime.status.kind {
            case .fullDiskAccessRequired:
                Button("Open Full Disk Access") {
                    screenTime.openFullDiskAccessSettings()
                }
                .buttonStyle(.borderedProminent)
            case .localOnly, .noAppleData:
                Button("Open Screen Time settings") {
                    screenTime.openScreenTimeSettings()
                }
                .buttonStyle(.bordered)
            case .ready, .partial:
                EmptyView()
            }
        }

        private var scopeCard: some View {
            LHCard {
                VStack(alignment: .leading, spacing: 15) {
                    sectionHeader(
                        symbol: "macbook.and.iphone",
                        tint: LHTheme.teal,
                        title: "Devices included",
                        subtitle:
                            "Choose the current Mac, every device Apple has synchronized, or an exact physical-device selection."
                    )

                    Picker(
                        "Device scope",
                        selection: Binding(
                            get: { screenTime.configuration.scope.mode },
                            set: { screenTime.setScopeMode($0) }
                        )
                    ) {
                        ForEach(AppleScreenTimeScopeMode.allCases, id: \.self) { mode in
                            Text(scopeTitle(mode)).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    HStack(spacing: 9) {
                        Image(systemName: scopeStatusSymbol)
                            .foregroundStyle(scopeStatusTint)
                        Text(scopeStatusMessage)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(11)
                    .background(
                        scopeStatusTint.opacity(0.065),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )

                    if screenTime.configuration.scope.mode == .selectedDevices {
                        Divider()
                        if screenTime.availableDevices.isEmpty {
                            Text("No Apple device has been discovered yet.")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        } else {
                            LazyVGrid(
                                columns: [GridItem(.adaptive(minimum: 215), spacing: 9)],
                                spacing: 9
                            ) {
                                ForEach(screenTime.availableDevices) { device in
                                    deviceSelectionButton(device)
                                }
                            }
                        }
                    }
                }
            }
        }

        private func metrics(for summary: AppleScreenTimeDaySummary) -> some View {
            HStack(spacing: 12) {
                metric(
                    title: "Apple Screen Time",
                    value: duration(summary.totalScreenOnDuration),
                    note: summary.deviceSummaries.count > 1
                        ? "Sum by device; simultaneous use is not deduplicated"
                        : "Apple app-usage intervals for this device",
                    symbol: "hourglass"
                )
                metric(
                    title: "Included devices",
                    value: String(summary.deviceSummaries.count),
                    note: scopeDescription(summary.scope),
                    symbol: "macbook.and.iphone"
                )
                metric(
                    title: "Applications",
                    value: String(summary.topApplications.count),
                    note: "Apple bundle-level application durations",
                    symbol: "square.grid.2x2.fill"
                )
                metric(
                    title: "Latest Apple update",
                    value: screenTime.latestAppleUpdate.map(relativeDate) ?? "—",
                    note: screenTime.selectedDayIsToday ? "Checked every 5 seconds" : "Last stored Apple event",
                    symbol: "icloud.and.arrow.down"
                )
            }
        }

        private func deviceCard(_ summary: AppleScreenTimeDaySummary) -> some View {
            LHCard {
                VStack(alignment: .leading, spacing: 14) {
                    sectionHeader(
                        symbol: "display.2",
                        tint: LHTheme.teal,
                        title: "Usage by Apple device",
                        subtitle: "Every row retains its physical-device identifier and Apple source."
                    )

                    if summary.deviceSummaries.isEmpty {
                        Text("The selected scope contains no Apple usage intervals for this day.")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(summary.deviceSummaries) { item in
                            HStack(spacing: 10) {
                                Image(systemName: deviceSymbol(item.device.kind))
                                    .foregroundStyle(LHTheme.teal)
                                    .frame(width: 20)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.device.displayName)
                                        .font(.system(size: 10, weight: .semibold))
                                        .lineLimit(1)
                                    Text(screenTime.sourceLabel(for: item.device))
                                        .font(.system(size: 8))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                if item.device.id == screenTime.currentMacDeviceID {
                                    StatusPill(
                                        title: "This Mac",
                                        symbol: "laptopcomputer",
                                        tint: LHTheme.success
                                    )
                                }
                                Text(duration(item.screenOnDuration))
                                    .font(.system(size: 11, weight: .bold, design: .rounded))
                                    .monospacedDigit()
                            }
                            .padding(.vertical, 3)
                            if item.id != summary.deviceSummaries.last?.id { Divider() }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }

        private func applicationCard(_ summary: AppleScreenTimeDaySummary) -> some View {
            LHCard {
                VStack(alignment: .leading, spacing: 14) {
                    sectionHeader(
                        symbol: "square.grid.2x2.fill",
                        tint: LHTheme.accent,
                        title: "Applications used",
                        subtitle:
                            "Durations come from Apple’s `/app/usage` records and synchronized `App.InFocus` transitions."
                    )

                    if summary.topApplications.isEmpty {
                        Text("No attributable Apple application activity is available for this scope and day.")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(summary.topApplications.prefix(12).enumerated()), id: \.element.id) { index, app in
                            HStack(spacing: 10) {
                                Text(String(index + 1))
                                    .font(.system(size: 9, weight: .bold, design: .rounded))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 18)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(app.resolvedName)
                                        .font(.system(size: 10, weight: .medium))
                                        .lineLimit(1)
                                    if let bundle = app.bundleIdentifier,
                                       app.displayName != nil
                                    {
                                        Text(bundle)
                                            .font(.system(size: 7, design: .monospaced))
                                            .foregroundStyle(.tertiary)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer()
                                Text(duration(app.duration))
                                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                                    .monospacedDigit()
                            }
                            .padding(.vertical, 3)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }

        private func shareCard(_ summary: AppleScreenTimeDaySummary) -> some View {
            LHCard {
                HStack(spacing: 16) {
                    featureIcon("square.and.arrow.up.on.square.fill", tint: LHTheme.accent)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Share this Apple-source view")
                            .font(.system(size: 13, weight: .semibold))
                        Text(
                            "The export states the exact device scope, Apple system-store provenance, aggregation rule and whether application details are included."
                        )
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 20)
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
                    Button {
                        screenTime.exportSharePayload()
                    } label: {
                        Label("Export Apple Screen Time", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(screenTime.isBusy || summary.deviceSummaries.isEmpty)
                }
            }
        }

        private var emptyCard: some View {
            LHCard {
                VStack(spacing: 16) {
                    EmptyStateView(
                        symbol: emptySymbol,
                        title: screenTime.status.title,
                        message: screenTime.status.message
                    )
                    .frame(minHeight: 210)

                    if screenTime.needsFullDiskAccess {
                        Button {
                            screenTime.openFullDiskAccessSettings()
                        } label: {
                            Label("Open Full Disk Access", systemImage: "lock.open.display")
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        Button {
                            screenTime.openScreenTimeSettings()
                        } label: {
                            Label("Open Screen Time settings", systemImage: "hourglass")
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }

        private var sourceCard: some View {
            LHCard {
                HStack(alignment: .top, spacing: 14) {
                    featureIcon("apple.logo", tint: LHTheme.success)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("What is being read")
                            .font(.system(size: 12, weight: .semibold))
                        Text(
                            "This page reads Apple-generated data directly: ScreenTime.AppUsage for the best available Mac attribution, knowledgeC `/app/usage` as a fallback, and Biome `App.InFocus` streams synchronized by iCloud for other devices. macOS may keep the private DeviceActivity summary used by Settings inaccessible, so reconstructed totals can differ from the Settings app."
                        )
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        Text(
                            "It never substitutes Goalong History foreground events. The Apple formats are private and may require maintenance after a macOS update."
                        )
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(LHTheme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 18)
                    VStack(alignment: .trailing, spacing: 5) {
                        Text("\(screenTime.screenTimeAppUsageIntervalCount) AppUsage intervals")
                        Text("\(screenTime.knowledgeIntervalCount) knowledgeC intervals")
                        Text("\(screenTime.biomeIntervalCount) Biome intervals")
                    }
                    .font(.system(size: 8, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                }
            }
        }

        private var storageCard: some View {
            LHCard {
                HStack(spacing: 13) {
                    Image(systemName: "internaldrive.fill")
                        .foregroundStyle(LHTheme.teal)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Read-only Apple access")
                            .font(.system(size: 11, weight: .semibold))
                        Text(
                            "Apple’s databases and streams are opened read-only. Goalong History stores only your device-scope configuration and any share file you explicitly export."
                        )
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button("Open Goalong config folder") {
                        screenTime.openConfigurationFolder()
                    }
                    .buttonStyle(.bordered)
                }
            }
        }

        private func deviceSelectionButton(_ device: AppleScreenTimeDevice) -> some View {
            let selected = screenTime.selectedDeviceIDs.contains(device.id)
            let isCurrentMac = device.id == screenTime.currentMacDeviceID
            return Button {
                screenTime.toggleDevice(device)
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: deviceSymbol(device.kind))
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(device.displayName)
                            .font(.system(size: 10, weight: .semibold))
                            .lineLimit(1)
                        Text(isCurrentMac ? "This Mac" : screenTime.sourceLabel(for: device))
                            .font(.system(size: 8))
                            .foregroundStyle(isCurrentMac ? LHTheme.success : Color.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? LHTheme.accent : Color.secondary)
                }
                .padding(11)
                .background(
                    selected ? LHTheme.accent.opacity(0.1) : Color.primary.opacity(0.035),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
            }
            .buttonStyle(.plain)
        }

        private var scopeStatusMessage: String {
            switch screenTime.configuration.scope.mode {
            case .macOnly:
                return "Only this physical Mac is included, using Apple’s own local usage records."
            case .allDevices:
                return screenTime.hasRemoteDevices
                    ? "This Mac plus all \(screenTime.remoteDeviceCount) Apple device stream\(screenTime.remoteDeviceCount == 1 ? "" : "s") synchronized here."
                    : "This Mac is included; Apple has not synchronized another device stream here yet."
            case .selectedDevices:
                let count = screenTime.selectedDeviceIDs.count
                return "\(count) exact physical device\(count == 1 ? "" : "s") selected."
            }
        }

        private var scopeStatusSymbol: String {
            if screenTime.configuration.scope.mode == .allDevices, !screenTime.hasRemoteDevices {
                return "exclamationmark.triangle.fill"
            }
            return "checkmark.circle.fill"
        }

        private var scopeStatusTint: Color {
            if screenTime.configuration.scope.mode == .allDevices, !screenTime.hasRemoteDevices {
                return LHTheme.warning
            }
            return LHTheme.success
        }

        private var statusTint: Color {
            switch screenTime.status.kind {
            case .ready: return LHTheme.success
            case .localOnly: return LHTheme.teal
            case .fullDiskAccessRequired: return LHTheme.warning
            case .noAppleData: return LHTheme.warning
            case .partial: return LHTheme.warning
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

        private var statusPillTitle: String {
            switch screenTime.status.kind {
            case .ready: return "Apple + iCloud"
            case .localOnly: return "Apple · this Mac"
            case .fullDiskAccessRequired: return "Permission required"
            case .noAppleData: return "Waiting for Apple data"
            case .partial: return "Partial Apple data"
            }
        }

        private var emptySymbol: String {
            screenTime.needsFullDiskAccess ? "lock.display" : "macbook.and.iphone"
        }

        private func scopeTitle(_ mode: AppleScreenTimeScopeMode) -> String {
            switch mode {
            case .macOnly: return "This Mac"
            case .allDevices: return "All devices"
            case .selectedDevices: return "Selected devices"
            }
        }

        private func scopeDescription(_ scope: AppleScreenTimeScope) -> String {
            switch scope.mode {
            case .macOnly: return "This physical Mac only"
            case .allDevices: return "Every Apple device synchronized to this Mac"
            case .selectedDevices: return "Exact selected device set"
            }
        }

        private func sectionHeader(symbol: String, tint: Color, title: String, subtitle: String) -> some View {
            HStack(alignment: .top, spacing: 12) {
                featureIcon(symbol, tint: tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
        }

        private func featureIcon(_ symbol: String, tint: Color) -> some View {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 38, height: 38)
                .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        }

        private func metric(title: String, value: String, note: String, symbol: String) -> some View {
            LHCard {
                VStack(alignment: .leading, spacing: 8) {
                    Label(title, systemImage: symbol)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(value)
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    Text(note)
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
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

        private func duration(_ seconds: TimeInterval) -> String {
            let total = max(0, Int(seconds.rounded()))
            let hours = total / 3_600
            let minutes = (total % 3_600) / 60
            if hours > 0 { return "\(hours)h \(minutes)m" }
            if minutes > 0 { return "\(minutes)m" }
            return "\(total)s"
        }

        private func relativeDate(_ date: Date) -> String {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .abbreviated
            return formatter.localizedString(for: date, relativeTo: Date())
        }
    }
#endif
