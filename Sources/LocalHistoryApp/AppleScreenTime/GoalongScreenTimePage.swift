#if os(macOS)
import AppleScreenTime
import SwiftUI

struct GoalongScreenTimePage: View {
    @ObservedObject private var dashboard: DashboardViewModel
    @StateObject private var screenTime: AppleScreenTimeDashboardModel
    @ObservedObject private var consents = GoalongCapabilityConsentStore.shared
    @State private var search = ""
    @State private var accessRevoked = false
    @State private var showsAllUsage = false
    @State private var filter: GoalongAppleUsageFilter = .applications
    private let showsHeader: Bool

    init(model: DashboardViewModel, screenTimeModel: AppleScreenTimeDashboardModel? = nil,
         showsHeader: Bool = true) {
        _dashboard = ObservedObject(wrappedValue: model)
        self.showsHeader = showsHeader
        _screenTime = StateObject(wrappedValue: screenTimeModel ?? AppleScreenTimeDashboardModel(
            rootDirectory: AppPaths.screenTimeDirectory, deviceID: model.deviceID,
            selectedDay: model.selectedDay,
            accessEnabled: GoalongCapabilityConsentStore.shared.isEnabled(.appleScreenTime)))
    }

    var body: some View {
        SourceAccessGate(capability: .appleScreenTime,
            knownAccessIssue: accessRevoked ? .fullDiskAccess : nil) { pageBody }
    }

    private var rows: [GoalongAppleUsageRow] { GoalongAppleUsageProjection.rows(screenTime.summary) }

