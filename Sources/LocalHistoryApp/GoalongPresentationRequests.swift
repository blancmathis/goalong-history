#if os(macOS)
import Foundation

/// Capture navigation arguments together with presentation identity. A separate
/// Boolean and payload can otherwise present stale values on the first click.
struct GoalongWebsitePresentation: Identifiable {
    let id = UUID()
    let day: Date?
}
struct GoalongAnalysisPresentation: Identifiable {
    let id = UUID()
    let tab: Int
}
enum GoalongUIFormat {
    static func day(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.wide).year().locale(Locale(identifier: "fr_FR")))
    }
}

#endif
