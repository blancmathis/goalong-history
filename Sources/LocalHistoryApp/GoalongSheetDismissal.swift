#if os(macOS)
import AppKit
import SwiftUI

/// T-052 lot 1: a click in the Goalong window outside an open sheet, and ⌘W, do what the sheet's « Annuler » does.
/// One shared mechanism: sheets never copy this code. A sheet that must never close this way (password, stop
/// phrase, busy sheet) simply does not use the modifier.
enum GoalongSheetDismissal {
    enum Decision: Equatable { case ignore, cancel, askToDiscard }

    /// What a click or ⌘W does. Pure, so a test proves every exclusion without a window.
    /// - `otherLayerAbove`: an alert, a confirmation, a file panel or a popover sits above the sheet.
    static func decision(isEnabled: Bool, isDirty: Bool, otherLayerAbove: Bool) -> Decision {
        guard isEnabled, !otherLayerAbove else { return .ignore }
        return isDirty ? .askToDiscard : .cancel
    }

    /// True when something other than the sheet itself is in front: a nested sheet (alert, panel) or a child window (popover).
    @MainActor static func otherLayerAbove(sheet: NSWindow) -> Bool {
        if sheet.attachedSheet != nil { return true }
        if NSApp.modalWindow != nil { return true }
        return sheet.childWindows?.contains(where: { $0.isVisible }) ?? false
    }

    /// Gives the first editable text field of a sheet (top-most, then left-most) the keyboard focus. A sheet without a
    /// text field is left alone. Never activates the app or raises a window: it only picks the sheet's first responder.
    @MainActor static func focusFirstField(in window: NSWindow) {
        guard let root = window.contentView, !(window.firstResponder is NSTextView && (window.firstResponder as? NSTextView)?.isEditable == true) else { return }
        var found: [(NSView, NSRect)] = []
        func walk(_ view: NSView) {
            if !view.isHiddenOrHasHiddenAncestor {
                if let text = view as? NSTextView, text.isEditable, text.isFieldEditor == false { found.append((text, view.convert(view.bounds, to: nil))) }
                else if let field = view as? NSTextField, field.isEditable, field.acceptsFirstResponder { found.append((field, view.convert(view.bounds, to: nil))) }
            }
            view.subviews.forEach(walk)
        }
        walk(root)
        let first = found.min { a, b in a.1.maxY != b.1.maxY ? a.1.maxY > b.1.maxY : a.1.minX < b.1.minX }
        if let view = first?.0 { window.makeFirstResponder(view) }
    }

    /// Watches one sheet window. Installed when the probe joins the sheet window, removed when it leaves.
    @MainActor final class Watcher {
        weak var window: NSWindow?
        var isEnabled: () -> Bool = { true }
        var isDirty: () -> Bool = { false }
        var cancel: () -> Void = {}
        var askToDiscard: () -> Void = {}
        private var monitor: Any?
        static let escapeKeyCode: UInt16 = 53

        func start(in window: NSWindow) {
            stop()
            self.window = window
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .keyDown]) { [weak self] event in
                MainActor.assumeIsolated { self?.handle(event) ?? event }
            }
            // First field gets the focus once the sheet's views exist.
            DispatchQueue.main.async { [weak window] in
                guard let window else { return }
                GoalongSheetDismissal.focusFirstField(in: window)
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            window = nil
        }

        /// Returns nil when the event is consumed (a click that closes the sheet must not reach the page behind).
        func handle(_ event: NSEvent) -> NSEvent? {
            guard let sheet = window else { return event }
            switch event.type {
            case .leftMouseDown:
                // Only a click in the window the sheet hangs from, and not in the sheet itself.
                guard let parent = sheet.sheetParent, event.window === parent, parent.attachedSheet === sheet else { return event }
            case .keyDown:
                // ⌘W or Escape while the sheet is the key window: both do what « Annuler » does.
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                let isCommandW = flags == .command && event.charactersIgnoringModifiers == "w"
                let isEscape = flags.isEmpty && event.keyCode == Self.escapeKeyCode
                guard event.window === sheet, isCommandW || isEscape else { return event }
            default:
                return event
            }
            switch GoalongSheetDismissal.decision(isEnabled: isEnabled(), isDirty: isDirty(),
                                                  otherLayerAbove: GoalongSheetDismissal.otherLayerAbove(sheet: sheet)) {
            case .ignore: return event
            case .cancel: cancel(); return nil
            case .askToDiscard: askToDiscard(); return nil
            }
        }
    }

    struct Probe: NSViewRepresentable {
        let watcher: Watcher
        final class View: NSView {
            var watcher: Watcher?
            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                if let window { MainActor.assumeIsolated { watcher?.start(in: window) } }
                else { MainActor.assumeIsolated { watcher?.stop() } }
            }
        }
        func makeNSView(context: Context) -> View { let view = View(); view.watcher = watcher; return view }
        func updateNSView(_ view: View, context: Context) { view.watcher = watcher }
    }
}

private struct GoalongDismissOnOutsideClick: ViewModifier {
    let isDirty: () -> Bool
    let isEnabled: () -> Bool
    let onCancel: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var watcher = GoalongSheetDismissal.Watcher()
    @State private var confirming = false

    func body(content: Content) -> some View {
        configure() // the watcher is a plain object: refreshing its closures on every body keeps them current
        return content
            .background(GoalongSheetDismissal.Probe(watcher: watcher).frame(width: 0, height: 0).allowsHitTesting(false))
            .alert("Abandonner les modifications ?", isPresented: $confirming) {
                Button("Continuer", role: .cancel) {}
                Button("Abandonner", role: .destructive) { cancel() }
            }
    }

    private func cancel() { if let onCancel { onCancel() } else { dismiss() } }

    private func configure() {
        watcher.isDirty = isDirty
        watcher.isEnabled = isEnabled
        watcher.cancel = cancel
        watcher.askToDiscard = { confirming = true }
    }
}

extension View {
    /// A click in the Goalong window outside this sheet, and ⌘W, act like the sheet's « Annuler »: the sheet closes at
    /// once when `isDirty` is false, otherwise it stays and asks « Abandonner les modifications ? ». Never closes while an
    /// alert, a file panel or a popover is above the sheet. Use `onCancel` when « Annuler » does more than dismiss.
    /// Place it next to `goalongControls()`, on the sheet's root. Never on a password, stop-phrase or busy sheet.
    /// `isEnabled` turns it off while the sheet is busy (a restart in progress, for instance).
    func goalongDismissOnOutsideClick(isDirty: @escaping () -> Bool = { false }, isEnabled: @escaping () -> Bool = { true },
                                      onCancel: (() -> Void)? = nil) -> some View {
        modifier(GoalongDismissOnOutsideClick(isDirty: isDirty, isEnabled: isEnabled, onCancel: onCancel))
    }
}
#endif
