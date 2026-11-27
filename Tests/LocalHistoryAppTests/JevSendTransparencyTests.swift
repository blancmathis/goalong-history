#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import LocalHistoryApp

final class JevSendTransparencyTests: XCTestCase {
    func testClassificationListNamesEveryPromptField() {
        let names = JevSendFields.classification.map(\.name).joined(separator: "|")
        for expected in ["Application, site, titre", "Minutes", "Voisins", "Extrait visible", "Tâches connues", "Réponses passées", "Note du jour"] {
            XCTAssertTrue(names.contains(expected), expected)
        }
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
