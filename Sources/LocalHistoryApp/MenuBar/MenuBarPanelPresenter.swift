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
    ///
    /// The SwiftUI view never changes size. A hosting view resized while a SwiftUI animation runs gets its root
    /// size animated too, and NSHostingView centres that smaller root in its new bounds: every row moved by half
    /// the step (header and player shook by up to 24 pt on each opening, 83 pt for one jump of 166 pt).
    /// So the SwiftUI view is as tall as the screen, pinned to the top of a clipping container the size of the
    /// window (`PanelClipController`). The window edge only uncovers; nothing inside moves with it.
    final class MenuBarPanelPresenter {
        let popover = NSPopover()
        /// Test probe: every height the content reports.
        @MainActor var heightObserver: ((CGFloat) -> Void)?
        @MainActor private(set) var host: NSHostingController<MenuBarPanelView>?
        @MainActor private var clip: PanelClipController?
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
            let clip = PanelClipController(host: host)
            popover.contentViewController = clip
            self.host = host
            self.clip = clip
        }

        @MainActor private func resize(to height: CGFloat) {
            guard height > 0 else { return }
            let target = ceil(height)
            // Only for a panel taller than the screen (never seen): the hosting view must hold the content.
            clip?.ensureHostHeight(target)
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

    /// The popover content: a clipping view the size of the window, with the SwiftUI view pinned to its top.
    /// The SwiftUI view keeps one height (the tallest screen): a window resize moves nothing in it.
    final class PanelClipController: NSViewController {
        let host: NSHostingController<MenuBarPanelView>

        init(host: NSHostingController<MenuBarPanelView>) {
            self.host = host
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override func loadView() {
            let view = NSView(frame: NSRect(x: 0, y: 0, width: MenuBarPanelView.width, height: 100))
            view.wantsLayer = true
            view.layer?.masksToBounds = true
            addChild(host)
            let hosted = host.view
            let tallest = NSScreen.screens.map(\.frame.height).max() ?? 0
            let height = max(1200, ceil(tallest))
            hosted.frame = NSRect(x: 0, y: view.bounds.height - height, width: view.bounds.width, height: height)
            // Width follows; the top margin stays fixed (non-flipped view: the bottom margin is the flexible one).
            hosted.autoresizingMask = [.width, .minYMargin]
            view.addSubview(hosted)
            self.view = view
        }

        var hostHeight: CGFloat { host.view.frame.height }

        func ensureHostHeight(_ height: CGFloat) {
            if height > hostHeight { setHostHeight(height) }
        }

        func setHostHeight(_ height: CGFloat) {
            let bounds = view.bounds
            let frame = NSRect(x: 0, y: bounds.height - height, width: bounds.width, height: height)
            guard host.view.frame != frame else { return }
            host.view.frame = frame
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
