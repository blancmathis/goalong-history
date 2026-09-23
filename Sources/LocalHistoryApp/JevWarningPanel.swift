#if os(macOS)
import AppKit
import SwiftUI
import LocalHistoryCore

/// Non-activating, click-through screen effects. Never changes display brightness, gamma,
/// keyboard routing or system settings. All windows die with the application process.
@MainActor final class JevWarningPanel {
    static let shared = JevWarningPanel(
        onExpiry: { JevMonitor.shared.dismissWarning() },
        onDismiss: { JevMonitor.shared.dismissWarning() })
    private(set) var panel: NSPanel?
    private(set) var overlays: [NSPanel] = []
    private var previousAnchor: JevWarningAnchor?
    private var expiry: Timer?
    private let content = JevWarningContent()
    private let ordersWindows: Bool
    private let onExpiry: () -> Void
    private let onDismiss: () -> Void
    init(ordersWindows: Bool = true, onExpiry: @escaping () -> Void = {},
         onDismiss: @escaping () -> Void = {}) {
        self.ordersWindows = ordersWindows; self.onExpiry = onExpiry; self.onDismiss = onDismiss
    }

    func update(seconds: Int, appearance: Int, present: Bool, settings: JevInterventionSettings) {
        guard seconds >= 30 else { hide(); return }
        guard present || panel != nil || !overlays.isEmpty else { return }
        if panel == nil && present {
            guard let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main else { return }
            let anchor = JevWarningAnchor.next(appearance: appearance,
                moving: settings.moveAfterSecondAppearance, previous: previousAnchor,
                sample: Int.random(in: 0...Int.max))
            previousAnchor = anchor
            let target = Self.frame(in: screen.visibleFrame, anchor: anchor)
            let value = JevNonactivatingPanel(contentRect: target,
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            value.isReleasedWhenClosed = false
            value.isFloatingPanel = true; value.hidesOnDeactivate = false
            value.level = .floating; value.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            value.isOpaque = false; value.backgroundColor = .clear; value.hasShadow = true
            // A content hosting view otherwise derives window min/max sizes from SwiftUI.
            // This reminder has an explicitly bounded layout, including after the first run loop.
            let host = NSHostingView(rootView: JevWarningView(content: content, onClose: { [weak self] in
                self?.dismissPopup(); self?.onDismiss()
            })
                .frame(width: target.width, height: target.height))
            host.sizingOptions = []
            host.frame = NSRect(origin: .zero, size: target.size)
            host.autoresizingMask = [.width, .height]
            value.contentView = host
            value.contentMinSize = target.size; value.contentMaxSize = target.size
            value.setFrame(target, display: false)
            panel = value
        }
        content.seconds = seconds
        updateEffects(settings.stage(at: seconds))
        if ordersWindows { panel?.orderFrontRegardless() }
        expiry?.invalidate()
        // A missing callback must never leave an effect indefinitely. Every fresh verdict renews it.
        let lease = Timer(timeInterval: 30, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.expire() }
        }
        RunLoop.main.add(lease, forMode: .common)
        expiry = lease
    }

    /// Closing a reminder is not a pause: keep effects and their existing safety lease.
    func dismissPopup() {
        panel?.orderOut(nil); panel?.close(); panel = nil
    }

    func hide(resetPosition: Bool = false) {
        expiry?.invalidate(); expiry = nil
        dismissPopup()
        clearEffects()
        if resetPosition { previousAnchor = nil }
    }

    func expire() {
        hide()
        onExpiry()
    }

    private func clearEffects() {
        for overlay in overlays { overlay.orderOut(nil); overlay.close() }
        overlays.removeAll()
    }
    private func updateEffects(_ stage: JevInterventionStage?) {
        guard let stage else { clearEffects(); return }
        // Reuse windows between decisions: no flashing or repeated fade animation.
        if overlays.count != NSScreen.screens.count {
            clearEffects()
            for screen in NSScreen.screens {
                let overlay = JevNonactivatingPanel(contentRect: screen.frame,
                    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                overlay.isReleasedWhenClosed = false
                overlay.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
                overlay.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                overlay.ignoresMouseEvents = true
                overlay.isOpaque = false; overlay.hasShadow = false; overlay.hidesOnDeactivate = false
                overlays.append(overlay)
            }
        }
        let opacity = Double(min(40, max(10, stage.intensity))) / 100
        let red: Double = stage.effect == .dim ? 0 : stage.effect == .red ? 1 : 0.45
        for (overlay, screen) in zip(overlays, NSScreen.screens) {
            overlay.setFrame(screen.frame, display: false)
            overlay.backgroundColor = NSColor(srgbRed: red, green: 0, blue: 0, alpha: opacity)
            if ordersWindows { overlay.orderFrontRegardless() }
        }
    }

    static func frame(in visible: NSRect, anchor: JevWarningAnchor) -> NSRect {
        let area = visible.insetBy(dx: 16, dy: 16)
        let width = min(400, max(1, area.width)), height = min(156, max(1, area.height))
        let x: CGFloat
        switch anchor {
        case .topRight, .bottomRight: x = area.maxX - width
        case .topLeft, .bottomLeft: x = area.minX
        case .topCenter, .bottomCenter: x = area.midX - width / 2
        }
        let top = [JevWarningAnchor.topRight, .topLeft, .topCenter].contains(anchor)
        return NSRect(x: x, y: top ? area.maxY - height : area.minY, width: width, height: height)
    }
}

private final class JevNonactivatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
@MainActor final class JevWarningContent: ObservableObject {
    @Published var seconds = 30
}
@MainActor struct JevWarningView: View {
    @ObservedObject var content: JevWarningContent
    var onClose: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Arrête de procrastiner.")
                .font(.system(size: 20, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            Text("Ça fait \(JevInterventionSettings.duration(content.seconds)) que tu procrastines.")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("jev-warning-duration")
            HStack {
                Button("Fermer", action: onClose)
                    .accessibilityIdentifier("jev-warning-close")
                    .help("Masquer uniquement ce rappel jusqu’à la prochaine détection. Les effets restent actifs.")
                Spacer()
            }
        }.padding(18).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(LHTheme.warning.opacity(0.5)))
    }
}
#endif
