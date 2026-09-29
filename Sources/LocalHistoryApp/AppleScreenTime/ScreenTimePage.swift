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
                        eyebrow: "Données système Apple",
                        title: "Temps d’écran Apple",
                        subtitle:
                            "Lecture du Temps d’écran qu’Apple conserve sur ce Mac et synchronise depuis vos autres appareils via iCloud. L’enregistreur de Goalong n’intervient pas dans ces chiffres."
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
                        Text("La fraîcheur dépend de la synchronisation locale/iCloud d’Apple, pas d’un serveur Goalong.")
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
                Button("Ouvrir l’accès complet au disque") {
                    screenTime.openFullDiskAccessSettings()
                }
                .buttonStyle(LHPrimaryButtonStyle())
            case .localOnly, .noAppleData:
                Button("Ouvrir les réglages Temps d’écran") {
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
                            "Choisissez ce Mac, tous les appareils synchronisés par Apple, ou une sélection précise d’appareils."
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
                            Text("Aucun appareil Apple détecté pour l’instant.")
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
                    title: "Temps d’écran Apple",
                    value: duration(summary.totalScreenOnDuration),
                    note: summary.deviceSummaries.count > 1
                        ? "Somme par appareil ; l’usage simultané n’est pas dédoublonné"
                        : "Périodes d’utilisation des apps pour cet appareil",
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
                    title: "Dernière mise à jour Apple",
                    value: screenTime.latestAppleUpdate.map(relativeDate) ?? "—",
                    note: screenTime.selectedDayIsToday ? "Vérifié toutes les 5 secondes" : "Last stored Apple event",
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
                        Text("Aucune utilisation Apple pour cette sélection et ce jour.")
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
                                        title: "Ce Mac",
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
                        title: "Applications utilisées",
                        subtitle:
                            "Les durées proviennent des enregistrements Apple `/app/usage` et des transitions `App.InFocus` synchronisées."
                    )

                    if summary.topApplications.isEmpty {
                        Text("Aucune activité d’application attribuable pour cette sélection et ce jour.")
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
                        Text("Partager cette vue Temps d’écran")
                            .font(.system(size: 13, weight: .semibold))
                        Text(
                            "L’export indique les appareils inclus, la provenance exacte, la règle de cumul et si le détail des applications est inclus. Les formats privés d’Apple ne sont pas présentés comme identiques certifiés aux Réglages."
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
                        Label("Exporter les données", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(LHPrimaryButtonStyle())
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
                            Label("Ouvrir l’accès complet au disque", systemImage: "lock.open.display")
                        }
                        .buttonStyle(LHPrimaryButtonStyle())
                    } else {
                        Button {
                            screenTime.openScreenTimeSettings()
                        } label: {
                            Label("Ouvrir les réglages Temps d’écran", systemImage: "hourglass")
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
                        Text("Ce qui est lu")
                            .font(.system(size: 12, weight: .semibold))
                        Text(
                            "Cette page lit d’abord sur place les agrégats privés d’Apple (ScreenTimeAgent). Si ce stockage est indisponible, les flux ScreenTime.AppUsage, knowledgeC `/app/usage` et Biome `App.InFocus` servent à une reconstitution limitée."
                        )
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        Text(
                            "Les événements de Goalong ne les remplacent jamais. Ces formats privés ne sont pas une API publique d’Apple et ne sont pas certifiés identiques aux Réglages."
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
                        Text("Accès Apple en lecture seule")
                            .font(.system(size: 11, weight: .semibold))
                        Text(
                            "Les bases et flux d’Apple sont ouverts en lecture seule. Goalong ne conserve que votre choix d’appareils et les fichiers que vous exportez vous-même."
                        )
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button("Ouvrir le dossier de configuration") {
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
                        Text(isCurrentMac ? "Ce Mac" : screenTime.sourceLabel(for: device))
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
                return "Seul ce Mac est inclus, d’après les enregistrements locaux d’Apple."
            case .allDevices:
                return screenTime.hasRemoteDevices
                    ? "This Mac plus all \(screenTime.remoteDeviceCount) Apple device stream\(screenTime.remoteDeviceCount == 1 ? "" : "s") synchronized here."
                    : "Ce Mac est inclus ; Apple n’a encore synchronisé aucun autre appareil ici."
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
            case .macOnly: return "Ce Mac"
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
