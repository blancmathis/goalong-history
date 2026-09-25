#if os(macOS)
import AppKit
import Carbon
import Foundation
import LocalHistoryCore

extension Notification.Name {
    static let jevBoundaryChanged = Notification.Name("goalong.jev.boundary")
}

/// Bounded, transient projection of already-authorized capture. No input values,
/// full URLs, screenshots or persisted mixed semantic payloads are exported.
final class JevIngress: @unchecked Sendable {
    static let shared = JevIngress()
    static let foregroundSampleInterval: TimeInterval = 5
    private let lock = NSLock()
    private let notificationCenter: NotificationCenter
    private let contextIsPermitted: (ContextSnapshot) -> Bool
    init(notificationCenter: NotificationCenter = .default,
         contextIsPermitted: @escaping (ContextSnapshot) -> Bool = JevIngress.permitsLiveContext) {
        self.notificationCenter = notificationCenter
        self.contextIsPermitted = contextIsPermitted
    }
    private var enabled = false
    private var includeText = false
    private var enabledAt = Date.distantFuture
    private var samples: [JevSample] = []
    private var overflow = false
    private var blocked = false
    private var privateWindow = false
    private var revision: UInt64 = 0
    private var nextPlaybackProbe = Date.distantPast
    private var foregroundKey = ""

    var isEnabled: Bool { lock.lock(); defer { lock.unlock() }; return enabled }
    var wantsVisibleText: Bool {
        lock.lock(); defer { lock.unlock() }
        return enabled && includeText && !privateWindow && !blocked
    }
    func setPrivateWindow(_ value: Bool) {
        lock.lock(); privateWindow = value; lock.unlock()
        if value { boundary() }
    }
    var generation: UInt64 { lock.lock(); defer { lock.unlock() }; return revision }
    var isBlocked: Bool { lock.lock(); defer { lock.unlock() }; return blocked }
    func configure(enabled: Bool, includeText: Bool = false, now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        self.enabled = enabled; self.includeText = includeText; enabledAt = now
        samples.removeAll(); overflow = false; blocked = false
        nextPlaybackProbe = .distantPast; foregroundKey = ""; revision &+= 1
    }
    func boundary() {
        lock.lock()
        guard enabled else { lock.unlock(); return }
        let notify = !blocked
        blocked = true; samples.removeAll(); overflow = false; revision &+= 1
        nextPlaybackProbe = .distantPast; foregroundKey = ""
        lock.unlock()
        if notify {
            // Never make EventRecorder's writer wait for the main thread, which
            // can itself be draining the writer during screen lock or sleep.
            let center = notificationCenter
            DispatchQueue.main.async { center.post(name: .jevBoundaryChanged, object: nil) }
        }
    }
    func take(start: Date, end: Date) -> JevWindow? {
        lock.lock(); defer { lock.unlock() }
        defer { samples.removeAll { $0.date < end }; overflow = false }
        guard enabled, !privateWindow, !blocked, !overflow else { return nil }
        return JevWindow(start: start, end: end, samples: samples)
    }
    /// Called only AFTER journal append and integrity commit, including privacy redaction.
    func receive(_ event: HistoryEvent) {
        lock.lock(); let active = enabled; let expected = revision; lock.unlock()
        guard active else { return }
        let boundaries: Set<LocalHistoryCore.EventKind> = [.recordingPaused, .recorderStopped, .captureSuppressed,
            .secureInputSuppressed, .sessionLocked, .systemSleep, .historyCleared]
        guard event.suppressionReason == nil, event.element?.isSecure != true,
              !boundaries.contains(event.kind), !GoalongGlobalPause.isPaused(),
              GoalongPrivacyPolicyCache.read(in: AppPaths.applicationSupportDirectory).permits(event)
        else { boundary(); return }
        guard let sample = Self.sample(event) else { return }
        lock.lock(); defer { lock.unlock() }
        guard enabled, !privateWindow, revision == expected, event.timestamp >= enabledAt else { return }
        blocked = false
        appendLocked(sample)
    }
    func offerVisibleText(_ text: String, context: ContextSnapshot, at date: Date, generation expected: UInt64) {
        guard contextIsPermitted(context) else { return }
        let excerpt = Self.redactedText(text, limit: 224)
        guard !excerpt.isEmpty else { return }
        let sample = Self.foregroundSample(context, evidence: context.foregroundUsage?.evidence, at: date)
        lock.lock(); defer { lock.unlock() }
        guard enabled, includeText, !privateWindow, !blocked, revision == expected, date >= enabledAt else { return }
        appendLocked(JevSample(date: date, resource: sample.resource, title: sample.title,
            action: "visible", surface: sample.surface, isActivity: false, excerpt: excerpt))
    }
    private func appendLocked(_ sample: JevSample) {
        samples.removeAll { sample.date.timeIntervalSince($0.date) > 60 }
        // Do not move or coalesce timestamps across arbitrary half-open boundaries.
        if samples.last == sample { return }
        guard samples.count < 512 else { overflow = true; return }
        samples.append(sample)
    }

