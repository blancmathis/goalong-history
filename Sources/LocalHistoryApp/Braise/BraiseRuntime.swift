#if os(macOS)
import AppKit
import AppleScreenTime
import BraiseCore
import Carbon
import Combine
import Foundation
import LocalHistoryQueryCLI
import SwiftUI

/// What the menu-bar panel and the right-click menu show on their « Écran rouge » line.
struct RedScreenState: Equatable {
    /// Red is on the screens now.
    var on = false
    var intensity = 1.0
    var followsSchedule = false
}

/// The « Écran rouge » line of Goalong's menu (left-click panel and right-click menu).
@MainActor protocol RedScreenControlling: AnyObject {
    var redScreen: RedScreenState { get }
    var redScreenChanges: AnyPublisher<RedScreenState, Never> { get }
    func setRedScreen(_ on: Bool)
    func setRedScreenIntensity(_ value: Double)
    func followRedScreenSchedule()
    func restoreColors()
}

/// No module to enable. Unused costs nothing: no directory, controller, timer, shortcut or gamma call
/// until red is turned on (or scheduled) once. The setting then survives a restart.
@MainActor final class BraiseRuntime: ObservableObject, RedScreenControlling {
    static let shared = BraiseRuntime()
    /// mode ≠ off on the last run: the controller starts with the app (red back on, or the schedule followed).
    nonisolated static let armedKey = "goalong.redScreen.armed"
    nonisolated static let intensityKey = "goalong.redScreen.intensity"
    /// The old Réglages › Modules switch. An enabled Braise is migrated once, then the key is removed.
    nonisolated static let legacyModuleKey = GoalongModule.braise.defaultsKey
    @Published private(set) var controller: BraiseController?
    @Published private(set) var error: String?
    @Published private(set) var redScreen: RedScreenState
    var redScreenChanges: AnyPublisher<RedScreenState, Never> { $redScreen.removeDuplicates().eraseToAnyPublisher() }
    var onOpen: (() -> Void)?
    private let factory: @MainActor () throws -> BraiseController
    private let registersShortcut: Bool
    private let diagnostics: SupportDiagnostics
    private let defaults: UserDefaults
    private var shortcut: BraiseShortcut?
    private(set) var factoryCalls = 0

