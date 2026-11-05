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

    /// A running helper, as the host needs it: its pid and a one-shot exit signal.
    struct HelperProcess {
        var pid: pid_t
        /// Calls back on the main queue once the process is gone; the returned closure cancels the watch.
        var watchExit: (@escaping @MainActor () -> Void) -> (() -> Void)
    }
    typealias Launcher = (_ url: URL, _ configuration: NSWorkspace.OpenConfiguration,
                          _ completion: @escaping @MainActor (HelperProcess?, Error?) -> Void) -> Void

    /// Opens the helper through NSWorkspace and watches its pid with a process source.
    /// `didTerminateApplicationNotification` is not sent for LSUIElement apps, and the helper is one.
    static let workspaceLauncher: Launcher = { url, configuration, completion in
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, error in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let app else { completion(nil, error); return }
                    completion(HelperProcess(pid: app.processIdentifier) { onExit in
                        let source = DispatchSource.makeProcessSource(identifier: app.processIdentifier, eventMask: .exit, queue: .main)
                        source.setEventHandler { MainActor.assumeIsolated { onExit() } }
                        source.activate()
                        // The process may have left before the source existed.
                        if app.isTerminated { DispatchQueue.main.async { MainActor.assumeIsolated { onExit() } } }
                        return { source.cancel() }
                    }, nil)
                }
            }
        }
    }

    private(set) var isHosting = false
    /// Launches that failed or ended without the icon ever showing; a helper seen `shown` resets it.
    private(set) var failures = 0
    static let maxFailures = 3
    private let launcher: Launcher
    private let token = UUID().uuidString
    private let hostID: String
    private let appURL: URL
    private var helper: HelperProcess?
    private var cancelExitWatch: (() -> Void)?
    private var starting = false
    /// Bumped on each start and stop, so a late launch answer knows whether it is still wanted.
    private var generation = 0
    private var seenShown = false
    private var lastSent: MenuBarRelay.State?
    private var observers: [NSObjectProtocol] = []
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ai.goalong.localhistory",
                                       category: "menubar-visibility")

    init(hostID: String = Bundle.main.bundleIdentifier ?? "", appURL: URL = Bundle.main.bundleURL,
         launcher: Launcher? = nil) {
        self.hostID = hostID
        self.appURL = appURL
        self.launcher = launcher ?? Self.workspaceLauncher
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
        case nil where helper != nil || starting:
            stop()
            log(Self.hostLogLine("app", state: .shown, item: itemName, bundleID: hostID, reason: "app-item-back"))
        default: break
        }
    }

    private func startIfNeeded() {
        guard helper == nil, !starting else { return }
        let helperID = MenuBarRelay.helperBundleID(host: hostID)
        guard failures < Self.maxFailures else { return }
        guard let url = Self.helperURL(appURL: appURL, hostID: hostID) else {
            failures = Self.maxFailures
            log(Self.hostLogLine("none", item: itemName, bundleID: helperID, reason: "helper-missing"))
            return
        }
        starting = true
        seenShown = false
        generation += 1
        let mine = generation
        listen()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.createsNewApplicationInstance = false
        configuration.promptsUserIfNeeded = false
        configuration.addsToRecentItems = false
        configuration.arguments = MenuBarRelay.Launch(hostPID: ProcessInfo.processInfo.processIdentifier, token: token,
                                                      itemName: itemName).arguments
        log(Self.hostLogLine("helper-starting", item: itemName, bundleID: helperID, reason: "app-item-parkedBySystem"))
        launcher(url, configuration) { [self] process, error in
            guard mine == generation else {
                // Our own item came back while the helper was starting: send it away again.
                if process != nil { post(.quit) }
                return
            }
            starting = false
            guard let process else {
                failures += 1
                log(Self.hostLogLine("none", item: itemName, bundleID: helperID,
                                     reason: "launch-failed:\((error as NSError?)?.code ?? 0)"))
                return
            }
            helper = process
            cancelExitWatch = process.watchExit { [weak self] in self?.helperExited(generation: mine) }
        }
    }

    /// The helper's process is gone (crash, its own 15 s exit, a kill). Forget it, show the banner again
    /// through `onHosting(false)`, and let the next confirmed reading start a new one.
    private func helperExited(generation exited: Int) {
        guard exited == generation, helper != nil else { return }
        cancelExitWatch = nil
        helper = nil
        lastSent = nil
        if !seenShown { failures += 1 }
        setHosting(false)
        log(Self.hostLogLine("none", item: itemName, bundleID: MenuBarRelay.helperBundleID(host: hostID), reason: "helper-exited"))
    }

    private func listen() {
        guard observers.isEmpty else { return }
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: MenuBarRelay.toApp(host: hostID), object: token, queue: .main
        ) { [weak self] notification in
            let message = MenuBarRelay.Message(userInfo: notification.userInfo)
            MainActor.assumeIsolated { if let message { self?.received(message) } }
        })
    }

    func received(_ message: MenuBarRelay.Message) {
        switch message {
        case .ready: lastSent = nil; pushState()
        case let .click(menu, frame): onClick?(menu, frame)
        case let .placed(frame):
            helperPlaced(MenuBarItemVisibility.state(itemFrame: frame, screens: NSScreen.screens.map(MenuBarItemVisibility.Screen.init)),
                         frame: frame)
        case .state, .quit: break
        }
    }

    /// The helper reported where its icon sits: `.shown` means the member sees it.
    func helperPlaced(_ state: MenuBarItemVisibility, frame: CGRect) {
        log(Self.hostLogLine("helper", state: state, frame: frame, item: itemName,
                             bundleID: MenuBarRelay.helperBundleID(host: hostID)))
        if state == .shown { seenShown = true; failures = 0 }
        setHosting(state == .shown)
    }

    private func setHosting(_ hosting: Bool) {
        guard hosting != isHosting else { return }
        isHosting = hosting
        onHosting?(hosting)
    }

    /// Sends the icon's current look when it changed; nothing while no helper listens.
    func pushState() {
        guard !observers.isEmpty, helper != nil || starting, let state = stateProvider?(), state != lastSent else { return }
        lastSent = state
        post(.state(state))
    }

    private func post(_ message: MenuBarRelay.Message) {
        DistributedNotificationCenter.default().postNotificationName(
            MenuBarRelay.toHelper(host: hostID), object: token, userInfo: message.userInfo, deliverImmediately: true)
    }

    /// Asks the helper to leave (Goalong quits, or its own item is back).
    func stop() {
        guard helper != nil || starting || !observers.isEmpty else { return }
        post(.quit)
        generation += 1
        starting = false
        cancelExitWatch?(); cancelExitWatch = nil
        helper = nil
        lastSent = nil
        setHosting(false)
    }
}
#endif
