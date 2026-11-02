#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import LocalHistoryApp

/// T-043 O1 « Réglages et partage »: texts, VoiceOver and scrollers of Settings and Share. Views are hosted off
/// screen (a hosting view with no window): nothing is shown, nothing takes the focus.
final class T043O1Tests: XCTestCase {
    private static let enhancedUI = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
    private var enhancedUIBefore: Any?

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            enhancedUIBefore = NSApplication.shared.accessibilityAttributeValue(Self.enhancedUI)
            NSApplication.shared.accessibilitySetValue(true, forAttribute: Self.enhancedUI)
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            NSApplication.shared.accessibilitySetValue(enhancedUIBefore ?? false, forAttribute: Self.enhancedUI)
        }
        try await super.tearDown()
    }

    // MARK: Texts

    /// R-265: with recording off, the line says what turning it on changes, in plain words.
    func testShareProofSaysWhatRecordingChangesWhenItIsOff() {
        let status = ShareProofStatus.make(observedMinutes: 12, sealedMinutes: 0, recordingEnabled: false)
        XCTAssertEqual(status.detail, "Le fichier contiendra seulement les minutes confirmées. Activez l’enregistrement : ce Mac confirmera les minutes suivantes.")
        XCTAssertFalse(status.detail.contains("pour en avoir"))
        XCTAssertEqual(status.action, .openRecordingSettings)
    }

    /// 20-367 (20, 38): the ChatGPT pane says whose account writes what.
    func testChatGPTPaneLeadNamesTheAccountAndTheReport() {
        XCTAssertEqual(SettingsPane.chatGPT.lead,
                       "Avec votre compte ChatGPT, Goalong rédige le bilan d’une journée à partir des seules données que vous choisissez.")
    }

    /// UI16-4 (4): with no day read, « Voir l’aperçu » is held back and the footer line says why.
    @MainActor func testSharingFooterSaysWhyThePreviewIsHeldBack() {
        XCTAssertEqual(GoalongWebsiteSharingSheet.footerHint(previewReady: false, catalogLoaded: false, loading: false, selectionHint: nil),
                       "Aperçu indisponible : aucune donnée lue pour cette journée.")
        XCTAssertEqual(GoalongWebsiteSharingSheet.footerHint(previewReady: false, catalogLoaded: true, loading: false, selectionHint: nil),
                       "Aperçu local, rien n’est envoyé.")
        XCTAssertEqual(GoalongWebsiteSharingSheet.footerHint(previewReady: false, catalogLoaded: true, loading: false,
                                                             selectionHint: "Sélectionnez au moins un appareil."),
                       "Sélectionnez au moins un appareil.")
        XCTAssertEqual(GoalongWebsiteSharingSheet.footerHint(previewReady: true, catalogLoaded: true, loading: false, selectionHint: nil),
                       "La confirmation autorise l’envoi.")
    }

    // MARK: Rendered

    /// CUT-28 (28): the sheet asks for the height of its whole default content, so the footer covers nothing; it was
    /// fixed at 670 pt and cut « En savoir plus » and the last sentence.
    @MainActor func testRetentionSheetAsksForTheHeightOfItsContent() throws {
        let view = NSHostingView(rootView: HistoryRetentionSettingsSheet().environment(\.goalongReduceMotion, true).goalongControls())
        XCTAssertGreaterThanOrEqual(view.fittingSize.height, 760, "CUT-28: the sheet is shorter than its content")
        XCTAssertEqual(view.fittingSize.width, 700, accuracy: 1)
        if let path = ProcessInfo.processInfo.environment["GOALONG_O1_RENDER"] {
            view.frame = NSRect(origin: .zero, size: view.fittingSize)
            view.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
        }
    }

    /// R-264: the switch carries the warning written under its title.
    @MainActor func testVisibleTextSwitchReadsItsWarning() throws {
        let view = host(VisibleContextControl(), width: 700, height: 200)
        let helps = accessibilityObjects(of: view)
            .filter { (read($0, "accessibilityIdentifier") as? String) == "recording-visible-text" }
            .compactMap { read($0, "accessibilityHelp") as? String }
        XCTAssertTrue(helps.contains("Facultatif, sur ce Mac. Peut contenir des messages et documents personnels."), "saw \(helps)")
    }

    // MARK: Helpers

    @MainActor private func host(_ root: some View, width: CGFloat, height: CGFloat) -> NSView {
        let view = NSHostingView(rootView: root.environment(\.goalongReduceMotion, true).goalongControls())
        view.frame = NSRect(x: 0, y: 0, width: width, height: height)
        view.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        view.layoutSubtreeIfNeeded()
        return view
    }

    @MainActor private func accessibilityObjects(of view: NSView) -> [NSObject] {
        var found: [NSObject] = [], pending: [Any] = [view], visited = Set<ObjectIdentifier>()
        while let value = pending.popLast(), visited.count < 20_000 {
            guard let object = value as? NSObject, visited.insert(ObjectIdentifier(object)).inserted else { continue }
            found.append(object)
            pending.append(contentsOf: read(object, "accessibilityChildren") as? [Any] ?? [])
            if let child = object as? NSView { pending.append(contentsOf: child.subviews) }
        }
        return found
    }

    private func read(_ object: NSObject, _ name: String) -> AnyObject? {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector), let method = object.method(for: selector) else { return nil }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
        return unsafeBitCast(method, to: Getter.self)(object, selector)?.takeUnretainedValue()
    }
}
#endif
