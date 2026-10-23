#if os(macOS)
import Foundation
import SwiftUI
@testable import LocalHistoryApp

/// Every surface × state of the gallery (spec C §6). Zone files add their entries; ids are `surface/état`.
@MainActor enum GalleryCatalog {
    static var all: [GalleryEntry] {
        dashboardEntries + settingsEntries + onboardingEntries + menuBarEntries + concentrationEntries
            + blockingEntries + ambianceEntries + systemEntries
    }

    /// Entries whose id starts with one of the comma-separated prefixes (`ONLY=`).
    static func filtered(_ only: String?) -> [GalleryEntry] {
        guard let only, !only.isEmpty else { return all }
        let prefixes = only.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return all.filter { entry in prefixes.contains { entry.id == $0 || entry.id.hasPrefix($0) } }
    }

    /// A dashboard page in the real window (sidebar, banners), from the gallery's dashboard model.
    static func dashboard(_ id: String, section: DashboardSection, pane: SettingsPane = .home,
                          sizes: [GallerySize] = [.window], themes: [GalleryTheme] = GalleryTheme.standard,
                          environment: ((inout GalleryEnvironment) -> Void)? = nil,
                          paused: Bool = false, fixture: GalleryFixtureHome.Kind = .empty, period: Int = 1,
                          note: String? = nil, file: String = #fileID,
                          reached: (@MainActor () -> Bool)? = nil,
                          configure: (@MainActor (DashboardViewModel, GalleryContext) throws -> Void)? = nil) -> GalleryEntry {
        var model: DashboardViewModel?
        // `reached`: the state the entry names is on screen; else the image is `not-ready`, not a quiet wrong image.
        return GalleryEntry(id, sizes: sizes, themes: themes, clock: .injected, dashboardWindow: true, note: note,
                            section: section == .settings ? nil : section, pane: section == .settings ? pane : nil,
                            ready: { ctx in
                                guard let model, GalleryFixtures.dashboardReady(model)(ctx) else { return false }
                                return reached?() ?? true
                            }, file: file) { ctx in
            ctx.environment.usedBytes = GalleryFixtureHome.usedBytes(fixture)
            if let environment { environment(&ctx.environment) }
            try GalleryFixtureHome.install(fixture)
            var options = GalleryFixtures.DashboardOptions()
            options.section = section; options.settingsPane = pane; options.globallyPaused = paused
            let built = try GalleryFixtures.dashboardModel(ctx, options)
            try configure?(built, ctx)
            model = built
            return AnyView(LocalHistoryDashboardView(model: built, activityPeriod: period))
        }
    }

    /// A content panel (sheet, popover, card) rendered alone at a width, its height fitted.
    static func panel(_ id: String, width: CGFloat, height: CGFloat? = nil, themes: [GalleryTheme] = GalleryTheme.standard,
                      clock: GalleryClockUse = .none, note: String? = nil, file: String = #fileID,
                      _ view: @escaping @MainActor (GalleryContext) throws -> AnyView) -> GalleryEntry {
        GalleryEntry(id, sizes: [height.map { .fixed(width, $0) } ?? .fitWidth(width)], themes: themes, clock: clock,
                     note: note, file: file, view: view)
    }
}
#endif
