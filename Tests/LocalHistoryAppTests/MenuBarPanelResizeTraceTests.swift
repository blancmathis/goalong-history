#if os(macOS)
import Ambiance
import AppKit
import SwiftUI
import XCTest
@testable import LocalHistoryApp

/// Opt-in frame-by-frame trace of the panel while its height changes (no visible window).
/// `GOALONG_PANEL_TRACE=<dir> make check FILTER=MenuBarPanelResizeTraceTests`
final class MenuBarPanelResizeTraceTests: XCTestCase {
    @MainActor func testTraceResize() throws {
        guard let path = ProcessInfo.processInfo.environment["GOALONG_PANEL_TRACE"] else { throw XCTSkip("opt-in") }
        let dir = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory); app.finishLaunching()
        let suite = "menubar-trace-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let root = URL(fileURLWithPath: "/private/tmp/" + suite)
        let model = MenuBarPanelModel(
            state: CaptureState(isGloballyPaused: { false }), modules: GoalongModuleStore(defaults: defaults),
            concentration: { nil }, ambianceModule: AmbianceModule(settings: AmbianceSettings(defaults: defaults), supportDirectory: { root }),
            blocking: { nil }, onTogglePause: {}, onOpenSection: { _ in }, onOpenDay: {}, onShowClassicMenu: {})
        func source(_ id: String, _ title: String, _ kind: AmbianceSource.Kind) -> AmbianceSource {
            AmbianceSource(id: id, title: title, kind: kind, isAvailable: true)
        }
        let sources = [source("a", "Ambre", .focus), source("b", "Canopée", .focus), source("c", "Sillage", .focus),
                       source("d", "Lagon", .relax), source("e", "Pluie", .texture)]
        model.tracking = .active; model.trackingDetail = "Enregistrement local actif"
        model.focusAvailable = true; model.focusKind = .free; model.focusMinutes = 25; model.focusRun = nil
        model.concentrationEnabled = true
        model.ambianceEnabled = true; model.ambianceSources = sources; model.ambianceCurrent = sources[0]