    /// Fresh observations continue during quiet reading and confirmed playback.
    /// A content change is admitted immediately; unchanged foreground is refreshed
    /// every five seconds locally, while network analysis stays at fifteen seconds.
    func observeContext(_ context: ContextSnapshot?, foregroundEvidence: ForegroundActivityEvidence?,
                        presence: ForegroundUsageObservation? = nil, now: Date = Date()) {
        guard isEnabled else { return }
        guard let context, contextIsPermitted(context) else { boundary(); return }
        lock.lock(); defer { lock.unlock() }
        guard enabled, !privateWindow,
              Self.shouldSampleForeground(presence: presence, evidence: foregroundEvidence),
              now >= nextPlaybackProbe || foregroundKey != context.fingerprint,
              now >= enabledAt else { return }
        nextPlaybackProbe = now.addingTimeInterval(Self.foregroundSampleInterval)
        foregroundKey = context.fingerprint
        blocked = false
        appendLocked(Self.foregroundSample(context, evidence: foregroundEvidence, at: now))
    }

    static func permitsLiveContext(_ context: ContextSnapshot) -> Bool {
        guard context.suppressionReason == nil, context.focusedElement?.isSecure != true,
              !GoalongGlobalPause.isPaused(), !IsSecureEventInputEnabled() else { return false }
        let policy = GoalongPrivacyPolicyCache.read(in: AppPaths.applicationSupportDirectory)
        return !policy.blocked
            && !policy.excludes(appID: context.app.bundleIdentifier, name: context.app.name)
            && !policy.excludes(domain: context.url?.host)
            && (context.privacyRevision == nil || context.privacyRevision == policy.revision)
    }
    static func shouldSampleForeground(presence: ForegroundUsageObservation?, evidence: ForegroundActivityEvidence?) -> Bool {
        if let presence, !presence.isForegroundVisible { return false }
        let reading = presence.map { value in
            value.isForegroundVisible && (value.idleLimitSeconds == 0
                || (value.idleSeconds.isFinite && value.idleSeconds >= 0
                    && value.idleSeconds < Double(value.idleLimitSeconds)))
        } ?? false
        // A browser-wide display assertion does not identify the active tab.
        return reading || (evidence != nil && evidence != .displayAssertion)
    }

    static func sample(_ event: HistoryEvent) -> JevSample? {
        let activeKinds: Set<LocalHistoryCore.EventKind> = [.mouseClick, .typingBurst, .scrollBurst,
            .keyboardShortcut, .keyPressed, .applicationActivated, .windowChanged, .urlChanged, .focusChanged]
        guard activeKinds.contains(event.kind) || event.kind == .semanticSnapshot,
              let app = event.app, event.suppressionReason == nil, event.element?.isSecure != true else { return nil }
        if ForegroundUsageObservation.usesPresencePolicy(event),
           !ForegroundActivityEvidence.isActiveUsageEvidence(event) { return nil }
        let host = (event.url?.host ?? "").lowercased()
        let typing = event.kind == .typingBurst
        let path = event.url.flatMap { URLComponents(string: $0.value)?.path.lowercased() } ?? ""
        let mode = surface(host: host, path: path, element: event.element, typing: typing)
        let action = typing ? "typing" : event.kind == .scrollBurst ? "scroll" : event.kind == .mouseClick ? "click" : "context"
        return JevSample(date: event.timestamp, resource: JevPayload.clean(host.isEmpty ? app.name : host, bytes: 36),
            title: redactedText(event.window?.title ?? "", limit: 160), action: action,
            surface: mode, isActivity: activeKinds.contains(event.kind))
    }
    static func foregroundSample(_ context: ContextSnapshot, evidence: ForegroundActivityEvidence?, at date: Date) -> JevSample {
        let host = (context.url?.host ?? "").lowercased()
        let path = context.url.flatMap { URLComponents(string: $0.value)?.path.lowercased() } ?? ""
        return JevSample(date: date, resource: JevPayload.clean(host.isEmpty ? context.app.name : host, bytes: 36),
            title: redactedText(context.window?.title ?? "", limit: 160),
            action: evidence == .call ? "call" : evidence == .mediaPlayback ? "playing" : "foreground",
            surface: evidence == .call ? "meeting" : evidence == .mediaPlayback ? "video"
                : surface(host: host, path: path, element: context.focusedElement, typing: false),
            isActivity: true)
    }
    /// Used by both input and periodic samples. Paths are interpreted locally and
    /// never transmitted. A composer must not become a feed on the next heartbeat.
    static func surface(host: String, path: String, element: ElementSnapshot?, typing: Bool) -> String {
        let role = (element?.role ?? "").lowercased()
        let marker = [element?.identifier, element?.label, element?.title]
            .compactMap { $0 }.joined(separator: " ").lowercased()
        let search = role.contains("search") || marker.contains("search") || marker.contains("recherche")
            || path == "/search" || path == "/results"
        let composer = !search && ((isSocial(host) && path.hasPrefix("/compose/"))
            || ((role.contains("textarea") || role.contains("textfield"))
                && ["tweettextarea", "compose", "what is happening", "quoi de neuf", "post text",
                    "texte du post", "tweet text"].contains(where: marker.contains)))
        if composer { return typing ? "composing" : "composer" }
        if isMedia(host) {
            if host == "studio.youtube.com" { return "other" }
            if search { return "video-search" }
            if path == "/" || path.hasPrefix("/feed/") { return "video-feed" }
            return "video"
        }
        if isSocial(host) {
            if path == "/messages" || path.hasPrefix("/messages/") { return "messaging" }
            if path.hasPrefix("/settings") || path.hasPrefix("/notifications") { return "social-navigation" }
            if typing && !search && role.contains("text") { return "editing-unknown" }
            return search ? "social-search" : "social-feed"
        }
        return search ? "search" : "other"
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
#endif
