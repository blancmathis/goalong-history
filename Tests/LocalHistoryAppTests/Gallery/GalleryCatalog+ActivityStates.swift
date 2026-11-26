#if os(macOS)
import Foundation
import SwiftUI
@testable import LocalHistoryApp
@testable import LocalHistoryCore

/// T-057 U1 (idée 10 et 7): Activité tells « lecture impossible » apart from « journée vide ».
/// The real empty-state view and the real copy; no data is read.
private struct ActivityStateGalleryView: View {
    let copy: GoalongActivityEmptyCopy.Copy
    let retry: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GoalongEmptyState(title: copy.title, kind: copy.kind, message: copy.message) {
                HStack {
                    if retry { Button("Réessayer") {}.buttonStyle(LHSecondaryButtonStyle()) }
                    if copy.offersHistory { Button("Consulter l’historique") {}.buttonStyle(LHSecondaryButtonStyle()) }
                }
            }
        }
        .padding(20).frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension GalleryCatalog {
    static var activityStateEntries: [GalleryEntry] {
        func state(_ id: String, _ copy: GoalongActivityEmptyCopy.Copy, retry: Bool) -> GalleryEntry {
            panel("activite-etats/\(id)", width: 560, height: 220) { _ in
                AnyView(ActivityStateGalleryView(copy: copy, retry: retry))
            }
        }
        let loss = CaptureStorageLoss(count: 12, first: GalleryClock.at(10, 12), last: GalleryClock.at(10, 31))
        let unreadable = GoalongActivityEmptyCopy.copy(isDay: true, isToday: false, eventCount: 0, incompleteDays: 1,
                                                       purged: false, recording: nil)
        let empty = GoalongActivityEmptyCopy.copy(isDay: true, isToday: false, eventCount: 0, incompleteDays: 0,
                                                  purged: false, recording: nil)
        let lossCopy = GoalongActivityEmptyCopy.copy(isDay: true, isToday: true, eventCount: 0, incompleteDays: 0,
            purged: false, recording: nil,
            storage: .init(kind: .diskFull, since: GalleryClock.at(10, 12), loss: loss))
        return [state("lecture-impossible", unreadable, retry: unreadable.offersRetry),
                state("journee-vide", empty, retry: empty.offersRetry),
                state("pertes-capture", lossCopy, retry: lossCopy.offersRetry)]
    }
}
#endif
