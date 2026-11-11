#if os(macOS)
import Carbon
import Combine
import Foundation

/// The global shortcut of « Relancer la dernière séance » (T-050 B2). Registered by the app only, never in tests:
/// it follows the choice kept in `PreparedSessionStore`.
@MainActor final class RelaunchHotKey {
    static let shared = RelaunchHotKey()
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var watch: AnyCancellable?
    private var action: () -> Void = {}

    func install(store: PreparedSessionStore = .shared, action: @escaping () -> Void) {
        self.action = action
        if handler == nil {
            var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                Task { @MainActor in RelaunchHotKey.shared.action() }
                return noErr
            }, 1, &type, nil, &handler)
        }
        watch = store.$document.map(\.shortcut).removeDuplicates().sink { [weak self] in self?.register($0) }
    }

    private func register(_ shortcut: RelaunchShortcut) {
        if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil }
        guard let key = shortcut.key else { return }
        // « GLRS »: Goalong, Relancer la séance.
        let id = EventHotKeyID(signature: OSType(0x474C_5253), id: 1)
        RegisterEventHotKey(key.code, key.modifiers, id, GetApplicationEventTarget(), 0, &hotKey)
    }
}
#endif
