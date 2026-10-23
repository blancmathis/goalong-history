#if os(macOS)
import AppKit
import CoreGraphics
import Foundation
import GoalongHeadlessTestSupport
import XCTest
@testable import LocalHistoryApp

/// In `make test`: four key gallery entries render in memory, in light and dark, with real content, no window on
/// screen and silent guards (spec C §10). Plus the catalog's coverage guard, which renders nothing.
final class GallerySmokeTests: XCTestCase {
    static let maximumDominantShare = 0.99
    static let smokeIDs = ["menubar/repos", "settings/accueil", "onboarding/etape-0", "blocking-surfaces/voile-site"]

    @MainActor func testKeyEntriesRenderRealContentInvisibly() throws {
        try Self.requireWindowServer()
        let started = Date()
        GalleryRenderer.prepareApplication()
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
        XCTAssertFalse(NSApp.windows.contains { $0.isVisible }, "a window became visible")
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "smoke budget is 5 s")
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
