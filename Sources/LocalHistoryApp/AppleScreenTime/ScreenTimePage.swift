#if os(macOS)
    import AppleScreenTime
    import Foundation
    import SwiftUI

    struct ScreenTimePage: View {
        @StateObject private var screenTime: AppleScreenTimeDashboardModel

        init(model: DashboardViewModel) {
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
                        eyebrow: "Always-current device activity",
                        title: "Screen Time",
                        subtitle:
                            "This Mac is measured automatically from LocalHistory's live foreground recorder, with an exact application breakdown and explicit device scope."
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

                    liveBanner
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

                    connectedDevicesCard
                    storageCard
                }
                .padding(.horizontal, 24)
                .padding(.top, 28)
                .padding(.bottom, 50)
            }
            .background(LHTheme.pageBackground)
            .onAppear { screenTime.refresh() }
            .alert(item: $screenTime.alert) { item in
                Alert(
                    title: Text(item.title),
                    message: Text(item.message),
                    dismissButton: .default(Text("OK"))
                )
            }
        }

        private var liveBanner: some View {
            HStack(alignment: .top, spacing: 13) {
                featureIcon("waveform.path.ecg.rectangle.fill", tint: LHTheme.success)
                VStack(alignment: .leading, spacing: 4) {
                    Text(screenTime.selectedDayIsToday ? "Live on this Mac" : "Recorded automatically on this Mac")
                        .font(.system(size: 12, weight: .semibold))
                    Text(
                        screenTime.selectedDayIsToday
                            ? "The total and application durations advance automatically while the Mac is awake and in use. No Screen Time export or daily action is required."
                            : "This historical view comes from the activity stream LocalHistory recorded on that day; no Apple Screen Time database was copied."
                    )
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 16)
                if screenTime.isBusy {
                    ProgressView()
                        .controlSize(.small)
                }
                StatusPill(
                    title: screenTime.selectedDayIsToday ? "Refreshes every 5s" : "Local history",
                    symbol: screenTime.selectedDayIsToday ? "dot.radiowaves.left.and.right" : "clock.arrow.circlepath",
                    tint: LHTheme.success
                )
            }
            .padding(14)
            .background(LHTheme.success.opacity(0.055), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(LHTheme.success.opacity(0.14), lineWidth: 1)
            )
        }

        private var scopeCard: some View {
            LHCard {
                VStack(alignment: .leading, spacing: 15) {
                    sectionHeader(
                        symbol: "macbook.and.iphone",
                        tint: LHTheme.teal,
                        title: "Devices included",
                        subtitle:
                            "The selected scope is preserved in the dashboard and in every shared Screen Time file."
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
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 205), spacing: 9)],
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

        private func metrics(for summary: AppleScreenTimeDaySummary) -> some View {
            HStack(spacing: 12) {
                metric(
                    title: "Screen time",
                    value: duration(summary.totalScreenOnDuration),
                    note: summary.deviceSummaries.count > 1
                        ? "Sum by device; simultaneous use is not deduplicated"
                        : "Continuously measured foreground time",
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
                    note: "Detailed durations for the selected scope",
                    symbol: "square.grid.2x2.fill"
                )
                metric(
                    title: "Last refresh",
                    value: screenTime.lastRefreshAt.map(relativeDate) ?? "—",
                    note: screenTime.selectedDayIsToday ? "Automatically refreshed" : "Historical calculation",
                    symbol: "arrow.triangle.2.circlepath"
                )
            }
        }

        private func deviceCard(_ summary: AppleScreenTimeDaySummary) -> some View {
            LHCard {
                VStack(alignment: .leading, spacing: 14) {
                    sectionHeader(
                        symbol: "display.2",
                        tint: LHTheme.teal,
                        title: "Usage by device",
                        subtitle: "Each physical device keeps its own duration and source label."
                    )

                    if summary.deviceSummaries.isEmpty {
                        Text("The selected scope contains no measured activity for this day.")
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
                                    Text(
                                        item.device.id == screenTime.currentMacDeviceID
                                            ? "This Mac · live recorder"
                                            : "\(item.device.kind.displayName) · connected snapshot"
                                    )
                                    .font(.system(size: 8))
                                    .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if item.device.id == screenTime.currentMacDeviceID {
                                    StatusPill(
                                        title: screenTime.selectedDayIsToday ? "Live" : "Local",
                                        symbol: "dot.radiowaves.left.and.right",
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
                            "The Mac breakdown updates automatically from foreground app changes and recorder heartbeats."
                    )

                    if summary.topApplications.isEmpty {
                        Text("No attributable application activity is available for this scope and day.")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(summary.topApplications.prefix(10).enumerated()), id: \.element.id) { index, app in
                            HStack(spacing: 10) {
                                Text(String(index + 1))
                                    .font(.system(size: 9, weight: .bold, design: .rounded))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 18)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(app.resolvedName)
                                        .font(.system(size: 10, weight: .medium))
                                        .lineLimit(1)
                                    if let bundle = app.bundleIdentifier {
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
                        Text("Share this Screen Time view")
                            .font(.system(size: 13, weight: .semibold))
                        Text(
                            "The export states whether it covers this Mac, every connected device or a specific selection, and whether application details are included."
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
                        Label("Export Screen Time", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(screenTime.isBusy || summary.deviceSummaries.isEmpty)
                }
            }
        }

        private var emptyCard: some View {
            LHCard {
                EmptyStateView(
                    symbol: "display",
                    title: "No measured activity for this day",
                    message:
                        "Keep LocalHistory running on the Mac. Screen Time will appear here automatically as soon as foreground activity is recorded."
                )
                .frame(minHeight: 250)
            }
        }

        private var connectedDevicesCard: some View {
            LHCard {
                HStack(alignment: .top, spacing: 14) {
                    featureIcon(
                        screenTime.hasRemoteDevices ? "checkmark.icloud.fill" : "iphone.gen3",
                        tint: screenTime.hasRemoteDevices ? LHTheme.success : LHTheme.warning
                    )
                    VStack(alignment: .leading, spacing: 5) {
                        Text("iPhone, iPad and other Macs")
                            .font(.system(size: 12, weight: .semibold))
                        Text(
                            screenTime.hasRemoteDevices
                                ? "\(screenTime.remoteDeviceCount) additional device\(screenTime.remoteDeviceCount == 1 ? " is" : "s are") available for All devices and Selected devices views."
                                : "This Mac is already automatic. Continuous iPhone and iPad data requires the Goalong iOS companion with Apple's Screen Time data-access entitlement and automatic sync."
                        )
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        Text(
                            "A diagnostic snapshot import remains available for development, but it is not the intended daily workflow."
                        )
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 16)
                    Button {
                        screenTime.importExport()
                    } label: {
                        Label("Import test snapshot", systemImage: "hammer")
                    }
                    .buttonStyle(.bordered)
                    .disabled(screenTime.isBusy)
                }
            }
        }

        private var storageCard: some View {
            LHCard {
                HStack(spacing: 13) {
                    Image(systemName: "internaldrive.fill")
                        .foregroundStyle(LHTheme.teal)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Local and separate")
                            .font(.system(size: 11, weight: .semibold))
                        Text(
                            "Live Mac usage is calculated from LocalHistory events. Device-scope settings and optional companion snapshots stay under LocalHistory/apple-screen-time."
                        )
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    if screenTime.hasImports {
                        Text("\(screenTime.importCount) test snapshot\(screenTime.importCount == 1 ? "" : "s")")
                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                    Button("Open folder") { screenTime.openDataFolder() }
                        .buttonStyle(.bordered)
                    if screenTime.hasImports {
                        Button("Delete snapshots") { screenTime.deleteAllImports() }
                            .buttonStyle(.bordered)
                            .disabled(screenTime.isBusy)
                    }
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
                        Text(isCurrentMac ? "This Mac · live" : device.kind.displayName)
                            .font(.system(size: 8))
                            .foregroundStyle(isCurrentMac ? LHTheme.success : Color.secondary)
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
                return "Only this running Mac is included. Its data is live and does not require an export."
            case .allDevices:
                return screenTime.hasRemoteDevices
                    ? "This Mac plus every connected Apple device is included."
                    : "This Mac is included; no other Apple device is connected yet."
            case .selectedDevices:
                let count = screenTime.selectedDeviceIDs.count
                return "\(count) exact device\(count == 1 ? "" : "s") selected."
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

        private func scopeTitle(_ mode: AppleScreenTimeScopeMode) -> String {
            switch mode {
            case .macOnly: return "This Mac"
            case .allDevices: return "All devices"
            case .selectedDevices: return "Selected devices"
            }
        }

        private func scopeDescription(_ scope: AppleScreenTimeScope) -> String {
            switch scope.mode {
            case .macOnly: return "This Mac only"
            case .allDevices: return "Every currently connected device"
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