        let harness = PanelPopoverHarness(model: model)
        harness.show()
        pump(0.6)
        /// Pass A: heights only, sampled every ~4 ms. Pass B: one PNG per frame (slower, so timing differs).
        func trace(_ name: String, _ change: () -> Void, revert: () -> Void) throws {
            let out = dir.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            var log = "t_ms window_h view_h\n"
            var start = Date()
            harness.presenter.heightObserver = { h in log += "report \(Int(Date().timeIntervalSince(start) * 1000)) \(h)\n" }
            change()
            while Date().timeIntervalSince(start) < 0.7 {
                pump(0.004)
                log += "\(Int(Date().timeIntervalSince(start) * 1000)) \(Int(harness.popoverHeight)) \(Int(harness.host.view.bounds.height))\n"
            }
            try log.write(to: out.appendingPathComponent("trace.txt"), atomically: true, encoding: .utf8)
            print("PANEL_TRACE \(name)\n\(log)")
            harness.presenter.heightObserver = nil
            revert(); pump(0.7)
            start = Date()
            change()
            var index = 0
            while Date().timeIntervalSince(start) < 0.7 {
                pump(0.001)
                let t = Int(Date().timeIntervalSince(start) * 1000)
                if let bitmap = harness.snapshot() {
                    try bitmap.representation(using: .png, properties: [:])?
                        .write(to: out.appendingPathComponent(String(format: "f%03d_%04dms.png", index, t)))
                }
                index += 1
            }
            pump(0.5)
        }
        let toPomodoro = { withAnimation(LHTheme.settle) { model.focusKind = .pomodoro } }
        let toFree = { withAnimation(LHTheme.settle) { model.focusKind = .free } }
        try trace("1-libre-pomodoro", toPomodoro, revert: toFree)
        pump(0.5)
        try trace("2-pomodoro-libre", toFree, revert: toPomodoro)
        pump(0.5)
        try trace("3-music-open", { harness.toggleMusic(model) }, revert: { harness.toggleMusic(model) })
        pump(0.5)
        try trace("4-music-close", { harness.toggleMusic(model) }, revert: { harness.toggleMusic(model) })
        harness.close()
    }


    /// Opt-in timing probe of opening the sounds: main-thread stalls per frame, window height per frame,
    /// cost of one resize with the sounds open vs closed. `GOALONG_PANEL_PROBE=1 make check FILTER=MenuBarPanelResizeTraceTests`
    @MainActor func testProbeMusicOpen() throws {
        guard ProcessInfo.processInfo.environment["GOALONG_PANEL_PROBE"] != nil else { throw XCTSkip("opt-in") }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory); app.finishLaunching()
        let suite = "menubar-probe-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let root = URL(fileURLWithPath: "/private/tmp/" + suite)
        let model = MenuBarPanelModel(
            state: CaptureState(isGloballyPaused: { false }), modules: GoalongModuleStore(defaults: defaults),
            concentration: { nil }, ambianceModule: AmbianceModule(settings: AmbianceSettings(defaults: defaults), supportDirectory: { root }),
            blocking: { nil }, onTogglePause: {}, onOpenSection: { _ in }, onOpenDay: {}, onShowClassicMenu: {})
        var sources: [AmbianceSource] = []
        for (kind, count) in [(AmbianceSource.Kind.focus, 9), (.relax, 6), (.texture, 8)] {
            for i in 0..<count { sources.append(AmbianceSource(id: "\(kind)\(i)", title: "Sonar \(i)", kind: kind, isAvailable: i % 4 != 3)) }
        }
        model.tracking = .active; model.trackingDetail = "Enregistrement local actif"
        model.focusAvailable = true; model.focusKind = .free; model.focusMinutes = 25; model.focusRun = nil
        model.concentrationEnabled = true
        model.ambianceEnabled = true; model.ambianceSources = sources; model.ambianceCurrent = sources[0]
        let harness = PanelPopoverHarness(model: model)
        harness.show()
        pump(0.6)
        var report = ""
        var stallTotals: [String: Double] = [:]
        func frames(_ name: String, _ change: () -> Void) {
            var ticks: [(Double, CGFloat)] = []
            let start = ProcessInfo.processInfo.systemUptime
            let timer = Timer(timeInterval: 1.0 / 240.0, repeats: true) { _ in
                ticks.append(((ProcessInfo.processInfo.systemUptime - start) * 1000, harness.popoverHeight))
            }
            RunLoop.main.add(timer, forMode: .common)
            change()
            let changeCost = (ProcessInfo.processInfo.systemUptime - start) * 1000
            pump(0.45)
            timer.invalidate()
            var gaps: [Double] = []
            var prev = changeCost
            for t in ticks { gaps.append(t.0 - prev); prev = t.0 }
            let stalls = gaps.filter { $0 > 12 }
            stallTotals[name] = stalls.reduce(0, +)
            report += "\(name): change() \(Int(changeCost)) ms; first tick \(Int(ticks.first?.0 ?? -1)) ms; stalls>12ms \(stalls.count) max \(Int(gaps.max() ?? 0)) ms; total stall \(Int(stalls.reduce(0, +))) ms\n"
            var line = ""
            var last: CGFloat = -1
            for t in ticks where t.0 < 330 && t.1 != last { line += "\(Int(t.0)):\(Int(t.1)) "; last = t.1 }
            var maxStep: CGFloat = 0
            for i in 1..<max(1, ticks.count) { maxStep = max(maxStep, abs(ticks[i].1 - ticks[i - 1].1)) }
            report += "  max step \(Int(maxStep)) px; heights " + line + "\n"
        }
        func resizeCost(_ label: String) {
            let base = harness.presenter.popover.contentSize
            let start = ProcessInfo.processInfo.systemUptime
            for i in 0..<40 {
                harness.presenter.popover.animates = false
                harness.presenter.popover.contentSize = NSSize(width: base.width, height: base.height - CGFloat(i % 2) * 7)
                harness.host.view.layoutSubtreeIfNeeded()
                harness.host.view.displayIfNeeded()
            }
            harness.presenter.popover.contentSize = base
            report += "\(label): \(String(format: "%.2f", (ProcessInfo.processInfo.systemUptime - start) * 1000 / 40)) ms per resize\n"
        }
        resizeCost("resize, sounds closed")
        frames("pomodoro", { withAnimation(LHTheme.settle) { model.focusKind = .pomodoro } })
        pump(0.3)
        frames("libre", { withAnimation(LHTheme.settle) { model.focusKind = .free } })
        pump(0.3)
        frames("open", { harness.toggleMusic(model) })
        pump(0.3)
        resizeCost("resize, sounds open")
        frames("close", { harness.toggleMusic(model) })
        pump(0.3)
        frames("open again", { harness.toggleMusic(model) })
        pump(0.3)
        frames("close again", { harness.toggleMusic(model) })
        pump(0.3)
        if ProcessInfo.processInfo.environment["GOALONG_PANEL_PROBE_LOOP"] != nil {
            for _ in 0..<12 { harness.toggleMusic(model); pump(0.4) }
        }
        print("PANEL_PROBE\n" + report)
        // Before the fix (chevron symbol swapped inside the animation): 230 to 300 ms of stalls per opening or closing.
        for name in ["open", "close", "open again", "close again"] {
            XCTAssertLessThan(stallTotals[name] ?? .infinity, 100, "\(name): the main thread stalls during the sounds animation")
        }
        try? report.write(toFile: "/private/tmp/goalong-panel-motion/probe.txt", atomically: true, encoding: .utf8)
        harness.close()
    }

    /// Opt-in: what the eye sees while the sounds open and close. Per sample, the on-screen y (AppKit, bottom-left)
    /// of the header top, the shift of the header + player band against the first sample, and the footer bottom,
    /// from a bitmap of the content placed with the window frame. Any back-and-forth of header or player = tremble.
    /// `GOALONG_PANEL_TREMBLE=<file> make check FILTER=MenuBarPanelResizeTraceTests`
    @MainActor func testProbeTremble() throws {
        guard let out = ProcessInfo.processInfo.environment["GOALONG_PANEL_TREMBLE"] else { throw XCTSkip("opt-in") }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory); app.finishLaunching()
        let suite = "menubar-tremble-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let root = URL(fileURLWithPath: "/private/tmp/" + suite)
        let model = MenuBarPanelModel(
            state: CaptureState(isGloballyPaused: { false }), modules: GoalongModuleStore(defaults: defaults),
            concentration: { nil }, ambianceModule: AmbianceModule(settings: AmbianceSettings(defaults: defaults), supportDirectory: { root }),
            blocking: { nil }, onTogglePause: {}, onOpenSection: { _ in }, onOpenDay: {}, onShowClassicMenu: {})
        var sources: [AmbianceSource] = []
        for (kind, count) in [(AmbianceSource.Kind.focus, 9), (.relax, 6), (.texture, 8)] {
            for i in 0..<count { sources.append(AmbianceSource(id: "\(kind)\(i)", title: "Sonar \(i)", kind: kind, isAvailable: i % 4 != 3)) }
        }
        model.tracking = .active; model.trackingDetail = "Enregistrement local actif"
        model.focusAvailable = true; model.focusKind = .free; model.focusMinutes = 25; model.focusRun = nil
        model.concentrationEnabled = true
        model.ambianceEnabled = true; model.ambianceSources = sources; model.ambianceCurrent = sources[0]
        let harness = PanelPopoverHarness(model: model)
        harness.show()
        pump(0.6)
        var report = ""
        var worst: [String: (back: Int, span: Double)] = [:]

        struct Sample { let t: Double; let winY: Double; let winH: Double; let wsY: Double; let headerY: Double; let bandShift: Int; let footerY: Double }
        func ink(_ rep: NSBitmapImageRep) -> [Int] {
            let w = rep.pixelsWide, h = rep.pixelsHigh
            guard let data = rep.bitmapData else { return [] }
            let bpr = rep.bytesPerRow, bpp = rep.bitsPerPixel / 8
            func px(_ x: Int, _ y: Int) -> (Int, Int, Int) {
                let o = y * bpr + x * bpp; return (Int(data[o]), Int(data[o + 1]), Int(data[o + 2]))
            }
            var rows = [Int](repeating: 0, count: h)
            for y in 0..<h {
                let bg = px(2, y)
                var n = 0
                var x = 8
                while x < w - 8 {
                    let c = px(x, y)
                    n += abs(c.0 - bg.0) + abs(c.1 - bg.1) + abs(c.2 - bg.2)
                    x += 2
                }
                rows[y] = n
            }
            return rows
        }
        func wsY(_ window: NSWindow) -> Double {
            guard let list = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(window.windowNumber)) as? [[String: Any]],
                  let b = list.first?[kCGWindowBounds as String] as? [String: Any],
                  let y = b["Y"] as? Double, let h = b["Height"] as? Double,
                  let screenH = NSScreen.screens.first?.frame.height else { return -1 }
            return screenH - y - h
        }
        func run(_ name: String, _ change: () -> Void) {
            let view = harness.host.view
            guard let window = view.window else { return }
            let scale = window.backingScaleFactor
            var samples: [Sample] = []
            var refBand: [Int] = []
            // The fixed part: everything above the sounds (window height closed, minus player and footer).
            let bandRows = Int((min(harness.popoverHeight, 433) - 120) * scale)
            var raw: [(Double, NSRect, NSRect, Double, NSBitmapImageRep)] = []
            let start = ProcessInfo.processInfo.systemUptime
            change()
            while ProcessInfo.processInfo.systemUptime - start < 0.4 {
                pump(0.002)
                // Only what the window shows (the hosting view can be taller than the window).
                let visible = view.visibleRect
                guard let rep = view.bitmapImageRepForCachingDisplay(in: visible) else { continue }
                view.cacheDisplay(in: visible, to: rep)
                raw.append(((ProcessInfo.processInfo.systemUptime - start) * 1000, window.frame,
                            window.convertToScreen(view.convert(visible, to: nil)), wsY(window), rep))
            }
            for (t, frame, rect, ws, rep) in raw {
                let rows = ink(rep)
                guard rows.count > bandRows else { continue }
                let top = rows.firstIndex { $0 > 200 } ?? -1
                let bottom = rows.lastIndex { $0 > 200 } ?? -1
                let band = Array(rows[0..<bandRows])
                if refBand.isEmpty { refBand = band }
                var best = 0, bestErr = Int.max
                for s in -24...24 {
                    var err = 0
                    for y in 30..<(bandRows - 30) { err += abs(band[y] - refBand[y - s]) }
                    if err < bestErr { bestErr = err; best = s }
                }
                let headerY = rect.maxY - Double(top) / scale
                let footerY = rect.maxY - Double(bottom + 1) / scale
                samples.append(Sample(t: t, winY: frame.minY, winH: frame.height, wsY: ws, headerY: headerY,
                                      bandShift: best, footerY: footerY - frame.minY))
            }
            // Back-and-forth: a sign change in the step of the header y or the band shift.
            var back = 0, lastStep = 0.0
            for i in 1..<samples.count {
                let step = samples[i].headerY - samples[i - 1].headerY + Double(samples[i].bandShift - samples[i - 1].bandShift)
                if step != 0 { if lastStep != 0, (step > 0) != (lastStep > 0) { back += 1 }; lastStep = step }
            }
            let ys = samples.map(\.headerY)
            let span = (ys.max() ?? 0) - (ys.min() ?? 0)
            let shifts = samples.map(\.bandShift)
            worst[name] = (back, span)
            report += "\(name): samples \(samples.count); header y span \(span) pt; band shift min \(shifts.min() ?? 0) max \(shifts.max() ?? 0) px; reversals \(back)\n"
            report += "  t_ms winY winH wsY headerY bandShift footerAboveWinBottom\n"
            for s in samples {
                report += String(format: "  %5.1f %7.1f %6.1f %7.1f %7.1f %3d %6.1f\n", s.t, s.winY, s.winH, s.wsY, s.headerY, s.bandShift, s.footerY)
            }
        }
        run("open", { harness.toggleMusic(model) }); pump(0.3)
        run("close", { harness.toggleMusic(model) }); pump(0.3)
        run("open again", { harness.toggleMusic(model) }); pump(0.3)
        run("close again", { harness.toggleMusic(model) }); pump(0.3)
        run("pomodoro", { withAnimation(LHTheme.settle) { model.focusKind = .pomodoro } }); pump(0.3)
        run("libre", { withAnimation(LHTheme.settle) { model.focusKind = .free } }); pump(0.3)
        print("PANEL_TREMBLE\n" + report)
        // Before the fix (hosting view resized with the window): the header moved by up to 37 pt on opening.
        for (name, result) in worst { XCTAssertEqual(result.span, 0, "\(name): the header moves on screen") }
        try? report.write(toFile: out, atomically: true, encoding: .utf8)
        harness.close()
    }

    @MainActor private func pump(_ s: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }
}

