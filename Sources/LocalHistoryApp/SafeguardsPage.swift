#if os(macOS)
import SwiftUI

/// Garde-fous (T-048 B2): what holds you to your own rules. Blocages (lists and weekly program) and
/// Écran rouge (manual red and protected ranges) share one entry and the same range safeties.
@MainActor struct SafeguardsPage: View {
    /// R14b: counts this body's evaluations in DashboardRestTests (off in the app).
    var bodyProbe = DashboardBodyProbe("safeguards")
    let model: DashboardViewModel
    @ObservedObject var navigationStore: DashboardNavigation

    init(model: DashboardViewModel) {
        self.model = model
        _navigationStore = ObservedObject(wrappedValue: model.navigationStore)
    }

    nonisolated static let tabs: [DashboardSection] = [.blocking, .braise]

    nonisolated static func tabTitle(_ section: DashboardSection) -> String {
        section == .braise ? "Écran rouge" : "Garde-fous"
    }

    private var tab: DashboardSection { navigationStore.selectedSection == .braise ? .braise : .blocking }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Garde-fous").goalongPageTitle()
                GoalongSegmentedControl("Garde-fou", selection: Binding(get: { tab }, set: { model.selectSection($0) }),
                                        options: Self.tabs, title: Self.tabTitle)
                    .accessibilityIdentifier("safeguards-tabs")
            }
            .frame(maxWidth: LHTheme.readableWidth, alignment: .leading)
            .padding(.horizontal, LHTheme.pageInset).padding(.top, 28).padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            Group {
                switch tab {
                case .braise: BraisePage(showsTitle: false)
                default: BlockingPage(onOpenLists: { model.selectSection(.distractions) })
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(LHTheme.pageBackground)
    }
}
#endif
