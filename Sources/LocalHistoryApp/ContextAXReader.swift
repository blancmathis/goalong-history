#if os(macOS)
    import ApplicationServices
    import Foundation
    import LocalHistoryCore

    /// Mutable caches belong to this reader alone. Every operation receives an
    /// immutable descriptor/configuration view and returns values, without effects.
    final class ContextAXReader {
        private let clock: AXCaptureClock
        private var privateWindowUpdate: Bool?
        private var discoveredBrowserUpdate: AppSnapshot?
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

        init(clock: AXCaptureClock = AXCaptureClock()) { self.clock = clock }

        // NSWorkspace fallback and reads of our own process are not AX evidence.
        private(set) var lastCaptureProvedExternalAX = false
        static func provesExternalAX(pid: Int32, ownPID: Int32, protectedReadSucceeded: Bool) -> Bool {
            protectedReadSucceeded && PermissionManager.isExternalProbeTarget(pid: pid, ownPID: ownPID)
        }

        func capture(parameters: ContextReadParameters, blockingPrivateApp: AppSnapshot? = nil,
                     resolvedApplication: ForegroundAXApplication? = nil) -> ContextReadResult {
            lastCaptureProvedExternalAX = false
            privateWindowUpdate = nil
            discoveredBrowserUpdate = nil
            guard let pauseRevision = parameters.pauseRevision else {
                return ContextReadResult(snapshot: nil, privateWindowUpdate: nil, provedExternalAX: false, discoveredBrowser: nil)
            }
            let policy = parameters.privacy
            let snapshot: ContextSnapshot?
            if let app = blockingPrivateApp {
                snapshot = ContextSnapshot(app: app, window: nil, focusedElement: nil, url: nil,
                    suppressionReason: .privateBrowserWindow)
            } else {
                snapshot = capture(privacy: policy, parameters: parameters, resolvedApplication: resolvedApplication)
            }
            return ContextReadResult(snapshot: snapshot.map {
                ContextSnapshot(app: $0.app, window: $0.window, focusedElement: $0.focusedElement,
                    url: $0.url, suppressionReason: $0.suppressionReason,
                    privacyRevision: policy.revision, globalPauseRevision: pauseRevision)
            }, privateWindowUpdate: privateWindowUpdate, provedExternalAX: lastCaptureProvedExternalAX,
               discoveredBrowser: discoveredBrowserUpdate)
        }

        private func capture(privacy: GoalongPrivacyPolicy, parameters: ContextReadParameters,
                             resolvedApplication: ForegroundAXApplication?) -> ContextSnapshot? {
            guard let workspaceApplication = parameters.foregroundApplication else { return nil }
            let runningApplication = resolvedApplication ?? focusedRunningApplication(fallback: workspaceApplication, parameters: parameters)
            let config = privacy.applying(to: parameters.config)
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

            guard parameters.accessibilityAvailable else {
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
                lastURLProbe = clock.date()
            }

            if isBrowser {
                let shouldProbePrivacy =
                    cachedPrivacyIdentity != windowIdentity
                    || clock.date().timeIntervalSince(lastPrivacyProbe) >= 1.25

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
                    lastPrivacyProbe = clock.date()
                }

                // Private browsing may be explicitly recorded locally, but is never sent to Jev.
                privateWindowUpdate = cachedPrivateWindow
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

            if !isBrowser { privateWindowUpdate = false }
            let window = AXReader.windowSnapshot(windowElement, config: config)
            let focusedElement = AXReader.focusedElement(for: applicationElement)
                .map { AXReader.elementSnapshot($0, config: config) }

            var urlSnapshot: URLSnapshot?
            if isBrowser, config.captureURLs {
                let shouldProbeURL =
                    cachedBrowserIdentity != windowIdentity
                    || clock.date().timeIntervalSince(lastURLProbe) >= 1.25

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
                    lastURLProbe = clock.date()
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
        func captureBlocking(parameters: ContextReadParameters, of application: ForegroundAXApplication? = nil) -> BlockingObservation? {
            guard let running = application ?? parameters.foregroundApplication else { return nil }
            let app = AppSnapshot(name: running.localizedName ?? "", bundleIdentifier: running.bundleIdentifier, processIdentifier: running.processIdentifier)
            let known = BlockingRules.isKnownBrowser(running.bundleIdentifier, configured: parameters.config.browserBundleIdentifiers)
            var result = BlockingObservation(bundleIdentifier: running.bundleIdentifier ?? "", pid: running.processIdentifier,
                windowFrame: nil, isBrowser: known, url: nil,
                privateWindow: false, at: clock.date(), regular: running.regular,
                sessionAvailable: parameters.sessionAvailable, idleSeconds: parameters.idleSeconds)
            guard result.sessionAvailable, parameters.blockingAXTrusted else { return result }
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
            guard known || isBrowser(app: app, config: parameters.config) || AXReader.containsWebArea(window) else { return result }
            // Every app that may show a page is checked for a private window before any address read.
            let key = BlockingWindowKey(pid: running.processIdentifier, window: result.windowIdentity)
            if let cached = blockingPrivateWindows[key], result.at.timeIntervalSince(cached.at) < 30 {
                result.privateWindow = cached.isPrivate
            } else {
                var signals: [String?] = [AXReader.string(window, attribute: "AXTitle" as CFString),
                                         AXReader.string(window, attribute: "AXDescription" as CFString)]
                signals.append(contentsOf: AXReader.browserChromeLabels(window, limit: 80))
                result.privateWindow = PrivacyClassifier.containsPrivateMarker(in: signals, markers: parameters.config.privateWindowMarkers)
                if blockingPrivateWindows.count >= 64 { blockingPrivateWindows.removeAll() }
                blockingPrivateWindows[key] = (result.privateWindow, result.at)
            }
            if result.privateWindow {
                // An unknown app counts as a browser only when it shows an address field, found without reading it.
                if !known { result.isBrowser = AXReader.hasAddressField(in: window, addressFieldMarkers: parameters.config.addressFieldMarkers) }
                return result
            }
            if let raw = AXReader.browserURL(from: window, addressFieldMarkers: parameters.config.addressFieldMarkers) {
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

        func fastSuppressionReason(parameters: ContextReadParameters) -> SuppressionReason? {
            guard parameters.pauseRevision != nil else { return .manualPause }
            guard let runningApplication = parameters.foregroundApplication else { return .sessionUnavailable }
            let privacy = parameters.privacy
            let config = privacy.applying(to: parameters.config)
            let app = AppSnapshot(
                name: runningApplication.localizedName ?? "Unknown application",
                bundleIdentifier: runningApplication.bundleIdentifier,
                processIdentifier: runningApplication.processIdentifier
            )

            if privacy.blocked || isExcluded(app: app, config: config) {
                return .excludedApplication
            }

            guard parameters.accessibilityAvailable else {
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

        /// A known browser is handled by the rate-limited URL/privacy probes below.
        /// Re-running the bounded AX tree discovery on every keyboard or pointer input
        /// adds no coverage and can starve the event-tap drain on complex web views.
        static func shouldProbeBrowserCapability(
            isKnownBrowser: Bool,
            capturesURLs: Bool
        ) -> Bool {
            capturesURLs && !isKnownBrowser
        }

        func element(at point: CGPoint, expectedProcessIdentifier: pid_t? = nil, parameters: ContextReadParameters) -> ElementSnapshot? {
            guard parameters.accessibilityAvailable else { return nil }
            guard let element = AXReader.actionableElement(at: point) else { return nil }
            if let expectedProcessIdentifier {
                var actual: pid_t = 0
                guard AXAccess.getPID(element, &actual) == .success,
                    actual == expectedProcessIdentifier
                else { return nil }
            }
            return AXReader.elementSnapshot(element, config: parameters.config)
        }

        private func isExcluded(app: AppSnapshot, config: RecorderConfig) -> Bool {
            !config.allowsApplication(bundleIdentifier: app.bundleIdentifier)
        }

        func rememberBrowser(_ app: AppSnapshot) {
            discoveredBrowserUpdate = app
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
            fallback workspaceApplication: ForegroundAXApplication, parameters: ContextReadParameters
        ) -> ForegroundAXApplication {
            guard parameters.accessibilityAvailable,
                let focusedProcessIdentifier = AXReader.focusedApplicationProcessIdentifier(),
                focusedProcessIdentifier != workspaceApplication.processIdentifier,
                let focusedApplication = parameters.applications[focusedProcessIdentifier],
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
