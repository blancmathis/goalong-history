#if os(macOS)
import AppKit
import ApplicationServices
import Carbon
import Foundation
import LocalHistoryCore

/// Called on the context monitor's main-thread path. AX traversal is serialized
/// off the main thread, with one pending read, a node cap and a wall-time budget.
/// This does not enable collection, grant permissions, persist text or make requests.
final class JevVisibleContextSampler {
    private let queue = DispatchQueue(label: "ai.goalong.jev.visible-context", qos: .utility)
    private var pending = false
    private var generation: UInt64 = 0
    private var nextProbe: TimeInterval = 0
    private let inbox = JevIngress.shared

    func invalidate() { generation &+= 1; nextProbe = 0 }

    static func eligible(remoteText: Bool, localText: Bool, context: ContextSnapshot,
                         presence: ForegroundUsageObservation) -> Bool {
        remoteText && localText && context.suppressionReason == nil
            && context.focusedElement?.isSecure != true
            && JevIngress.shouldSampleForeground(presence: presence, evidence: presence.evidence)
    }
    static func sameBoundary(_ current: ContextSnapshot, _ expected: ContextSnapshot) -> Bool {
        current.suppressionReason == nil && current.focusedElement?.isSecure != true
            && current.app.processIdentifier == expected.app.processIdentifier
            && current.fingerprint == expected.fingerprint
            && current.privacyRevision == expected.privacyRevision
            && current.globalPauseRevision == expected.globalPauseRevision
    }

    func observe(_ context: ContextSnapshot, presence: ForegroundUsageObservation,
                 revalidate: @escaping () -> ContextSnapshot?) {
        guard Self.eligible(remoteText: inbox.wantsVisibleText,
                            localText: ActivityAnalysisPreferences.richContextEnabled,
                            context: context, presence: presence),
              ForegroundSessionAvailability.isAvailable(), !IsSecureEventInputEnabled() else {
            invalidate(); return
        }
        let uptime = ProcessInfo.processInfo.systemUptime
        guard !pending, uptime >= nextProbe else { return }
        nextProbe = uptime + JevIngress.foregroundSampleInterval
        pending = true
        let ownGeneration = generation, ingressGeneration = inbox.generation
        let capturedAt = Date()
        let browser = ForegroundActivityProbe.isBrowser(context)
        queue.async { [weak self] in
            let text = JevVisibleTextReader.capture(processIdentifier: context.app.processIdentifier, browser: browser)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                defer { self.pending = false }
                guard let text, Date().timeIntervalSince(capturedAt) < 2,
                      let current = revalidate(),
                      self.generation == ownGeneration, self.inbox.generation == ingressGeneration,
                      Self.sameBoundary(current, context),
                      let freshPresence = current.foregroundUsage,
                      Self.eligible(remoteText: self.inbox.wantsVisibleText,
                                    localText: ActivityAnalysisPreferences.richContextEnabled,
                                    context: current, presence: freshPresence),
                      ForegroundSessionAvailability.isAvailable(), !IsSecureEventInputEnabled(),
                      JevIngress.permitsLiveContext(current) else { return }
                self.inbox.offerVisibleText(text, context: current, at: capturedAt, generation: ingressGeneration)
            }
        }
    }
}

/// Read-only text policy is separate from local rich capture. Editable values,
/// selected text, hidden nodes, off-viewport content and toolbar/tab labels are excluded.
enum JevVisibleTextPolicy {
    static func permitsTraversal(role: String, hidden: Bool, protected: Bool, editable: Bool) -> Bool {
        guard !hidden, !protected, !editable else { return false }
        let role = role.lowercased()
        return !role.contains("secure") && !role.contains("password")
            && !["axtextfield", "axtextarea", "axcombobox", "axsearchfield", "axtoolbar",
                 "axmenubar", "axmenu", "axtabgroup", "axbutton"].contains(role)
    }
    static func isText(role: String) -> Bool { ["AXStaticText", "AXHeading", "AXLink"].contains(role) }
    static func isVisible(_ frame: CGRect?, in viewport: CGRect) -> Bool {
        guard let frame, !frame.isEmpty, !frame.isInfinite, !frame.isNull,
              frame.origin.x.isFinite, frame.origin.y.isFinite,
              frame.width.isFinite, frame.height.isFinite else { return false }
        return frame.intersects(viewport)
    }
    static func compact(_ snippets: [String]) -> String {
        let generic: Set<String> = ["home", "accueil", "for you", "pour vous", "following", "abonnements",
            "notifications", "messages", "search", "recherche", "explore", "explorer", "subscribe", "s'abonner"]
        var seen = Set<String>(), values: [String] = []
        for snippet in snippets {
            let value = JevIngress.redactedText(snippet, limit: 112)
            guard value.count >= 12, !generic.contains(value.lowercased()), seen.insert(value).inserted else { continue }
            values.append(value)
        }
        return JevPayload.clean(values.joined(separator: " | "), bytes: 224)
    }
}

