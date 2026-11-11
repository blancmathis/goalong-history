#if os(macOS)
import Carbon
import Combine
import Foundation

/// The global shortcut of « Relancer la dernière séance » (T-050 B2). Registered by the app only, never in tests:
/// it follows the choice kept in `PreparedSessionStore`.
@MainActor final class RelaunchHotKey {
    static let shared = RelaunchHotKey()
    /// « GLRS »: Goalong, Relancer la séance.
    nonisolated static let id = EventHotKeyID(signature: OSType(0x474C_5253), id: 1)
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var watch: AnyCancellable?
    var action: () -> Void = {}

    /// Handles only its own shortcut: any other one (Braise's ⌃⌥⌘R red-screen escape) goes on to its owner.
    nonisolated static let handle: EventHandlerUPP = { _, event, _ -> OSStatus in
        guard let event else { return OSStatus(eventNotHandledErr) }
        var pressed = EventHotKeyID()
        guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                MemoryLayout<EventHotKeyID>.size, nil, &pressed) == noErr,
              pressed.signature == RelaunchHotKey.id.signature, pressed.id == RelaunchHotKey.id.id
        else { return OSStatus(eventNotHandledErr) }
        Task { @MainActor in RelaunchHotKey.shared.action() }
        return noErr
    }

    func install(store: PreparedSessionStore = .shared, action: @escaping () -> Void) {
        self.action = action
        if handler == nil {
            var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), Self.handle, 1, &type, nil, &handler)
        }
        watch = store.$document.map(\.shortcut).removeDuplicates().sink { [weak self] in self?.register($0) }
    }

    private func register(_ shortcut: RelaunchShortcut) {
        if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil }
        guard let key = shortcut.key else { return }
        RegisterEventHotKey(key.code, key.modifiers, Self.id, GetApplicationEventTarget(), 0, &hotKey)
    }
}
#endif