    private var pageBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if showsHeader {
                    PageHeader(eyebrow: "Source indépendante", title: "Temps d’écran Apple",
                        subtitle: "Les données Apple restent séparées des observations Goalong.") {
                        HStack(spacing: 10) {
                            DateSelectionControl(date: screenTime.selectedDay, onChange: selectDay)
                            Button { screenTime.refresh() } label: { Label("Actualiser", systemImage: "arrow.clockwise") }
                                .disabled(screenTime.isBusy)
                        }
                    }
                }
                if consents.isEnabled(.appleScreenTime), !accessRevoked {
                    sourceStatus
                    deviceScopeCard
                    if let summary = screenTime.summary { dayOverview(summary) }
                    usageCard
                    if (screenTime.summary?.deviceSummaries.count ?? 0) > 1 {
                        deviceUsageCard
                    }
                    GoalongDisclosureGroup("Source, confidentialité et export") {
                        sourceDetails.padding(.top, 14)
                    }.font(.system(size: 13))
                } else { screenTimeConsentCard }
            }
            .frame(maxWidth: 1100)
            .padding(.horizontal, LHTheme.pageInset).padding(.top, showsHeader ? 28 : 20)
            .padding(.bottom, 40).frame(maxWidth: .infinity)
        }
        .background(LHTheme.pageBackground)
        .onAppear {
            accessRevoked = false
            screenTime.setAccessEnabled(consents.isEnabled(.appleScreenTime))
            if screenTime.selectedDay != dashboard.selectedDay { screenTime.selectDay(dashboard.selectedDay) }
            screenTime.setActive(dashboard.dashboardIsVisible)
        }
        .onDisappear { screenTime.setActive(false) }
        .onChange(of: screenTime.needsFullDiskAccess) { if $0 { stopForMissingAccess() } }
        .onChange(of: consents.isEnabled(.appleScreenTime)) { enabled in
            if enabled { accessRevoked = false }
            screenTime.setAccessEnabled(enabled)
        }
        .onChange(of: dashboard.dashboardIsVisible) { screenTime.setActive($0) }
        .onChange(of: dashboard.selectedDay) { day in
            showsAllUsage = false
            if screenTime.selectedDay != day { screenTime.selectDay(day) }
        }
        .onChange(of: filter) { _ in showsAllUsage = false }
        .alert(item: $screenTime.alert) { item in
            Alert(title: Text(item.title), message: Text(item.message), dismissButton: .default(Text("OK")))
        }
    }

    private var sourceStatus: some View {
        LHCard(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 14) {
                    if let summary = screenTime.summary {
                        GoalongScreenTimeSourceNotice(presentation: .init(provenance: summary.provenance))
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            Label(screenTime.isBusy ? "Lecture des données Apple…" : "Données Apple indisponibles",
                                systemImage: screenTime.isBusy ? "clock" : "info.circle")
                                .font(.system(size: 13, weight: .semibold))
                            Text(screenTime.isBusy ? "Vérification de la journée et des appareils sélectionnés."
                                : screenTime.storageState == .missingCompletedDay
                                ? "Aucune archive Apple n’a été enregistrée pour cette journée. Ce n’est pas un temps d’écran à zéro."
                                : "Aucune durée Apple lisible pour cette sélection. Essayez une autre journée ou vérifiez les appareils inclus.")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if screenTime.isBusy { ProgressView().controlSize(.small) }
                }
                if screenTime.status.kind == .partial,
                   let summary = screenTime.summary,
                   !GoalongScreenTimeSourcePresentation(provenance: summary.provenance).isPartial {
                    Label("Une partie des données Apple n’est pas disponible. Le périmètre reçu peut être incomplet.",
                        systemImage: "exclamationmark.triangle").foregroundStyle(LHTheme.warning).font(.system(size: 12))
                }
                if screenTime.storageState == .activeDayStoredFallback {
                    Label("La dernière lecture a échoué. La dernière copie disponible est conservée ; elle peut être incomplète.",
                        systemImage: "exclamationmark.triangle").foregroundStyle(LHTheme.warning).font(.system(size: 12))
                }
                HStack(spacing: 16) {
                    Button("Voir dans les Réglages Apple") { screenTime.openScreenTimeSettings() }
                        .buttonStyle(.bordered).controlSize(.small).accessibilityIdentifier("screen-time-open-settings")
                    Text("Aucune modification de vos réglages Apple.").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }.fixedSize(horizontal: false, vertical: true)
        }.accessibilityIdentifier("screen-time-status")
    }

    private var deviceScopeCard: some View {
        LHCard(padding: 16) {
            VStack(alignment: .leading, spacing: 14) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 20) { scopeTitle; Spacer(minLength: 12); scopePicker }
                    VStack(alignment: .leading, spacing: 12) { scopeTitle; scopePicker }
                }
                if screenTime.configuration.scope.mode == .selectedDevices {
                    if screenTime.availableDevices.isEmpty {
                        Text("Aucun appareil détecté pour le moment.").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 10)], spacing: 10) {
                        ForEach(screenTime.availableDevices) { device in
                            Button { screenTime.toggleDevice(device) } label: {
                                HStack(spacing: 9) {
                                    Image(systemName: deviceSymbol(device.kind))
                                    Text(device.id == screenTime.currentMacDeviceID ? "Ce Mac" : device.displayName)
                                        .lineLimit(1).help(device.displayName)
                                    Spacer(minLength: 5)
                                    Image(systemName: screenTime.selectedDeviceIDs.contains(device.id) ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(screenTime.selectedDeviceIDs.contains(device.id) ? LHTheme.accent : LHTheme.secondaryText)
                                }.font(.system(size: 12)).padding(10).contentShape(Rectangle())
                            }.buttonStyle(.bordered)
                        }
                    }
                    if screenTime.selectedDeviceIDs.isEmpty {
                        Text("Sélectionnez au moins un appareil pour afficher ses données.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
    private var scopeTitle: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Appareils inclus").font(.system(size: 14, weight: .semibold))
            Text("Uniquement les données Apple reçues sur ce Mac.").font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }
    private var scopePicker: some View {
        Picker("Appareils inclus", selection: Binding(get: { screenTime.configuration.scope.mode }, set: screenTime.setScopeMode)) {
            Text("Ce Mac").tag(AppleScreenTimeScopeMode.macOnly)
            Text("Tous").tag(AppleScreenTimeScopeMode.allDevices)
            Text("Choisir…").tag(AppleScreenTimeScopeMode.selectedDevices)
        }.labelsHidden().pickerStyle(.segmented).frame(width: 280).accessibilityIdentifier("screen-time-device-scope")
    }

    private func dayOverview(_ summary: AppleScreenTimeDaySummary) -> some View {
        let presentation = GoalongScreenTimeSourcePresentation(provenance: summary.provenance)
        return LHCard {
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(presentation.durationTitle).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                    Text(duration(summary.totalScreenOnDuration)).font(.system(size: 34, weight: .semibold))
                        .monospacedDigit().accessibilityIdentifier("screen-time-day-total")
                    Text(presentation.isPartial ? "Valeur partielle · pas le total officiel" : "Périmètre Apple sélectionné")
                        .font(.system(size: 12)).foregroundStyle(presentation.isPartial ? LHTheme.warning : LHTheme.secondaryText)
                }.frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Applications").font(.system(size: 13)).foregroundStyle(.secondary)
                    Text("\(rows.filter { !$0.isWebsite }.count)").font(.system(size: 28, weight: .semibold))
                        .monospacedDigit().accessibilityIdentifier("screen-time-day-applications")
                    Text("\(summary.deviceSummaries.count) appareil(s) avec des données").font(.system(size: 12)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Dernière lecture").font(.system(size: 13)).foregroundStyle(.secondary)
                    Text(screenTime.lastRefreshAt.map { $0.formatted(.dateTime.locale(Locale(identifier: "fr_FR")).hour().minute()) } ?? "—")
                        .font(.system(size: 25, weight: .semibold)).monospacedDigit().accessibilityIdentifier("screen-time-day-update")
                    Text(screenTime.selectedDayIsToday ? "Actualisation locale toutes les 30 s" : "Archive locale · Apple non relu")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.fixedSize(horizontal: false, vertical: true)
        }.accessibilityIdentifier("screen-time-day-overview")
    }

    private var usageCard: some View {
        let matching = GoalongAppleUsageProjection.visibleRows(rows, filter: filter, search: search)
        let visible = showsAllUsage || !search.isEmpty ? matching : Array(matching.prefix(8))
        return LHCard(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("Usages reçus d’Apple").font(.system(size: 16, weight: .semibold))
                        Spacer(minLength: 12)
                        Picker("Type d’usage Apple", selection: $filter) {
                            ForEach(GoalongAppleUsageFilter.allCases) { Text($0.title).tag($0) }
                        }.labelsHidden().pickerStyle(.segmented).frame(width: 230)
                    }
                    Text("Les durées ne sont ni remplacées ni réparties à partir de l’historique Goalong.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Rechercher dans les données Apple", text: $search).textFieldStyle(.plain)
                            .accessibilityIdentifier("screen-time-search")
                        if !search.isEmpty {
                            Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain).accessibilityLabel("Effacer la recherche")
                        }
                        Text("\(matching.count) résultat(s)").font(.system(size: 12)).foregroundStyle(.secondary)
                    }.padding(10).background(LHTheme.secondaryText.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
                }.padding(18)
                Divider()
                if visible.isEmpty && screenTime.isBusy {
                    ProgressView("Lecture des usages Apple…")
                        .frame(maxWidth: .infinity, minHeight: 120)
                } else if visible.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(!search.isEmpty ? "Aucun résultat" : filter == .websites ? "Aucun détail de site fourni par Apple" : "Aucune application disponible")
                            .font(.system(size: 14, weight: .medium))
                        Text(!search.isEmpty ? "Essayez un autre nom." : filter == .websites
                            ? "Les sites observés par Goalong sont disponibles dans Activité. Ils ne sont pas présentés ici comme des données Apple."
                            : "Les données manquantes ne sont pas remplacées par votre historique local.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                        if filter == .websites && search.isEmpty {
                            Button("Voir mon activité Goalong") { dashboard.selectSection(.overview) }.buttonStyle(.bordered)
                        }
                    }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(visible) { row in
                            HStack(spacing: 14) {
                                if let host = row.host { WebsiteIconView(host: host, size: 36).accessibilityHidden(true) }
                                else { AppIconView(bundleIdentifier: row.bundleIdentifier, appName: row.name, size: 36).accessibilityHidden(true) }
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(row.name).font(.system(size: 13, weight: .medium)).lineLimit(1).help(row.name)
                                    Text(row.isWebsite ? "Site fourni par Apple" : "Application · source Apple")
                                        .font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 10)
                                Text(duration(row.seconds)).font(.system(size: 14, weight: .semibold)).monospacedDigit()
                            }.padding(.horizontal, 18).padding(.vertical, 12).accessibilityElement(children: .combine)
                            if row.id != visible.last?.id { Divider().padding(.leading, 68) }
                        }
                    }
                }
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    if matching.count > 8 && search.isEmpty {
                        Button(showsAllUsage ? "Réduire la liste" : "Voir les \(matching.count) usages") { showsAllUsage.toggle() }
                            .buttonStyle(.borderless).accessibilityIdentifier("screen-time-show-all")
                    }
                    Text("Applications et sites sont deux lectures distinctes. Le temps d’un site peut déjà être inclus dans son navigateur ; les lignes ne sont donc pas additionnées pour recréer le total.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(18)
            }
        }.accessibilityIdentifier("screen-time-apple-only-usage")
    }

    private var deviceUsageCard: some View {
        LHCard {
            VStack(alignment: .leading, spacing: 14) {
                Text("Répartition par appareil").font(.system(size: 15, weight: .semibold))
                ForEach(screenTime.summary?.deviceSummaries ?? []) { item in
                    HStack {
                        Image(systemName: deviceSymbol(item.device.kind))
                        Text(item.device.displayName)
                        Spacer()
                        Text(duration(item.screenOnDuration)).monospacedDigit()
                    }.font(.system(size: 13))
                }
                Text("Les usages simultanés sur plusieurs appareils peuvent se chevaucher.").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }
    private var screenTimeConsentCard: some View {
        LHCard {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(consents.isEnabled(.appleScreenTime) ? "Lecture des données Apple activée" : "Temps d’écran Apple désactivé")
                        .font(.system(size: 14, weight: .semibold))
                    Text(accessRevoked ? "La lecture a été arrêtée car macOS refuse l’accès. Réactivez cette source pour vérifier les autorisations."
                        : "Source facultative. L’accès est expliqué et vérifié avant toute lecture.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 10)
                SourceActivationToggle(capability: .appleScreenTime) { Text("Temps d’écran Apple") }
                    .labelsHidden().toggleStyle(.switch).accessibilityLabel("Lire les données Temps d’écran Apple")
            }
        }
    }
    private var sourceDetails: some View {
        VStack(alignment: .leading, spacing: 16) {
            screenTimeConsentCard
            Text("Seule la journée en cours est relue dans les sources Apple autorisées. Une copie locale compacte est conservée ; les journées terminées sont consultées depuis cette archive. Aucun réglage Apple n’est modifié et aucune donnée n’est envoyée en consultant cette page.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            GoalongDisclosureGroup("Diagnostic technique") {
                VStack(alignment: .leading, spacing: 7) {
                    Text(screenTime.status.message)
                    Button("Vérifier les autorisations macOS…") { screenTime.openFullDiskAccessSettings() }
                        .buttonStyle(.borderless)
                        .help("L’accès complet au disque ne garantit pas que l’agrégat privé d’Apple soit disponible.")
                    Text("AppUsage : \(screenTime.screenTimeAppUsageIntervalCount) intervalles · knowledgeC : \(screenTime.knowledgeIntervalCount) · Biome : \(screenTime.biomeIntervalCount)")
                    if let provenance = screenTime.summary?.provenance { Text(provenance.api) }
                }.font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled).padding(.top, 8)
            }
            HStack(spacing: 14) {
                Picker("Détail de l’export", selection: Binding(get: { screenTime.configuration.shareLevel }, set: screenTime.setShareLevel)) {
                    ForEach(AppleScreenTimeShareLevel.allCases, id: \.self) { level in Text(level.displayName).tag(level) }
                }.frame(maxWidth: 370)
                Spacer(minLength: 10)
                Button("Exporter un fichier…") { screenTime.exportSharePayload() }.buttonStyle(.bordered)
                    .disabled(screenTime.summary == nil || screenTime.isBusy)
            }
            Text("L’export conserve le périmètre, la provenance et les limites de la source.").font(.system(size: 12)).foregroundStyle(.secondary)
        }.fixedSize(horizontal: false, vertical: true)
    }

    private func stopForMissingAccess() {
        accessRevoked = true
        let saved = consents.set(.appleScreenTime, enabled: false, surface: .settings)
        screenTime.setAccessEnabled(false)
        if !saved {
            screenTime.alert = AppleScreenTimeDashboardAlert(title: "Accès Apple indisponible",
                message: "La lecture est arrêtée, mais le réglage n’a pas pu être enregistré. Réessayez de désactiver cette source.")
        }
    }
    private func selectDay(_ date: Date) { dashboard.selectDay(date); screenTime.selectDay(date) }
    private func duration(_ seconds: TimeInterval) -> String { GoalongAnalyticsFormatting.duration(seconds) }
    private func deviceSymbol(_ kind: AppleScreenTimeDeviceKind) -> String {
        switch kind {
        case .mac: return "laptopcomputer"
        case .iPhone: return "iphone"
        case .iPad: return "ipad"
        default: return "display"
        }
    }
}
#endif
