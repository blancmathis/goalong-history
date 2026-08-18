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
                    selectedDay: model.selectedDay
                )
            )
        }

        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    PageHeader(
                        eyebrow: "Apple activity data",
                        title: "Apple Screen Time",
                        subtitle: "Analyze Mac, iPhone and iPad usage without ever hiding which devices a total covers."
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
                            Button {
                                screenTime.importExport()
                            } label: {
                                Label("Import export", systemImage: "square.and.arrow.down")
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(screenTime.isBusy)
                        }
                    }

                    provenanceBanner
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

                    requirementsCard
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

        private var provenanceBanner: some View {
            HStack(alignment: .top, spacing: 13) {
                featureIcon("rectangle.stack.badge.person.crop", tint: LHTheme.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Device scope is part of the claim")
                        .font(.system(size: 12, weight: .semibold))
                    Text(
                        "Mac only, every Apple device and a hand-picked device set remain distinct in the dashboard and in every exported share file."
                    )
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if let summary = screenTime.summary {
                    StatusPill(
                        title: verificationTitle(summary.verification),
                        symbol: verificationSymbol(summary.verification),
                        tint: verificationTint(summary.verification)
                    )
                } else {
                    StatusPill(
                        title: screenTime.hasImports ? "No data for this day" : "Not connected",
                        symbol: screenTime.hasImports ? "calendar.badge.exclamationmark" : "link.badge.plus",
                        tint: LHTheme.warning
                    )
                }
            }
            .padding(14)
            .background(LHTheme.accent.opacity(0.055), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(LHTheme.accent.opacity(0.12), lineWidth: 1)
            )
        }

        private var scopeCard: some View {
            LHCard {
                VStack(alignment: .leading, spacing: 15) {
                    sectionHeader(
                        symbol: "macbook.and.iphone",
                        tint: LHTheme.teal,
                        title: "Devices included",
                        subtitle: "This scope is stored separately from the Mac activity recorder."
                    )

                    Picker(
                        "Device scope",
                        selection: Binding(
                            get: { screenTime.configuration.scope.mode },
                            set: { screenTime.setScopeMode($0) }
                        )
                    ) {
                        ForEach(AppleScreenTimeScopeMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    if screenTime.configuration.scope.mode == .selectedDevices {
                        Divider()
                        if screenTime.availableDevices.isEmpty {
                            Text("Import data first to choose individual physical devices.")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        } else {
                            LazyVGrid(
                                columns: [GridItem(.adaptive(minimum: 190), spacing: 9)],
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
                    title: "Summed screen-on",
                    value: duration(summary.totalScreenOnDuration),
                    note: "Per-device sum; concurrent devices are not deduplicated",
                    symbol: "hourglass"
                )
                metric(
                    title: "Included devices",
                    value: String(summary.deviceSummaries.count),
                    note: scopeDescription(summary.scope),
                    symbol: "macbook.and.iphone"
                )
                metric(
                    title: "Latest Apple update",
                    value: summary.latestDataUpdate.map(relativeDate) ?? "Unknown",
                    note: summary.provenance.fetchPolicy == .live ? "Live fetch" : "Cached fetch",
                    symbol: "arrow.triangle.2.circlepath"
                )
                metric(
                    title: "Import trust",
                    value: verificationShortTitle(summary.verification),
                    note: verificationNote(summary.verification),
                    symbol: verificationSymbol(summary.verification)
                )
            }
        }

        private func deviceCard(_ summary: AppleScreenTimeDaySummary) -> some View {
            LHCard {
                VStack(alignment: .leading, spacing: 14) {
                    sectionHeader(
                        symbol: "display.2",
                        tint: LHTheme.teal,
                        title: "Per-device usage",
                        subtitle: "The original physical-device rows stay visible."
                    )
                    if summary.deviceSummaries.isEmpty {
                        Text("The current scope includes no activity for this day.")
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
                                    Text(item.device.kind.displayName)
                                        .font(.system(size: 8))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
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
                        title: "Top applications",
                        subtitle: "Available only when the official export includes application rows."
                    )
                    if summary.topApplications.isEmpty {
                        Text("This import contains device totals but no application breakdown.")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(summary.topApplications.prefix(8).enumerated()), id: \.element.id) { index, app in
                            HStack(spacing: 10) {
                                Text(String(index + 1))
                                    .font(.system(size: 9, weight: .bold, design: .rounded))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 18)
                                Text(app.resolvedName)
                                    .font(.system(size: 10, weight: .medium))
                                    .lineLimit(1)
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
                        Text("Share this Screen Time analysis")
                            .font(.system(size: 13, weight: .semibold))
                        Text(
                            "The JSON carries the scope, included device count, aggregation rule, Apple provenance and import-verification state."
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
                    symbol: screenTime.hasImports ? "calendar.badge.exclamationmark" : "macbook.and.iphone",
                    title: screenTime.hasImports ? "No import covers this day" : "Connect Apple Screen Time",
                    message: screenTime.hasImports
                        ? "Choose another day or import a newer Apple DeviceActivity export."
                        : "Import a JSON export from the isolated Apple Screen Time collector, then choose all devices, Mac only or exact physical devices.",
                    buttonTitle: "Import Apple export",
                    action: screenTime.importExport
                )
                .frame(minHeight: 280)
            }
        }

        private var requirementsCard: some View {
            LHCard {
                HStack(alignment: .top, spacing: 14) {
                    featureIcon("checklist.checked", tint: LHTheme.warning)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Official Apple collection requirements")
                            .font(.system(size: 12, weight: .semibold))
                        Text(
                            "The 2026 DeviceActivity export API requires an eligible EU customer device, approved-with-data-access authorization and Apple’s managed Family Controls App and Website Usage entitlement."
                        )
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        Text("LocalHistory never reads private Screen Time databases or uses undocumented Apple APIs.")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(LHTheme.success)
                    }
                    Spacer()
                }
            }
        }

        private var storageCard: some View {
            LHCard {
                HStack(spacing: 13) {
                    Image(systemName: "internaldrive.fill")
                        .foregroundStyle(LHTheme.teal)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Separate local storage")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Imports and scope settings live under LocalHistory/apple-screen-time with private permissions.")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(screenTime.importCount) import\(screenTime.importCount == 1 ? "" : "s")")
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                    Button("Open folder") { screenTime.openDataFolder() }
                        .buttonStyle(.bordered)
                    Button("Delete imports") { screenTime.deleteAllImports() }
                        .buttonStyle(.bordered)
                        .disabled(!screenTime.hasImports || screenTime.isBusy)
                }
            }
        }

        private func deviceSelectionButton(_ device: AppleScreenTimeDevice) -> some View {
            let selected = screenTime.selectedDeviceIDs.contains(device.id)
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
                        Text(device.kind.displayName)
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
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

        private func scopeDescription(_ scope: AppleScreenTimeScope) -> String {
            switch scope.mode {
            case .allDevices: return "Every device returned by Apple"
            case .macOnly: return "Only reports identified as Mac"
            case .selectedDevices: return "\(scope.selectedDeviceIDs.count) selected physical device(s)"
            }
        }

        private func verificationTitle(_ value: AppleScreenTimeImportVerification) -> String {
            switch value {
            case .verifiedOfficialCollector: return "Official signature verified"
            case .signaturePresentUnverified: return "Signature not verified"
            case .unsigned: return "Unsigned import"
            }
        }

        private func verificationShortTitle(_ value: AppleScreenTimeImportVerification) -> String {
            value == .verifiedOfficialCollector ? "Verified" : (value == .unsigned ? "Unsigned" : "Unverified")
        }

        private func verificationNote(_ value: AppleScreenTimeImportVerification) -> String {
            switch value {
            case .verifiedOfficialCollector: return "Signature matched a trusted collector key"
            case .signaturePresentUnverified: return "Signature present; official key not established"
            case .unsigned: return "File may have been edited before import"
            }
        }

        private func verificationSymbol(_ value: AppleScreenTimeImportVerification) -> String {
            value == .verifiedOfficialCollector ? "checkmark.shield.fill" : "exclamationmark.triangle.fill"
        }

        private func verificationTint(_ value: AppleScreenTimeImportVerification) -> Color {
            value == .verifiedOfficialCollector ? LHTheme.success : LHTheme.warning
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
            let value = max(0, Int(seconds.rounded()))
            let hours = value / 3_600
            let minutes = (value % 3_600) / 60
            return hours > 0 ? "\(hours)h \(String(format: "%02d", minutes))m" : "\(minutes)m"
        }

        private func relativeDate(_ date: Date) -> String {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .abbreviated
            return formatter.localizedString(for: date, relativeTo: Date())
        }
    }
#endif