/// The real presenter in a popover anchored to an alpha 0 window (the headless support keeps it invisible).
@MainActor final class PanelPopoverHarness {
    let presenter = MenuBarPanelPresenter()
    let window = NSWindow(contentRect: NSRect(x: 200, y: 600, width: 200, height: 40), styleMask: [.titled], backing: .buffered, defer: false)
    let anchor = NSButton(title: "Ancre", target: nil, action: nil)
    var host: NSHostingController<MenuBarPanelView> { presenter.host! }
    var popoverHeight: CGFloat { host.view.window?.frame.height ?? 0 }

    init(model: MenuBarPanelModel) {
        window.isReleasedWhenClosed = false
        window.contentView = anchor
        presenter.popover.behavior = .applicationDefined
        presenter.popover.animates = true
        presenter.install(model: model)
    }

    func show() {
        // Like the status item: the anchor at the top of the screen, the popover below it with room to grow.
        if let screen = NSScreen.main {
            window.setFrameTopLeftPoint(NSPoint(x: screen.visibleFrame.midX, y: screen.visibleFrame.maxY))
        }
        window.orderFront(nil)
        presenter.prepareToShow()
        presenter.popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
    }

    func close() { presenter.popover.close(); window.orderOut(nil); window.contentView = nil }

    func snapshot() -> NSBitmapImageRep? {
        let view = host.view
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }

    func toggleMusic(_ model: MenuBarPanelModel) { model.toggleAmbianceExpanded(animated: true) }
}
#endif
