#if os(macOS)
import AppKit
import Foundation
import SwiftUI
import XCTest
import LocalHistoryCore
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
        // The glyph is not in the AX tree: compare pixels. The phase line of the locked card is the line with its
        // own glyph (« scope »), not the padlock that « Verrouillé » already shows.
        let size = NSSize(width: 360, height: 40)
        let phase = try pixels(FocusActiveSession(controller: controller, session: session, now: GalleryConcentrationFixtures.now,
                                                  live: false).phaseLine, size: size)
        let words = "Séance libre"
        let own = try pixels(Label(words, systemImage: "scope").font(.system(size: 13, weight: .medium)), size: size)
        let padlock = try pixels(Label(words, systemImage: "lock.fill").font(.system(size: 13, weight: .medium)), size: size)
        XCTAssertNotEqual(own, padlock, "the two glyphs must draw differently, or this test proves nothing")
        XCTAssertEqual(phase, own, "the phase line of a locked card keeps its own glyph; the padlock is « Verrouillé »'s")
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

    // R-90 (R9C-41), rendered: the refused write shows a padlock, says that the folder refuses the write, offers the
    // Finder and « Actualiser », and never sends to Full Disk Access (it fixes none of the errors mapped here).
    // It fails if the `.permissionDenied` case goes: the generic notice has another title and « Signaler le problème… ».
    func testRefusedStorageBannerIsRenderedWithItsOwnTextAndActions() throws {
        let model = try dashboardModel()
        let seen = visibleText(GoalongAttentionBanner(model: model, showing: .storage(.permissionDenied)), width: 1_000, height: 120)
        XCTAssertTrue(seen.contains(GoalongAttentionBanner.storageRefusedTitle), "saw \(seen.sorted())")
        XCTAssertTrue(seen.contains(GoalongAttentionBanner.storageRefusedDetail), "saw \(seen.sorted())")
        XCTAssertTrue(seen.contains(GoalongAttentionBanner.storageRefusedOpenTitle), "saw \(seen.sorted())")
        XCTAssertTrue(seen.contains(GoalongAttentionBanner.storageRefusedRefreshTitle), "saw \(seen.sorted())")
        XCTAssertFalse(seen.contains("Signaler le problème…"), "the generic notice is another case; saw \(seen.sorted())")
        XCTAssertFalse(seen.contains { $0.contains("Accès complet au disque") || $0.contains("Réglages Système") },
                       "Full Disk Access does not fix a refused folder write; saw \(seen.sorted())")
        XCTAssertTrue(GoalongAttentionBanner.storageRefusedTitle.contains("refuse l’écriture"), "the one name of this failure (décision 18)")
        XCTAssertEqual(GoalongAttentionBanner.storageSymbol(.permissionDenied), "lock.fill")
        XCTAssertEqual(GoalongAttentionBanner.storageSymbol(.diskFull), "internaldrive")
        // The disk-full banner keeps its own title and has no Finder button.
        let full = visibleText(GoalongAttentionBanner(model: model, showing: .storage(.diskFull)), width: 1_000, height: 120)
        XCTAssertTrue(full.contains("Enregistrement interrompu : le disque est plein"), "saw \(full.sorted())")
        XCTAssertFalse(full.contains(GoalongAttentionBanner.storageRefusedOpenTitle))
    }

    // MARK: Helpers

    func dashboardModel() throws -> DashboardViewModel {
        try requireIsolatedHome()
        let config = ConfigManager(), permissions = PermissionManager(), health = CaptureHealthStore(permissions: PermissionManager())
        let agents = try AgentActivityRuntime(rootDirectory: AppPaths.agentActivityDirectory,
            executableURL: URL(fileURLWithPath: "/nonexistent/r4c-test"), performInitialDiscovery: false,
            sourceDiscovery: { [] }, onCaptured: { _ in })
        return DashboardViewModel(state: CaptureState(), permissions: permissions, configManager: config,
            sharingRulesStore: SharingRulesStore(), agentActivityRuntime: agents,
            deviceInfo: DeviceIdentityInfo(deviceID: "r4c-fixture", publicKeyBase64: "", trustTier: "test", algorithm: "test"),
            eventTapStatus: { false }, currentSuppression: { nil }, captureHealthSnapshot: { health.snapshot },
            onBeginCaptureValidation: {}, onTogglePause: {}, onRequestPermissions: {},
            onSaveConfiguration: { try config.save($0) }, onDeleteDetails: { _, done in done(.success(0)) },
            onDeleteTargetedDetails: { _, done in done(.success(0)) })
    }

    func requireIsolatedHome() throws {
        guard FileManager.default.homeDirectoryForCurrentUser.path.hasPrefix("/tmp/goalong-") else {
            throw XCTSkip("needs the isolated test HOME of make check (writes fixtures under Application Support)")
        }
    }

    /// The pixels of a view hosted off screen on white, as bytes.
    func pixels(_ root: some View, size: NSSize) throws -> Data {
        let host = NSHostingView(rootView: root.frame(width: size.width, height: size.height, alignment: .leading)
            .background(Color.white).environment(\.goalongReduceMotion, true).goalongControls())
        host.appearance = NSAppearance(named: .aqua)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
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
