#if os(macOS)
    import Foundation
    import LocalHistoryCore

    // R14b: the dashboard's state, split by what changes together. A view observes only the objects it reads, so a
    // publication re-evaluates only the views that show it. Rule (`make audit`): a view reads one of these objects
    // only through an `@ObservedObject` (or `@EnvironmentObject`) of its own, never as `model.<object>.<property>`:
    // an unobserved read would leave the screen frozen. Each setter publishes only a changed value.

    /// What the dashboard identifies this Mac as (rare: rotation, degraded keychain).
    final class DashboardDeviceState: ObservableObject {
        @Published private(set) var deviceID: String
        /// Nil while the identity is degraded and no earlier device ID is known: Screen Time and ChatGPT stay off.
        @Published private(set) var knownDeviceID: String?
        @Published private(set) var deviceTrustTier: String
        @Published private(set) var deviceAlgorithm: String
        @Published private(set) var deviceProtectionTitle: String
        /// No view reads it (searched by name): it does not publish.
        private(set) var deviceProtectionSummary: String
        /// Changed or degraded trust state (rotation, sealing suspended), shown in the integrity section.
        @Published private(set) var trustNotices: [String] = []

        init(_ info: DeviceIdentityInfo) {
            deviceID = info.deviceID
            knownDeviceID = info.knownDeviceID
            deviceTrustTier = info.trustTier
            deviceAlgorithm = info.algorithm
            deviceProtectionTitle = info.protectionTitle
            deviceProtectionSummary = info.protectionSummary
        }

        func update(_ info: DeviceIdentityInfo) {
            if deviceID != info.deviceID { deviceID = info.deviceID }
            if knownDeviceID != info.knownDeviceID { knownDeviceID = info.knownDeviceID }
            if deviceTrustTier != info.trustTier { deviceTrustTier = info.trustTier }
            if deviceAlgorithm != info.algorithm { deviceAlgorithm = info.algorithm }
            if deviceProtectionTitle != info.protectionTitle { deviceProtectionTitle = info.protectionTitle }
            deviceProtectionSummary = info.protectionSummary
        }

        func setTrustNotices(_ notices: [String]) {
            if trustNotices != notices { trustNotices = notices }
        }
    }

    /// The dashboard's alert, and the signed export running behind it.
    final class DashboardAlertCenter: ObservableObject {
        /// Set by the model on an error; a view's `.alert(item:)` clears it.
        @Published var alert: DashboardAlert?
        @Published private(set) var isExportingShare = false

        func setExportingShare(_ exporting: Bool) {
            if isExportingShare != exporting { isExportingShare = exporting }
        }
    }

    /// Where the dashboard is: page, Settings pane, day, welcome and sheets. Changes on a click.
    final class DashboardNavigation: ObservableObject {
        @Published var selectedSection: DashboardSection = .overview
        @Published var settingsPane: SettingsPane = .home
        @Published var showingWebsiteShare = false
        @Published var showWelcome: Bool
        /// The day the pages show (midnight in the current zone). The model moves it (`selectDay`, `followToday`).
        @Published private(set) var selectedDay: Date
        /// Where a secondary page (Temps d’écran, Confidentialité, Terminal…) returns: the page, and Settings pane,
        /// it was opened from. Not published: it changes only in `selectSection`, with `selectedSection`.
        private(set) var secondaryReturn: DashboardSecondaryReturn?
        private let now: () -> Date

        init(day: Date, showWelcome: Bool, now: @escaping () -> Date) {
            selectedDay = day
            self.showWelcome = showWelcome
            self.now = now
        }

        func setSelectedDay(_ day: Date) {
            if selectedDay != day { selectedDay = day }
        }

        func setSecondaryReturn(_ destination: DashboardSecondaryReturn?) {
            secondaryReturn = destination
        }

        var isTodaySelected: Bool {
            Calendar.current.isDate(selectedDay, inSameDayAs: now())
        }

        var secondaryReturnTitle: String {
            switch secondaryReturn?.section ?? selectedSection.defaultReturnSection {
            case .settings: return "Retour aux réglages"
            case .history: return "Retour à l’historique"
            case .monitoring: return "Retour à Jev"
            // Same « ‹ Activité » as the return inside Activity's own detail views (UI-13B).
            default: return "Activité"
            }
        }

        /// A secondary page keeps the sidebar on the destination it was opened from.
        var highlightedSidebarSection: DashboardSection {
            guard selectedSection.isSecondary else { return selectedSection.sidebarParent }
            return (secondaryReturn?.section ?? selectedSection.defaultReturnSection).sidebarParent
        }
    }

    /// The recording settings being edited, the sharing rules and the state of config.json.
    final class DashboardSettingsState: ObservableObject {
        @Published var settingsDraft: DashboardSettingsDraft
        /// What config.json holds: the draft differs from it while changes are pending.
        @Published private(set) var savedSettingsDraft: DashboardSettingsDraft
        @Published var usageSearch = ""
        @Published private(set) var sharingRules: [String: SharingVisibility]
        @Published private(set) var defaultSharingVisibility: SharingVisibility
        /// Shown in Settings while config.json is unreadable.
        @Published private(set) var configNotice: String?
        /// config.json was unreadable at launch: recording is paused and saves are refused.
        @Published private(set) var configLocked = false
        /// Name of the damaged config.json kept aside by the last reset.
        @Published private(set) var configBackupName: String?

        init(draft: DashboardSettingsDraft, sharingRules: [String: SharingVisibility], defaultSharingVisibility: SharingVisibility) {
            settingsDraft = draft
            savedSettingsDraft = draft
            self.sharingRules = sharingRules
            self.defaultSharingVisibility = defaultSharingVisibility
        }

        var settingsHaveChanges: Bool { settingsDraft != savedSettingsDraft }

        func sharingVisibility(for subjectID: String) -> SharingVisibility {
            sharingRules[subjectID] ?? defaultSharingVisibility
        }

        func setSavedSettingsDraft(_ draft: DashboardSettingsDraft) {
            if savedSettingsDraft != draft { savedSettingsDraft = draft }
        }

        func setSharing(rules: [String: SharingVisibility], defaultVisibility: SharingVisibility? = nil) {
            if let defaultVisibility, defaultSharingVisibility != defaultVisibility { defaultSharingVisibility = defaultVisibility }
            if sharingRules != rules { sharingRules = rules }
        }

        func setConfigStatus(notice: String?, locked: Bool, backupName: String?) {
            if configNotice != notice { configNotice = notice }
            if configLocked != locked { configLocked = locked }
            if configBackupName != backupName { configBackupName = backupName }
        }
    }
#endif
