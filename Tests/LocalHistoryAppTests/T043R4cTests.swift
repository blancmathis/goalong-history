#if os(macOS)
import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import LocalHistoryApp

/// T-043 lot R4c (« restes R4 »): each screen says a thing once, and a control shows the state it really has.
/// Views are hosted off screen (no window ordered front, no focus).
@MainActor
final class T043R4cTests: XCTestCase {
    // R282-6: a stored automatic analysis with a selection that is no longer valid shows OFF, so it is greyed.
    func testAutomaticSwitchIsGreyedFromTheValueItShows() {
        let stale = GoalongChatGPTSettings.automaticSwitch(stored: true, selectionValid: false, consented: true, locked: false)
        XCTAssertFalse(stale.isOn, "an invalid selection shows the switch OFF")
        XCTAssertTrue(stale.disabled, "OFF and impossible to turn on: greyed, not a click that does nothing")
        let lockedStale = GoalongChatGPTSettings.automaticSwitch(stored: true, selectionValid: false, consented: true, locked: true)
        XCTAssertTrue(lockedStale.disabled, "same in the version without sign-in")
        let on = GoalongChatGPTSettings.automaticSwitch(stored: true, selectionValid: true, consented: true, locked: true)
        XCTAssertTrue(on.isOn); XCTAssertFalse(on.disabled, "an ON switch can always be turned off (R282-1)")
        let off = GoalongChatGPTSettings.automaticSwitch(stored: false, selectionValid: true, consented: true, locked: false)
        XCTAssertFalse(off.isOn); XCTAssertFalse(off.disabled)
    }

    // R281b-2: an info button inside a disabled row stays as readable as an enabled one.
    func testHelpButtonKeepsItsInkInsideADisabledRow() throws {
        let enabled = try darkestInk(GoalongHelpButton(text: "Aide").padding(4), size: NSSize(width: 32, height: 32))
        let disabled = try darkestInk(GoalongHelpButton(text: "Aide").padding(4).disabled(true), size: NSSize(width: 32, height: 32))
        XCTAssertLessThan(enabled, 0.6, "the glyph rendered")
        XCTAssertEqual(disabled, enabled, accuracy: 0.02, "a disabled row must not fade its help (enabled \(enabled), disabled \(disabled))")
    }

    // R280-6 (règle R-85): the Blocage page of a frozen Mac shows the end time once, on the thread.
    func testFrozenBlockingPageShowsTheEndOnce() {
        let now = GalleryFixtures.blockingNow
        var document = BlockingDocument()
        document.freeze = GalleryFixtures.freeze
        let controller = BlockingController(document: document, clock: { now }, continuous: { now.timeIntervalSince1970 },
                                            runningApps: GalleryFixtures.noApps)
        let seen = visibleText(BlockingPageContent(controller: controller, now: now, expanded: nil), width: 900, height: 900)
        XCTAssertTrue(seen.contains(FrozenMacShield.stateLine), "saw \(seen.sorted())")
        XCTAssertFalse(seen.contains { $0.contains("gelé jusqu") }, "the thread already shows the end; saw \(seen.sorted())")
    }

    // M1 (R-85): the rendered freeze shield says « Mac gelé » without the end time beside it.
    func testFrozenShieldRendersItsStateWithoutTheEnd() {
        let freeze = GalleryFixtures.freeze
        let seen = visibleText(FrozenMacShield(freeze: freeze, now: GalleryFixtures.blockingNow), width: 1_000, height: 700)
        XCTAssertTrue(seen.contains(FrozenMacShield.stateLine), "saw \(seen.sorted())")
        XCTAssertFalse(seen.contains { $0.contains("gelé jusqu") }, "saw \(seen.sorted())")
    }

    // M1 (R-85) and the double padlock: the rendered locked session says « Verrouillé » once, its phase line keeps
    // its own glyph, and the end time is not repeated beside the state.
    func testLockedSessionCardRendersOneLockedStateWithoutTheEnd() throws {
        try requireIsolatedHome()
        let fixtures = GalleryConcentrationFixtures()
        let controller = try fixtures.locked()
        let session = try XCTUnwrap(controller.currentSession)
        let seen = visibleText(FocusActiveSession(controller: controller, session: session, now: GalleryConcentrationFixtures.now,
                                                  live: false), width: 760, height: 520)
        XCTAssertTrue(seen.contains(FocusActiveSession.lockedLine), "saw \(seen.sorted())")
        XCTAssertFalse(seen.contains { $0.hasPrefix("Verrouillé jusqu") }, "saw \(seen.sorted())")
        XCTAssertEqual(FocusActiveSession.phaseSymbol("scope", locked: true), "scope", "one padlock per card, beside « Verrouillé »")
    }

