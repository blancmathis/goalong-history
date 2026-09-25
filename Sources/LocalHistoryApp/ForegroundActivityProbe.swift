#if os(macOS)
import AppKit
import Carbon
import Darwin
import Foundation
import IOKit.pwr_mgt
import LocalHistoryCore

/// The SDK specifies kCGAnyInputEventType (all UInt32 bits set), not the
/// distinct null event. The C macro is not imported by Swift, so bridge its
/// documented raw value. Used by recording and semantic sampling alike.
enum UserInputActivityClock {
    static let anyInputEventType = CGEventType(rawValue: UInt32.max)!

    static func secondsSinceLastInput(
        reader: (CGEventSourceStateID, CGEventType) -> TimeInterval = {
            CGEventSource.secondsSinceLastEventType($0, eventType: $1)
        }
    ) -> TimeInterval {
        reader(.combinedSessionState, anyInputEventType)
    }
}

/// Local, content-free OS evidence plus optional, bounded focused-window control
/// checks. Never captures audio/video, requests a new permission, launches a shell,
/// or uses global audio/CPU activity as evidence that the foreground app is in use.
final class ForegroundActivityProbe {
    static let interval: TimeInterval = 10
    private var cachedContext: ContextSnapshot?
    private var cachedLabelsEnabled = false
    private var nextProbe: TimeInterval = 0
    private var cachedEvidence: ForegroundActivityEvidence?
    private var visiblePID: pid_t = 0
    private var visibleUntil: TimeInterval = 0
    private var cachedVisible = false

    func observe(_ context: ContextSnapshot, labelsEnabled: Bool, idleSeconds: TimeInterval,
                 idleLimitSeconds: Int, at date: Date) -> ForegroundUsageObservation {
        let evidence = sample(context, labelsEnabled: labelsEnabled)
        var visible = false
        if !IsSecureEventInputEnabled(), !GoalongGlobalPause.isPaused(),
           let front = NSWorkspace.shared.frontmostApplication,
           Self.isEligibleForeground(context, frontmostPID: front.processIdentifier, isHidden: front.isHidden) {
            let now = ProcessInfo.processInfo.systemUptime
            if visiblePID != front.processIdentifier || now >= visibleUntil {
                visiblePID = front.processIdentifier
                cachedVisible = Self.hasVisibleWindow(pid: front.processIdentifier)
                visibleUntil = now + 1
            }
            visible = cachedVisible
        }
        return ForegroundUsageObservation(observedAt: date, idleSeconds: idleSeconds,
            idleLimitSeconds: idleLimitSeconds, isForegroundVisible: visible,
            evidence: visible ? evidence : nil)
    }

    func reset() {
        cachedContext = nil; cachedEvidence = nil; nextProbe = 0
        visiblePID = 0; visibleUntil = 0; cachedVisible = false
    }

    func sample(_ context: ContextSnapshot, labelsEnabled: Bool) -> ForegroundActivityEvidence? {
        guard context.suppressionReason == nil, context.focusedElement?.isSecure != true,
              !IsSecureEventInputEnabled(), !GoalongGlobalPause.isPaused(),
              let front = NSWorkspace.shared.frontmostApplication,
              Self.isEligibleForeground(context, frontmostPID: front.processIdentifier,
                                        isHidden: front.isHidden) else { reset(); return nil }
        let now = ProcessInfo.processInfo.systemUptime
        let same = cachedContext.map {
            $0.app == context.app && $0.window == context.window && $0.url == context.url
                && $0.privacyRevision == context.privacyRevision
                && $0.globalPauseRevision == context.globalPauseRevision
        } ?? false
        if now < nextProbe {
            if same, cachedLabelsEnabled == labelsEnabled { return cachedEvidence }
            // A changed app/window/tab invalidates evidence immediately, but must
            // not turn fast title changes into repeated AX walks on the main thread.
            cachedContext = nil; cachedEvidence = nil
            return nil
        }
        cachedContext = context; cachedLabelsEnabled = labelsEnabled
        nextProbe = now + Self.interval; cachedEvidence = nil

        guard Self.hasVisibleWindow(pid: front.processIdentifier) else { return nil }
        let browser = Self.isBrowser(context)
        let controls = labelsEnabled && AXIsProcessTrusted() ? ForegroundPlaybackControls.probe(context) : .unknown
        let holdsDisplay = Self.holdsDisplayAssertion(pid: front.processIdentifier, bundleURL: front.bundleURL)
        let evidence = Self.resolve(
            isBrowser: browser,
            isCallApplication: Self.isCallApplication(front.bundleIdentifier),
            control: controls,
            holdsDisplayAssertion: holdsDisplay
        )
        // Reject a result when focus/privacy changed during the synchronous probe.
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == front.processIdentifier,
              !IsSecureEventInputEnabled(), !GoalongGlobalPause.isPaused() else { reset(); return nil }
        cachedEvidence = evidence
        return evidence
    }

