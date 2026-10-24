#if os(macOS)
import Foundation
import SwiftUI
@testable import LocalHistoryApp

/// Activité in developer mode, on its preview with sample data (the page's own switch, opened from the start).
extension GalleryCatalog {
    static var previewEntries: [GalleryEntry] {
        [
            dashboard("activite/apercu-developpeur", section: .analytics, sizes: [.window, .full(1240)],
                      fixture: .recordingOn, note: "aperçu avec données fictives (mode développeur)",
                      configure: { _, ctx in
                ctx.defaults.set(true, forKey: GoalongDeveloperPreferences.enabledKey)
                GoalongAnalyticsPage.galleryStartsInPreview = true
                ctx.cleanups.append { GoalongAnalyticsPage.galleryStartsInPreview = false }
            }),
        ]
    }
}
#endif
