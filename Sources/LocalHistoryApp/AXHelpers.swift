#if os(macOS)
    import ApplicationServices
    import Foundation
    import LocalHistoryCore

    private enum AXAttribute {
        static let role = "AXRole" as CFString
        static let subrole = "AXSubrole" as CFString
        static let title = "AXTitle" as CFString
        static let description = "AXDescription" as CFString
        static let roleDescription = "AXRoleDescription" as CFString
        static let identifier = "AXIdentifier" as CFString
        static let value = "AXValue" as CFString
        static let children = "AXChildren" as CFString
        static let focusedWindow = "AXFocusedWindow" as CFString
        static let focusedElement = "AXFocusedUIElement" as CFString
        static let parent = "AXParent" as CFString
        static let document = "AXDocument" as CFString
        static let url = "AXURL" as CFString
        static let protectedContent = "AXProtectedContent" as CFString
    }

    enum AXReader {
        static func copyValue(_ element: AXUIElement, attribute: CFString) -> CFTypeRef? {
            var value: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(element, attribute, &value)
            guard result == .success else { return nil }
            return value
        }

        static func string(_ element: AXUIElement, attribute: CFString) -> String? {
            guard let value = copyValue(element, attribute: attribute) else { return nil }
            if let string = value as? String { return string }
            if let url = value as? URL { return url.absoluteString }
            if let number = value as? NSNumber { return number.stringValue }
            return nil
        }

        static func bool(_ element: AXUIElement, attribute: CFString) -> Bool? {
            guard let value = copyValue(element, attribute: attribute) else { return nil }
            if let number = value as? NSNumber { return number.boolValue }
            return nil
        }

        static func element(_ element: AXUIElement, attribute: CFString) -> AXUIElement? {
            guard let value = copyValue(element, attribute: attribute) else { return nil }
            guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return (value as! AXUIElement)
        }

        static func elements(_ element: AXUIElement, attribute: CFString = AXAttribute.children) -> [AXUIElement] {
            guard let value = copyValue(element, attribute: attribute) else { return [] }
            return value as? [AXUIElement] ?? []
        }

        static func focusedWindow(for application: AXUIElement) -> AXUIElement? {
            element(application, attribute: AXAttribute.focusedWindow)
        }

        static func focusedElement(for application: AXUIElement) -> AXUIElement? {
            element(application, attribute: AXAttribute.focusedElement)
        }

        /// `NSWorkspace.frontmostApplication` remains the underlying application
        /// while transient system surfaces such as Control Center own keyboard or
        /// accessibility focus. The system-wide AX focus is therefore the more
        /// accurate foreground owner when available. This is one bounded AX read;
        /// callers retain their workspace value as the failure fallback.
        static func focusedApplicationProcessIdentifier() -> pid_t? {
            let systemWide = AXUIElementCreateSystemWide()
            AXUIElementSetMessagingTimeout(systemWide, 0.10)
            guard let application = element(
                systemWide,
                attribute: kAXFocusedApplicationAttribute as CFString
            ) else { return nil }
            var processIdentifier: pid_t = 0
            guard AXUIElementGetPid(application, &processIdentifier) == .success,
                processIdentifier > 0
            else { return nil }
            return processIdentifier
        }

        static func element(at point: CGPoint) -> AXUIElement? {
            let systemWide = AXUIElementCreateSystemWide()
            var result: AXUIElement?
            let error = AXUIElementCopyElementAtPosition(
                systemWide,
                Float(point.x),
                Float(point.y),
                &result
            )
            guard error == .success else { return nil }
            return result
        }

        /// Returns the closest actionable accessibility ancestor for a click. Web pages often
        /// report a static-text leaf at the pointer while the useful label and role live on its
        /// parent button or link. The original leaf is retained as a safe fallback.
        static func actionableElement(at point: CGPoint, maximumAncestorDepth: Int = 8) -> AXUIElement? {
            guard let leaf = element(at: point) else { return nil }
            var current: AXUIElement? = leaf
            var depth = 0
            while let element = current, depth <= maximumAncestorDepth {
                let role = string(element, attribute: AXAttribute.role) ?? ""
                if isActionableRole(role) { return element }
                current = self.element(element, attribute: AXAttribute.parent)
                depth += 1
            }
            return leaf
        }

        static func windowSnapshot(_ element: AXUIElement, config: RecorderConfig) -> WindowSnapshot {
            let title =
                config.captureWindowTitles
                ? StringSanitizer.clean(
                    string(element, attribute: AXAttribute.title), maxLength: config.maxStringLength)
                : nil

            return WindowSnapshot(
                title: title,
                role: StringSanitizer.clean(string(element, attribute: AXAttribute.role), maxLength: 128),
                subrole: StringSanitizer.clean(string(element, attribute: AXAttribute.subrole), maxLength: 128)
            )
        }

        static func elementSnapshot(_ element: AXUIElement, config: RecorderConfig) -> ElementSnapshot {
            let role = StringSanitizer.clean(string(element, attribute: AXAttribute.role), maxLength: 128)
            let subrole = StringSanitizer.clean(string(element, attribute: AXAttribute.subrole), maxLength: 128)
            let secure =
                bool(element, attribute: AXAttribute.protectedContent) == true
                || isSecure(role: role, subrole: subrole)

            guard config.captureElementLabels, !secure else {
                return ElementSnapshot(
                    role: role,
                    subrole: subrole,
                    title: nil,
                    label: nil,
                    identifier: nil,
                    isSecure: secure
                )
            }

            let title = StringSanitizer.clean(
                string(element, attribute: AXAttribute.title), maxLength: config.maxStringLength)
            let description =
                StringSanitizer.clean(
                    string(element, attribute: AXAttribute.description), maxLength: config.maxStringLength)
                ?? StringSanitizer.clean(
                    string(element, attribute: AXAttribute.roleDescription), maxLength: config.maxStringLength)
            let identifier = StringSanitizer.clean(string(element, attribute: AXAttribute.identifier), maxLength: 256)

            return ElementSnapshot(
                role: role,
                subrole: subrole,
                title: title,
                label: description,
                identifier: identifier,
                isSecure: secure
            )
        }

        /// Minimal secure-field check for the input fast path. It reads only fixed
        /// AX role/protection attributes and never reads the control value.
        static func isSecureElement(_ element: AXUIElement) -> Bool {
            let role = string(element, attribute: AXAttribute.role)
            let subrole = string(element, attribute: AXAttribute.subrole)
            return bool(element, attribute: AXAttribute.protectedContent) == true
                || isSecure(role: role, subrole: subrole)
        }

        static func browserChromeLabels(_ window: AXUIElement, limit: Int = 160) -> [String?] {
            var output: [String?] = []
            var queue: [AXUIElement] = [window]
            var index = 0
            var visited = 0

            while index < queue.count, visited < limit {
                let element = queue[index]
                index += 1
                visited += 1

                let role = string(element, attribute: AXAttribute.role)
                if role == "AXWebArea" {
                    continue
                }

                output.append(string(element, attribute: AXAttribute.title))
                output.append(string(element, attribute: AXAttribute.description))
                output.append(string(element, attribute: AXAttribute.roleDescription))
                output.append(string(element, attribute: AXAttribute.identifier))

                if queue.count < limit * 3 {
                    queue.append(contentsOf: elements(element))
                }
            }

            return output
        }

        /// Capability probe used for browsers and browser-like wrappers that are not in a
        /// maintained bundle list. It intentionally looks only for an accessibility web area;
        /// it does not depend on an application name such as Safari, Chrome, or any wrapper.
        static func containsWebArea(_ window: AXUIElement, maxNodes: Int = 220) -> Bool {
            var queue: [AXUIElement] = [window]
            var index = 0
            var visited = 0

            while index < queue.count, visited < maxNodes {
                let element = queue[index]
                index += 1
                visited += 1

                let role = string(element, attribute: AXAttribute.role) ?? ""
                if role == "AXWebArea" { return true }
                if role == "AXStaticText" { continue }

                if queue.count < maxNodes * 2 {
                    queue.append(contentsOf: elements(element))
                }
            }
            return false
        }

        static func browserURL(
            from window: AXUIElement,
            addressFieldMarkers: [String],
            maxNodes: Int = 320
        ) -> String? {
            for attribute in [AXAttribute.document, AXAttribute.url] {
                if let direct = string(window, attribute: attribute), looksLikeURL(direct) {
                    return direct
                }
            }

            let normalizedMarkers = addressFieldMarkers.map {
                $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            }
            let capabilityMarkers = [
                "address", "url", "location", "omnibox", "search field", "website",
                "adresse", "ubicación", "indirizzo", "endereço", "網址", "アドレス", "주소",
            ]

            var queue: [AXUIElement] = [window]
            var index = 0
            var visited = 0

            while index < queue.count, visited < maxNodes {
                let element = queue[index]
                index += 1
                visited += 1

                let role = string(element, attribute: AXAttribute.role) ?? ""

                // Many browsers expose the actual page URL on AXWebArea rather than on the
                // top-level window. Inspect that node before deliberately avoiding the full
                // document subtree, where link AXURL values would be false positives.
                if role == "AXWebArea" || role == "AXDocument" {
                    for attribute in [AXAttribute.document, AXAttribute.url] {
                        if let candidate = string(element, attribute: attribute), looksLikeURL(candidate) {
                            return candidate
                        }
                    }
                    continue
                }
                if role == "AXStaticText" { continue }

                let metadata = [
                    string(element, attribute: AXAttribute.title),
                    string(element, attribute: AXAttribute.description),
                    string(element, attribute: AXAttribute.roleDescription),
                    string(element, attribute: AXAttribute.identifier),
                ]
                .compactMap { $0 }
                .joined(separator: " ")
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)

                let isAddressLike = normalizedMarkers.contains {
                    metadata.localizedCaseInsensitiveContains($0)
                } || capabilityMarkers.contains {
                    metadata.localizedCaseInsensitiveContains($0)
                }
                let isEditableRole = role == "AXTextField" || role == "AXComboBox"

                if isAddressLike && isEditableRole,
                    let candidate = string(element, attribute: AXAttribute.value),
                    looksLikeURL(candidate)
                {
                    return candidate
                }

                if queue.count < maxNodes * 2 {
                    queue.append(contentsOf: elements(element))
                }
            }

            return nil
        }

        private static func isActionableRole(_ role: String) -> Bool {
            [
                "AXButton", "AXLink", "AXMenuItem", "AXMenuButton", "AXPopUpButton",
                "AXCheckBox", "AXRadioButton", "AXTab", "AXCell", "AXRow",
                "AXDisclosureTriangle", "AXTextField", "AXTextArea", "AXComboBox", "AXSlider",
            ].contains(role)
        }

        private static func isSecure(role: String?, subrole: String?) -> Bool {
            let joined = [role, subrole]
                .compactMap { $0 }
                .joined(separator: " ")
                .lowercased()

            return joined.contains("securetextfield")
                || joined.contains("password")
                || joined.contains("secure text")
        }

        private static func looksLikeURL(_ value: String) -> Bool {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return false }

            let lower = trimmed.lowercased()
            if lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("file://") {
                return true
            }
            if lower.hasPrefix("about:") || lower.hasPrefix("chrome:") || lower.hasPrefix("edge:")
                || lower.hasPrefix("brave:") || lower.hasPrefix("vivaldi:") || lower.hasPrefix("opera:")
            {
                return true
            }
            return trimmed.contains(".") && !trimmed.contains(" ")
        }
    }
#endif
