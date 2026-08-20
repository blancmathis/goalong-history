#if os(macOS)
    import AppKit
    import ApplicationServices
    import Foundation
    import LocalHistoryCore

    final class ContextProvider {
        private let configManager: ConfigManager
        private let permissions: PermissionManager

        private var cachedURL: URLSnapshot?
        private var cachedBrowserIdentity: String?
        private var lastURLProbe = Date.distantPast

        private var cachedPrivateWindow = false
        private var cachedPrivacyIdentity: String?
        private var lastPrivacyProbe = Date.distantPast
        private var discoveredBrowserBundleIdentifiers = Set<String>()
        private var discoveredBrowserProcessIdentifiers = Set<Int32>()

        init(configManager: ConfigManager, permissions: PermissionManager) {
            self.configManager = configManager
            self.permissions = permissions
        }

        func capture() -> ContextSnapshot? {
            guard let runningApplication = NSWorkspace.shared.frontmostApplication else { return nil }
            let config = configManager.config
            let app = AppSnapshot(
                name: StringSanitizer.clean(
                    runningApplication.localizedName ?? "Unknown application",
                    maxLength: 256
                ) ?? "Unknown application",
                bundleIdentifier: runningApplication.bundleIdentifier,
                processIdentifier: runningApplication.processIdentifier
            )

            if isExcluded(app: app, config: config) {
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

            let applicationElement = AXUIElementCreateApplication(runningApplication.processIdentifier)
            AXUIElementSetMessagingTimeout(applicationElement, 0.30)
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

            let windowIdentity = [
                String(runningApplication.processIdentifier),
                String(CFHash(windowElement)),
            ].joined(separator: "|")

            var capabilityURL: String?
            if config.captureURLs {
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

                if cachedPrivateWindow {
                    clearCachedURL()
                    return ContextSnapshot(
                        app: app,
                        window: nil,
                        focusedElement: nil,
                        url: nil,
                        suppressionReason: .privateBrowserWindow
                    )
                }
            }

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

                if URLRedactor.domain(urlSnapshot?.host, matches: config.excludedDomains) {
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

        func fastSuppressionReason() -> SuppressionReason? {
            guard let runningApplication = NSWorkspace.shared.frontmostApplication else { return .sessionUnavailable }
            let config = configManager.config
            let app = AppSnapshot(
                name: runningApplication.localizedName ?? "Unknown application",
                bundleIdentifier: runningApplication.bundleIdentifier,
                processIdentifier: runningApplication.processIdentifier
            )

            if isExcluded(app: app, config: config) {
                return .excludedApplication
            }

            var isBrowser = isBrowser(app: app, config: config)
            guard permissions.currentStatus.accessibility else {
                return isBrowser ? .accessibilityUnavailable : nil
            }

            let applicationElement = AXUIElementCreateApplication(runningApplication.processIdentifier)
            AXUIElementSetMessagingTimeout(applicationElement, 0.12)
            guard let windowElement = AXReader.focusedWindow(for: applicationElement) else {
                return isBrowser ? .accessibilityUnavailable : nil
            }

            let rawURL = config.captureURLs
                ? AXReader.browserURL(
                    from: windowElement,
                    addressFieldMarkers: config.addressFieldMarkers,
                    maxNodes: 140
                )
                : nil

            if !isBrowser,
                rawURL != nil || AXReader.containsWebArea(windowElement, maxNodes: 120)
            {
                isBrowser = true
                rememberBrowser(app)
            }
            guard isBrowser else { return nil }

            if let sanitized = URLRedactor.sanitize(
                rawURL,
                redactAllQueryValues: config.redactAllURLQueryValues,
                maxLength: config.maxStringLength
            ), URLRedactor.domain(sanitized.host, matches: config.excludedDomains) {
                return .excludedDomain
            }

            var signals: [String?] = [
                AXReader.string(windowElement, attribute: "AXTitle" as CFString),
                AXReader.string(windowElement, attribute: "AXDescription" as CFString),
                AXReader.string(windowElement, attribute: "AXSubrole" as CFString),
            ]
            signals.append(contentsOf: AXReader.browserChromeLabels(windowElement, limit: 20))

            if PrivacyClassifier.containsPrivateMarker(in: signals, markers: config.privateWindowMarkers) {
                return .privateBrowserWindow
            }

            return nil
        }

        func frontmostProcessIdentifier() -> pid_t? {
            NSWorkspace.shared.frontmostApplication?.processIdentifier
        }

        func element(at point: CGPoint, expectedProcessIdentifier: pid_t? = nil) -> ElementSnapshot? {
            guard permissions.currentStatus.accessibility else { return nil }
            guard let element = AXReader.actionableElement(at: point) else { return nil }
            if let expectedProcessIdentifier {
                var actual: pid_t = 0
                guard AXUIElementGetPid(element, &actual) == .success,
                    actual == expectedProcessIdentifier
                else { return nil }
            }
            return AXReader.elementSnapshot(element, config: configManager.config)
        }

        private func isExcluded(app: AppSnapshot, config: RecorderConfig) -> Bool {
            guard let bundleIdentifier = app.bundleIdentifier else { return false }
            return config.excludedBundleIdentifiers.contains(bundleIdentifier)
        }

        private func rememberBrowser(_ app: AppSnapshot) {
            discoveredBrowserProcessIdentifiers.insert(app.processIdentifier)
            if let bundleIdentifier = app.bundleIdentifier, !bundleIdentifier.isEmpty {
                discoveredBrowserBundleIdentifiers.insert(bundleIdentifier)
            }
        }

        private func clearCachedURL() {
            cachedURL = nil
            cachedBrowserIdentity = nil
            lastURLProbe = .distantPast
        }

        private func isBrowser(app: AppSnapshot, config: RecorderConfig) -> Bool {
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
    }
#endif
