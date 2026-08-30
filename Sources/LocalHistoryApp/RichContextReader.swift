#if os(macOS)
    import AppKit
    import ApplicationServices
    import Carbon
    import Foundation
    import LocalHistoryCore

    struct AXRichContextCapture {
        let text: String
        let source: String
        let redacted: Bool
        let truncated: Bool
        let fingerprint: String
    }

    enum AXRichContextReader {
        private static let selectedText = "AXSelectedText" as CFString
        private static let role = "AXRole" as CFString
        private static let title = "AXTitle" as CFString
        private static let description = "AXDescription" as CFString
        private static let value = "AXValue" as CFString
        private static let protectedContent = "AXProtectedContent" as CFString
        private static let children = "AXChildren" as CFString
        private static let visibleChildren = "AXVisibleChildren" as CFString
        private static let parent = "AXParent" as CFString

        static func capture(
            processIdentifier: pid_t,
            maximumCharacters: Int,
            maximumNodes: Int = 260
        ) -> AXRichContextCapture? {
            guard !IsSecureEventInputEnabled() else { return nil }
            let characterLimit = min(max(maximumCharacters, 256), 20_000)
            let nodeLimit = min(max(maximumNodes, 0), 600)
            let application = AXUIElementCreateApplication(processIdentifier)
            AXUIElementSetMessagingTimeout(application, 0.35)
            guard let window = AXReader.focusedWindow(for: application) else { return nil }

            var snippets: [String] = []
            var sources: [String] = []
            var rawCharacterCount = 0
            var truncated = false
            var addedVisibleText = false

            let focusedElement = AXReader.focusedElement(for: application)
            if let focused = focusedElement {
                let focusedRole = AXReader.string(focused, attribute: role) ?? ""
                if !isSecure(focused, role: focusedRole) {
                    if let selected = sanitized(
                        AXReader.string(focused, attribute: selectedText),
                        maximum: min(1_200, characterLimit)
                    ) {
                        snippets.append(selected)
                        sources.append("selected")
                        rawCharacterCount += selected.count
                    }
                    if shouldReadValue(role: focusedRole),
                        let focusedValue = sanitized(
                            AXReader.string(focused, attribute: value),
                            maximum: min(1_800, characterLimit)
                        )
                    {
                        snippets.append(focusedValue)
                        sources.append("focused")
                        rawCharacterCount += focusedValue.count
                    }
                }
            }

            if nodeLimit > 0 {
                // Start where the user is acting, then widen through its ancestors and
                // the window. For large browser/app trees, prefer visible children and
                // fall back to all children only when the app exposes no visible subset.
                // This raises useful text per AX call while keeping the same hard budgets.
                var queue: [AXUIElement] = []
                var enqueued = Set<CFHashCode>()
                func enqueue(_ element: AXUIElement) {
                    let identity = CFHash(element)
                    guard enqueued.insert(identity).inserted,
                        queue.count < nodeLimit * 2
                    else { return }
                    queue.append(element)
                }
                if let focusedElement {
                    enqueue(focusedElement)
                    var ancestor = AXReader.element(focusedElement, attribute: parent)
                    var depth = 0
                    while let current = ancestor, depth < 5 {
                        enqueue(current)
                        ancestor = AXReader.element(current, attribute: parent)
                        depth += 1
                    }
                }
                enqueue(window)
                var index = 0
                var visited = 0
                while index < queue.count,
                    visited < nodeLimit,
                    rawCharacterCount < characterLimit * 2
                {
                    let element = queue[index]
                    index += 1
                    visited += 1
                    let elementRole = AXReader.string(element, attribute: role) ?? ""
                    guard !isSecure(element, role: elementRole) else { continue }
                    if shouldReadVisibleText(role: elementRole) {
                        for attribute in [title, description, value] {
                            if let text = sanitized(
                                AXReader.string(element, attribute: attribute),
                                maximum: 700
                            ) {
                                snippets.append(text)
                                rawCharacterCount += text.count
                                addedVisibleText = true
                            }
                        }
                    }

                    if shouldTraverseChildren(role: elementRole) {
                        let visible = AXReader.elements(
                            element,
                            attribute: visibleChildren
                        )
                        let descendants = visible.isEmpty
                            ? AXReader.elements(element, attribute: children)
                            : visible
                        for child in descendants { enqueue(child) }
                    }
                }
                if index < queue.count || rawCharacterCount >= characterLimit * 2 {
                    truncated = true
                }
            }
            if addedVisibleText { sources.append("visible") }

            var seen = Set<String>()
            var output: [String] = []
            var outputCount = 0
            for snippet in snippets {
                let key = normalized(snippet)
                guard key.count >= 3,
                    seen.insert(key).inserted,
                    !isGenericUIString(key)
                else { continue }
                let separatorCount = output.isEmpty ? 0 : 1
                let available = characterLimit - outputCount - separatorCount
                guard available > 24 else {
                    truncated = true
                    break
                }
                let bounded = snippet.count <= available
                    ? snippet
                    : String(snippet.prefix(available))
                output.append(bounded)
                outputCount += bounded.count + separatorCount
                if bounded.count < snippet.count {
                    truncated = true
                    break
                }
            }

            let joined = output.joined(separator: "\n")
            guard let cleaned = ActivitySemanticTextSanitizer.clean(
                joined,
                maximumLength: characterLimit
            ), cleaned.count >= 12 else { return nil }
            return AXRichContextCapture(
                text: cleaned,
                source: Array(Set(sources)).sorted().joined(separator: "+"),
                redacted: cleaned.contains("[REDACTED"),
                truncated: truncated || cleaned.count < joined.count,
                fingerprint: stableFingerprint(cleaned)
            )
        }

        private static func shouldReadValue(role: String) -> Bool {
            ["AXTextArea", "AXTextField", "AXDocument", "AXWebArea", "AXStaticText"]
                .contains(role)
        }

        private static func shouldReadVisibleText(role: String) -> Bool {
            [
                "AXStaticText", "AXHeading", "AXLink", "AXTextArea", "AXTextField",
                "AXDocument", "AXWebArea", "AXDescriptionList", "AXListItem",
            ].contains(role)
        }

        private static func shouldTraverseChildren(role: String) -> Bool {
            ![
                "AXStaticText", "AXHeading", "AXTextArea", "AXTextField",
            ].contains(role)
        }

        private static func isSecure(_ element: AXUIElement, role: String) -> Bool {
            if AXReader.bool(element, attribute: protectedContent) == true { return true }
            let roleValue = role.lowercased()
            return roleValue.contains("secure") || roleValue.contains("password")
        }

        private static func sanitized(_ value: String?, maximum: Int) -> String? {
            guard let cleaned = ActivitySemanticTextSanitizer.clean(
                value,
                maximumLength: maximum
            ), cleaned.count >= 3 else { return nil }
            return cleaned
        }

        private static func normalized(_ value: String) -> String {
            value
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }

        private static func isGenericUIString(_ value: String) -> Bool {
            let generic: Set<String> = [
                "back", "forward", "reload", "share", "close", "minimize", "zoom",
                "search", "new tab", "address and search bar", "toolbar", "sidebar",
                "window", "button",
            ]
            return generic.contains(value)
        }

        private static func stableFingerprint(_ value: String) -> String {
            var hash: UInt64 = 14_695_981_039_346_656_037
            for byte in value.utf8 {
                hash ^= UInt64(byte)
                hash &*= 1_099_511_628_211
            }
            return String(format: "%016llx", hash)
        }
    }
#endif
