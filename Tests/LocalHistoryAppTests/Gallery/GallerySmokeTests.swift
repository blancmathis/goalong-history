#if os(macOS)
import AppKit
import CoreGraphics
import Foundation
import GoalongHeadlessTestSupport
import SwiftUI
import XCTest
@testable import LocalHistoryApp
import LocalHistoryCore

/// In `make test`: four key gallery entries render in memory, in light and dark, with real content, no window on
/// screen and silent guards (spec C §10). Plus the catalog's coverage guard, which renders nothing.
final class GallerySmokeTests: XCTestCase {
    static let maximumDominantShare = 0.99
    static let smokeIDs = ["menubar/repos", "settings/accueil", "onboarding/etape-0", "blocking-surfaces/voile-site"]

    @MainActor func testKeyEntriesRenderRealContentInvisibly() throws {
        try Self.requireWindowServer()
        let started = Date()
        var elapsed: TimeInterval = 0
        try GalleryRenderer.withPreparedApplication {
            try renderKeyEntries()
            elapsed = Date().timeIntervalSince(started)  // the spec's budget covers the four key entries
            try renderProbes()
        }
        XCTAssertFalse(NSApp.windows.contains { $0.isVisible }, "a window became visible")
        XCTAssertLessThan(elapsed, 5, "smoke budget is 5 s")
    }

    /// The smoke test runs inside `make test`: the time zone, identity, toasts and analysis clock it sets for the
    /// gallery are back as they were for the test classes that follow (C1-outil-04).
    @MainActor func testPreparedApplicationLeavesNoProcessGlobals() {
        let zone = NSTimeZone.default
        let toasts = GoalongToastCenter.suppressedForTesting
        let identity = ProductIdentity.galleryOverride
        let preferences = ActivityAnalysisRuntime.shared.preferences
        let version = SoftwareUpdateManager.shared.currentVersion
        let applications = GoalongApplicationCatalog.galleryApplications
        GalleryRenderer.withPreparedApplication {
            XCTAssertEqual(NSTimeZone.default.identifier, "Europe/Paris")
            XCTAssertEqual(ActivityAnalysisRuntime.shared.clock(), GalleryClock.now)
            // Settings › home and the "updated" banner show the gallery's version, not xctest's (C1-couverture-04).
            XCTAssertEqual(SoftwareUpdateManager.shared.currentVersion, ProductIdentity.GalleryIdentity().version)
            // Réglages › Applications lists the invented apps, never this Mac's (C1-couverture-03).
            let catalog = GoalongApplicationCatalog()
            catalog.load()
            XCTAssertEqual(Set(catalog.apps.map(\.id)), Set(GalleryFixtures.installedApplications.map(\.id)))
        }
        XCTAssertEqual(GoalongApplicationCatalog.galleryApplications, applications)
        XCTAssertEqual(NSTimeZone.default, zone)
        XCTAssertEqual(GoalongToastCenter.suppressedForTesting, toasts)
        XCTAssertEqual(ProductIdentity.galleryOverride, identity)
        XCTAssertTrue(ActivityAnalysisRuntime.shared.preferences === preferences)
        XCTAssertNotEqual(ActivityAnalysisRuntime.shared.clock(), GalleryClock.now)
        XCTAssertEqual(SoftwareUpdateManager.shared.currentVersion, version)
    }

    /// The realistic morning (08:12-09:40) reads as about 88 active minutes through the duration rule that
    /// Historique, Activité and Partager share, and the classified fixture has a verdict for every context of the
    /// 28 days (C1-couverture-05, C1-couverture-06). Reads no file.
    @MainActor func testRealisticFixtureReadsAsOneDurationAndIsFullyClassified() {
        let morning = GalleryFixtureHome.workDay(GalleryClock.today, offset: 0)
        var seconds: TimeInterval = 0
        for (index, event) in morning.enumerated() {
            let next = index + 1 < morning.count ? morning[index + 1] : nil
            seconds += ForegroundUsageObservation.activeDuration(after: event, until: next?.timestamp ?? event.timestamp,
                                                                 nextEvent: next, isTail: next == nil)
        }
        XCTAssertEqual(seconds / 60, 88, accuracy: 1, "active minutes of the realistic morning")
        var keys = Set<String>()
        for offset in 0..<28 {
            let day = GalleryClock.calendar.date(byAdding: .day, value: -offset, to: GalleryClock.today)!
            var tracker = GoalongWorkContext.Tracker()
            for event in GalleryFixtureHome.workDay(day, offset: offset) {
                if let key = tracker.context(for: event)?.key { keys.insert(key) }
            }
        }
        XCTAssertEqual(keys, Set(GalleryFixtureHome.verdicts.map(\.label.key)), "contexts without a verdict")
    }

