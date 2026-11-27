#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import LocalHistoryApp
import LocalHistoryCore

final class JevSendTransparencyTests: XCTestCase {
    func testClassificationListNamesEveryPromptField() {
        let names = JevSendFields.classification.map(\.name).joined(separator: "|")
        for expected in ["Application, site, titre", "Minutes", "Voisins", "Extrait visible", "Tâches connues", "Réponses passées", "Note du jour"] {
            XCTAssertTrue(names.contains(expected), expected)
        }
    }
    /// The list must describe the real Jev body: a new key or row column there must show up here (T-057 review).
    func testJevListMatchesTheRealRequestBody() throws {
        let now = Date(timeIntervalSince1970: 1_790_300_000)
        let sample = JevSample(date: now, resource: "x.com", title: "Home", action: "scroll", surface: "social-feed",
                               isActivity: true, excerpt: "texte visible")
        let work = try JevWorkContext(summary: "Écrire", applications: "Xcode", content: "docs", procrastination: "vidéos")
        let data = try JevPayload.build(JevWindow(start: now, end: now.addingTimeInterval(15), samples: [sample]), work: work)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["model", "questions", "state"])
        let state = try XCTUnwrap(object["state"] as? [String: Any])
        // goals/apps/content = critères ; avoid = exemples hors travail ; rows = app ou site, surface, titre, action, extrait.
        XCTAssertEqual(Set(state.keys), ["goals", "apps", "content", "avoid", "rows"])
        let rows = try XCTUnwrap(state["rows"] as? [[String]])
        XCTAssertTrue(rows.allSatisfy { $0.count <= 5 })
        XCTAssertEqual(JevSendFields.jev(includesExcerpt: true).map(\.name),
                       ["Critères de travail", "Exemples hors travail", "App ou site", "Titre", "Action", "Surface",
                        "Action en cours", "Extrait du texte affiché"])
    }
    func testExcerptLineFollowsTheSwitch() {
        XCTAssertTrue(JevSendFields.jev(includesExcerpt: false).last!.detail.contains("non envoyé"))
        XCTAssertFalse(JevSendFields.jev(includesExcerpt: true).last!.detail.contains("non envoyé"))
    }
    func testRetryTextUsesClockTime() {
        let text = JevSendFields.retryText(at: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertTrue(text.hasPrefix("Nouvel essai automatique à "))
        XCTAssertTrue(text.contains(":"))
    }

    @MainActor func testRenderSyntheticTransparency() throws {
        guard let output = ProcessInfo.processInfo.environment["GOALONG_JEV_SEND_SNAPSHOTS"] else {
            throw XCTSkip("Opt-in native rendering, fixtures only")
        }
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory); app.finishLaunching()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil); window.contentViewController = nil }
        let retry = Date(timeIntervalSince1970: 1_800_000_000)
        for (name, expanded) in [("summary", false), ("fields", true)] {
            let view = VStack(alignment: .leading, spacing: 12) {
                JevRetryTimeNote(at: retry)
                if expanded { JevSendFieldsList(fields: JevSendFields.jev(includesExcerpt: false)) }
                else { JevSendFieldsDisclosure(includesExcerpt: false) }
            }.padding(24).frame(width: 700, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                .background(LHTheme.pageBackground).foregroundStyle(LHTheme.text)
            let controller = NSHostingController(rootView: view)
            window.contentViewController = controller
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            let host = controller.view
            host.frame = NSRect(x: 0, y: 0, width: 700, height: max(200, host.fittingSize.height))
            host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("after-\(name).png"))
        }
    }
}
#endif