    static func isEligibleForeground(_ context: ContextSnapshot, frontmostPID: pid_t, isHidden: Bool) -> Bool {
        // OS process evidence does not require permission to read window titles
        // or controls. A visible window is checked separately through CoreGraphics.
        context.suppressionReason == nil && context.focusedElement?.isSecure != true
            && context.app.processIdentifier > 0 && context.app.processIdentifier == frontmostPID && !isHidden
    }

    static func resolve(isBrowser: Bool, isCallApplication: Bool,
                        control: ForegroundPlaybackControls.State, holdsDisplayAssertion: Bool) -> ForegroundActivityEvidence? {
        switch control {
        case .playing: return .mediaPlayback
        case .call: return .call
        case .stopped: return nil
        case .unknown: break
        }
        guard holdsDisplayAssertion else { return nil }
        // This proves use of the foreground PROCESS, not of a specific browser
        // tab. Process-only evidence counts app time but never website time or
        // realtime semantic monitoring (those require focused controls/input).
        return !isBrowser && isCallApplication ? .call : .displayAssertion
    }

    static func isBrowser(_ context: ContextSnapshot) -> Bool {
        // Treat web wrappers conservatively too: an app-wide assertion cannot
        // establish which page is playing. The provider already privacy-gates URLs.
        if let scheme = context.url.flatMap({ URLComponents(string: $0.value)?.scheme }),
           ["http", "https"].contains(scheme.lowercased()) { return true }
        if RecorderConfig.default.browserBundleIdentifiers.contains(context.app.bundleIdentifier ?? "") { return true }
        let identity = (context.app.name + " " + (context.app.bundleIdentifier ?? "")).lowercased()
        return ["safari", "chrome", "chromium", "firefox", "librewolf", "floorp", "edge", "brave",
                "arc", "opera", "vivaldi", "orion", "duckduckgo", "browser", "sigmaos"].contains { identity.contains($0) }
    }

    static func isCallApplication(_ identifier: String?) -> Bool {
        guard let id = identifier?.lowercased() else { return false }
        return ["us.zoom.xos", "com.microsoft.teams", "com.microsoft.teams2",
                "com.apple.facetime", "com.cisco.webexmeetingsapp", "com.webex.meetingmanager",
                "com.hnc.discord", "com.skype.skype"].contains(id)
    }

    private static func hasVisibleWindow(pid: pid_t) -> Bool {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                      kCGNullWindowID) as? [[String: Any]] else { return false }
        return windows.contains {
            ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid
                && ($0[kCGWindowLayer as String] as? NSNumber)?.intValue == 0
                && (($0[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 0) > 0
        }
    }

    static func assertionOwnerMatches(ownerPID: pid_t, foregroundPID: pid_t,
                                      ownerExecutable: String?, foregroundBundlePath: String?) -> Bool {
        guard ownerPID > 0, foregroundPID > 0 else { return false }
        if ownerPID == foregroundPID { return true }
        // Helpers embedded in this exact .app are allowed. Prefix lookalikes,
        // system daemons, caffeinate and unrelated background apps are not.
        guard let ownerExecutable, let foregroundBundlePath,
              foregroundBundlePath.hasSuffix(".app") else { return false }
        return ownerExecutable.hasPrefix(foregroundBundlePath + "/Contents/")
    }

    static func isDisplayAssertion(type: String?, level: Int?) -> Bool {
        type == kIOPMAssertPreventUserIdleDisplaySleep && level == Int(kIOPMAssertionLevelOn)
    }

    static func holdsDisplayAssertion(pid: pid_t, bundleURL: URL?) -> Bool {
        var unmanaged: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&unmanaged) == kIOReturnSuccess,
              let dictionary = unmanaged?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return false }
        let bundlePath = bundleURL?.resolvingSymlinksInPath().path
        for (owner, assertions) in dictionary {
            guard assertions.contains(where: {
                isDisplayAssertion(type: $0[kIOPMAssertionTypeKey] as? String,
                                   level: ($0[kIOPMAssertionLevelKey] as? NSNumber)?.intValue)
            }) else { continue }
            let ownerPID = owner.int32Value
            var path: String?
            if ownerPID != pid {
                var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
                if proc_pidpath(ownerPID, &buffer, UInt32(buffer.count)) > 0 {
                    path = URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath().path
                }
            }
            if assertionOwnerMatches(ownerPID: ownerPID, foregroundPID: pid,
                                     ownerExecutable: path, foregroundBundlePath: bundlePath) { return true }
        }
        return false
    }
}

