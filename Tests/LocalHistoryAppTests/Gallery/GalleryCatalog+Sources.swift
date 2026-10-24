#if os(macOS)
import Foundation
import SwiftUI
import AppleScreenTime
import AppleSystemScreenTime
@testable import LocalHistoryApp

/// Pages that show data read from another source: Temps d'écran with an imported day.
extension GalleryCatalog {
    private static func screenTimeCollection(_ day: Date) -> AppleSystemScreenTimeCollection {
        let provenance = AppleScreenTimeProvenance(
            api: AppleScreenTimeProvenance.screenTimeAgentAggregateAPI, collectorBundleIdentifier: "galerie",
            collectorVersion: "1", collectorPlatform: "macOS", authorization: .unknown, fetchPolicy: .live,
            euCustomerRequirementAcknowledged: false)
        let device = AppleScreenTimeDevice(id: "apple-system-current-mac:galerie", name: "MacBook de Léa", kind: .mac)
        let end = day.addingTimeInterval(86_400)
        let apps: [AppleScreenTimeApplicationUsage] = [
            .init(bundleIdentifier: "com.apple.dt.Xcode", displayName: "Xcode", duration: 5_400),
            .init(bundleIdentifier: "com.apple.Safari", displayName: "Safari", duration: 3_000),
            .init(bundleIdentifier: "website:docs.example.org", displayName: "docs.example.org", duration: 1_200),
            .init(bundleIdentifier: "com.apple.MobileSMS", displayName: "Messages", duration: 540),
            .init(bundleIdentifier: "com.apple.Notes", displayName: "Notes", duration: 300),
        ]
        let stored = AppleScreenTimeStoredExport(
            verification: .unsigned,
            envelope: .init(requestedStart: day, requestedEnd: end, requestedScope: .allDevices, provenance: provenance,
                            reports: [.init(device: device, lastUpdatedAt: GalleryClock.at(9, 35),
                                            segments: [.init(start: day, end: day.addingTimeInterval(7_200),
                                                             totalScreenOnDuration: 7_200, applications: apps)])]))
        return .init(storedExport: stored, availableDevices: [device],
                     status: .init(kind: .ready, title: "Prêt", message: "Données de la galerie"),
                     deviceSourceLabels: [:], latestAppleUpdate: GalleryClock.at(9, 35),
                     knowledgeIntervalCount: 0, biomeIntervalCount: 0)
    }

    /// The command link the app installs (`~/.local/bin/goalong` → its own executable), in the entry's own home.
    /// Removed afterwards: the home is shared by the entries of a shard, and the « absent » states read the same place.
    private static func installCLILink(_ ctx: GalleryContext) throws {
        guard let executable = Bundle.main.executableURL else { throw GalleryError.fixture("exécutable introuvable") }
        let link = ctx.home.appendingPathComponent(".local/bin/goalong", isDirectory: false)
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: executable)
        ctx.cleanups.append { try? FileManager.default.removeItem(at: link) }
    }

    static var sourcesEntries: [GalleryEntry] {
        var screenTime: AppleScreenTimeDashboardModel?
        return [
            dashboard("terminal/installe", section: .cli, note: "la commande goalong est installée dans le Terminal",
                      configure: { _, ctx in try installCLILink(ctx) }),
            GalleryEntry("temps-ecran/importe", sizes: [.window], clock: .injected,
                         note: "un jour de Temps d'écran lu : applications et site",
                         ready: { _ in screenTime.map { $0.summary != nil && !$0.isBusy } ?? false }) { ctx in
                try GalleryFixtureHome.install(.recordingOn)
                GoalongCapabilityConsentStore.shared.set(.appleScreenTime, enabled: true, surface: .settings)
                let model = try GalleryFixtures.dashboardModel(ctx, .init(section: .screenTime))
                let built = AppleScreenTimeDashboardModel(
                    rootDirectory: AppPaths.screenTimeDirectory, deviceID: "galerie", selectedDay: GalleryClock.today,
                    refreshInterval: 3_600, includesUnfilteredSummary: true,
                    collectionProvider: { screenTimeCollection($0) })
                screenTime = built
                ctx.keep(built)
                ctx.cleanups.append { built.setActive(false) }
                return AnyView(GoalongScreenTimePage(model: model, screenTimeModel: built))
            },
        ]
    }
}
#endif
