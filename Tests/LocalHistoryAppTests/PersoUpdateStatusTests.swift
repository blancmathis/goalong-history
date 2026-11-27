#if os(macOS)
import AppKit
import GoalongGuardCore
import SwiftUI
import XCTest
@testable import LocalHistoryApp

/// T-057 idées 5 et 6: one status line for the last `make perso` hand-off, history on demand.
final class PersoUpdateStatusTests: XCTestCase {
    private let full = "1a2b3c4d" + String(repeating: "0", count: 32)
    private let other = "9f8e7d6c" + String(repeating: "0", count: 32)
    private var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Europe/Paris")!; return c }
    private var start: Date { calendar.date(from: .init(year: 2026, month: 11, day: 27, hour: 14, minute: 5))! }

    private func entry(_ phases: [PersoUpdateHistory.Phase], reason: String? = nil, commit: String? = nil) -> PersoUpdateHistory.Entry {
        let base = start.timeIntervalSince1970
        return .init(id: "x", commit: commit ?? full,
                     steps: phases.enumerated().map { .init(phase: $1, at: base + Double($0 * 3)) }, reason: reason)
    }

    private func line(_ e: PersoUpdateHistory.Entry, running: String? = nil, after: TimeInterval = 20) -> String {
        PersoUpdateStatusText.line(e, runningCommit: running ?? full, now: start.addingTimeInterval(after), calendar: calendar)
    }

    func testRunningPhasesSayWhichStep() {
        XCTAssertEqual(line(entry([.received])), "Mise à jour perso 1a2b3c4d en cours : demande reçue… (étape 1 sur 5)")
        XCTAssertEqual(line(entry([.received, .verified, .closing])), "Mise à jour perso 1a2b3c4d en cours : fermeture… (étape 3 sur 5)")
        XCTAssertEqual(line(entry([.received, .verified, .closing, .relaunching])),
                       "Mise à jour perso 1a2b3c4d en cours : redémarrage… (étape 4 sur 5)")
    }

    func testDoneConfirmsTheCommitRelaunched() {
        let done = entry([.received, .verified, .closing, .relaunching, .done])
        XCTAssertTrue(line(done).hasSuffix("en 12 s : 1a2b3c4d relancé et actif."), line(done))
        XCTAssertTrue(line(done).hasPrefix("Mise à jour perso terminée à 14:05"), line(done))
        XCTAssertTrue(line(done, running: other).hasSuffix("1a2b3c4d installé, mais ce Goalong exécute 9f8e7d6c."), line(done, running: other))
    }

    func testFailuresSayWhyAndOldDaysShowTheirDate() {
        XCTAssertEqual(line(entry([.received, .refused], reason: "numéro de build plus ancien")),
                       "Mise à jour perso 1a2b3c4d refusée à 14:05 : numéro de build plus ancien.")
        let restored = line(entry([.received, .verified, .closing, .relaunching, .restored], reason: "la nouvelle version n’a pas confirmé son démarrage"), after: 86_400 * 2)
        XCTAssertTrue(restored.contains("annulée le 27 nov. 2026 à 14:05, ancienne version restaurée : la nouvelle version"), restored)
        XCTAssertTrue(line(entry([.received, .verified, .closing, .relaunching, .failed], reason: "x")).contains("retour arrière impossible"))
    }

    func testAHandOffSilentForFiveMinutesIsInterrupted() {
        XCTAssertEqual(line(entry([.received, .verified, .closing]), after: 400),
                       "Mise à jour perso 1a2b3c4d interrompue à 14:05, à l’étape « fermeture ».")
    }

    func testHistoryRowListsThePhasesWithTheirOffsets() {
        let done = entry([.received, .verified, .closing, .relaunching, .done])
        XCTAssertEqual(PersoUpdateStatusText.steps(done), "demande reçue → vérifiée +3 s → fermeture +6 s → redémarrage +9 s → terminée +12 s")
        XCTAssertTrue(PersoUpdateStatusText.title(done).hasSuffix(" · 1a2b3c4d · terminée"), PersoUpdateStatusText.title(done))
        XCTAssertEqual(PersoUpdateStatusText.seconds(75), "1 min 15 s")
    }

    /// Fixtures only, in a temporary folder: never the real PersoUpdate data. PNGs for the owner's review.
    @MainActor func testRenderStatusLineAndHistory() throws {
        guard let path = ProcessInfo.processInfo.environment["GOALONG_PERSO_STATUS_SNAPSHOTS"] else { throw XCTSkip("Opt-in perso status render") }
        let output = URL(fileURLWithPath: path); try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let root = URL(fileURLWithPath: "/private/tmp/goalong-perso-status-render-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let history = PersoUpdateHistory(root: root)
        let now = Date().timeIntervalSince1970
        for (index, phases) in [[PersoUpdateHistory.Phase.received, .refused], [.received, .verified, .closing, .relaunching, .restored],
                                [.received, .verified, .closing, .relaunching, .done]].enumerated() {
            let id = "20261127-1400\(index)0-1"
            for (offset, phase) in phases.enumerated() {
                history.record(id, phase, commit: index == 2 ? full : other,
                               reason: phase == .refused ? "blocage verrouillé : 1 installation par 10 min, réessayez dans 412 s"
                                   : phase == .restored ? "la nouvelle version n’a pas confirmé son démarrage" : nil,
                               now: now - Double((3 - index) * 900) + Double(offset * 3))
            }
        }
        let model = PersoUpdateStatusModel(history: history); model.reload()
        let running = PersoUpdateHistory(root: root.appendingPathComponent("running"))
        for (offset, phase) in [PersoUpdateHistory.Phase.received, .verified, .closing].enumerated() {
            running.record("20261127-150000-1", phase, commit: full, now: now - 6 + Double(offset * 3))
        }
        let runningModel = PersoUpdateStatusModel(history: running); runningModel.reload()
        let app = NSApplication.shared; app.setActivationPolicy(.accessory); app.finishLaunching()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil); window.contentViewController = nil }
        func render(_ name: String, _ view: some View, height: CGFloat) throws {
            let host = NSHostingController(rootView: view.padding(16).frame(width: 620, height: height, alignment: .topLeading)
                .background(LHTheme.cardBackground).goalongControls().environment(\.goalongReduceMotion, true))
            window.contentViewController = host; window.setContentSize(NSSize(width: 620, height: height))
            window.makeKeyAndOrderFront(nil); RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            host.view.layoutSubtreeIfNeeded(); host.view.displayIfNeeded()
            let image = try XCTUnwrap(host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds))
            host.view.cacheDisplay(in: host.view.bounds, to: image)
            try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name + ".png"))
        }
        for dark in [false, true] {
            app.appearance = NSAppearance(named: dark ? .darkAqua : .aqua); window.appearance = app.appearance
            let suffix = dark ? "dark" : "light"
            try render("perso-status-done-" + suffix, VStack(alignment: .leading, spacing: 8) {
                Text("Build perso · perso · 1a2b3c4d").font(.system(size: 12, design: .monospaced))
                PersoUpdateStatusLine(model: model, runningCommit: full)
                PersoUpdateHistoryList(model: model, initiallyExpanded: false)
            }, height: 150)
            try render("perso-status-running-" + suffix, PersoUpdateStatusLine(model: runningModel, runningCommit: other), height: 70)
            try render("perso-history-open-" + suffix, PersoUpdateHistoryList(model: model, initiallyExpanded: true), height: 300)
        }
    }
}
#endif