    // R9B-43: the journal-off finding carries its own way out, and the answer to « Noter l’heure du problème »
    // does not repeat the finding (title or settings path).
    func testJournalOffIsSaidOnceAndFixedInPlace() {
        let finding = SupportFinding(severity: .info, code: .diagnosticsDisabled, title: "Journal technique désactivé",
                                     detail: "Le rapport ne contient que l’état actuel.")
        let seen = visibleText(SupportFindingRow(finding: finding, enableJournal: {}), width: 520, height: 160)
        XCTAssertTrue(seen.contains(SupportFindingRow.enableJournalTitle), "saw \(seen.sorted())")
        let answer = SupportRequestController.journalOffFeedback
        XCTAssertFalse(answer.contains("désactivé"), "the finding row already says it: \(answer)")
        XCTAssertFalse(answer.contains("Réglages"), "the way out is the button, not a path to type: \(answer)")
    }

    // R-90 (R9C-41): the refused write shows a padlock, the full settings path, a button that opens it, and the
    // sidebar's own name for the state.
    func testRefusedStorageBannerLeadsToTheSettingThatFixesIt() {
        XCTAssertEqual(GoalongAttentionBanner.storageSymbol(.permissionDenied), "lock.fill")
        XCTAssertEqual(GoalongAttentionBanner.storageSymbol(.diskFull), "internaldrive")
        XCTAssertTrue(GoalongAttentionBanner.storageRefusedDetail.contains("Confidentialité et sécurité › Accès complet au disque"))
        XCTAssertEqual(GoalongAttentionBanner.storageRefusedOpenTitle, "Ouvrir Réglages Système…")
        XCTAssertTrue(GoalongAttentionBanner.storageRefusedTitle.localizedCaseInsensitiveContains("écriture impossible"))
    }

    // MARK: Helpers

    func requireIsolatedHome() throws {
        guard FileManager.default.homeDirectoryForCurrentUser.path.hasPrefix("/tmp/goalong-") else {
            throw XCTSkip("needs the isolated test HOME of make check (writes fixtures under Application Support)")
        }
    }

    /// Lowest luminance drawn by the view on a white light-mode background (0 = black ink, 1 = white).
    func darkestInk(_ root: some View, size: NSSize) throws -> CGFloat {
        let host = NSHostingView(rootView: root.frame(width: size.width, height: size.height).background(Color.white)
            .environment(\.goalongReduceMotion, true).goalongControls())
        host.appearance = NSAppearance(named: .aqua)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        var darkest: CGFloat = 1
        for y in 0..<rep.pixelsHigh { for x in 0..<rep.pixelsWide {
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
            darkest = min(darkest, 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent)
        } }
        return darkest
    }

    /// Renders off screen (no window, no focus) and returns every label, title, value, help and identifier of the AX tree.
    func visibleText(_ root: some View, width: CGFloat, height: CGFloat) -> Set<String> {
        let view = NSHostingView(rootView: root.frame(width: width).environment(\.goalongReduceMotion, true).goalongControls())
        view.frame = NSRect(x: 0, y: 0, width: width, height: height)
        view.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        view.layoutSubtreeIfNeeded()
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApplication.shared.accessibilityAttributeValue(enhanced)
        NSApplication.shared.accessibilitySetValue(true, forAttribute: enhanced)
        defer { NSApplication.shared.accessibilitySetValue(previous ?? false, forAttribute: enhanced) }
        var found = Set<String>(), pending: [Any] = [view], seen = Set<ObjectIdentifier>()
        while let value = pending.popLast(), seen.count < 20_000 {
            guard let object = value as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else { continue }
            for name in ["accessibilityIdentifier", "accessibilityLabel", "accessibilityTitle", "accessibilityValue", "accessibilityHelp"] {
                if let text = read(object, name) as? String, !text.isEmpty { found.insert(text) }
            }
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
