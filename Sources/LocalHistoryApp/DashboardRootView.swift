#if os(macOS)
    import Foundation
    import SwiftUI
    import LocalHistoryCore

    struct LocalHistoryDashboardView: View {
        @ObservedObject var model: DashboardViewModel
        /// Starts on the model's today (the real clock in the app, the frozen one in the gallery).
        @State private var activityNavigation: GoalongActivityNavigation
        /// Activité's days stay read while the window is open, so coming back to the page
        /// shows them at once; closing the window releases them.
        @StateObject private var activity: GoalongAnalyticsModel
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        /// `activityPeriod` (1, 7 or 28 days) lets the gallery open Activité on a week or a month.
        init(model: DashboardViewModel, activityPeriod: Int = 1) {
            _model = ObservedObject(wrappedValue: model)
            _activity = StateObject(wrappedValue: GoalongAnalyticsModel(reader: model.analyticsReader))
            _activityNavigation = State(initialValue: GoalongActivityNavigation(day: model.now(), period: activityPeriod))
        }

        var body: some View {
            Group {
                if model.showWelcome {
                    LocalHistoryOnboardingView(model: model)
                } else {
                    HStack(spacing: 0) {
                        DashboardSidebar(model: model)
                            .frame(width: 208)
                        Rectangle()
                            .fill(LHTheme.separator)
                            .frame(width: 1)
                        page
                            // Changing destination is a short crossfade, never a slide.
                            .id("\(model.selectedSection)|\(model.knownDeviceID ?? "")")
                            .onAppear {
                                // Activité closes its measure once its period is read (GoalongAnalyticsPage).
                                let section = model.selectedSection
                                GoalongSwitchTiming.end(section.rawValue, stage: "shown", last: section != .overview)
                            }
                            .transition(.opacity)
                            .animation(reduceMotion ? nil : LHTheme.ease(0.16), value: model.selectedSection)
                            .safeAreaInset(edge: .top, spacing: 0) {
                                VStack(spacing: 0) {
                                    GoalongGlobalPauseBanner(model: model)
                                    GoalongAttentionBanner(model: model)
                                }
                            }
                            .safeAreaInset(edge: .bottom, spacing: 0) {
                                if model.settingsHaveChanges && model.selectedSection != .settings {
                                    HStack(spacing: 12) {
                                        // R-80: say what is pending and apply it here; the settings stay one click away.
                                        Label(DashboardSection.pendingChangeSummary(saved: model.savedSettingsDraft, draft: model.settingsDraft),
                                              systemImage: "pencil.circle")
                                            .font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.tail)
                                        Spacer()
                                        Button("Voir dans Réglages") { model.openRecordingSettings() }
                                            .buttonStyle(LHQuietButtonStyle())
                                        Button("Abandonner") { model.discardSettingsChanges() }
                                        Button("Appliquer") { model.saveSettings() }
                                            .buttonStyle(LHPrimaryButtonStyle())
                                    }
                                    .padding(.horizontal, LHTheme.pageInset).padding(.vertical, 12)
                                    .background(LHTheme.cardBackground)
                                    .overlay(alignment: .top) { Rectangle().fill(LHTheme.separator).frame(height: 1) }
                                }
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) { GoalongDevBanner() }
            .overlay { GoalongToastHost() }
            .environment(\.goalongRecordingModel, model)
            .sheet(isPresented: $model.showingWebsiteShare) { GoalongWebsiteSharingSheet(initialDay: model.selectedDay).goalongControls() }
            .onReceive(NotificationCenter.default.publisher(for: .goalongOpenRecordingSettings)) { _ in model.openRecordingSettings() }
            .background(GoalongProfileShareHost(host: model.profileStudio))
            .background(LHTheme.pageBackground)
            .foregroundStyle(LHTheme.text)
            .tint(LHTheme.accent)
            .accentColor(LHTheme.accent)
            .goalongControls()
            .frame(minWidth: 900, minHeight: 620)
            .alert(item: $model.alert) { item in
                Alert(
                    title: Text(item.title),
                    message: Text(item.message),
                    dismissButton: .default(Text("OK"))
                )
            }
        }

        @ViewBuilder private var page: some View {
            switch model.selectedSection {
            case .overview, .analytics:
                GoalongAnalyticsPage(model: model, navigation: $activityNavigation, analytics: activity)
            case .work:
                GoalongWorkPage(model: model)
            case .history:
                UnifiedHistoryPage(model: model)
            case .concentration, .distractions, .blocking:
                ConcentrationHubPage(model: model)
            case .activity:
                ActivityPage(
                    model: model,
                )
            case .screenTime:
                GoalongScreenTimePage(model: model)
                    .safeAreaInset(edge: .top, spacing: 0) { secondaryReturnBar }
            case .agentActivity:
                AgentActivityPage(agents: model.agentActivityRuntime, dashboardDay: model.selectedDay,
                                  onSelectDashboardDay: model.selectDay)
                    .safeAreaInset(edge: .top, spacing: 0) { secondaryReturnBar }
            case .chatGPTRecap:
                ChatGPTRecapPage(model: model)
                    .safeAreaInset(edge: .top, spacing: 0) { secondaryReturnBar }
            case .share:
                SharePage(model: model)
                    .safeAreaInset(edge: .top, spacing: 0) { secondaryReturnBar }
            case .privacy:
                PrivacyPage(model: model)
                    .safeAreaInset(edge: .top, spacing: 0) { secondaryReturnBar }
            case .cli:
                CLIHelpPage {
                    model.returnFromSecondaryPage()
                }
            case .braise:
                BraisePage(onOpenModules: { model.openSettingsPane(.modules) })
            case .ambiance:
                AmbiancePage(model: model)
            case .settings, .monitoring:
                SettingsPage(model: model)
            }
        }

        /// Returns to the page (and Settings pane) the secondary page was opened from.
        private var secondaryReturnBar: some View {
            SettingsBackBar(title: model.secondaryReturnTitle) { model.returnFromSecondaryPage() }
        }
    }

    private struct DashboardSidebar: View {
        @ObservedObject var model: DashboardViewModel
        @ObservedObject private var updates = SoftwareUpdateManager.shared
        @ObservedObject private var consents = GoalongCapabilityConsentStore.shared
        @ObservedObject private var monitor = JevMonitor.shared

        @ObservedObject private var modules = GoalongModuleStore.shared
        @ObservedObject private var ambianceDownload = AmbianceDownloadSignal.shared
        @State private var globalPause = GoalongGlobalPause.load()
        private var primarySections: [DashboardSection] { DashboardSection.sidebarSections(modules: modules.enabled, showing: model.selectedSection) }
        @Namespace private var selection
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                brand
                    .padding(.horizontal, 20)
                    .padding(.top, 24)
                    .padding(.bottom, 24)

                VStack(spacing: 2) {
                    ForEach(primarySections) { section in
                        navigationButton(section)
                    }
                }
                .padding(.horizontal, 10)
                .animation(reduceMotion ? nil : LHTheme.settle, value: model.highlightedSidebarSection)

                if let version = updates.availableVersion {
                    updateButton(version: version)
                        .padding(.horizontal, 12)
                        .padding(.top, 12)
                }

                Spacer(minLength: 20)

                // Reminder breaks only mean something once real-time monitoring is on.
                if consents.isEnabled(.jevMonitoring) || monitor.timedBreak != nil {
                    JevQuickPauseControl()
                        .padding(.horizontal, 16).padding(.bottom, 12)
                }

                statusRow
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)

                footer
                    .padding(.horizontal, 26)
                    .padding(.bottom, 16)
            }
            .background(LHTheme.sidebarBackground)
            .onAppear {
                updates.refreshAvailableUpdate()
            }
        }

        private var brand: some View {
            HStack(spacing: 11) {
                GoalongMark()
                    .stroke(LHTheme.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .frame(width: 28, height: 20)
                    .accessibilityLabel("Logo Goalong")

                VStack(alignment: .leading, spacing: 0) {
                    Text("Goalong")
                        .font(.system(size: 17, weight: .bold))
                        .tracking(-0.5)
                    Text("Historique sur ce Mac")
                        .font(.system(size: 12))
                        .foregroundStyle(LHTheme.secondaryText)
                }
            }
        }

        private func navigationButton(_ section: DashboardSection) -> some View {
            Button {
                model.selectSection(section)
            } label: {
                navigationLabel(
                    title: section.simpleTitle,
                    symbol: section == .overview ? "chart.bar.xaxis" : section.symbol,
                    selected: model.highlightedSidebarSection == section,
                    pill: section.sidebarPill(ambianceDownloading: ambianceDownload.downloading && modules.enabled.contains(.ambiance))
                )
            }
            .buttonStyle(LHNavigationButtonStyle())
            // The selection glides between destinations, carrying a short piece of the thread.
            .background {
                if model.highlightedSidebarSection == section {
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: LHTheme.controlRadius, style: .continuous)
                            .fill(LHTheme.selectionBackground)
                        RoundedRectangle(cornerRadius: 1.5).fill(LHTheme.accent)
                            .frame(width: 3, height: 16).padding(.leading, 5)
                    }
                    .matchedGeometryEffect(id: "sidebar-selection", in: selection)
                    .accessibilityHidden(true)
                }
            }
            .accessibilityIdentifier("sidebar-\(section.rawValue)")
            .accessibilityLabel([section.simpleTitle, section.sidebarPill(ambianceDownloading: ambianceDownload.downloading
                && modules.enabled.contains(.ambiance))].compactMap { $0 }.joined(separator: ", "))
            .accessibilityAddTraits(model.highlightedSidebarSection == section ? .isSelected : [])
        }

        private func navigationLabel(
            title: String,
            symbol: String,
            selected: Bool,
            pill: String? = nil
        ) -> some View {
            GoalongSidebarRowLabel(title: title, symbol: symbol, selected: selected, pill: pill)
        }

        /// The banner's own slot rule (GoalongAttentionBanner.currentStorageSlot): the banner names a storage failure when the slot is .storage.
        private var storageNamedByBanner: Bool {
            GoalongAttentionBanner.currentStorageSlot(model: model, localEnabled: consents.isEnabled(.localComputerHistory),
                globallyPaused: globalPause.blocksActivity, section: model.selectedSection) == .storage
        }

        private var statusRow: some View {
            Button {
                if !consents.isEnabled(.localComputerHistory) {
                    model.openRecordingSettings()
                } else if model.runtime.state == .permissionsMissing || model.runtime.state == .inputTapUnavailable {
                    model.selectSection(.settings); model.settingsPane = .permissions
                } else if model.runtime.storageFailure != nil {
                    model.selectSection(.settings); model.settingsPane = .storage
                } else { model.selectSection(.overview) }
            } label: {
                HStack(spacing: 9) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(consents.isEnabled(.localComputerHistory) ? model.runtime.displayTint : LHTheme.tertiaryText)
                        .frame(width: 7, height: 7)
                    // UI-15A / T-043 R-24: short state (≤ 24 characters); switched off is not a pause, and the
                    // global pause says so. « Enregistrement désactivé » is wider than the 208 pt sidebar:
                    // it wraps to a second line instead of losing its end.
                    Text(model.runtime.sidebarTitle(recordingEnabled: consents.isEnabled(.localComputerHistory),
                                                    globallyPaused: globalPause.blocksActivity,
                                                    storageNamedByBanner: storageNamedByBanner))
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    if model.runtime.needsAttention {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .foregroundStyle(LHTheme.secondaryText)
                .padding(.leading, 16).padding(.trailing, 10)
                .frame(minHeight: 32)
            }
            .buttonStyle(LHNavigationButtonStyle())
            .onReceive(NotificationCenter.default.publisher(for: .goalongGlobalPauseDidChange)) { _ in globalPause = .load() }
        }

        private func updateButton(version: String) -> some View {
            Button {
                updates.showAvailableUpdate()
            } label: {
                HStack(spacing: 9) {
                    if updates.isPreparingAvailableUpdate {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    // UI-50: one line in the sidebar width; the version says what « Installer » would install.
                    Text(updates.isPreparingAvailableUpdate ? "Préparation…" : "Mise à jour \(version)")
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .opacity(0.7)
                }
                .foregroundStyle(LHTheme.accent)
                .padding(.horizontal, 11)
                .frame(height: 32)
                .background(LHTheme.selectionBackground,
                            in: RoundedRectangle(cornerRadius: LHTheme.controlRadius, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(updates.isPreparingAvailableUpdate)
            .help("Installer la version \(version)")
            .accessibilityLabel("Mise à jour disponible : installer la version \(version)")
        }

        private var footer: some View {
            HStack {
                if updates.isConfigured {
                    Button {
                        updates.checkForUpdates()
                    } label: {
                        if updates.isPreparingAvailableUpdate {
                            ProgressView()
                                .controlSize(.mini)
                        } else {
                            Text(Self.version)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(updates.isPreparingAvailableUpdate)
                    .help("Rechercher les mises à jour")
                } else {
                    // UI-13B (13): plain secondary text (≥ 4,5:1), not a dimmed disabled button.
                    Text(Self.version)
                        .help("Mises à jour désactivées dans cette version compilée localement")
                }
                Spacer()
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(LHTheme.secondaryText)
        }

        private static var version: String {
            "\(ProductIdentity.interfaceName) \(ProductIdentity.shortVersion ?? "0.6.0-dev")"
        }
    }

    extension DashboardSection {
        static let primarySections: [DashboardSection] = [.overview, .work, .history, .concentration, .settings]

        /// R-80: « 1 modification en attente : clics » or « 3 modifications en attente : clics, défilement… ».
        /// R-73 (R4d-9): the one global sign of a sound download, on Ambiance's row; the page keeps its own text.
        static let ambianceDownloadPill = "Téléchargement…"
        func sidebarPill(ambianceDownloading: Bool) -> String? {
            self == .ambiance && ambianceDownloading ? Self.ambianceDownloadPill : nil
        }

        static func pendingChangeSummary(saved: DashboardSettingsDraft, draft: DashboardSettingsDraft) -> String {
            var names: [String] = []
            func check<T: Equatable>(_ path: KeyPath<DashboardSettingsDraft, T>, _ name: String) {
                if saved[keyPath: path] != draft[keyPath: path], !names.contains(name) { names.append(name) }
            }
            check(\.captureClicks, "clics"); check(\.captureScroll, "défilement")
            check(\.captureKeyboardActivity, "activité du clavier"); check(\.captureShortcuts, "raccourcis")
            check(\.captureWindowTitles, "titres de fenêtre"); check(\.captureElementLabels, "libellés des éléments")
            check(\.captureURLs, "adresses des sites"); check(\.captureCallPresence, "appels")
            check(\.capturePrivateBrowsing, "navigation privée"); check(\.redactAllURLQueryValues, "paramètres des adresses")
            check(\.foregroundIdleSeconds, "délai d’inactivité"); check(\.retentionDays, "durée de conservation")
            check(\.verificationEnabled, "vérification"); check(\.verificationServerURL, "vérification")
            check(\.enableAppAttest, "vérification")
            check(\.excludedDomainsText, "exclusions"); check(\.excludedApplicationsText, "exclusions")
            check(\.includedDomainsText, "inclusions"); check(\.includedApplicationsText, "inclusions")
            guard !names.isEmpty else { return "Modifications en attente" }
            let count = names.count == 1 ? "1 modification en attente" : "\(names.count) modifications en attente"
            return count + " : " + names.joined(separator: ", ")
        }

        /// An enabled module's page joins the sidebar before Réglages; a disabled one has no entry.
        /// Blocage and Surveillance live in Concentration's tabs, which is always there.
        /// R-73 (R9A-33): a disabled module's page that is open keeps its entry, selected, until the user leaves it.
        static func sidebarSections(modules: Set<GoalongModule>, showing: DashboardSection? = nil) -> [DashboardSection] {
            var sections = primarySections
            if modules.contains(.ambiance) || showing == .ambiance { sections.insert(.ambiance, at: sections.count - 1) }
            if modules.contains(.braise) || showing == .braise { sections.insert(.braise, at: sections.count - 1) }
            return sections
        }

        var simpleTitle: String {
            switch self {
            case .overview, .analytics: return "Activité"
            case .work: return "Mon travail"
            case .history: return "Historique"
            case .monitoring: return "Jev"
            case .blocking: return "Blocage"
            case .concentration: return "Concentration"
            case .distractions: return "Distractions"
            case .ambiance: return "Ambiance"
            case .braise: return "Braise"
            case .activity: return "Enregistrement"
            case .screenTime: return "Temps d’écran"
            case .agentActivity: return "Conversations IA"
            case .chatGPTRecap: return "Activité"
            case .share: return "Partager"
            case .privacy: return "Confidentialité"
            case .cli: return "Terminal"
            case .settings: return "Réglages"
            }
        }

        var sidebarParent: DashboardSection {
            switch self {
            case .overview, .analytics, .chatGPTRecap, .share:
                return .overview
            case .concentration, .distractions, .blocking:
                return .concentration
            case .braise: return .braise
            case .ambiance:
                return .ambiance
            case .work:
                return .work
            case .history, .activity, .screenTime:
                return .history
            case .agentActivity, .privacy, .cli, .settings, .monitoring:
                return .settings
            }
        }
    }
#endif

/// One row of the sidebar. Internal so a test can measure it: with or without the pill, it keeps the height of the other rows.
struct GoalongSidebarRowLabel: View {
    let title: String
    let symbol: String
    let selected: Bool
    var pill: String?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(selected ? LHTheme.accent : LHTheme.secondaryText)
                .frame(width: 20)
            // R4d-9: the pill sits under the title (1 pt apart: the row keeps the height of the others, 34 pt content); beside it, the narrow bar cut « Ambiance » to « … ».
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                if let pill {
                    Text(pill).font(.system(size: 10, weight: .medium)).foregroundStyle(LHTheme.secondaryText)
                        .lineLimit(1).fixedSize()
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(LHTheme.selectionBackground))
                }
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(selected ? LHTheme.text : LHTheme.secondaryText)
        .padding(.leading, 16).padding(.trailing, 10)
        .frame(maxWidth: .infinity, minHeight: 34)
        .contentShape(Rectangle())
    }
}
