#if os(macOS)
import Foundation

/// Real archive reads retain the window-focus boundary. Synthetic previews never
/// touch those stores and must not wait for, or restart on, keyboard focus changes.
struct GoalongAnalyticsLoadRequest: Equatable {
    let day: Date
    let count: Int
    let revision: Int
    let isPreview: Bool
    let permitsLoading: Bool

    /// T-052 (8): « Lire maintenant » reads once, only while Goalong is the app in front. The privacy rule is kept:
    /// with another app in front, nothing is read, whatever was asked before.
    static func permits(preview: Bool, dashboardIsVisible: Bool, userAskedNow: Bool, appIsActive: Bool) -> Bool {
        preview || dashboardIsVisible || (userAskedNow && appIsActive)
    }

    init(day: Date, count: Int, revision: Int = 0, preview: Bool,
         dashboardIsVisible: Bool, userAskedNow: Bool = false, appIsActive: Bool = false, calendar: Calendar = .current) {
        self.day = calendar.startOfDay(for: day)
        self.count = [1, 7, 28].contains(count) ? count : 7
        self.revision = revision
        self.isPreview = preview
        self.permitsLoading = Self.permits(preview: preview, dashboardIsVisible: dashboardIsVisible,
            userAskedNow: userAskedNow, appIsActive: appIsActive)
    }
}
#endif
