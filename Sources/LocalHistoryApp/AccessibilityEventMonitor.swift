#if os(macOS)
import AppKit
import ApplicationServices
import Foundation

private let observationCallback: AXObserverCallback = { _, _, notification, refcon in
    guard let refcon else { return }
    let attachment = Unmanaged<AXObserverOwner.Attachment>.fromOpaque(refcon).takeUnretainedValue()
    guard attachment.active else { return }
    attachment.owner?.handle(notification: notification as String, generation: attachment.generation)
}

/// All AX handles, registrations and focus reads belong to the observation thread.
final class AXObserverOwner {
    final class Attachment {
        weak var owner: AXObserverOwner?
        let generation: UUID
        var active = true
        init(owner: AXObserverOwner, generation: UUID) { self.owner = owner; self.generation = generation }
    }
    private let client: AXClient
    private let publish: (UUID, Bool, String?) -> Void
    private var attachment: Attachment?
    private var observer: AXObserver?
    private var applicationElement: AXUIElement?
    private var focusedElement: AXUIElement?
    private var observedPID: pid_t?
    private var registeredApplicationNotifications = Set<String>()
    private var registeredFocusedNotifications = Set<String>()
    private let applicationNotifications: [CFString] = [
        kAXFocusedUIElementChangedNotification as CFString, kAXFocusedWindowChangedNotification as CFString,
        kAXWindowCreatedNotification as CFString, kAXTitleChangedNotification as CFString,
    ]
    private let focusedNotifications: [CFString] = [
        kAXValueChangedNotification as CFString, kAXSelectedTextChangedNotification as CFString,
        kAXTitleChangedNotification as CFString, kAXUIElementDestroyedNotification as CFString,
    ]
    init(client: AXClient, publish: @escaping (UUID, Bool, String?) -> Void) {
        self.client = client; self.publish = publish
    }
    private var coverage: Bool {
        let required = Set([kAXFocusedUIElementChangedNotification as String,
                            kAXFocusedWindowChangedNotification as String, kAXTitleChangedNotification as String])
        return observer != nil && required.isSubset(of: registeredApplicationNotifications)
            && (focusedElement == nil || registeredFocusedNotifications.contains(kAXValueChangedNotification as String)
                || registeredFocusedNotifications.contains(kAXSelectedTextChangedNotification as String))
    }
    func attach(to application: ForegroundAXApplication?, generation: UUID) {
        AXAccess.withBackgroundClient(client) {
            // Replace the callback token even on A -> B -> A or the same PID:
            // a retired source can never acquire the new attachment's identity.
            detachObserver()
            guard let application, !application.isTerminated else { publish(generation, false, nil); return }
            attach(application, generation: generation)
            publish(generation, coverage, nil)
        }
    }
    private func attach(_ application: ForegroundAXApplication, generation: UUID) {
            var created: AXObserver?
            let result = AXAccess.createObserver(
                application.processIdentifier,
                observationCallback,
                &created
            )
            guard result == .success, let created else {
                Diagnostics.write(
                    "Accessibility event observer unavailable for PID \(application.processIdentifier): \(result.rawValue)"
                )
                return
            }

            attachment = Attachment(owner: self, generation: generation)
            let appElement = AXAccess.application(application.processIdentifier)
            AXAccess.setMessagingTimeout(appElement, 0.20)
            let refcon = Unmanaged.passUnretained(attachment!).toOpaque()
            for notification in applicationNotifications {
                let error = AXAccess.addNotification(
                    created,
                    appElement,
                    notification,
                    refcon
                )
                if error != .success && error != .notificationAlreadyRegistered {
                    Diagnostics.write(
                        "Could not observe \(notification) for PID \(application.processIdentifier): \(error.rawValue)"
                    )
                } else {
                    registeredApplicationNotifications.insert(notification as String)
                }
            }

            observer = created
            applicationElement = appElement
            observedPID = application.processIdentifier
            CFRunLoopAddSource(
                CFRunLoopGetCurrent(),
                AXObserverGetRunLoopSource(created),
                .commonModes
            )
            refreshFocusedElementNotifications()
        }

        private func refreshFocusedElementNotifications() {
            guard let observer, let applicationElement else { return }
            let refcon = Unmanaged.passUnretained(attachment!).toOpaque()
            if let previous = focusedElement {
                for notification in focusedNotifications {
                    _ = AXAccess.removeNotification(observer, previous, notification)
                }
            }
            registeredFocusedNotifications.removeAll()
            focusedElement = AXReader.focusedElement(for: applicationElement)
            guard let focusedElement else { return }
            AXAccess.setMessagingTimeout(focusedElement, 0.15)
            for notification in focusedNotifications {
                let error = AXAccess.addNotification(
                    observer,
                    focusedElement,
                    notification,
                    refcon
                )
                if error != .success
                    && error != .notificationAlreadyRegistered
                    && error != .notificationUnsupported
                {
                    Diagnostics.write(
                        "Could not observe focused element \(notification): \(error.rawValue)"
                    )
                } else if error == .success || error == .notificationAlreadyRegistered {
                    registeredFocusedNotifications.insert(notification as String)
                }
            }
        }

