#if os(macOS)
    import AppKit
    import ApplicationServices
    import Foundation

    private let computerHistoryAXObserverCallback: AXObserverCallback = {
        _, _, notification, refcon in
        guard let refcon else { return }
        let monitor = Unmanaged<AccessibilityEventMonitor>
            .fromOpaque(refcon)
            .takeUnretainedValue()
        monitor.handle(notification: notification as String)
    }

    /// Supplements the foreground polling loop with event-driven Accessibility signals.
    /// The observer never captures data itself; it only asks the existing privacy-aware
    /// sampler to refresh and persist an eligible, bounded semantic observation.
    final class AccessibilityEventMonitor {
        private static let requiredApplicationNotifications = Set([
            kAXFocusedUIElementChangedNotification as String,
            kAXFocusedWindowChangedNotification as String,
            kAXTitleChangedNotification as String,
        ])

        private let onChange: (String) -> Void
        private var observer: AXObserver?
        private var applicationElement: AXUIElement?
        private var focusedElement: AXUIElement?
        private var observedPID: pid_t?
        private var activationToken: NSObjectProtocol?
        private var debounceWorkItem: DispatchWorkItem?
        private var pendingNotifications = Set<String>()
        private var registeredApplicationNotifications = Set<String>()
        private var registeredFocusedNotifications = Set<String>()

        /// Long polling backoff is safe only when the observer can cover the
        /// foreground window/focus and the focused control's changing value.
        var hasReliableEventCoverage: Bool {
            guard observer != nil else { return false }
            guard Self.requiredApplicationNotifications.isSubset(
                of: registeredApplicationNotifications
            ) else { return false }
            guard focusedElement != nil else { return true }
            return registeredFocusedNotifications.contains(
                kAXValueChangedNotification as String
            ) || registeredFocusedNotifications.contains(
                kAXSelectedTextChangedNotification as String
            )
        }

        private let applicationNotifications: [CFString] = [
            kAXFocusedUIElementChangedNotification as CFString,
            kAXFocusedWindowChangedNotification as CFString,
            kAXWindowCreatedNotification as CFString,
            kAXTitleChangedNotification as CFString,
        ]
        private let focusedNotifications: [CFString] = [
            kAXValueChangedNotification as CFString,
            kAXSelectedTextChangedNotification as CFString,
            kAXTitleChangedNotification as CFString,
            kAXUIElementDestroyedNotification as CFString,
        ]

        init(onChange: @escaping (String) -> Void) {
            self.onChange = onChange
        }

        deinit {
            stop()
        }

        func start() {
            stop()
            activationToken = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication
                self?.attach(to: application ?? NSWorkspace.shared.frontmostApplication)
            }
            attach(to: NSWorkspace.shared.frontmostApplication)
        }

        func stop() {
            debounceWorkItem?.cancel()
            debounceWorkItem = nil
            pendingNotifications.removeAll()
            if let token = activationToken {
                NSWorkspace.shared.notificationCenter.removeObserver(token)
            }
            activationToken = nil
            detachObserver()
        }

        fileprivate func handle(notification: String) {
            pendingNotifications.insert(notification)
            if notification == (kAXFocusedUIElementChangedNotification as String)
                || notification == (kAXFocusedWindowChangedNotification as String)
                || notification == (kAXUIElementDestroyedNotification as String)
            {
                refreshFocusedElementNotifications()
            }

            debounceWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                let trigger = self.pendingNotifications
                    .map(Self.shortName)
                    .sorted()
                    .joined(separator: "+")
                self.pendingNotifications.removeAll()
                self.onChange(trigger.isEmpty ? "accessibility_change" : trigger)
            }
            debounceWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: workItem)
        }

        private func attach(to application: NSRunningApplication?) {
            guard let application, application.isTerminated == false else {
                detachObserver()
                return
            }
            if observedPID == application.processIdentifier, observer != nil {
                refreshFocusedElementNotifications()
                return
            }

            detachObserver()
            var created: AXObserver?
            let result = AXObserverCreate(
                application.processIdentifier,
                computerHistoryAXObserverCallback,
                &created
            )
            guard result == .success, let created else {
                Diagnostics.write(
                    "Accessibility event observer unavailable for PID \(application.processIdentifier): \(result.rawValue)"
                )
                return
            }

            let appElement = AXUIElementCreateApplication(application.processIdentifier)
            AXUIElementSetMessagingTimeout(appElement, 0.20)
            let refcon = Unmanaged.passUnretained(self).toOpaque()
            for notification in applicationNotifications {
                let error = AXObserverAddNotification(
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
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(created),
                .commonModes
            )
            refreshFocusedElementNotifications()
        }

        private func refreshFocusedElementNotifications() {
            guard let observer, let applicationElement else { return }
            let refcon = Unmanaged.passUnretained(self).toOpaque()
            if let previous = focusedElement {
                for notification in focusedNotifications {
                    _ = AXObserverRemoveNotification(observer, previous, notification)
                }
            }
            registeredFocusedNotifications.removeAll()
            focusedElement = AXReader.focusedElement(for: applicationElement)
            guard let focusedElement else { return }
            AXUIElementSetMessagingTimeout(focusedElement, 0.15)
            for notification in focusedNotifications {
                let error = AXObserverAddNotification(
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
                    _ = AXObserverRemoveNotification(observer, focusedElement, notification)
                }
            }
            if let applicationElement {
                for notification in applicationNotifications {
                    _ = AXObserverRemoveNotification(observer, applicationElement, notification)
                }
            }
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(observer),
                .commonModes
            )
            self.observer = nil
            applicationElement = nil
            focusedElement = nil
            observedPID = nil
            registeredApplicationNotifications.removeAll()
            registeredFocusedNotifications.removeAll()
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
