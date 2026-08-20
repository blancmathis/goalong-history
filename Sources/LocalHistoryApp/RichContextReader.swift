#if os(macOS)
    import AppKit
    import Carbon
    import ApplicationServices
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

        static func capture(processIdentifier: pid_t, maximumCharacters: Int) -> AXRichContextCapture? {
            guard !IsSecureEventInputEnabled() else { return nil }
            let application = AXUIElementCreateApplication(processIdentifier)
            AXUIElementSetMessagingTimeout(application, 0.35)
            guard let window = AXReader.focusedWindow(for: application) else { return nil }

            var snippets: [String] = []
            var sources: [String] = []
            var rawCharacterCount = 0
            var truncated = false

            if let focused = AXReader.focusedElement(for: application), !isSecure(focused) {
                if let selected = sanitized(AXReader.string(focused, attribute: selectedText), maximum: 1_200) {
                    snippets.append(selected)
                    sources.append("selected")
                    rawCharacterCount += selected.count
                }
                let focusedRole = AXReader.string(focused, attribute: role) ?? ""
                if shouldReadValue(role: focusedRole),
                    let focusedValue = sanitized(AXReader.string(focused, attribute: value), maximum: 1_200)
                {
                    snippets.append(focusedValue)
                    sources.append("focused")
                    rawCharacterCount += focusedValue.count
                }
            }

            var queue: [AXUIElement] = [window]
            var index = 0
            var visited = 0
            while index < queue.count, visited < 260, rawCharacterCount < maximumCharacters * 2 {
                let element = queue[index]
                index += 1
                visited += 1
                guard !isSecure(element) else { continue }

                let elementRole = AXReader.string(element, attribute: role) ?? ""
                if shouldReadVisibleText(role: elementRole) {
                    for attribute in [title, description, value] {
                        if let text = sanitized(AXReader.string(element, attribute: attribute), maximum: 700) {
                            snippets.append(text)
                            rawCharacterCount += text.count
                        }
                    }
                }

                if queue.count < 600 {
                    queue.append(contentsOf: AXReader.elements(element, attribute: children))
                }
            }
            if visited >= 260 || rawCharacterCount >= maximumCharacters * 2 { truncated = true }

            var seen = Set<String>()
            var output: [String] = []
            var outputCount = 0
            for snippet in snippets {
                let key = normalized(snippet)
                guard key.count >= 3, seen.insert(key).inserted, !isGenericUIString(key) else { continue }
                let separatorCount = output.isEmpty ? 0 : 1
                let available = maximumCharacters - outputCount - separatorCount
                guard available > 24 else {
                    truncated = true
                    break
                }
                let bounded = snippet.count <= available ? snippet : String(snippet.prefix(available))
                output.append(bounded)
                outputCount += bounded.count + separatorCount
                if bounded.count < snippet.count {
                    truncated = true
                    break
                }
            }

            let joined = output.joined(separator: "\n")
            guard let cleaned = ActivitySemanticTextSanitizer.clean(joined, maximumLength: maximumCharacters),
                cleaned.count >= 12
            else { return nil }
            let redacted = cleaned.contains("[REDACTED")
            let source = Array(Set(sources + ["visible"])).sorted().joined(separator: "+")
            return AXRichContextCapture(
                text: cleaned,
                source: source,
                redacted: redacted,
                truncated: truncated || cleaned.count < joined.count,
                fingerprint: stableFingerprint(cleaned)
            )
        }

        private static func shouldReadValue(role: String) -> Bool {
            ["AXTextArea", "AXTextField", "AXDocument", "AXWebArea", "AXStaticText"].contains(role)
        }

        private static func shouldReadVisibleText(role: String) -> Bool {
            [
                "AXStaticText", "AXHeading", "AXLink", "AXTextArea", "AXTextField",
                "AXDocument", "AXWebArea", "AXDescriptionList", "AXListItem",
            ].contains(role)
        }

        private static func isSecure(_ element: AXUIElement) -> Bool {
            if AXReader.bool(element, attribute: protectedContent) == true { return true }
            let roleValue = (AXReader.string(element, attribute: role) ?? "").lowercased()
            return roleValue.contains("secure") || roleValue.contains("password")
        }

        private static func sanitized(_ value: String?, maximum: Int) -> String? {
            guard let cleaned = ActivitySemanticTextSanitizer.clean(value, maximumLength: maximum) else { return nil }
            guard cleaned.count >= 3 else { return nil }
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
                "back", "forward", "reload", "share", "close", "minimize", "zoom", "search",
                "new tab", "address and search bar", "toolbar", "sidebar", "window", "button",
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
