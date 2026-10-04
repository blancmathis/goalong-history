#if os(macOS)
import AppKit
import SwiftUI

/// Functional only. Replace this file's view/panel when the visual design is ready.
@MainActor final class SlowDownPlaceholderPanel {
    private class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }
    private var panel: NSPanel?
    private var key: String?
    func show(_ target: BlockingObservation, presentation: BlockingFrictionPresentation, onRenounce: @escaping () -> Void, onContinue: @escaping () -> Void) {
        let screen = target.windowFrame.flatMap { frame in NSScreen.screens.first { $0.frame.intersects(StandardBlockingBackend.appKitFrame(frame)) } } ?? NSScreen.main
        let frame = target.isBrowser ? target.windowFrame.map(StandardBlockingBackend.appKitFrame) ?? screen?.visibleFrame ?? .zero
            : CGRect(x: (screen?.visibleFrame.midX ?? 400) - 180, y: (screen?.visibleFrame.midY ?? 300) - 80, width: 360, height: 160)
        let p = panel ?? Panel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isReleasedWhenClosed = false; p.hidesOnDeactivate = false; p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]; p.level = .floating
        if key != presentation.key {
            p.contentView = NSHostingView(rootView: SlowDownPlaceholderView(presentation: presentation, onRenounce: onRenounce, onContinue: onContinue))
            key = presentation.key
        }
        p.setFrame(frame, display: true); p.orderFrontRegardless(); panel = p
    }
    func close() { panel?.close(); panel = nil; key = nil }
}
private struct SlowDownPlaceholderView: View {
    var presentation: BlockingFrictionPresentation
    var onRenounce: () -> Void
    var onContinue: () -> Void
    var body: some View {
        TimelineView(.periodic(from: presentation.shownAt, by: 1)) { context in
            VStack(spacing: 12) {
                Text(presentation.name)
                Text("\(max(0, Int(ceil(presentation.readyAt.timeIntervalSince(context.date))))) s")
                Text("\(presentation.occurrence)e fois aujourd’hui")
                HStack { Button("Renoncer", action: onRenounce); Button("Continuer", action: onContinue).disabled(context.date < presentation.readyAt) }
            }.padding().frame(maxWidth: .infinity, maxHeight: .infinity).background(.regularMaterial)
        }
    }
}
#endif
