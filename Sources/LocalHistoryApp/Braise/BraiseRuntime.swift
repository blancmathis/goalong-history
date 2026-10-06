#if os(macOS)
import AppKit
import BraiseCore
import Carbon
import Combine
import Foundation
import LocalHistoryQueryCLI
import SwiftUI

/// The gate is cheap; the directory, controller, shortcut and menu item exist only while enabled.
@MainActor final class BraiseRuntime: ObservableObject {
    static let shared = BraiseRuntime()
    @Published private(set) var controller: BraiseController?
    @Published private(set) var error: String?
    var onOpen: (() -> Void)?
    private var modules: GoalongModuleStore?
    private let factory: @MainActor () throws -> BraiseController
    private let presentsMenu: Bool
    private var menuBar: BraiseMenuBar?
    init(presentsMenu: Bool = true, factory: @escaping @MainActor () throws -> BraiseController = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let store = BraiseStore(directory: AppPaths.applicationSupportDirectory.appendingPathComponent("Braise", isDirectory: true),
                               legacySettings: support.appendingPathComponent("Braise/settings.json"))
        return try BraiseController(store: store, gamma: GammaController(directory: store.directory))
    }) { self.factory = factory; self.presentsMenu = presentsMenu }
    func start(modules: GoalongModuleStore = .shared) {
        self.modules = modules
        modules.onBraiseEnabledChange = { [weak self] in self?.apply(enabled: $0) }
        apply(enabled: modules.isEnabled(.braise))
    }
    func apply(enabled: Bool) {
        if enabled, controller == nil {
            do {
                let value = try factory(); controller = value; error = nil
                if presentsMenu {
                    let menu = BraiseMenuBar(controller: value, onOpen: { [weak self] in self?.onOpen?() },
                                            onDisable: { [weak self] in self?.modules?.setEnabled(.braise, false) })
                    menuBar = menu; value.stateChanged = { [weak menu] in menu?.refresh() }
                }
            } catch { self.error = "Braise n’a pas pu démarrer. Vérifiez ses réglages locaux ; aucun filtre n’a été appliqué." }
        } else if !enabled {
            menuBar?.shutdown(); menuBar = nil
            controller?.shutdown(); controller = nil; error = nil
        }
    }
    func shutdown() { apply(enabled: false) }
    func handle(_ input: GoalongFocusRequest) throws -> Data {
        let request = try GoalongBraiseCLI.validated(input)
        if request.command == "braise enable" {
            let wasEnabled = modules?.isEnabled(.braise) == true
            modules?.setEnabled(.braise, true)
            if wasEnabled, controller == nil { apply(enabled: true) }
        }
        if ["braise disable", "braise quit"].contains(request.command) {
            modules?.setEnabled(.braise, false); apply(enabled: false)
            return Data("{\"schema\":1,\"module\":\"braise\",\"enabled\":false}".utf8)
        }
        if request.command == "braise status", modules?.isEnabled(.braise) != true {
            return Data("{\"schema\":1,\"module\":\"braise\",\"enabled\":false}".utf8)
        }
        guard modules?.isEnabled(.braise) == true else { throw GoalongFocusError.moduleDisabled }
        guard let controller else { throw GoalongFocusError.storageFailed }
        let o = request.options
        switch request.command {
        case "braise status", "braise enable": break
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
        case "braise show":
            if let menuBar { menuBar.showPanel() } else { onOpen?() }
        case "braise probe":
            let records: [[String: Any]] = GammaController.displays().map { id in
                guard let table = try? GammaTable.read(id) else { return ["display": id, "error": "gamma table unavailable"] }
                return ["display": id, "samples": table.red.count, "redMax": table.red.max() ?? 0,
                        "greenMax": table.green.max() ?? 0, "blueMax": table.blue.max() ?? 0]
            }
            return try JSONSerialization.data(withJSONObject: records, options: [.sortedKeys])
        default: throw GoalongFocusError.invalidArgument
        }
        if !["braise status", "braise show"].contains(request.command) { try controller.persistCommand() }
        return try JSONSerialization.data(withJSONObject: controller.status, options: [.sortedKeys])
    }
}

@MainActor private final class BraiseMenuBar: NSObject {
    private let controller: BraiseController
    private let onOpen: () -> Void
    private let onDisable: () -> Void
    private let item: NSStatusItem
    private let panel = NSPopover()
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var resignObserver: NSObjectProtocol?
    private nonisolated static let signature = OSType(0x42525332)
    init(controller: BraiseController, onOpen: @escaping () -> Void, onDisable: @escaping () -> Void) {
        self.controller = controller; self.onOpen = onOpen; self.onDisable = onDisable
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        item.button?.target = self; item.button?.action = #selector(clicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        item.button?.setAccessibilityLabel("Braise, filtre rouge de Goalong")
        panel.behavior = .transient
        panel.contentSize = NSSize(width: 480, height: 680)
        panel.contentViewController = NSHostingController(rootView: BraisePageContent(controller: controller, compact: true).goalongControls())
        resignObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.panel.performClose(nil) } }
        registerShortcut(); refresh()
    }
    func refresh() {
        let image = NSImage(systemSymbolName: controller.active ? "sun.horizon.fill" : "sun.horizon", accessibilityDescription: controller.stateLabel)
        image?.isTemplate = true; item.button?.image = image
        item.button?.toolTip = "Braise · \(controller.stateLabel)\n\(controller.nextEvent)"
    }
    func showPanel() {
        guard !panel.isShown, let button = item.button, button.window != nil else { return }
        NSApp.activate(ignoringOtherApps: true)
        panel.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        panel.contentViewController?.view.window?.makeKey()
    }
    @objc private func clicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            panel.performClose(nil)
            let menu = NSMenu()
            for (title, action) in [("Ouvrir Braise", #selector(show)), ("Ouvrir dans Goalong", #selector(openDashboard)),
                                    ("Suivre les horaires", #selector(autoMode)), ("Activer le rouge", #selector(onMode)),
                                    ("Rétablir les couleurs", #selector(offMode)), ("Désactiver Braise", #selector(disableModule))] {
                let entry = NSMenuItem(title: title, action: action, keyEquivalent: ""); entry.target = self; menu.addItem(entry)
            }
            item.menu = menu; item.button?.performClick(nil); item.menu = nil
        } else if panel.isShown { panel.performClose(nil) } else { showPanel() }
    }
    @objc private func show() { showPanel() }
    @objc private func openDashboard() { onOpen() }
    @objc private func autoMode() { controller.setMode(.auto) }
    @objc private func onMode() { controller.setMode(.on) }
    @objc private func offMode() { controller.emergencyOff() }
    @objc private func disableModule() { onDisable() }
    private func registerShortcut() {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, data -> OSStatus in
            guard let event, let data else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                    MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
                  id.signature == BraiseMenuBar.signature, id.id == 1 else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<BraiseMenuBar>.fromOpaque(data).takeUnretainedValue()
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
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }; resignObserver = nil
        panel.performClose(nil); panel.contentViewController = nil; NSStatusBar.system.removeStatusItem(item)
    }
}
#endif
