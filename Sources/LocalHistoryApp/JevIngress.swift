#if os(macOS)
import AppKit
import Carbon
import Foundation
import LocalHistoryCore

extension Notification.Name {
    static let jevBoundaryChanged = Notification.Name("goalong.jev.boundary")
}

/// A bounded, transient projection of already-authorized capture; never holds a
/// HistoryEvent, URL query, input text, screenshot or full semantic payload.
final class JevIngress: @unchecked Sendable {
    static let shared = JevIngress()
    private let lock = NSLock()
    private var enabled = false
    private var includeText = false
    private var enabledAt = Date.distantFuture
    private var samples: [JevSample] = []
    private var excerpts: [String: (Date, String)] = [:]
    private var overflow = false
    private var blocked = false
    private var privateWindow = false
    private var revision: UInt64 = 0
    private var nextPlaybackProbe = Date.distantPast

    var isEnabled: Bool { lock.lock(); defer { lock.unlock() }; return enabled }
    func setPrivateWindow(_ value: Bool) {
        lock.lock(); privateWindow = value; lock.unlock()
        if value { boundary() }
    }
    var generation: UInt64 { lock.lock(); defer { lock.unlock() }; return revision }
    var isBlocked: Bool { lock.lock(); defer { lock.unlock() }; return blocked }
    func configure(enabled: Bool, includeText: Bool = false, now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        self.enabled = enabled; self.includeText = includeText; enabledAt = now
        samples.removeAll(); excerpts.removeAll(); overflow = false; blocked = false
        nextPlaybackProbe = .distantPast; revision &+= 1
    }
    func boundary() {
        lock.lock()
        guard enabled else { lock.unlock(); return }
        let notify = !blocked
        blocked = true; samples.removeAll(); excerpts.removeAll(); overflow = false; revision &+= 1
        lock.unlock()
        if notify { NotificationCenter.default.post(name: .jevBoundaryChanged, object: nil) }
    }
    func take(start: Date, end: Date) -> JevWindow? {
        lock.lock(); defer { lock.unlock() }
        defer { samples.removeAll { $0.date < end }; overflow = false; excerpts = excerpts.filter { $0.value.0 >= end } }
        guard enabled, !privateWindow, !blocked, !overflow else { return nil }
        return JevWindow(start: start, end: end, samples: samples)
    }
    /// Called only AFTER journal append and integrity commit, including privacy redaction.
    func receive(_ event: HistoryEvent) {
        lock.lock(); let active = enabled; lock.unlock()
        guard active else { return }
        let boundaries: Set<LocalHistoryCore.EventKind> = [.recordingPaused, .recorderStopped, .captureSuppressed,
            .secureInputSuppressed, .sessionLocked, .systemSleep, .historyCleared]
        guard event.suppressionReason == nil, event.element?.isSecure != true,
              !boundaries.contains(event.kind), !GoalongGlobalPause.isPaused(),
              GoalongPrivacyPolicyCache.read(in: AppPaths.applicationSupportDirectory).permits(event)
        else { boundary(); return }
        guard let sample = Self.sample(event) else { return }
        lock.lock(); defer { lock.unlock() }
        guard enabled, !privateWindow, event.timestamp >= enabledAt else { return }
        blocked = false
        var value = sample
        if includeText, let reference = event.semanticContext,
           let excerpt = excerpts[reference.snapshotID], abs(excerpt.0.timeIntervalSince(event.timestamp)) <= 15 {
            value = JevSample(date: sample.date, resource: sample.resource,
                title: JevPayload.clean(sample.title + " " + excerpt.1, bytes: 112),
                action: sample.action, surface: sample.surface, isActivity: sample.isActivity)
        }
        appendLocked(value)
    }
    func offer(_ payload: SemanticContextPayload) {
        lock.lock(); defer { lock.unlock() }
        guard enabled, !privateWindow, includeText, payload.capturedAt >= enabledAt,
              payload.source == .visibleText || payload.source == .mixed else { return }
        excerpts = excerpts.filter { payload.capturedAt.timeIntervalSince($0.value.0) <= 15 }
        if excerpts.count >= 8 { excerpts.removeAll() }
        excerpts[payload.id] = (payload.capturedAt, Self.redactedText(payload.text, limit: 96))
    }
    private func appendLocked(_ sample: JevSample) {
        samples.removeAll { sample.date.timeIntervalSince($0.date) > 60 }
        guard samples.count < 512 else { overflow = true; return }
        samples.append(sample)
    }

    /// Called with fresh ContextProvider output. A known Pause playback control is
    /// positive playback evidence; idle time alone is NEVER treated as watching.
    func observeContext(_ context: ContextSnapshot?, labelsEnabled: Bool) {
        lock.lock(); let active = enabled; lock.unlock()
        guard active else { return }
        guard let context, context.suppressionReason == nil, context.focusedElement?.isSecure != true,
              !GoalongGlobalPause.isPaused(), !IsSecureEventInputEnabled() else { boundary(); return }
        let now = Date()
        lock.lock()
        guard enabled, !privateWindow, labelsEnabled, now >= nextPlaybackProbe else { lock.unlock(); return }
        nextPlaybackProbe = now.addingTimeInterval(10)
        lock.unlock()
        guard Self.isMedia(context.url?.host), JevPlaybackProbe.isPlaying(context) else { return }
        let policy = GoalongPrivacyPolicy.load(in: AppPaths.applicationSupportDirectory)
        guard !policy.excludes(appID: context.app.bundleIdentifier, name: context.app.name),
              !policy.excludes(domain: context.url?.host), !GoalongGlobalPause.isPaused(),
              !IsSecureEventInputEnabled() else { boundary(); return }
        lock.lock(); defer { lock.unlock() }
        guard enabled, !privateWindow, now >= enabledAt else { return }
        blocked = false
        appendLocked(JevSample(date: now, resource: context.url?.host ?? "video",
            title: Self.redactedText(context.window?.title ?? "", limit: 72),
            action: "playing", surface: "video", isActivity: true))
    }

