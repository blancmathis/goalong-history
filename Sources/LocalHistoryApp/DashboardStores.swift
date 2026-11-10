#if os(macOS)
    import Combine
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
        @Published private var storedAlert: DashboardAlert?
        /// R14b: writing the shown value again publishes nothing.
        var alert: DashboardAlert? {
            get { storedAlert }
            set { if newValue?.id != storedAlert?.id { storedAlert = newValue } }
        }
        @Published private(set) var isExportingShare = false

        func setExportingShare(_ exporting: Bool) {
            if isExportingShare != exporting { isExportingShare = exporting }
        }
    }

    /// Where the dashboard is: page, Settings pane, day, welcome and sheets. Changes on a click.
    final class DashboardNavigation: ObservableObject {
        @Published private var storedSelectedSection: DashboardSection = .overview
        /// Every request to open a section, also the one already shown. It publishes no change of the object: a page
        /// that leads to one of its parts (« Blocages ») listens to it, and nothing else draws again.
        let sectionRequests = PassthroughSubject<DashboardSection, Never>()
        /// R14b: writing the shown value again publishes nothing.
        var selectedSection: DashboardSection {
            get { storedSelectedSection }
            set { if newValue != storedSelectedSection { storedSelectedSection = newValue } }
        }
        @Published private var storedSettingsPane: SettingsPane = .home
        /// R14b: writing the shown value again publishes nothing.
        var settingsPane: SettingsPane {
            get { storedSettingsPane }
            set { if newValue != storedSettingsPane { storedSettingsPane = newValue } }
        }
        @Published private var storedShowingWebsiteShare = false
        /// R14b: writing the shown value again publishes nothing.
        var showingWebsiteShare: Bool {
            get { storedShowingWebsiteShare }
            set { if newValue != storedShowingWebsiteShare { storedShowingWebsiteShare = newValue } }
        }
        @Published private var storedShowWelcome: Bool
        /// R14b: writing the shown value again publishes nothing.
        var showWelcome: Bool {
            get { storedShowWelcome }
            set { if newValue != storedShowWelcome { storedShowWelcome = newValue } }
        }
        /// The day the pages show (midnight in the current zone). The model moves it (`selectDay`, `followToday`).
        @Published private(set) var selectedDay: Date
        /// Where a secondary page (Temps d’écran, Confidentialité, Terminal…) returns: the page, and Settings pane,
        /// it was opened from. Not published: it changes only in `selectSection`, with `selectedSection`.
        private(set) var secondaryReturn: DashboardSecondaryReturn?
        private let now: () -> Date

        init(day: Date, showWelcome: Bool, now: @escaping () -> Date) {
            selectedDay = day
            storedShowWelcome = showWelcome
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
        @Published private var storedSettingsDraft: DashboardSettingsDraft
        /// R14b: writing the shown value again publishes nothing.
        var settingsDraft: DashboardSettingsDraft {
            get { storedSettingsDraft }
            set { if newValue != storedSettingsDraft { storedSettingsDraft = newValue } }
        }
        /// What config.json holds: the draft differs from it while changes are pending.
        @Published private(set) var savedSettingsDraft: DashboardSettingsDraft
        @Published private var storedUsageSearch = ""
        /// R14b: writing the shown value again publishes nothing.
        var usageSearch: String {
            get { storedUsageSearch }
            set { if newValue != storedUsageSearch { storedUsageSearch = newValue } }
        }
        @Published private(set) var sharingRules: [String: SharingVisibility]
        @Published private(set) var defaultSharingVisibility: SharingVisibility
        /// Shown in Settings while config.json is unreadable.
        @Published private(set) var configNotice: String?
        /// config.json was unreadable at launch: recording is paused and saves are refused.
        @Published private(set) var configLocked = false
        /// Name of the damaged config.json kept aside by the last reset.
        @Published private(set) var configBackupName: String?

        init(draft: DashboardSettingsDraft, sharingRules: [String: SharingVisibility], defaultSharingVisibility: SharingVisibility) {
            storedSettingsDraft = draft
            savedSettingsDraft = draft
            self.sharingRules = sharingRules
            self.defaultSharingVisibility = defaultSharingVisibility
        }

        var settingsHaveChanges: Bool { settingsDraft != savedSettingsDraft }

        /// The Privacy screen reports persisted choices, never an unsaved editor draft.
        var appliedSettings: DashboardSettingsDraft { savedSettingsDraft }

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
    /// The recording status, the free space and the window's visibility. Read every 5 s while visible; publishes only
    /// a change.
    final class DashboardRuntimeState: ObservableObject {
        @Published private(set) var runtime: RuntimePresentation = .unavailable
        /// Free space of the history volume, read at most once a minute while visible. It moves by a few bytes with each
        /// write: it publishes only a change the user can see (its rounded text, or the low-space state). A view always
        /// reads the exact value.
        private(set) var freeDiskBytes: Int64?
        @Published private(set) var dashboardIsVisible = false
        /// The window can be seen, with or without the keyboard: only the cheap status is kept live.
        @Published private(set) var dashboardStatusIsVisible = false

        /// The recording status is fresh: the banner and the page bodies show it only then.
        var recordingStatusIsLive: Bool { dashboardIsVisible || dashboardStatusIsVisible }

        func setRuntime(_ next: RuntimePresentation) {
            if runtime != next { runtime = next }
        }

        func setFreeDiskBytes(_ bytes: Int64?) {
            guard bytes != freeDiskBytes else { return }
            if Self.shownFreeSpace(bytes) != Self.shownFreeSpace(freeDiskBytes) { objectWillChange.send() }
            freeDiskBytes = bytes
        }

        /// What the banner and Settings show of a free space: its text, and whether it is low.
        static func shownFreeSpace(_ bytes: Int64?) -> String? {
            bytes.map { "\(StorageHealth.formatted($0)) \(StorageHealth.isLow($0))" }
        }

        func setDashboardVisible(_ visible: Bool) {
            if dashboardIsVisible != visible { dashboardIsVisible = visible }
        }

        func setStatusVisible(_ visible: Bool) {
            if dashboardStatusIsVisible != visible { dashboardStatusIsVisible = visible }
        }
    }

    /// The selected day's data. The 60 s pass re-reads it; an equal snapshot (every field) publishes nothing.
    final class DashboardSnapshotStore: ObservableObject {
        @Published private(set) var snapshot: DashboardDaySnapshot
        /// Counts the reads shown, so a page can tell a new read from the same one. Not published: it moves only with
        /// `snapshot`, which publishes once for both.
        private(set) var snapshotGeneration: UInt64 = 0
        /// False while `snapshot` is the placeholder of a hidden or new window: the next read is then always shown.
        private var snapshotIsRead = false
        /// Only a forced read (a click, the window shown) turns it on; the 60 s pass stays silent.
        @Published private(set) var isRefreshing = false
        @Published private(set) var historyDeletionGeneration = 0

        init(day: Date) {
            snapshot = .empty(day: day)
        }

        /// Shows a read unless it equals the shown one on every field (the 60 s pass on a quiet day publishes nothing).
        /// The first read after the placeholder is always shown, so the generation tells a read from it.
        @discardableResult
        func show(_ next: DashboardDaySnapshot) -> Bool {
            guard next != snapshot || !snapshotIsRead else { return false }
            snapshotGeneration &+= 1
            snapshotIsRead = true
            snapshot = next
            return true
        }

        /// The same day with fresher names and icons: shown only if something changed.
        func applyMetadata(_ next: DashboardDaySnapshot) {
            guard next != snapshot else { return }
            snapshotGeneration &+= 1
            snapshot = next
        }

        /// The window was hidden: its day is dropped, so it is never shown stale on return (R13). The placeholder
        /// already shown is not published again.
        func discard(day: Date) {
            let placeholder = DashboardDaySnapshot.empty(day: day)
            guard snapshotIsRead || snapshot != placeholder else { return }
            snapshotGeneration &+= 1
            snapshotIsRead = false
            snapshot = placeholder
        }

        func setRefreshing(_ refreshing: Bool) {
            if isRefreshing != refreshing { isRefreshing = refreshing }
        }

        func historyWasDeleted() { historyDeletionGeneration &+= 1 }

        var mostRecentActivitySession: ActivitySession? { snapshot.sessions.first }
    }
#endif
