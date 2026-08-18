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

        static func browserURL(
            from window: AXUIElement,
            addressFieldMarkers: [String],
            maxNodes: Int = 260
        ) -> String? {
            for attribute in [AXAttribute.document, AXAttribute.url] {
                if let direct = string(window, attribute: attribute), looksLikeURL(direct) {
                    return direct
                }
            }

            let normalizedMarkers = addressFieldMarkers.map {
                $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            }

            var queue: [AXUIElement] = [window]
            var index = 0
            var visited = 0

            while index < queue.count, visited < maxNodes {
                let element = queue[index]
                index += 1
                visited += 1

                let role = string(element, attribute: AXAttribute.role) ?? ""
                if role == "AXWebArea" || role == "AXStaticText" {
                    continue
                }

                let metadata = [
                    string(element, attribute: AXAttribute.title),
                    string(element, attribute: AXAttribute.description),
                    string(element, attribute: AXAttribute.roleDescription),
                    string(element, attribute: AXAttribute.identifier),
                ]
                .compactMap { $0 }
                .joined(separator: " ")
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)

                let isAddressLike = normalizedMarkers.contains { metadata.localizedCaseInsensitiveContains($0) }
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
                || lower.hasPrefix("brave:")
            {
                return true
            }
            return trimmed.contains(".") && !trimmed.contains(" ")
        }
    }
#endif
