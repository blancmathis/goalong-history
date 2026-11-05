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
    /// A protected range runs: commands that take red away ask for the page.
    var isProtected = false
    /// A protected range stopped the slider at its intensity: the short text shown next to it.
    var notice: String?
}

/// The « Écran rouge » line of Goalong's menu (left-click panel and right-click menu).
@MainActor protocol RedScreenControlling: AnyObject {
    var redScreen: RedScreenState { get }
    var redScreenChanges: AnyPublisher<RedScreenState, Never> { get }
    func setRedScreen(_ on: Bool)
    func setRedScreenIntensity(_ value: Double)
    func setRedScreenFollowsSchedule(_ on: Bool)
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
    /// Receives `BraiseController.guardUntil` once at start, then on every change (the app wires it to
    /// `BlockingRuntime.setRedScreenGuard`). nil in tests: no marker, no guard.
    var guardSink: (@MainActor (Date?) -> Void)?
    private var reportedGuard: Date?? = .none
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
        // Always once: until this report the blocking side keeps a marker a protected range left (relaunch).
        reportGuard()
    }
    private func reportGuard() {
        let until = controller?.guardUntil
        guard reportedGuard != .some(until) else { return }
        reportedGuard = .some(until); guardSink?(until)
    }
    /// The first explicit use builds the controller; later calls return it.
    @discardableResult func ensureController() -> BraiseController? {
        if let controller { return controller }
        factoryCalls += 1
        do {
            let value = try factory(); controller = value; error = nil
            value.stateChanged = { [weak self] in self?.sync() }
            value.onStopRequired = { [weak self] in self?.onOpen?() }
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
        if !keepsSetting { defaults.set(false, forKey: Self.armedKey); reportGuard() }
        redScreen.on = false
    }
    private func sync() {
        guard let controller else { return }
        let p = controller.preferences
        let next = RedScreenState(on: controller.active, intensity: controller.active ? controller.appliedIntensity : p.intensity,
                                  followsSchedule: controller.ranges.follows, isProtected: controller.protectedWindow != nil,
                                  notice: controller.sliderNotice)
        if redScreen != next { redScreen = next }
        // Ranges followed or held keep the controller across launches, like a manual red.
        let armed = p.mode == .on || controller.ranges.follows || !controller.ranges.holds.isEmpty
        if defaults.object(forKey: Self.armedKey) as? Bool != armed { defaults.set(armed, forKey: Self.armedKey) }
        if defaults.object(forKey: Self.intensityKey) as? Double != p.intensity { defaults.set(p.intensity, forKey: Self.intensityKey) }
        reportGuard()
    }

    // MARK: RedScreenControlling
    /// Off is the manual switch going off: during a range it follows the weakening rule (T-048 B2).
    func setRedScreen(_ on: Bool) {
        if on { ensureController()?.setManual(true) }
        else { controller?.setManual(false) }
    }
    func setRedScreenIntensity(_ value: Double) {
        guard value.isFinite, let controller = ensureController() else { return }
        controller.slideIntensity(value)
    }
    func setRedScreenFollowsSchedule(_ on: Bool) {
        if on { ensureController()?.setFollows(true) } else { controller?.setFollows(false) }
    }
    /// Same as ⌃⌥⌘R. Without a controller nothing was ever changed: no call at all.
    func restoreColors() { controller?.emergencyOff() }

    func handle(_ input: GoalongFocusRequest) throws -> Data {
        let request = try GoalongBraiseCLI.validated(input)
        let off = Data("{\"schema\":1,\"module\":\"braise\",\"enabled\":false}".utf8)
        switch request.command {
        case "braise disable", "braise quit":
            if let controller {
                try Self.require(controller.emergencyOff())
                if controller.ranges.follows { try Self.require(controller.setFollows(false)) }
            }
            stop(keepsSetting: false); return off
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
        case "braise on": controller.setManual(true)
        case "braise off": try Self.require(controller.emergencyOff())
        case "braise auto": controller.setFollows(true)
        case "braise pause": try Self.require(controller.pause())
        case "braise resume": controller.resume()
        case "braise intensity": try Self.require(controller.setIntensity(Double(o["value"]!)! / 100))
        case "braise brightness": controller.update { $0.brightness = Double(o["value"]!)! / 100 }
        case "braise schedule": return try Self.schedule(controller.ranges)
        case "braise rule-add":
            // CLI days stay Braise's (Sunday = 1); the ranges count from Monday = 1.
            let days = Set(o["days"]!.split(separator: ",").compactMap { Int($0) }.compactMap(RedScreenProgram.isoWeekday(fromFoundation:)))
            let end = GoalongBraiseCLI.minute(o["end"]!)!
            let range = BlockProgramRange(weekdays: days, startMinute: GoalongBraiseCLI.minute(o["start"]!)!, endMinute: end == 0 ? 1_440 : end)
            try Self.mapRefusal { try controller.saveRange(range, intensity: controller.preferences.intensity) }
        case "braise rule-remove", "braise rule-enable", "braise rule-disable":
            let id = UUID(uuidString: o["id"]!)!
            guard controller.ranges.program.ranges.contains(where: { $0.id == id }) else { throw GoalongFocusError.notFound }
            try Self.mapRefusal {
                if request.command == "braise rule-remove" { try controller.deleteRange(id) }
                else { try controller.setRangeEnabled(id, request.command == "braise rule-enable") }
            }
        case "braise login": try controller.setLogin(o["value"] == "on")
        default: throw GoalongFocusError.invalidArgument
        }
        try controller.persistCommand()
        return try JSONSerialization.data(withJSONObject: controller.status, options: [.sortedKeys])
    }
    /// A command a protected range refused: the CLI says « locked », the page shows why.
    private static func require(_ result: RedScreenGuardResult) throws {
        if result != .applied { throw GoalongFocusError.locked }
    }
    private static func mapRefusal(_ body: () throws -> Void) throws {
        do { try body() } catch let refusal as RedScreenRefusal { throw refusal.isLock ? GoalongFocusError.locked : GoalongFocusError.invalidArgument }
    }
    /// `braise schedule`: ranges with ISO weekdays (Monday = 1), minutes, intensity 0…1, lock.
    static func schedule(_ ranges: RedScreenProgram) throws -> Data {
        let rows: [[String: Any]] = ranges.program.ranges.map { range in
            ["id": range.id.uuidString, "weekdays": range.weekdays.sorted(), "startMinute": range.startMinute,
             "endMinute": range.endMinute, "intensity": ranges.intensity(of: range.id),
             "enabled": !ranges.disabled.contains(range.id), "lock": range.effectiveLock.rawValue]
        }
        return try JSONSerialization.data(withJSONObject: ["follows": ranges.follows, "ranges": rows], options: [.sortedKeys])
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