    static func sample(_ event: HistoryEvent) -> JevSample? {
        let activeKinds: Set<LocalHistoryCore.EventKind> = [.mouseClick, .typingBurst, .scrollBurst,
            .keyboardShortcut, .keyPressed, .applicationActivated, .windowChanged, .urlChanged, .focusChanged]
        guard activeKinds.contains(event.kind) || event.kind == .semanticSnapshot,
              let app = event.app, event.suppressionReason == nil, event.element?.isSecure != true else { return nil }
        let host = (event.url?.host ?? "").lowercased()
        let typing = event.kind == .typingBurst
        let role = (event.element?.role ?? "").lowercased()
        // Used locally only. Do not transmit arbitrary control values or full URLs.
        let marker = [event.element?.identifier, event.element?.label, event.element?.title]
            .compactMap { $0 }.joined(separator: " ").lowercased()
        let path = event.url.flatMap { URLComponents(string: $0.value)?.path.lowercased() } ?? ""
        let search = role.contains("search") || marker.contains("search") || marker.contains("recherche")
        let composer = !search && (role.contains("textarea") || role.contains("textfield"))
            && (marker.contains("tweettextarea") || marker.contains("compose") || marker.contains("what is happening")
                || marker.contains("quoi de neuf") || marker.contains("post text") || marker.contains("texte du post")
                || marker.contains("tweet text") || path.hasPrefix("/compose/"))
        let social = isSocial(host)
        let surface: String
        if composer { surface = typing ? "composing" : "composer" }
        else if isMedia(host) { surface = "video" }
        else if social, typing, !search, role.contains("text") { surface = "editing-unknown" }
        else if social { surface = search ? "social-search" : "social-feed" }
        else { surface = search ? "search" : "other" }
        let action = typing ? "typing" : event.kind == .scrollBurst ? "scroll" : event.kind == .mouseClick ? "click" : "context"
        return JevSample(date: event.timestamp, resource: host.isEmpty ? JevPayload.clean(app.name, bytes: 36) : JevPayload.clean(host, bytes: 36),
            title: redactedText(event.window?.title ?? "", limit: 96), action: action,
            surface: surface, isActivity: activeKinds.contains(event.kind))
    }
    static func isMedia(_ host: String?) -> Bool {
        matches(host, domains: ["youtube.com", "youtu.be", "netflix.com", "twitch.tv", "tiktok.com"])
    }
    static func isSocial(_ host: String?) -> Bool {
        matches(host, domains: ["x.com", "twitter.com", "instagram.com", "facebook.com", "reddit.com", "threads.net", "threads.com", "linkedin.com"])
    }
    private static func matches(_ host: String?, domains: [String]) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return domains.contains { host == $0 || host.hasSuffix("." + $0) }
    }
    static func redactedText(_ text: String, limit: Int) -> String {
        var result = String(text.prefix(512))
        for pattern in [#"https?://\S+"#, #"[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}"#,
                        #"(?i)(token|password|secret|api.key)\s*[:=]\s*\S+"#] {
            result = result.replacingOccurrences(of: pattern, with: "[masqué]", options: .regularExpression)
        }
        return JevPayload.clean(result, bytes: limit)
    }
}

private enum JevPlaybackProbe {
    static func isPlaying(_ context: ContextSnapshot) -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == context.app.processIdentifier else { return false }
        let application = AXUIElementCreateApplication(context.app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.05)
        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &windowValue) == .success,
              let windowValue, CFGetTypeID(windowValue) == AXUIElementGetTypeID() else { return false }
        let window = unsafeBitCast(windowValue, to: AXUIElement.self)
        var queue: [AXUIElement] = [window]
        let deadline = ProcessInfo.processInfo.systemUptime + 0.075
        var index = 0
        while index < queue.count, index < 128, ProcessInfo.processInfo.systemUptime < deadline {
            let element = queue[index]; index += 1
            func string(_ attribute: String) -> String {
                var value: CFTypeRef?
                guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return "" }
                return (value as? String ?? "").lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if string(kAXRoleAttribute) == "axbutton" {
                let labels = [string(kAXTitleAttribute), string(kAXDescriptionAttribute)]
                if labels.contains(where: { ["pause", "pause (k)", "mettre en pause", "mettre en pause (k)"].contains($0) }) {
                    return NSWorkspace.shared.frontmostApplication?.processIdentifier == context.app.processIdentifier
                }
            }
            var children: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
               let values = children as? [AXUIElement] { queue.append(contentsOf: values.prefix(max(0, 128 - queue.count))) }
        }
        return false
    }
}
#endif
