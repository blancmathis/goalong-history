#if os(macOS)
    import AppKit
    import SwiftUI

    /// The menu bar panel's popover and its hosted content, and how the popover follows the content's height.
    ///
    /// The content reports its final height at once, while its own animation (`LHTheme.settle`) moves the
    /// rows over 240 ms. NSPopover animates a size change on its own clock and curve, so the edge and the rows
    /// were out of step: « Ouvrir Goalong » was cut when the panel shrank, and the sounds were cut while they opened.
    /// Here the popover size is set by `PanelHeightTween`, on the same curve and duration as the content, so the
    /// edge and the rows move together (a frame of margin keeps the window on the safe side: ahead when it
    /// grows, behind when it shrinks).
    final class MenuBarPanelPresenter {
        let popover = NSPopover()
        /// Test probe: every height the content reports.
        @MainActor var heightObserver: ((CGFloat) -> Void)?
        @MainActor private(set) var host: NSHostingController<MenuBarPanelView>?
        @MainActor private var tween: PanelHeightTween?
        @MainActor private var timer: Timer?
        /// The height the window has now (it moves while a tween runs).
        @MainActor private(set) var shownHeight: CGFloat = 0

        @MainActor func install(model: MenuBarPanelModel) {
            let host = NSHostingController(rootView: MenuBarPanelView(model: model) { [weak self] height in
                self?.resize(to: height)
            })
            // The presenter drives the popover size itself (see resize), on the content's own curve.
            host.sizingOptions = []
            popover.contentViewController = host
            self.host = host
        }

        @MainActor private func resize(to height: CGFloat) {
            guard height > 0 else { return }
            let target = ceil(height)
            if let tween, tween.target == target { return }
            if tween == nil, target == shownHeight { return }
            guard popover.isShown, !GoalongMotionPreference.reduced() else {
                cancelTween()
                apply(target)
                return
            }
            tween = PanelHeightTween(from: shownHeight, to: target, now: ProcessInfo.processInfo.systemUptime)
            guard timer == nil else { return }
            let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.step() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
            step()
        }

        @MainActor private func step() {
            guard let tween else { cancelTween(); return }
            let now = ProcessInfo.processInfo.systemUptime
            apply(tween.height(at: now))
            if tween.isFinished(at: now) { cancelTween() }
        }

        /// Sets the window size at once: NSPopover must not animate it a second time.
        @MainActor private func apply(_ height: CGFloat) {
            shownHeight = height
            let size = NSSize(width: MenuBarPanelView.width, height: height)
            guard popover.contentSize != size else { return }
            let animates = popover.animates
            popover.animates = false
            popover.contentSize = size
            popover.animates = animates
        }

        /// Stops following (panel closed, or the size set at once). The window keeps its last size.
        @MainActor func cancelTween() {
            timer?.invalidate(); timer = nil
            tween = nil
        }

        /// Before `show`: the natural height, so the popover opens at its final size.
        @MainActor func prepareToShow() {
            guard let host else { return }
            cancelTween()
            // With no sizing options, fittingSize is wrong; ask SwiftUI for the natural height.
            // A zero proposal returns the fixed-size content height (the outer frame never shrinks it).
            let ideal = host.sizeThatFits(in: NSSize(width: MenuBarPanelView.width, height: 0))
            if ideal.height > 0 { apply(ceil(ideal.height)) }
        }
    }

    /// The height of the window between two sizes: the content's curve and duration (`LHTheme.settle`), sampled by time.
    struct PanelHeightTween: Equatable {
        let from: CGFloat
        let target: CGFloat
        let start: TimeInterval
        let duration: TimeInterval

        /// Growing starts one frame in: the edge must not trail the rows (it would cut them).
        /// Shrinking starts on time: the edge trails the rows by the start latency, which cuts nothing.
        static let growthLead: TimeInterval = 1.0 / 60.0

        init(from: CGFloat, to target: CGFloat, now: TimeInterval, duration: TimeInterval = LHTheme.settleDuration) {
            self.from = from
            self.target = target
            self.duration = duration
            self.start = target > from ? now - Self.growthLead : now
        }

        func progress(at time: TimeInterval) -> Double {
            Self.bezier(min(1, max(0, (time - start) / duration)))
        }

        func height(at time: TimeInterval) -> CGFloat {
            let value = from + (target - from) * CGFloat(progress(at: time))
            // Half points: the window edge lands on a pixel on every screen.
            return (value * 2).rounded() / 2
        }

        func isFinished(at time: TimeInterval) -> Bool { time - start >= duration }

        /// The cubic Bézier of `LHTheme.ease` (CSS `cubic-bezier`): y for a given x.
        static func bezier(_ x: Double) -> Double {
            let c = LHTheme.easeCurve
            func coordinate(_ t: Double, _ a: Double, _ b: Double) -> Double {
                let u = 1 - t
                return 3 * u * u * t * a + 3 * u * t * t * b + t * t * t
            }
            var low = 0.0, high = 1.0, t = x
            for _ in 0..<40 {
                let value = coordinate(t, c.x1, c.x2)
                if abs(value - x) < 1e-6 { break }
                if value < x { low = t } else { high = t }
                t = (low + high) / 2
            }
            return coordinate(t, c.y1, c.y2)
        }
    }
#endif
