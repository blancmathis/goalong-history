#if os(macOS)
import AppKit
import SwiftUI

/// Click-through capsule that shows the most urgent Blocage countdown. It never takes focus,
/// stays out of Cmd-Tab and Mission Control, and holds no timer while hidden.
@MainActor final class BlockingTimerHUD {
    private let input: () -> BlockingTimerInput?
    private let clock: () -> Date
    private var panel: NSPanel?
    private var host: NSHostingView<BlockingTimerCapsule>?
    private var shown: BlockingVisibleTimer?
    private var pulse = 0
    private var tick: Timer?

    init(clock: @escaping () -> Date = Date.init, // wall: tests; the app passes the controller's trusted now
         input: @escaping () -> BlockingTimerInput?) {
        self.clock = clock; self.input = input
    }

    func update() {
        let now = clock(), snapshot = input()
        guard let value = snapshot.flatMap({ BlockingTimerSelection.select($0, at: now) }) else { hide(); return }
        if let shown, value.urgency > shown.urgency { pulse += 1 }
        shown = value
        let view = BlockingTimerCapsule(timer: value, pulse: pulse)
        let panel = self.panel ?? makePanel(view)
        host?.rootView = view
        let size = host?.fittingSize ?? .zero
        let frame = Self.frame(size: size, on: Self.screen(for: snapshot?.target))
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        if !panel.isVisible { panel.orderFrontRegardless() }
        // Wake when the shown second changes; a paused quota is re-read once a second.
        let fraction = value.remaining - (value.remaining.rounded(.up) - 1)
        let delay = value.counting && value.remaining > 0 ? min(1, max(0.05, fraction + 0.02)) : 1
        tick?.invalidate()
        let next = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.update() }
        }
        next.tolerance = 0.05
        RunLoop.main.add(next, forMode: .common); tick = next
    }

    func hide() {
        tick?.invalidate(); tick = nil; shown = nil
        panel?.orderOut(nil)
    }

    private func makePanel(_ view: BlockingTimerCapsule) -> NSPanel {
        let value = BlockingTimerPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        value.isReleasedWhenClosed = false; value.hidesOnDeactivate = false; value.isFloatingPanel = true
        // Above full-screen apps and Goalong's own veils; out of Mission Control and window cycling.
        value.level = .statusBar
        value.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        value.ignoresMouseEvents = true; value.isExcludedFromWindowsMenu = true
        value.isOpaque = false; value.backgroundColor = .clear; value.hasShadow = false
        let hosting = Self.makeHost(view)
        value.contentView = hosting
        panel = value; host = hosting
        return value
    }

    /// Intrinsic size only: measurable, without min/max constraints on the panel.
    /// With no sizing options `fittingSize` is zero and the capsule never shows.
    static func makeHost(_ view: BlockingTimerCapsule) -> NSHostingView<BlockingTimerCapsule> {
        let hosting = NSHostingView(rootView: view)
        hosting.sizingOptions = [.intrinsicContentSize]
        hosting.autoresizingMask = [.width, .height]
        return hosting
    }

    /// Screen of the foreground window, else the one under the pointer.
    private static func screen(for target: BlockingObservation?) -> NSScreen? {
        if let window = target?.windowFrame, !window.isEmpty {
            let frame = StandardBlockingBackend.appKitFrame(window)
            if let best = NSScreen.screens.max(by: { area($0.frame.intersection(frame)) < area($1.frame.intersection(frame)) }),
               area(best.frame.intersection(frame)) > 0 { return best }
        }
        return NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
    }
    private static func area(_ rect: CGRect) -> CGFloat { rect.isNull ? 0 : rect.width * rect.height }

    private static func frame(size: CGSize, on screen: NSScreen?) -> CGRect {
        guard let screen else { return CGRect(origin: .zero, size: size) }
        return frame(size: size, screen: screen.frame, visible: screen.visibleFrame, safeTop: screen.safeAreaInsets.top)
    }

    /// Top centre, under the menu bar and the notch; never over the centre of the screen.
    nonisolated static func frame(size: CGSize, screen: CGRect, visible: CGRect, safeTop: CGFloat) -> CGRect {
        let top = min(visible.maxY, screen.maxY - safeTop) - BlockingTimerCapsule.topGap
        return CGRect(x: (screen.midX - size.width / 2).rounded(), y: top - size.height, width: size.width, height: size.height)
    }
}

private final class BlockingTimerPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Dark translucent capsule, 28 pt high. Amber at 5 min, red at 1 min; a short pulse marks each
/// crossing, or only the colour change when motion is reduced.
struct BlockingTimerCapsule: View {
    var timer: BlockingVisibleTimer
    var pulse: Int
    static let height: CGFloat = 28
    /// Room for the pulse inside the click-through panel.
    static let inset: CGFloat = 4
    static let topGap: CGFloat = 2
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.goalongReduceMotion) private var localReduceMotion
    @State private var flash = 0.0

    private var tint: Color {
        switch timer.urgency {
        case .neutral: return Color.white.opacity(0.92)
        case .warning: return Color(red: 1.0, green: 0.76, blue: 0.29)
        case .critical: return Color(red: 1.0, green: 0.45, blue: 0.38)
        }
    }
    private var symbol: String {
        guard timer.counting else { return "pause.fill" }
        switch timer.kind {
        case .quota: return "hourglass"
        case .breakTime: return "cup.and.saucer.fill"
        case .slowDownAllowance: return "tortoise.fill"
        case .upcomingStart: return "lock.fill"
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(tint)
            HStack(spacing: 0) {
                Text(timer.prefix).foregroundStyle(Color.white.opacity(0.86))
                Text(timer.clock).foregroundStyle(tint)
            }
            .font(.system(size: 13, weight: .semibold).monospacedDigit())
            .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .frame(height: Self.height)
        .background(Capsule().fill(Color.black.opacity(0.78)))
        .background(Capsule().fill(tint.opacity(0.10 + 0.30 * flash)))
        .overlay(Capsule().strokeBorder(timer.urgency == .neutral ? Color.white.opacity(0.14) : tint.opacity(0.45 + 0.4 * flash), lineWidth: 1))
        .scaleEffect(1 + 0.06 * flash)
        .opacity(timer.counting ? 1 : 0.6)
        .environment(\.colorScheme, .dark)
        .padding(Self.inset)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(timer.accessibilityLabel)
        .onChange(of: pulse) { _ in
            guard !systemReduceMotion, !localReduceMotion, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
            withAnimation(.easeOut(duration: 0.3)) { flash = 1 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { withAnimation(.easeIn(duration: 0.3)) { flash = 0 } }
        }
    }
}
#endif