/// Only called when control-label capture is already authorized. Reads the
/// focused window, not all windows/tabs; retains only the resulting enum.
enum ForegroundPlaybackControls {
    enum State { case unknown, playing, call, stopped }

    static func state(role: String, labels: [String], enabled: Bool = true, nativeCall: Bool = false) -> State {
        guard enabled, role.lowercased() == "axbutton" else { return .unknown }
        let labels = labels.map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
        if labels.contains(where: { ["pause", "pause (k)", "mettre en pause", "mettre en pause (k)",
                                     "pause playback", "pause video", "pause (space)", "pause (espace)",
                                     "mettre la vidéo en pause", "pause video playback"].contains($0) }) { return .playing }
        if labels.contains(where: { ["leave meeting", "leave call", "end call", "end meeting",
                                     "end meeting for all", "quitter la réunion", "quitter la réunion zoom",
                                     "quitter l’appel", "quitter l'appel", "raccrocher", "terminer l’appel",
                                     "terminer l'appel", "mettre fin à la réunion"].contains($0) }) { return .call }
        if nativeCall, labels.contains(where: { ["leave", "end", "quitter", "fin"].contains($0) }) { return .call }
        if labels.contains(where: { ["play", "play (k)", "lire", "lire (k)", "lecture", "replay",
                                     "revoir", "play video", "playback"].contains($0) }) { return .stopped }
        return .unknown
    }

    static func probe(_ context: ContextSnapshot) -> State {
        // Do not walk arbitrary editors/documents looking for the word Pause.
        let isBrowser = ForegroundActivityProbe.isBrowser(context)
        let native = ForegroundActivityProbe.isCallApplication(context.app.bundleIdentifier)
            || ["com.apple.QuickTimePlayerX", "org.videolan.vlc", "com.colliderli.iina",
                "com.apple.TV", "com.apple.Music", "com.spotify.client", "com.apple.iWork.Keynote"]
                .contains(context.app.bundleIdentifier ?? "")
        guard isBrowser || native else { return .unknown }
        let application = AXUIElementCreateApplication(context.app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.025)
        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &windowValue) == .success,
              let windowValue, CFGetTypeID(windowValue) == AXUIElementGetTypeID() else { return .unknown }
        let window = unsafeBitCast(windowValue, to: AXUIElement.self)
        let deadline = ProcessInfo.processInfo.systemUptime + 0.10
        var queue: [AXUIElement] = [window]
        // Check the focused control/document first, but only after proving its
        // ancestor chain belongs to this exact focused window. This avoids
        // exhausting the budget on browser chrome before reaching the player.
        var focusValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &focusValue) == .success,
           let focusValue, CFGetTypeID(focusValue) == AXUIElementGetTypeID() {
            var current = unsafeBitCast(focusValue, to: AXUIElement.self)
            var seeds: [AXUIElement] = []
            for _ in 0..<8 {
                guard ProcessInfo.processInfo.systemUptime < deadline else { break }
                if CFEqual(current, window) { queue = seeds + [window]; break }
                seeds.append(current)
                var parent: CFTypeRef?
                guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parent) == .success,
                      let parent, CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
                current = unsafeBitCast(parent, to: AXUIElement.self)
            }
        }
        var seen = Set<CFHashCode>()
        var index = 0, sawStopped = false
        while index < queue.count, index < 192, ProcessInfo.processInfo.systemUptime < deadline {
            let element = queue[index]; index += 1
            guard seen.insert(CFHash(element)).inserted else { continue }
            func value(_ attribute: String) -> CFTypeRef? {
                guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
                var result: CFTypeRef?
                guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else { return nil }
                return result
            }
            if (value("AXHidden") as? Bool) == true { continue }
            let role = value(kAXRoleAttribute) as? String ?? ""
            if role == kAXButtonRole {
                let result = state(role: role, labels: [value(kAXTitleAttribute) as? String ?? "",
                    value(kAXDescriptionAttribute) as? String ?? ""], enabled: value(kAXEnabledAttribute) as? Bool ?? true,
                    nativeCall: ForegroundActivityProbe.isCallApplication(context.app.bundleIdentifier))
                if result == .playing || result == .call { return result }
                if result == .stopped { sawStopped = true }
            }
            for key in ["AXContents", "AXVisibleChildren", kAXChildrenAttribute] {
                if let children = value(key) as? [AXUIElement], !children.isEmpty {
                    queue.append(contentsOf: children.prefix(max(0, 192 - queue.count)))
                    break
                }
            }
        }
        return sawStopped ? .stopped : .unknown
    }
}
#endif
