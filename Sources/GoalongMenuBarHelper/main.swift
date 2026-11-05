#if os(macOS)
import AppKit
import GoalongMenuBarRelay

// T-048 C4: Goalong's menu bar icon under a second bundle id, for when Control Centre blocks the
// app's own item. It shows only what Goalong sends, hands clicks back, and leaves with Goalong.
// No history, no permission API, no network, no command, no other app opened.
guard let launch = MenuBarRelay.Launch(arguments: Array(CommandLine.arguments.dropFirst())) else { exit(64) }
let helperURL = Bundle.main.bundleURL.resolvingSymlinksInPath()
guard let hostURL = MenuBarRelay.hostAppURL(ofHelper: helperURL),
      let hostID = Bundle(url: hostURL)?.bundleIdentifier, MenuBarRelay.knownHosts.contains(hostID),
      Bundle.main.bundleIdentifier == MenuBarRelay.helperBundleID(host: hostID),
      let host = NSRunningApplication(processIdentifier: launch.hostPID), !host.isTerminated,
      host.bundleURL?.resolvingSymlinksInPath() == hostURL else { exit(66) }

final class MenuBarHelper: NSObject {
    private let center = DistributedNotificationCenter.default()
    private var item: NSStatusItem?
    private var timers: [Timer] = []
    private let launch: MenuBarRelay.Launch
    private let hostID: String

    init(launch: MenuBarRelay.Launch, hostID: String) {
        self.launch = launch
        self.hostID = hostID
    }

    func start() {
        center.addObserver(self, selector: #selector(received(_:)), name: MenuBarRelay.toHelper(host: hostID), object: launch.token)
        NotificationCenter.default.addObserver(self, selector: #selector(report), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        send(.ready)
        // Goalong answers at once; without an answer there is nothing to show.
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in if self?.item == nil { exit(0) } }
    }

    private func send(_ message: MenuBarRelay.Message) {
        center.postNotificationName(MenuBarRelay.toApp(host: hostID), object: launch.token, userInfo: message.userInfo,
                                    deliverImmediately: true)
    }

    @objc private func received(_ notification: Notification) {
        switch MenuBarRelay.Message(userInfo: notification.userInfo) {
        case let .state(state)?: apply(state)
        case .quit?: exit(0)
        default: break
        }
    }

    private func apply(_ state: MenuBarRelay.State) {
        let item = self.item ?? makeItem()
        guard let button = item.button else { return }
        if let image = NSImage(data: state.image) {
            image.size = NSSize(width: 18, height: 18)
            image.isTemplate = true
            button.image = image
        }
        if state.title.isEmpty {
            item.length = NSStatusItem.squareLength
            button.imagePosition = .imageOnly
            button.title = ""
            button.setAccessibilityValue(nil)
        } else {
            item.length = NSStatusItem.variableLength
            button.imagePosition = .imageLeading
            button.attributedTitle = NSAttributedString(string: " " + state.title, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)])
            button.setAccessibilityValue("Concentration : \(state.title)")
        }
        button.toolTip = state.toolTip
        button.setAccessibilityHelp(state.help)
        if state.development { badge(button) }
    }

    private func makeItem() -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.autosaveName = launch.itemName
        if let button = item.button {
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
            button.setAccessibilityLabel("Goalong History")
            button.target = self
            button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        self.item = item
        for delay in [1.0, 3.0, 10.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.report() }
        }
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in self?.report() }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        timers.append(timer)
        return item
    }

    @objc private func report() {
        send(.placed(frame: item?.button?.window?.frame ?? .zero))
    }

    @objc private func clicked() {
        let event = NSApplication.shared.currentEvent
        let menu = event?.type == .rightMouseUp || event?.modifierFlags.contains(.option) == true
        send(.click(menu: menu, frame: item?.button?.window?.frame ?? .zero))
    }

    /// The orange dot of Goalong Dev, as on the app's own item.
    private func badge(_ button: NSStatusBarButton) {
        let id = NSUserInterfaceItemIdentifier("goalong-dev-dot")
        guard !button.subviews.contains(where: { $0.identifier == id }) else { return }
        let dot = NSView()
        dot.identifier = id
        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemOrange.cgColor
        dot.layer?.cornerRadius = 3.5
        dot.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(dot)
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 7), dot.heightAnchor.constraint(equalToConstant: 7),
            dot.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -1),
            dot.topAnchor.constraint(equalTo: button.topAnchor, constant: 2),
        ])
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
// Leave with Goalong, whatever way it ends.
let hostExit = DispatchSource.makeProcessSource(identifier: launch.hostPID, eventMask: .exit, queue: .main)
hostExit.setEventHandler { exit(0) }
hostExit.activate()
if host.isTerminated { exit(0) }
let helper = MenuBarHelper(launch: launch, hostID: hostID)
helper.start()
app.run()
#endif
