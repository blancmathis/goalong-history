#if os(macOS)
import AppKit
import GoalongMenuBarRelay
import os

/// T-048 C4: Control Centre (macOS 26) can block every status item of `ai.goalong.localhistory`,
/// and only the member could lift it. When our own item stays `parkedBySystem`, Goalong opens the
/// helper nested in its bundle (`Contents/Helpers/Goalong Menu Bar.app`, bundle id `<ours>.menubar`).
/// The helper shows the same icon, hands clicks back here, and exits with Goalong.
@MainActor final class MenuBarHelperHost {
    static let shared = MenuBarHelperHost()

    /// What the helper draws; set by the menu bar controller.
    var stateProvider: (() -> MenuBarRelay.State)?
    /// A click on the helper's icon: menu (right click, ⌥) or panel, and the icon's screen frame.
    var onClick: ((_ menu: Bool, _ frame: CGRect) -> Void)?
    /// The helper's icon is visible (or no longer).
    var onHosting: ((Bool) -> Void)?
    var itemName = ""

    private(set) var isHosting = false
    private(set) var launches = 0
    static let maxLaunches = 3
    private let token = UUID().uuidString
    private let hostID: String
    private let appURL: URL
    private var helper: NSRunningApplication?
    private var lastSent: MenuBarRelay.State?
    private var observers: [NSObjectProtocol] = []
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ai.goalong.localhistory",
                                       category: "menubar-visibility")

    init(hostID: String = Bundle.main.bundleIdentifier ?? "", appURL: URL = Bundle.main.bundleURL) {
        self.hostID = hostID
        self.appURL = appURL
    }

    /// The nested helper, only when it carries our helper bundle id.
    static func helperURL(appURL: URL, hostID: String) -> URL? {
        let url = MenuBarRelay.helperURL(inApp: appURL)
        guard MenuBarRelay.knownHosts.contains(hostID),
              Bundle(url: url)?.bundleIdentifier == MenuBarRelay.helperBundleID(host: hostID) else { return nil }
        return url
    }

    /// One `menubar-visibility` line naming the host that shows the icon.
    nonisolated static func hostLogLine(_ host: String, state: MenuBarItemVisibility? = nil, frame: CGRect? = nil,
                                        item: String, bundleID: String, reason: String? = nil) -> String {
        var line = "icon-host=\(host)"
        if let state { line += " state=\(state.rawValue)" }
        if let f = frame { line += " frame=\(Int(f.minX)),\(Int(f.minY)),\(Int(f.width)),\(Int(f.height))" }
        line += " item=\(item.isEmpty ? "?" : item) bid=\(bundleID)"
        if let reason { line += " reason=\(reason)" }
        return line
    }

    private func log(_ line: String) { Self.logger.notice("\(line, privacy: .public)") }

    /// Called with the app item's confirmed state (two readings in a row), nil once it shows again.
    func appItemConfirmed(_ state: MenuBarItemVisibility?) {
        switch state {
        case .parkedBySystem?: startIfNeeded()
        case nil where helper != nil:
            stop()
            log(Self.hostLogLine("app", state: .shown, item: itemName, bundleID: hostID, reason: "app-item-back"))
        default: break
        }
    }

    private func startIfNeeded() {
        guard helper == nil else { return }
        let helperID = MenuBarRelay.helperBundleID(host: hostID)
        guard launches < Self.maxLaunches else { return }
        guard let url = Self.helperURL(appURL: appURL, hostID: hostID) else {
            launches = Self.maxLaunches
            log(Self.hostLogLine("none", item: itemName, bundleID: helperID, reason: "helper-missing"))
            return
        }
        launches += 1
        listen()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.createsNewApplicationInstance = false
        configuration.promptsUserIfNeeded = false
        configuration.addsToRecentItems = false
        configuration.arguments = MenuBarRelay.Launch(hostPID: ProcessInfo.processInfo.processIdentifier, token: token,
                                                      itemName: itemName).arguments
        log(Self.hostLogLine("helper-starting", item: itemName, bundleID: helperID, reason: "app-item-parkedBySystem"))
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, error in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let app { self.helper = app; return }
                    self.log(Self.hostLogLine("none", item: self.itemName, bundleID: helperID,
                                              reason: "launch-failed:\((error as NSError?)?.code ?? 0)"))
                }
            }
        }
    }

    private func listen() {
        guard observers.isEmpty else { return }
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: MenuBarRelay.toApp(host: hostID), object: token, queue: .main
        ) { [weak self] notification in
            let message = MenuBarRelay.Message(userInfo: notification.userInfo)
            MainActor.assumeIsolated { if let message { self?.received(message) } }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let pid = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated {
                guard let self, let pid, pid == self.helper?.processIdentifier else { return }
                self.helper = nil
                self.setHosting(false)
                self.log(Self.hostLogLine("none", item: self.itemName, bundleID: MenuBarRelay.helperBundleID(host: self.hostID),
                                          reason: "helper-exited"))
            }
        })
    }

    func received(_ message: MenuBarRelay.Message) {
        switch message {
        case .ready: lastSent = nil; pushState()
        case let .click(menu, frame): onClick?(menu, frame)
        case let .placed(frame):
            let state = MenuBarItemVisibility.state(itemFrame: frame, screens: NSScreen.screens.map(MenuBarItemVisibility.Screen.init))
            log(Self.hostLogLine("helper", state: state, frame: frame, item: itemName,
                                 bundleID: MenuBarRelay.helperBundleID(host: hostID)))
            setHosting(state == .shown)
        case .state, .quit: break
        }
    }

    private func setHosting(_ hosting: Bool) {
        guard hosting != isHosting else { return }
        isHosting = hosting
        onHosting?(hosting)
    }

    /// Sends the icon's current look when it changed; nothing while no helper listens.
    func pushState() {
        guard !observers.isEmpty, helper != nil || lastSent == nil, let state = stateProvider?(), state != lastSent else { return }
        lastSent = state
        post(.state(state))
    }

    private func post(_ message: MenuBarRelay.Message) {
        DistributedNotificationCenter.default().postNotificationName(
            MenuBarRelay.toHelper(host: hostID), object: token, userInfo: message.userInfo, deliverImmediately: true)
    }

    /// Asks the helper to leave (Goalong quits, or its own item is back).
    func stop() {
        guard helper != nil || !observers.isEmpty else { return }
        post(.quit)
        helper = nil
        lastSent = nil
        setHosting(false)
    }
}
#endif
