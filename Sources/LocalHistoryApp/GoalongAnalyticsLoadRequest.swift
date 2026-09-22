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

    init(day: Date, count: Int, revision: Int = 0, preview: Bool,
         dashboardIsVisible: Bool, calendar: Calendar = .current) {
        self.day = calendar.startOfDay(for: day)
        self.count = [1, 7, 28].contains(count) ? count : 7
        self.revision = revision
        self.isPreview = preview
        self.permitsLoading = preview || dashboardIsVisible
    }
}
#endif
