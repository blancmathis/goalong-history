#if os(macOS)
import SwiftUI
import LocalHistoryCore

/// T-052 lot 3b (point 17): the window shows one banner at a time, the most urgent, and a quiet line « n autres ».
/// Before, the pause, attention and menu bar banners stacked and pushed the page down.
enum GoalongBannerKind: Hashable { case pause, attention, menuBar, updated }

enum GoalongBannerStack {
    /// Most urgent first: nothing is recorded, then a problem with recording, then the hidden icon, then good news.
    static let order: [GoalongBannerKind] = [.pause, .attention, .menuBar, .updated]

    static func active(pause: Bool, notice: GoalongAttentionBanner.Notice?, menuBarHidden: Bool) -> [GoalongBannerKind] {
        var kinds: Set<GoalongBannerKind> = []
        if pause { kinds.insert(.pause) }
        switch notice {
        case .updated?: kinds.insert(.updated)
        case nil: break
        default: kinds.insert(.attention)
        }
        if menuBarHidden { kinds.insert(.menuBar) }
        return order.filter(kinds.contains)
    }

    /// One banner, or all of them once the person asks; `hidden` is the count the « n autres » line names.
    static func pick(_ active: [GoalongBannerKind], expanded: Bool) -> (shown: [GoalongBannerKind], hidden: Int) {
        expanded ? (active, active.count - 1) : (Array(active.prefix(1)), max(0, active.count - 1))
    }

    static func moreTitle(hidden: Int, expanded: Bool) -> String {
        expanded ? "Masquer les autres avis" : hidden == 1 ? "1 autre avis" : "\(hidden) autres avis"
    }
}

struct GoalongTopBanners: View {
    let model: DashboardViewModel
    @ObservedObject var navigationStore: DashboardNavigation
    @ObservedObject var runtimeStore: DashboardRuntimeState
    @ObservedObject private var updates = SoftwareUpdateManager.shared
    @ObservedObject private var consents = GoalongCapabilityConsentStore.shared
    @ObservedObject var watch: MenuBarVisibilityWatch
    @State private var pause = GoalongGlobalPause.load()
    @State private var expanded = false

    init(model: DashboardViewModel, watch: MenuBarVisibilityWatch = .shared) {
        self.model = model
        _navigationStore = ObservedObject(wrappedValue: model.navigationStore)
        _runtimeStore = ObservedObject(wrappedValue: model.runtimeStore)
        self.watch = watch
    }

    private var active: [GoalongBannerKind] {
        GoalongBannerStack.active(pause: pause.blocksActivity,
            notice: GoalongAttentionBanner.notice(runtime: runtimeStore, localEnabled: consents.isEnabled(.localComputerHistory),
                globallyPaused: pause.blocksActivity, section: navigationStore.selectedSection,
                updatedFrom: updates.updatedFromVersion, currentVersion: updates.currentVersion),
            menuBarHidden: watch.banner?.message != nil)
    }

    var body: some View {
        let kinds = active
        let pick = GoalongBannerStack.pick(kinds, expanded: expanded)
        VStack(spacing: 0) {
            ForEach(pick.shown, id: \.self) { kind in banner(kind) }
            if kinds.count > 1 {
                VStack(spacing: 0) {
                    HStack {
                        Button(GoalongBannerStack.moreTitle(hidden: pick.hidden, expanded: expanded)) { expanded.toggle() }
                            .buttonStyle(LHQuietButtonStyle()).font(.system(size: 12))
                            .accessibilityIdentifier("banner-more")
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, LHTheme.pageInset).padding(.vertical, 4)
                    Divider()
                }
            }
        }
        .onChange(of: kinds.count) { count in if count <= 1 { expanded = false } }
        .onReceive(NotificationCenter.default.publisher(for: .goalongGlobalPauseDidChange)) { _ in pause = .load() }
    }

    @ViewBuilder private func banner(_ kind: GoalongBannerKind) -> some View {
        switch kind {
        case .pause: GoalongGlobalPauseBanner(model: model)
        case .attention, .updated: GoalongAttentionBanner(model: model)
        case .menuBar: GoalongMenuBarVisibilityBanner(watch: watch)
        }
    }
}
#endif