    @MainActor private func renderKeyEntries() throws {
        let all = GalleryCatalog.all
        for id in Self.smokeIDs {
            let entry = try XCTUnwrap(all.first { $0.id == id }, "missing gallery entry \(id)")
            let size = entry.sizes[0]
            var hashes: [GalleryTheme: String] = [:]
            for theme in [GalleryTheme.light, .dark] {
                let ctx = GalleryContext()
                try GalleryStateReset.all(home: ctx.home, resetData: false)
                GalleryGuardReport.begin()
                var image: GalleryImage?
                var failure: Error?
                do { image = try GalleryRenderer.render(entry, theme: theme, size: size, ctx: ctx) } catch { failure = error }
                ctx.finish()
                let report = GalleryGuardReport.take()
                if let failure { throw failure }
                let rendered = try XCTUnwrap(image)
                let label = "\(id) \(theme.rawValue)"
                XCTAssertEqual(rendered.status, .ok, "\(label): \(rendered.detail ?? "")")
                XCTAssertTrue(report.isClean, "\(label): \(report.summary)\n\(report.standardStack ?? "")")
                XCTAssertGreaterThan(rendered.pixelSize.width, 100, label)
                XCTAssertGreaterThan(rendered.pixelSize.height, 40, label)
                let (colors, dominant) = Self.colorStatistics(rendered.bitmap)
                XCTAssertGreaterThanOrEqual(colors, 50, "\(label): only \(colors) colours")
                // A blank render is one colour at 100 %. The site veil is a calm page: its background alone covers
                // 97.6 % of a 1100×720 frame, so the spec's 95 % would reject real content (C-impl.md).
                XCTAssertLessThanOrEqual(dominant, Self.maximumDominantShare,
                                         "\(label): one colour covers \(Int(dominant * 100)) %")
                hashes[theme] = rendered.pixelHash
            }
            XCTAssertNotEqual(hashes[.light], hashes[.dark], "\(id): light and dark are identical")
        }
    }

    @MainActor private func renderProbes() throws {
        // A fixed panel larger than its content: the margins carry the page colour, not transparency (C1-couverture-11).
        let panel = try renderProbe(GalleryEntry("essai/panneau", sizes: [.fixed(300, 200)]) { _ in
            AnyView(Text("Panneau").padding())
        })
        XCTAssertEqual(panel.bitmap.colorAt(x: 0, y: 0)?.alphaComponent, 1, "transparent margin around a fixed panel")
        // A short page rendered whole keeps the window height, without an empty band down to 1500 pt (C1-couverture-09).
        let page = try renderProbe(GalleryEntry("essai/page-courte", sizes: [.full(600)]) { _ in
            AnyView(ScrollView { Text("Page courte").padding() })
        })
        XCTAssertEqual(page.pointSize.height, GalleryRenderer.fullStartHeight, "short --full page height")
    }

    @MainActor private func renderProbe(_ entry: GalleryEntry) throws -> GalleryImage {
        let ctx = GalleryContext()
        defer { ctx.finish() }
        GalleryGuardReport.begin()
        defer { _ = GalleryGuardReport.take() }
        let image = try GalleryRenderer.render(entry, theme: .light, size: entry.sizes[0], ctx: ctx)
        XCTAssertEqual(image.status, .ok, "\(entry.id): \(image.detail ?? "")")
        return image
    }

    /// Coverage guard: every dashboard destination and Settings pane has an entry; ids are unique and well formed.
    @MainActor func testCatalogCoversEveryDestinationWithUniqueIDs() {
        let entries = GalleryCatalog.all
        let sections = Set(entries.compactMap(\.section))
        for section in DashboardSection.allCases where section != .settings {
            XCTAssertTrue(sections.contains(section), "no gallery entry for DashboardSection.\(section)")
        }
        let panes = Set(entries.compactMap(\.pane))
        let allPanes: [SettingsPane] = [.home, .recording, .applications, .connections, .website, .chatGPT, .jev, .modules,
                                        .permissions, .storage, .advanced, .tools]
        for pane in allPanes { XCTAssertTrue(panes.contains(pane), "no gallery entry for SettingsPane.\(pane)") }
        var seen = Set<String>()
        let format = try! NSRegularExpression(pattern: "^[a-z0-9-]+/[a-z0-9-]+$")
        for entry in entries {
            XCTAssertTrue(seen.insert(entry.id).inserted, "duplicate gallery id \(entry.id)")
            let range = NSRange(entry.id.startIndex..., in: entry.id)
            XCTAssertNotNil(format.firstMatch(in: entry.id, range: range), "bad gallery id \(entry.id)")
            XCTAssertFalse(entry.sizes.isEmpty || entry.themes.isEmpty, "\(entry.id) renders nothing")
        }
        for id in Self.smokeIDs { XCTAssertTrue(seen.contains(id), "smoke entry \(id) left the catalog") }
    }

    static func requireWindowServer() throws {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              (session[kCGSessionOnConsoleKey as String] as? Bool) ?? false else {
            throw XCTSkip("WindowServer: no Aqua session on the console")
        }
    }

    /// Distinct colours on one pixel in three (both axes), and the share of the most frequent one.
    static func colorStatistics(_ bitmap: NSBitmapImageRep) -> (Int, Double) {
        guard let data = bitmap.bitmapData else { return (0, 1) }
        let row = bitmap.bytesPerRow, step = bitmap.bitsPerPixel / 8
        var counts: [UInt32: Int] = [:]
        var total = 0
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 3) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 3) {
                let p = data + y * row + x * step
                let key = UInt32(p[0]) << 24 | UInt32(p[1]) << 16 | UInt32(p[2]) << 8 | UInt32(step > 3 ? p[3] : 255)
                counts[key, default: 0] += 1
                total += 1
            }
        }
        guard total > 0 else { return (0, 1) }
        return (counts.count, Double(counts.values.max() ?? 0) / Double(total))
    }
}
#endif