        private func detachObserver() {
            attachment?.active = false
            guard let observer else {
                applicationElement = nil
                focusedElement = nil
                observedPID = nil
                registeredApplicationNotifications.removeAll()
                registeredFocusedNotifications.removeAll()
                return
            }
            if let focusedElement {
                for notification in focusedNotifications {
                    _ = AXAccess.removeNotification(observer, focusedElement, notification)
                }
            }
            if let applicationElement {
                for notification in applicationNotifications {
                    _ = AXAccess.removeNotification(observer, applicationElement, notification)
                }
            }
            CFRunLoopRemoveSource(
                CFRunLoopGetCurrent(),
                AXObserverGetRunLoopSource(observer),
                .commonModes
            )
            self.observer = nil
            attachment = nil
            applicationElement = nil
            focusedElement = nil
            observedPID = nil
            registeredApplicationNotifications.removeAll()
            registeredFocusedNotifications.removeAll()
        }


    func detach() { AXAccess.withBackgroundClient(client) { detachObserver() } }
    fileprivate func handle(notification: String, generation: UUID) {
        guard let attachment, attachment.active, attachment.generation == generation else { return }
        AXAccess.withBackgroundClient(client) {
            if notification == kAXFocusedUIElementChangedNotification as String
                || notification == kAXFocusedWindowChangedNotification as String
                || notification == kAXUIElementDestroyedNotification as String {
                refreshFocusedElementNotifications()
            }
        }
        publish(generation, coverage, notification)
    }
}

/// The main facade owns workspace notifications and debouncing only.
final class AccessibilityEventMonitor {
    private let isAccessibilityAvailable: () -> Bool
    private let onChange: (String) -> Void
    private let thread = AXObservationThread()
    private let client: AXClient
    private lazy var owner = AXObserverOwner(client: client) { [weak self] generation, coverage, notification in
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == generation else { return }
            self.hasReliableEventCoverage = coverage
            if let notification { self.handle(notification: notification) }
        }
    }
    private var generation = UUID()
    private var activationToken: NSObjectProtocol?
    private var launchToken: NSObjectProtocol?
    var onApplication: ((NSRunningApplication) -> Void)?
    var observesApplicationLaunches = false
    private var debounceWorkItem: DispatchWorkItem?
    private var pendingNotifications = Set<String>()
    private(set) var hasReliableEventCoverage = false
    var canAttemptAttachment: Bool { isAccessibilityAvailable() }

    init(isAccessibilityAvailable: @escaping () -> Bool, client: AXClient = .system,
         onChange: @escaping (String) -> Void) {
        self.isAccessibilityAvailable = isAccessibilityAvailable; self.client = client; self.onChange = onChange
    }
    deinit {
        if let activationToken { NSWorkspace.shared.notificationCenter.removeObserver(activationToken) }
        if let launchToken { NSWorkspace.shared.notificationCenter.removeObserver(launchToken) }
        debounceWorkItem?.cancel()
        let owner = owner
        thread.shutdown { owner.detach() }
    }
    func start() {
        stop()
        activationToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if let application { self.onApplication?(application) }
            self.onChange("application_activation")
            self.attach(to: application ?? NSWorkspace.shared.frontmostApplication)
        }
        if observesApplicationLaunches {
            launchToken = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
            ) { [weak self] notification in
                if let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                    self?.onApplication?(application)
                }
                self?.onChange("application_launch")
            }
        }
        attach(to: NSWorkspace.shared.frontmostApplication)
    }
    func stop() {
        generation = UUID()
        hasReliableEventCoverage = false
        debounceWorkItem?.cancel(); debounceWorkItem = nil; pendingNotifications.removeAll()
        if let activationToken { NSWorkspace.shared.notificationCenter.removeObserver(activationToken) }
        if let launchToken { NSWorkspace.shared.notificationCenter.removeObserver(launchToken) }
        activationToken = nil; launchToken = nil
        let owner = owner
        thread.submit { owner.detach() }
    }
    private func attach(to application: NSRunningApplication?) {
        debounceWorkItem?.cancel(); debounceWorkItem = nil; pendingNotifications.removeAll()
        generation = UUID()
        hasReliableEventCoverage = false
        let generation = generation
        let descriptor = canAttemptAttachment ? application.map(ForegroundAXApplication.init) : nil
        let owner = owner
        thread.submit { owner.attach(to: descriptor, generation: generation) }
    }
    private func handle(notification: String) {
        pendingNotifications.insert(notification)
        debounceWorkItem?.cancel()
        let generation = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == generation else { return }
            let trigger = self.pendingNotifications.map(Self.shortName).sorted().joined(separator: "+")
            self.pendingNotifications.removeAll()
            self.onChange(trigger.isEmpty ? "accessibility_change" : trigger)
        }
        debounceWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounceDelay(for: pendingNotifications), execute: work)
    }
    static func debounceDelay(for notifications: Set<String>) -> TimeInterval {
        let structural = Set([kAXFocusedUIElementChangedNotification as String, kAXFocusedWindowChangedNotification as String,
                              kAXUIElementDestroyedNotification as String, kAXWindowCreatedNotification as String])
        return notifications.isDisjoint(with: structural) ? 1.4 : 0.18
    }
        private static func shortName(_ notification: String) -> String {
            notification
                .replacingOccurrences(of: "AX", with: "")
                .replacingOccurrences(of: "Changed", with: "_changed")
                .replacingOccurrences(of: "Created", with: "_created")
                .replacingOccurrences(of: "UIElement", with: "_element")
                .replacingOccurrences(of: "Window", with: "_window")
                .replacingOccurrences(of: "Text", with: "_text")
                .lowercased()
        }
}
#endif
