#if os(macOS)
import Foundation
import SwiftUI
@testable import LocalHistoryApp

/// One image per named view of Activité (`GoalongActivityDetail`), on the day of `activite/jour-realiste`.
/// « Appels et agenda » has its own states in `agenda/`. `code` and `sleep` are left out: the fixture has no agent
/// conversations, no project and no Health import, so the page offers neither view and shows the summary instead.
extension GalleryCatalog {
    static var activityDetailEntries: [GalleryEntry] {
        GoalongActivityDetail.allCases.filter { ![.agenda, .code, .sleep].contains($0) }.map { shown in
            dashboard("activite/detail-\(shown == .screenTime ? "temps-ecran" : shown.rawValue)", section: .overview, sizes: [.full(1240)], fixture: .classified,
                      note: "vue nommée « \(shown.title(isDay: true)) » ouverte depuis « Explorer la journée »",
                      prepare: { ctx in
                GoalongAnalyticsPage.galleryDetail = shown
                ctx.cleanups.append { GoalongAnalyticsPage.galleryDetail = nil }
            })
        }
    }
}
#endif
