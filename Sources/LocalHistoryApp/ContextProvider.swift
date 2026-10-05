#if os(macOS)
    import AppKit
    import ApplicationServices
    import Foundation
    import LocalHistoryCore

    struct BoundedIdentifierCache<Value: Hashable> {
        private let capacity: Int
        private var values = Set<Value>()
        private var accessOrder: [Value] = []

        init(capacity: Int = 64) {
            self.capacity = max(1, capacity)
        }

        mutating func insert(_ value: Value) {
            if values.contains(value) {
                accessOrder.removeAll { $0 == value }
            } else {
                values.insert(value)
            }
            accessOrder.append(value)
            while accessOrder.count > capacity {
                values.remove(accessOrder.removeFirst())
            }
        }

        func contains(_ value: Value) -> Bool {
            values.contains(value)
        }

        var count: Int { values.count }
    }

    typealias BoundedProcessIdentifierCache = BoundedIdentifierCache<Int32>

    final class ContextProvider {
        private let configManager: ConfigManager
        private let permissions: PermissionManager
        private let blockingProbe: (() -> BlockingObservation?)?
        private struct BlockingWindowKey: Hashable { let pid: Int32; let window: Int }
        /// A window does not turn private: its answer is kept 30 s instead of rereading ~200 labels per sample.
        private var blockingPrivateWindows: [BlockingWindowKey: (isPrivate: Bool, at: Date)] = [:]

        private var cachedURL: URLSnapshot?
        private var cachedBrowserIdentity: String?
        private var lastURLProbe = Date.distantPast

        private var cachedPrivateWindow = false
        private var cachedPrivacyIdentity: String?
        private var lastPrivacyProbe = Date.distantPast
        private var discoveredBrowserBundleIdentifiers = BoundedIdentifierCache<String>(capacity: 128)
        private var discoveredBrowserProcessIdentifiers = BoundedProcessIdentifierCache()

        init(configManager: ConfigManager, permissions: PermissionManager, blockingProbe: (() -> BlockingObservation?)? = nil) {
            self.configManager = configManager
            self.permissions = permissions
            self.blockingProbe = blockingProbe
        }

        // NSWorkspace fallback and reads of our own process are not AX evidence.
        private(set) var lastCaptureProvedExternalAX = false
        static func provesExternalAX(pid: Int32, ownPID: Int32, protectedReadSucceeded: Bool) -> Bool {
            protectedReadSucceeded && PermissionManager.isExternalProbeTarget(pid: pid, ownPID: ownPID)
        }

        var historyPrivacyStopped: Bool {
            GoalongPrivacyPolicyCache.read(in: AppPaths.applicationSupportDirectory).blocked
        }
        func capture(blockingSink: ((BlockingObservation) -> Void)? = nil, historyEnabled: Bool = true) -> ContextSnapshot? {
            var blockingPrivateApp: AppSnapshot?
            if let blockingSink, let observation = blockingProbe == nil ? captureBlocking() : blockingProbe?() {
                blockingSink(observation)
                if observation.privateWindow {
                    blockingPrivateApp = AppSnapshot(name: observation.bundleIdentifier, bundleIdentifier: observation.bundleIdentifier, processIdentifier: observation.pid)
                }
            }
            guard historyEnabled else { return nil }
            lastCaptureProvedExternalAX = false
            guard let pauseRevision = try? GoalongGlobalPause.admit() else { return nil }
            let policy = GoalongPrivacyPolicyCache.read(in: AppPaths.applicationSupportDirectory)
            if let app = blockingPrivateApp {
                return ContextSnapshot(app: app, window: nil, focusedElement: nil, url: nil,
                    suppressionReason: .privateBrowserWindow, privacyRevision: policy.revision, globalPauseRevision: pauseRevision)
            }
            guard let snapshot = capture(privacy: policy) else { return nil }
            return ContextSnapshot(app: snapshot.app, window: snapshot.window,
                focusedElement: snapshot.focusedElement, url: snapshot.url,
                suppressionReason: snapshot.suppressionReason, privacyRevision: policy.revision, globalPauseRevision: pauseRevision)
        }

        private func capture(privacy: GoalongPrivacyPolicy) -> ContextSnapshot? {
            guard let workspaceApplication = NSWorkspace.shared.frontmostApplication else { return nil }
            let runningApplication = focusedRunningApplication(fallback: workspaceApplication)
            let config = privacy.applying(to: configManager.config)
            let app = AppSnapshot(
                name: StringSanitizer.clean(
                    runningApplication.localizedName ?? "Unknown application",
                    maxLength: 256
                ) ?? "Unknown application",
                bundleIdentifier: runningApplication.bundleIdentifier,
                processIdentifier: runningApplication.processIdentifier
            )

            if privacy.blocked || isExcluded(app: app, config: config) {
                return ContextSnapshot(
                    app: app,
                    window: nil,
                    focusedElement: nil,
                    url: nil,
                    suppressionReason: .excludedApplication
                )
            }

            var isBrowser = isBrowser(app: app, config: config)

            guard permissions.currentStatus.accessibility else {
                return ContextSnapshot(
                    app: app,
                    window: nil,
                    focusedElement: nil,
                    url: nil,
                    suppressionReason: isBrowser ? .accessibilityUnavailable : nil
                )
            }

            let applicationElement = AXAccess.application(runningApplication.processIdentifier)
            AXAccess.setMessagingTimeout(applicationElement, 0.30)
            guard let windowElement = AXReader.focusedWindow(for: applicationElement) else {
                return ContextSnapshot(
                    app: app,
                    window: nil,
                    focusedElement: isBrowser
                        ? nil
                        : AXReader.focusedElement(for: applicationElement)
                            .map { AXReader.elementSnapshot($0, config: config) },
                    url: nil,
                    suppressionReason: isBrowser ? .accessibilityUnavailable : nil
                )
            }

            lastCaptureProvedExternalAX = Self.provesExternalAX(
                pid: runningApplication.processIdentifier,
                ownPID: ProcessInfo.processInfo.processIdentifier, protectedReadSucceeded: true)

            let windowIdentity = [
                String(runningApplication.processIdentifier),
                String(CFHash(windowElement)),
            ].joined(separator: "|")

            var capabilityURL: String?
            if Self.shouldProbeBrowserCapability(
                isKnownBrowser: isBrowser,
                capturesURLs: config.captureURLs
            ) {
                capabilityURL = AXReader.browserURL(
                    from: windowElement,
                    addressFieldMarkers: config.addressFieldMarkers
                )
            }

            // Browser support is capability-based first. Any application exposing an AXWebArea
            // or a page URL is treated as a web container, including new browsers and wrappers
            // whose name or bundle identifier has never been seen by LocalHistory.
            if !isBrowser,
                capabilityURL != nil || AXReader.containsWebArea(windowElement)
            {
                isBrowser = true
                rememberBrowser(app)
            }

            if let capabilityURL, isBrowser {
                cachedURL = URLRedactor.sanitize(
                    capabilityURL,
                    redactAllQueryValues: config.redactAllURLQueryValues,
                    maxLength: config.maxStringLength
                )
                cachedBrowserIdentity = windowIdentity
                lastURLProbe = Date()
            }

            if isBrowser {
                let shouldProbePrivacy =
                    cachedPrivacyIdentity != windowIdentity
                    || Date().timeIntervalSince(lastPrivacyProbe) >= 1.25

                if shouldProbePrivacy {
                    var privacySignals: [String?] = [
                        AXReader.string(windowElement, attribute: "AXTitle" as CFString),
                        AXReader.string(windowElement, attribute: "AXDescription" as CFString),
                        AXReader.string(windowElement, attribute: "AXSubrole" as CFString),
                    ]
                    privacySignals.append(contentsOf: AXReader.browserChromeLabels(windowElement, limit: 80))
                    cachedPrivateWindow = PrivacyClassifier.containsPrivateMarker(
                        in: privacySignals,
                        markers: config.privateWindowMarkers
                    )
                    cachedPrivacyIdentity = windowIdentity
                    lastPrivacyProbe = Date()
                }

                // Private browsing may be explicitly recorded locally, but is never sent to Jev.
                JevIngress.shared.setPrivateWindow(cachedPrivateWindow)
                if config.suppressesPrivateWindow(detected: cachedPrivateWindow) {
                    clearCachedURL()
                    return ContextSnapshot(
                        app: app,
                        window: nil,
                        focusedElement: nil,
                        url: nil,
                        suppressionReason: .privateBrowserWindow
                    )
                }

                // A website exclusion or include-only scope must never fall back to recording a
                // browser without a host just because URL capture was disabled.
                if !config.captureURLs, !config.allowsWebsite(host: nil) {
                    // Inspection is separately authorized; do not cache or persist the URL.
                    let host = privacy.inspectDomainsForExclusions
                        ? AXReader.browserURL(from: windowElement, addressFieldMarkers: config.addressFieldMarkers)
                            .flatMap { URLComponents(string: $0)?.host }
                        : nil
                    clearCachedURL()
                    if !config.allowsWebsite(host: host) {
                        return ContextSnapshot(app: app, window: nil, focusedElement: nil, url: nil,
                                               suppressionReason: .excludedDomain)
                    }
                }
            }

            if !isBrowser { JevIngress.shared.setPrivateWindow(false) }
            let window = AXReader.windowSnapshot(windowElement, config: config)
            let focusedElement = AXReader.focusedElement(for: applicationElement)
                .map { AXReader.elementSnapshot($0, config: config) }

            var urlSnapshot: URLSnapshot?
            if isBrowser, config.captureURLs {
                let shouldProbeURL =
                    cachedBrowserIdentity != windowIdentity
                    || Date().timeIntervalSince(lastURLProbe) >= 1.25

                if shouldProbeURL {
                    let rawURL = AXReader.browserURL(
                        from: windowElement,
                        addressFieldMarkers: config.addressFieldMarkers
                    )
                    cachedURL = URLRedactor.sanitize(
                        rawURL,
                        redactAllQueryValues: config.redactAllURLQueryValues,
                        maxLength: config.maxStringLength
                    )
                    cachedBrowserIdentity = windowIdentity
                    lastURLProbe = Date()
                }
                urlSnapshot = cachedURL

                if !config.allowsWebsite(host: urlSnapshot?.host) {
                    return ContextSnapshot(
                        app: app,
                        window: nil,
                        focusedElement: nil,
                        url: nil,
                        suppressionReason: .excludedDomain
                    )
                }
            }

            return ContextSnapshot(
                app: app,
                window: window,
                focusedElement: focusedElement,
                url: urlSnapshot,
                suppressionReason: nil
            )
        }

        /// Ephemeral blocking lane. No history policy/cache, title snapshot, focused text or Jev call.
        /// The private flag is resolved before any address read, including capability discovery.
        func captureBlocking(of application: NSRunningApplication? = nil) -> BlockingObservation? {
            guard let running = application ?? NSWorkspace.shared.frontmostApplication else { return nil }
            let app = AppSnapshot(name: running.localizedName ?? "", bundleIdentifier: running.bundleIdentifier, processIdentifier: running.processIdentifier)
            let known = BlockingRules.isKnownBrowser(running.bundleIdentifier, configured: configManager.config.browserBundleIdentifiers)
            var result = BlockingObservation(bundleIdentifier: running.bundleIdentifier ?? "", pid: running.processIdentifier,
                windowFrame: nil, isBrowser: known, url: nil,
                privateWindow: false, at: Date(), regular: running.activationPolicy == .regular,
                sessionAvailable: ForegroundSessionAvailability.isAvailable(), idleSeconds: UserInputActivityClock.secondsSinceLastInput())
            guard result.sessionAvailable, AXIsProcessTrusted() else { return result }
            let element = AXAccess.application(running.processIdentifier)
            AXAccess.setMessagingTimeout(element, 0.20)
            // The main window stands in while no window holds focus (an open menu, a sheet closing).
            guard let window = AXReader.focusedWindow(for: element) ?? AXReader.element(element, attribute: kAXMainWindowAttribute as CFString)
            else { return result }
            result.windowIdentity = Int(CFHash(window))
            var position: CFTypeRef?, size: CFTypeRef?
            AXAccess.copyAttributeValue(window, kAXPositionAttribute as CFString, &position)
            AXAccess.copyAttributeValue(window, kAXSizeAttribute as CFString, &size)
            if let position, let size, CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() {
                var point = CGPoint.zero, dimensions = CGSize.zero
                if AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &point),
                   AXValueGetValue(unsafeBitCast(size, to: AXValue.self), .cgSize, &dimensions) {
                    result.windowFrame = CGRect(origin: point, size: dimensions)
                }
            }
            // Known browsers follow site rules and fail closed. Any other app follows app rules, unless an
            // address is actually read from it: showing web content does not make an app a browser.
            guard known || isBrowser(app: app, config: configManager.config) || AXReader.containsWebArea(window) else { return result }
            // Every app that may show a page is checked for a private window before any address read.
            let key = BlockingWindowKey(pid: running.processIdentifier, window: result.windowIdentity)
            if let cached = blockingPrivateWindows[key], result.at.timeIntervalSince(cached.at) < 30 {
                result.privateWindow = cached.isPrivate
            } else {
                var signals: [String?] = [AXReader.string(window, attribute: "AXTitle" as CFString),
                                         AXReader.string(window, attribute: "AXDescription" as CFString)]
                signals.append(contentsOf: AXReader.browserChromeLabels(window, limit: 80))
                result.privateWindow = PrivacyClassifier.containsPrivateMarker(in: signals, markers: configManager.config.privateWindowMarkers)
                if blockingPrivateWindows.count >= 64 { blockingPrivateWindows.removeAll() }
                blockingPrivateWindows[key] = (result.privateWindow, result.at)
            }
            if result.privateWindow {
                // An unknown app counts as a browser only when it shows an address field, found without reading it.
                if !known { result.isBrowser = AXReader.hasAddressField(in: window, addressFieldMarkers: configManager.config.addressFieldMarkers) }
                return result
            }
            if let raw = AXReader.browserURL(from: window, addressFieldMarkers: configManager.config.addressFieldMarkers) {
                result.isBrowser = true
                let lower = raw.lowercased()
                result.isInternalPage = lower.hasPrefix("about:") || lower.hasPrefix("favorites:")
                    || lower.hasPrefix("chrome://newtab") || lower.hasPrefix("edge://newtab")
                result.url = result.isInternalPage ? lower.components(separatedBy: "?")[0].components(separatedBy: "#")[0] : BlockingRules.normalize(raw)
            } else if known, result.bundleIdentifier == "com.apple.Safari" {
                // An empty Safari start page has no web area. Missing address on real content fails closed.
                result.isInternalPage = !AXReader.containsWebArea(window)
            }
            return result
        }

        func fastSuppressionReason() -> SuppressionReason? {
            guard !GoalongGlobalPause.isPaused() else { return .manualPause }
            guard let runningApplication = NSWorkspace.shared.frontmostApplication else { return .sessionUnavailable }
            let privacy = GoalongPrivacyPolicyCache.read(in: AppPaths.applicationSupportDirectory)
            let config = privacy.applying(to: configManager.config)
            let app = AppSnapshot(
                name: runningApplication.localizedName ?? "Unknown application",
                bundleIdentifier: runningApplication.bundleIdentifier,
                processIdentifier: runningApplication.processIdentifier
            )

            if privacy.blocked || isExcluded(app: app, config: config) {
                return .excludedApplication
            }

            guard permissions.currentStatus.accessibility else {
                return .accessibilityUnavailable
            }

            let applicationElement = AXAccess.application(runningApplication.processIdentifier)
            AXAccess.setMessagingTimeout(applicationElement, 0.12)
            if let focusedElement = AXReader.focusedElement(for: applicationElement),
                AXReader.isSecureElement(focusedElement)
            {
                return .secureInput
            }
            let isWebContainer = isBrowser(app: app, config: config)
            let hasDomainRules = !config.excludedDomains.isEmpty
                || config.includedDomains?.isEmpty == false
            let canUsePrivateWindows = isPrivateWindowCapableBrowser(
                app: app,
                config: config
            )
            guard Self.shouldProbeWebPrivacyOnInput(
                isWebContainer: isWebContainer,
                privateWindowCapable: canUsePrivateWindows,
                hasDomainRules: hasDomainRules
            ) else { return nil }

            guard let windowElement = AXReader.focusedWindow(for: applicationElement) else {
                return .accessibilityUnavailable
            }

            let rawURL = hasDomainRules && (config.captureURLs || privacy.inspectDomainsForExclusions)
                ? AXReader.browserURL(
                    from: windowElement,
                    addressFieldMarkers: config.addressFieldMarkers,
                    maxNodes: 140
                )
                : nil

            if hasDomainRules {
                let sanitized = URLRedactor.sanitize(
                    rawURL,
                    redactAllQueryValues: config.redactAllURLQueryValues,
                    maxLength: config.maxStringLength
                )
                if !config.allowsWebsite(host: sanitized?.host) {
                    return .excludedDomain
                }
            }

            if canUsePrivateWindows && config.capturePrivateBrowsing != true {
                let signals: [String?] = [
                    AXReader.string(windowElement, attribute: "AXTitle" as CFString),
                    AXReader.string(windowElement, attribute: "AXDescription" as CFString),
                    AXReader.string(windowElement, attribute: "AXSubrole" as CFString),
                ]
                if PrivacyClassifier.containsPrivateMarker(
                    in: signals,
                    markers: config.privateWindowMarkers
                ) {
                    return .privateBrowserWindow
                }
            }

            return nil
        }

        static func shouldProbeWebPrivacyOnInput(
            isWebContainer: Bool,
            privateWindowCapable: Bool,
            hasDomainRules: Bool
        ) -> Bool {
            isWebContainer && (privateWindowCapable || hasDomainRules)
        }

        func frontmostProcessIdentifier() -> pid_t? {
            NSWorkspace.shared.frontmostApplication?.processIdentifier
        }

        /// A known browser is handled by the rate-limited URL/privacy probes below.
        /// Re-running the bounded AX tree discovery on every keyboard or pointer input
        /// adds no coverage and can starve the event-tap drain on complex web views.
        static func shouldProbeBrowserCapability(
            isKnownBrowser: Bool,
            capturesURLs: Bool
        ) -> Bool {
            capturesURLs && !isKnownBrowser
        }

        func element(at point: CGPoint, expectedProcessIdentifier: pid_t? = nil) -> ElementSnapshot? {
            guard permissions.currentStatus.accessibility else { return nil }
            guard let element = AXReader.actionableElement(at: point) else { return nil }
            if let expectedProcessIdentifier {
                var actual: pid_t = 0
                guard AXAccess.getPID(element, &actual) == .success,
                    actual == expectedProcessIdentifier
                else { return nil }
            }
            return AXReader.elementSnapshot(element, config: configManager.config)
        }

        private func isExcluded(app: AppSnapshot, config: RecorderConfig) -> Bool {
            !config.allowsApplication(bundleIdentifier: app.bundleIdentifier)
        }

        private func rememberBrowser(_ app: AppSnapshot) {
            if let bundleIdentifier = app.bundleIdentifier, !bundleIdentifier.isEmpty {
                discoveredBrowserBundleIdentifiers.insert(bundleIdentifier)
            } else {
                discoveredBrowserProcessIdentifiers.insert(app.processIdentifier)
            }
        }

        private func clearCachedURL() {
            cachedURL = nil
            cachedBrowserIdentity = nil
            lastURLProbe = .distantPast
        }

        private func focusedRunningApplication(
            fallback workspaceApplication: NSRunningApplication
        ) -> NSRunningApplication {
            guard permissions.currentStatus.accessibility,
                let focusedProcessIdentifier = AXReader.focusedApplicationProcessIdentifier(),
                focusedProcessIdentifier != workspaceApplication.processIdentifier,
                let focusedApplication = NSRunningApplication(
                    processIdentifier: focusedProcessIdentifier
                ),
                !focusedApplication.isTerminated
            else { return workspaceApplication }
            return focusedApplication
        }

        func isBrowser(app: AppSnapshot, config: RecorderConfig) -> Bool {
            if discoveredBrowserProcessIdentifiers.contains(app.processIdentifier) {
                return true
            }
            if let bundleIdentifier = app.bundleIdentifier {
                if config.browserBundleIdentifiers.contains(bundleIdentifier)
                    || discoveredBrowserBundleIdentifiers.contains(bundleIdentifier)
                {
                    return true
                }
            }

            // Name markers remain only as a compatibility fast path. The capability probe above
            // is authoritative and lets unknown browsers work without adding a product-specific rule.
            let identity = [app.name, app.bundleIdentifier ?? ""].joined(separator: " ").lowercased()
            let browserNameMarkers = [
                "safari", "chrome", "chromium", "firefox", "librewolf", "floorp",
                "edge", "brave", "arc", "opera", "vivaldi", "orion", "duckduckgo",
                "zen browser", "dia", "sigmaos", "browser",
            ]
            return browserNameMarkers.contains { identity.contains($0) }
        }

        private func isPrivateWindowCapableBrowser(
            app: AppSnapshot,
            config: RecorderConfig
        ) -> Bool {
            if let bundleIdentifier = app.bundleIdentifier,
                config.browserBundleIdentifiers.contains(bundleIdentifier)
            {
                return true
            }
            let identity = [app.name, app.bundleIdentifier ?? ""]
                .joined(separator: " ")
                .lowercased()
            let markers = [
                "safari", "chrome", "chromium", "firefox", "librewolf", "floorp",
                "edge", "brave", "arc", "opera", "vivaldi", "orion", "duckduckgo",
                "zen browser", "dia", "sigmaos", "browser",
            ]
            return markers.contains { identity.contains($0) }
        }
    }
#endif