    init(registersShortcut: Bool = true, diagnostics: SupportDiagnostics = .shared, defaults: UserDefaults = GoalongDefaults.standard,
         factory: @escaping @MainActor () throws -> BraiseController = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let store = BraiseStore(directory: AppPaths.applicationSupportDirectory.appendingPathComponent("Braise", isDirectory: true),
                               legacySettings: support.appendingPathComponent("Braise/settings.json"))
        return try BraiseController(store: store, gamma: GammaController(directory: store.directory))
    }) {
        self.factory = factory; self.registersShortcut = registersShortcut; self.diagnostics = diagnostics; self.defaults = defaults
        let stored = defaults.object(forKey: Self.intensityKey) as? Double
        redScreen = RedScreenState(on: false, intensity: stored.map { min(1, max(0, $0)) } ?? 1)
    }
    /// At launch: only a red screen that was in use comes back.
    func start() {
        let legacy = defaults.bool(forKey: Self.legacyModuleKey)
        if defaults.bool(forKey: Self.armedKey) || legacy { ensureController() }
        if legacy, controller != nil { defaults.removeObject(forKey: Self.legacyModuleKey) }
    }
    /// The first explicit use builds the controller; later calls return it.
    @discardableResult func ensureController() -> BraiseController? {
        if let controller { return controller }
        factoryCalls += 1
        do {
            let value = try factory(); controller = value; error = nil
            value.stateChanged = { [weak self] in self?.sync() }
            if registersShortcut { shortcut = BraiseShortcut(controller: value) }
            sync(); return value
        } catch {
            diagnostics.failure(error, component: .storage)
            self.error = "L’écran rouge n’a pas pu démarrer. Aucun filtre n’a été appliqué."
            return nil
        }
    }
    /// The failure page's « Réessayer ».
    func retry() { ensureController() }
    /// App quit: colors back to normal now; the setting stays for the next launch.
    func shutdown() { stop(keepsSetting: true) }
    private func stop(keepsSetting: Bool) {
        shortcut?.shutdown(); shortcut = nil
        controller?.shutdown(); controller = nil; error = nil
        if !keepsSetting { defaults.set(false, forKey: Self.armedKey) }
        redScreen.on = false
    }
    private func sync() {
        guard let controller else { return }
        let p = controller.preferences
        let next = RedScreenState(on: controller.active, intensity: p.intensity, followsSchedule: p.mode == .auto)
        if redScreen != next { redScreen = next }
        let armed = p.mode != .off
        if defaults.object(forKey: Self.armedKey) as? Bool != armed { defaults.set(armed, forKey: Self.armedKey) }
        if defaults.object(forKey: Self.intensityKey) as? Double != p.intensity { defaults.set(p.intensity, forKey: Self.intensityKey) }
    }

    // MARK: RedScreenControlling
    func setRedScreen(_ on: Bool) {
        if on { ensureController()?.setMode(.on) }
        else { controller?.emergencyOff() }
    }
    func setRedScreenIntensity(_ value: Double) {
        let clamped = min(1, max(0, value))
        guard let controller = ensureController() else { return }
        controller.update { $0.intensity = clamped }
    }
    func followRedScreenSchedule() { ensureController()?.setMode(.auto) }
    /// Same as ⌃⌥⌘R. Without a controller nothing was ever changed: no call at all.
    func restoreColors() { controller?.emergencyOff() }

    func handle(_ input: GoalongFocusRequest) throws -> Data {
        let request = try GoalongBraiseCLI.validated(input)
        let off = Data("{\"schema\":1,\"module\":\"braise\",\"enabled\":false}".utf8)
        switch request.command {
        case "braise disable", "braise quit":
            controller?.emergencyOff(); stop(keepsSetting: false); return off
        case "braise status":
            guard let controller else { return off }
            return try JSONSerialization.data(withJSONObject: controller.status, options: [.sortedKeys])
        case "braise show":
            onOpen?(); return controller.map { (try? JSONSerialization.data(withJSONObject: $0.status, options: [.sortedKeys])) ?? off } ?? off
        case "braise probe":
            // Reads go through the driver of a running controller only; never a table read for nothing.
            guard let controller else { return try JSONSerialization.data(withJSONObject: [[String: Any]](), options: []) }
            return try JSONSerialization.data(withJSONObject: controller.probe(), options: [.sortedKeys])
        default: break
        }
        guard let controller = ensureController() else { throw GoalongFocusError.storageFailed }
        let o = request.options
        switch request.command {
        case "braise enable": break
        case "braise on": controller.setMode(.on)
        case "braise off": controller.emergencyOff()
        case "braise auto": controller.setMode(.auto)
        case "braise pause": controller.pause()
        case "braise resume": controller.resume()
        case "braise intensity": controller.update { $0.intensity = Double(o["value"]!)! / 100 }
        case "braise brightness": controller.update { $0.brightness = Double(o["value"]!)! / 100 }
        case "braise schedule": return try JSONEncoder().encode(controller.preferences.rules)
        case "braise rule-add":
            try controller.saveRule(ScheduleRule(weekdays: Set(o["days"]!.split(separator: ",").compactMap { Int($0) }),
                                                startMinute: GoalongBraiseCLI.minute(o["start"]!)!, endMinute: GoalongBraiseCLI.minute(o["end"]!)!))
        case "braise rule-remove", "braise rule-enable", "braise rule-disable":
            let id = UUID(uuidString: o["id"]!)!
            guard controller.preferences.rules.contains(where: { $0.id == id }) else { throw GoalongFocusError.notFound }
            if request.command == "braise rule-remove" { controller.deleteRule(id) }
            else { controller.update { p in if let i = p.rules.firstIndex(where: { $0.id == id }) { p.rules[i].enabled = request.command == "braise rule-enable" } } }
        case "braise login": try controller.setLogin(o["value"] == "on")
        default: throw GoalongFocusError.invalidArgument
        }
        try controller.persistCommand()
        return try JSONSerialization.data(withJSONObject: controller.status, options: [.sortedKeys])
    }
}

/// ⌃⌥⌘R restores the colors from anywhere while the red screen is in use.
@MainActor private final class BraiseShortcut {
    private let controller: BraiseController
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private nonisolated static let signature = OSType(0x42525332)
    init(controller: BraiseController) {
        self.controller = controller
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, data -> OSStatus in
            guard let event, let data else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                    MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
                  id.signature == BraiseShortcut.signature, id.id == 1 else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<BraiseShortcut>.fromOpaque(data).takeUnretainedValue()
            DispatchQueue.main.async { [weak owner] in owner?.controller.emergencyOff() }; return noErr
        }, 1, &type, context, &handler)
        guard installed == noErr else { return }
        let id = EventHotKeyID(signature: Self.signature, id: 1)
        controller.shortcutAvailable = RegisterEventHotKey(UInt32(kVK_ANSI_R), UInt32(controlKey | optionKey | cmdKey), id,
                                                          GetApplicationEventTarget(), 0, &hotKey) == noErr
    }
    func shutdown() {
        if let hotKey { UnregisterEventHotKey(hotKey) }; hotKey = nil
        if let handler { RemoveEventHandler(handler) }; handler = nil
        controller.shortcutAvailable = false
    }
}
#endif