/// No browser scripting, screenshots, audio, clipboard or input field access.
/// Browser text is restricted to the focused window's current web area.
enum JevVisibleTextReader {
    static func capture(processIdentifier pid: pid_t, browser: Bool) -> String? {
        guard AXIsProcessTrusted(), !IsSecureEventInputEnabled(), !GoalongGlobalPause.isPaused(),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return nil }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.20
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.025)
        func value(_ node: AXUIElement, _ attribute: String) -> CFTypeRef? {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
            var result: CFTypeRef?
            guard AXUIElementCopyAttributeValue(node, attribute as CFString, &result) == .success else { return nil }
            return result
        }
        func element(_ node: AXUIElement, _ attribute: String) -> AXUIElement? {
            guard let result = value(node, attribute), CFGetTypeID(result) == AXUIElementGetTypeID() else { return nil }
            return unsafeBitCast(result, to: AXUIElement.self)
        }
        func frame(_ node: AXUIElement) -> CGRect? {
            guard let position = value(node, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
                  let size = value(node, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
            var point = CGPoint.zero, dimensions = CGSize.zero
            guard AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &point),
                  AXValueGetValue(unsafeBitCast(size, to: AXValue.self), .cgSize, &dimensions) else { return nil }
            return CGRect(origin: point, size: dimensions)
        }
        func children(_ node: AXUIElement) -> [AXUIElement] {
            // Contents leads directly into the selected web document in Safari.
            for key in ["AXContents", "AXVisibleChildren", kAXChildrenAttribute] {
                if let result = value(node, key) as? [AXUIElement], !result.isEmpty { return Array(result.prefix(200)) }
            }
            return []
        }
        guard let window = element(app, kAXFocusedWindowAttribute), let windowFrame = frame(window),
              !windowFrame.isEmpty else { return nil }
        let initialFocus = element(app, kAXFocusedUIElementAttribute)
        func findWebArea() -> AXUIElement? {
            var ancestor = initialFocus
            for _ in 0..<10 {
                guard let node = ancestor else { break }
                if value(node, kAXRoleAttribute) as? String == "AXWebArea" { return node }
                ancestor = element(node, kAXParentAttribute)
            }
            var queue = [window], index = 0, seen = Set<CFHashCode>()
            while index < queue.count, index < 100, ProcessInfo.processInfo.systemUptime < deadline {
                let node = queue[index]; index += 1
                guard seen.insert(CFHash(node)).inserted, value(node, "AXHidden") as? Bool != true else { continue }
                let role = value(node, kAXRoleAttribute) as? String ?? ""
                if role == "AXWebArea" { return node }
                guard !["AXToolbar", "AXMenuBar", "AXTabGroup", "AXTextField", "AXTextArea"].contains(role) else { continue }
                queue.append(contentsOf: children(node).prefix(max(0, 200 - queue.count)))
            }
            return nil
        }
        let root: AXUIElement
        if browser {
            guard let web = findWebArea() else { return nil }
            root = web
        } else { root = window }
        let viewport = (frame(root) ?? windowFrame).intersection(windowFrame)
        guard !viewport.isEmpty else { return nil }
        var queue = [root], index = 0, seen = Set<CFHashCode>()
        var content: [String] = [], links: [String] = []
        while index < queue.count, index < 200, ProcessInfo.processInfo.systemUptime < deadline {
            let node = queue[index]; index += 1
            guard seen.insert(CFHash(node)).inserted else { continue }
            let role = value(node, kAXRoleAttribute) as? String ?? ""
            guard JevVisibleTextPolicy.permitsTraversal(role: role,
                hidden: value(node, "AXHidden") as? Bool == true,
                protected: value(node, "AXProtectedContent") as? Bool == true,
                editable: value(node, "AXEditable") as? Bool == true) else { continue }
            let bounds = frame(node)
            if let bounds, !bounds.isEmpty, !bounds.intersects(viewport) { continue }
            if JevVisibleTextPolicy.isText(role: role), JevVisibleTextPolicy.isVisible(bounds, in: viewport) {
                // Values are read ONLY for explicitly read-only roles after all gates.
                for attribute in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
                    guard let text = value(node, attribute) as? String, text.count >= 12 else { continue }
                    if role == "AXLink" { links.append(String(text.prefix(512))) }
                    else { content.append(String(text.prefix(512))) }
                    break
                }
            }
            queue.append(contentsOf: children(node).prefix(max(0, 400 - queue.count)))
        }
        // Use a separate tiny verification budget; never return a timed-out stale
        // window or a capture taken while another application acquired focus.
        guard !IsSecureEventInputEnabled(), !GoalongGlobalPause.isPaused(),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return nil }
        var finalWindow: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &finalWindow) == .success,
              let finalWindow, CFEqual(window, finalWindow) else { return nil }
        let text = JevVisibleTextPolicy.compact(content + links)
        return text.isEmpty ? nil : text
    }
}
#endif
