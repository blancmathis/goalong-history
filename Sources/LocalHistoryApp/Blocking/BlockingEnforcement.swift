#if os(macOS)
import AppKit
import ApplicationServices
import ServiceManagement
import SwiftUI

@MainActor protocol BlockingEnforcementBackend: AnyObject {
    var accessibilityAvailable: Bool { get }
    var canLockScreen: Bool { get }
    var browsers: [BlockingBrowserSupport] { get }
    var appStillBlocked: ((BlockingObservation) -> Bool)? { get set }
    var siteActionStillRequired: ((BlockingObservation) -> Bool)? { get set }
    var siteActionDeadline: ((BlockingObservation) -> Date?)? { get set }
    var onBlockPresented: ((BlockingObservation, UUID) -> BlockingListFeedback?)? { get set }
    func observeBrowser(_ target: BlockingObservation)
    func updateProtection(locked: Bool) -> BlockingProtectionState
    func blockApp(_ target: BlockingObservation, app: BlockAppRule, block: BlockingActiveBlock, listName: String)
    func blockSlowDownApp(_ target: BlockingObservation, app: BlockAppRule, block: BlockingActiveBlock, listName: String)
    func blockSite(_ target: BlockingObservation, presentation: BlockingVeilPresentation, onBreak: @escaping () -> Void)
    func clearSite()
    func slowDown(_ target: BlockingObservation, presentation: BlockingFrictionPresentation, onRenounce: @escaping () -> Void, onContinue: @escaping () -> Void)
    func clearSlowDown()
    func renounceSlowDown(_ target: BlockingObservation)
    func continueSlowDown(_ target: BlockingObservation)
    func updateFreeze(_ freeze: BlockFreeze?)
    func returnToShield()
    func shutdown()
    func invalidateSiteActions()
}

extension BlockingEnforcementBackend {
    var siteActionStillRequired: ((BlockingObservation) -> Bool)? { get { nil } set {} }
    var siteActionDeadline: ((BlockingObservation) -> Date?)? { get { nil } set {} }
    var onBlockPresented: ((BlockingObservation, UUID) -> BlockingListFeedback?)? { get { nil } set {} }
    func invalidateSiteActions() {}
    func blockSlowDownApp(_ target: BlockingObservation, app: BlockAppRule, block: BlockingActiveBlock, listName: String) {}
    func slowDown(_ target: BlockingObservation, presentation: BlockingFrictionPresentation, onRenounce: @escaping () -> Void, onContinue: @escaping () -> Void) {}
    func clearSlowDown() {}
    func renounceSlowDown(_ target: BlockingObservation) {}
    func continueSlowDown(_ target: BlockingObservation) {}
}

private final class BlockingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
private final class BlockingFreezePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// In-process, user-session enforcement only. No system service or network access.
@MainActor final class StandardBlockingBackend: BlockingEnforcementBackend {
    var accessibilityAvailable: Bool { AXIsProcessTrusted() }
    var canLockScreen: Bool { accessibilityAvailable }
    var appStillBlocked: ((BlockingObservation) -> Bool)?
    var siteActionStillRequired: ((BlockingObservation) -> Bool)?
    var siteActionDeadline: ((BlockingObservation) -> Date?)?
    var onBlockPresented: ((BlockingObservation, UUID) -> BlockingListFeedback?)?
    private(set) var appNoticeFeedback: BlockingListFeedback?
    private var observedBrowserSupport: [String: Bool] = [:]
    private var observedBrowserNames: [String: String] = [:]
    func observeBrowser(_ target: BlockingObservation) {
        guard target.isForeground, target.isBrowser, !target.privateWindow, !target.bundleIdentifier.isEmpty else { return }
        observedBrowserSupport[target.bundleIdentifier] = target.url != nil || target.isInternalPage
        if observedBrowserNames[target.bundleIdentifier] == nil {
            observedBrowserNames[target.bundleIdentifier] = NSRunningApplication(processIdentifier: target.pid)?.localizedName
        }
    }
    var browsers: [BlockingBrowserSupport] {
        var result = [("com.apple.Safari", "Safari"), ("com.google.Chrome", "Chrome"), ("com.microsoft.edgemac", "Edge"),
         ("com.brave.Browser", "Brave"), ("company.thebrowser.Browser", "Arc"), ("org.mozilla.firefox", "Firefox")]
            .map { BlockingBrowserSupport(bundleIdentifier: $0.0, name: $0.1, supported: accessibilityAvailable && (observedBrowserSupport[$0.0] ?? ($0.0 != "org.mozilla.firefox"))) }
        for (id, supported) in observedBrowserSupport where !result.contains(where: { $0.bundleIdentifier == id }) {
            result.append(BlockingBrowserSupport(bundleIdentifier: id, name: observedBrowserNames[id] ?? id, supported: accessibilityAvailable && supported))
        }
        return result
    }
    private let tabLane = BlockingTabAXLane()
    private let tabRuleAuthority = BlockingTabRuleAuthority()
    private var tabPermit: AXRequestPermit?
    private var renouncedTarget: BlockingObservation?
    private var tabIsRenounce = false
    private var frictionPanel: SlowDownPanel?
    private var veil: NSPanel?
    private var veilHost: NSHostingView<AnyView>?
    private var veilPresentation: BlockingVeilPresentation?
    private var notice: NSPanel?
    private var shields: [NSPanel] = []
    private var veilTarget: BlockingObservation?
    private var lastTabClose = Date.distantPast
    private var veilClear: DispatchWorkItem?
    private var noticeClear: DispatchWorkItem?
    private var terminations: [Int32: DispatchWorkItem] = [:]
    private var freeze: BlockFreeze?
    private var savedPresentation: NSApplication.PresentationOptions?
    private var screenToken: NSObjectProtocol?
    private var lockTimer: Timer?
    private var requestedLogin = false
    private var loginError: String?
    private var loginStatus: SMAppService.Status?
    private var loginStatusRead = Date.distantPast
    private var loginStatusReading = false

    /// `SMAppService.status` is a synchronous XPC round trip to smd (measured at ~300 ms)
    /// and `updateProtection` runs on every blocking refresh. The status is read once
    /// synchronously, then refreshed off the main thread at most every 30 s.
    private func currentLoginStatus() -> SMAppService.Status {
        guard let status = loginStatus else {
            let status = SMAppService.mainApp.status
            loginStatus = status; loginStatusRead = Date()
            return status
        }
        if Date().timeIntervalSince(loginStatusRead) > 30, !loginStatusReading {
            loginStatusReading = true
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let next = SMAppService.mainApp.status
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.loginStatusReading = false
                    if self.loginStatus != nil { self.loginStatus = next; self.loginStatusRead = Date() }
                }
            }
        }
        return status
    }

    func updateProtection(locked: Bool) -> BlockingProtectionState {
        if locked, currentLoginStatus() != .enabled, currentLoginStatus() != .requiresApproval, !requestedLogin {
            requestedLogin = true
            do { try SMAppService.mainApp.register() }
            catch { loginError = "Démarrage à la connexion indisponible : \(error.localizedDescription)" }
            loginStatus = nil
        } else if !locked { requestedLogin = false }
        var result = BlockingProtectionState()
        let status = currentLoginStatus()
        result.launchAtLogin = status == .enabled
        if locked && !result.launchAtLogin {
            result.component = status == .requiresApproval ? .awaitingApproval : .failed(loginError ?? "Activez Goalong dans les éléments d’ouverture.")
        }
        return result
    }
    func blockApp(_ target: BlockingObservation, app: BlockAppRule, block: BlockingActiveBlock, listName: String) {
        guard !BlockingRules.exempt(target), let running = NSRunningApplication(processIdentifier: target.pid),
              running.activationPolicy == .regular, running.bundleIdentifier == target.bundleIdentifier else { return }
        if terminations[target.pid] == nil {
            _ = running.terminate()
            let work = DispatchWorkItem { [weak self, running] in
                // Retain and revalidate the original object, never a potentially recycled PID.
                if !running.isTerminated, running.activationPolicy == .regular,
                   running.bundleIdentifier == target.bundleIdentifier, self?.appStillBlocked?(target) == true {
                    _ = running.forceTerminate()
                }
                self?.terminations[target.pid] = nil
            }
            terminations[target.pid] = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
        }
        showAppNotice(target, app: app, block: block, listName: listName)
    }
    private func showAppNotice(_ target: BlockingObservation, app: BlockAppRule, block: BlockingActiveBlock, listName: String) {
        let screen = target.windowFrame.flatMap { frame in NSScreen.screens.first { $0.frame.intersects(Self.appKitFrame(frame)) } } ?? NSScreen.main
        guard let screen else { return }
        if let id = block.feedback?.listID { appNoticeFeedback = onBlockPresented?(target, id) ?? block.feedback }
        let height = BlockedAppNotice.height(appNoticeFeedback)
        let frame = NSRect(x: screen.visibleFrame.midX - 190, y: screen.visibleFrame.maxY - 16 - height, width: 380, height: height)
        let panel = notice ?? makePanel(frame: frame)
        panel.contentView = host(BlockedAppNotice(app: app, end: block.end, lock: block.lock, listName: listName,
                                                  feedback: appNoticeFeedback), frame: frame)
        panel.setFrame(frame, display: true); panel.orderFrontRegardless(); notice = panel
        noticeClear?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.notice?.close(); self?.notice = nil; self?.appNoticeFeedback = nil }
        noticeClear = work; DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }
    /// Even an exhausted quota of a slow-down list preserves the member's open work.
    func blockSlowDownApp(_ target: BlockingObservation, app: BlockAppRule, block: BlockingActiveBlock, listName: String) {
        guard !BlockingRules.exempt(target), let running = NSRunningApplication(processIdentifier: target.pid),
              running.bundleIdentifier == target.bundleIdentifier, running.activationPolicy == .regular else { return }
        terminations[target.pid]?.cancel(); terminations[target.pid] = nil
        running.hide()
        showAppNotice(target, app: app, block: block, listName: listName)
    }
    func blockSite(_ target: BlockingObservation, presentation: BlockingVeilPresentation, onBreak: @escaping () -> Void) {
        var presentation = presentation
        if let id = presentation.feedback?.listID { presentation.feedback = onBlockPresented?(target, id) ?? presentation.feedback }
        veilClear?.cancel(); veilClear = nil
        let frame = target.windowFrame.map(Self.appKitFrame) ?? (NSScreen.main?.frame ?? .zero)
        let panel = veil ?? makePanel(frame: frame)
        // One hosting view per veil; rebuild its content only when what it says changes.
        if veilHost == nil || veilPresentation != presentation {
            let content = AnyView(BlockedSiteVeil(presentation: presentation, onBreak: onBreak).tint(LHTheme.accent).goalongControls())
            if let veilHost { veilHost.rootView = content } else {
                let host = NSHostingView(rootView: content)
                host.sizingOptions = []; host.frame = CGRect(origin: .zero, size: frame.size); host.autoresizingMask = [.width, .height]
                panel.contentView = host; veilHost = host
            }
            veilPresentation = presentation
        }
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        panel.alphaValue = 1; panel.orderFrontRegardless(); veil = panel
        if veilTarget?.pid != target.pid || veilTarget?.windowBoundary != target.windowBoundary
            || veilTarget?.url != target.url || veilTarget?.privateWindow != target.privateWindow
            || target.at.timeIntervalSince(lastTabClose) >= 1.5 {
            lastTabClose = target.at
            closeTab(target)
        }
        veilTarget = target
    }
    func clearSite() {
        if !tabIsRenounce { invalidateSiteActions() }
        guard veil != nil, veilClear == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let panel = self.veil
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2; panel?.animator().alphaValue = 0
            } completionHandler: { panel?.close() }
            self.veil = nil; self.veilHost = nil; self.veilPresentation = nil; self.veilTarget = nil; self.veilClear = nil
        }
        veilClear = work; DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }
    func slowDown(_ target: BlockingObservation, presentation: BlockingFrictionPresentation, onRenounce: @escaping () -> Void, onContinue: @escaping () -> Void) {
        if !target.isBrowser {
            guard let app = NSRunningApplication(processIdentifier: target.pid), app.bundleIdentifier == target.bundleIdentifier, app.activationPolicy == .regular else { return }
            app.hide()
        }
        let panel = frictionPanel ?? SlowDownPanel()
        panel.show(target, presentation: presentation, onRenounce: onRenounce, onContinue: onContinue)
        frictionPanel = panel
    }
    func clearSlowDown() {
        frictionPanel?.close(); frictionPanel = nil
    }
    func renounceSlowDown(_ target: BlockingObservation) { if target.isBrowser { closeTab(target, renounce: true) } }
    func continueSlowDown(_ target: BlockingObservation) {
        guard !target.isBrowser, let app = NSRunningApplication(processIdentifier: target.pid), app.bundleIdentifier == target.bundleIdentifier, app.activationPolicy == .regular else { return }
        app.unhide(); app.activate(options: [.activateIgnoringOtherApps])
    }
    func updateFreeze(_ proposed: BlockFreeze?) {
        var value = proposed
        if value?.mode == .lockScreen && !accessibilityAvailable { value?.mode = .shield }
        guard value != freeze else { return }
        let wasFreezing = freeze != nil
        freeze = value
        lockTimer?.invalidate(); lockTimer = nil
        if value == nil {
            for shield in shields { shield.close() }; shields.removeAll()
            if let savedPresentation { NSApp.presentationOptions = savedPresentation; self.savedPresentation = nil }
            if let screenToken { NotificationCenter.default.removeObserver(screenToken); self.screenToken = nil }
            return
        }
        if let value, value.mode == .lockScreen {
            // A one-second fallback also catches missed unlock notifications without a second foreground observer.
            if !wasFreezing { lockSession() }
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.freeze?.end ?? .distantPast > Date() else { return }
                    if ForegroundSessionAvailability.isAvailable() { self.lockSession() }
                }
            }
            RunLoop.main.add(timer, forMode: .common); lockTimer = timer
        } else {
            if savedPresentation == nil { savedPresentation = NSApp.presentationOptions }
            // Session termination remains available: disableSessionTermination also disables shutdown/restart.
            NSApp.presentationOptions = [.hideDock, .hideMenuBar, .disableProcessSwitching, .disableForceQuit, .disableHideApplication]
            rebuildShields()
            if screenToken == nil {
                screenToken = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.rebuildShields() }
                }
            }
            returnToShield()
        }
    }
    private func rebuildShields() {
        for shield in shields { shield.close() }; shields.removeAll()
        guard let freeze, freeze.mode == .shield else { return }
        for screen in NSScreen.screens {
            let panel = BlockingFreezePanel(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            configure(panel)
            panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 1)
            panel.contentView = host(FrozenMacShield(freeze: freeze, onOpen: { [weak self] app in self?.openAllowed(app) }), frame: screen.frame)
            panel.setFrame(screen.frame, display: true); panel.orderFrontRegardless(); shields.append(panel)
        }
    }
    private func openAllowed(_ app: BlockAppRule) {
        guard freeze?.allowedApps.contains(where: { $0.bundleIdentifier == app.bundleIdentifier }) == true,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleIdentifier) else { return }
        // Kept apps come forward alone: every other app is hidden, so nothing else shows above the shield.
        let kept = Set(freeze?.allowedApps.map(\.bundleIdentifier) ?? [])
        for other in NSWorkspace.shared.runningApplications where other.activationPolicy == .regular
            && other.processIdentifier != ProcessInfo.processInfo.processIdentifier && !kept.contains(other.bundleIdentifier ?? "") {
            other.hide()
        }
        let config = NSWorkspace.OpenConfiguration(); config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { [weak self] app, error in
            Task { @MainActor in
                guard error == nil, let app, self?.freeze?.allowedApps.contains(where: { $0.bundleIdentifier == app.bundleIdentifier }) == true else { return }
                for shield in self?.shields ?? [] { shield.level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1); shield.orderBack(nil) }
            }
        }
    }
    func returnToShield() {
        guard freeze?.mode == .shield else { return }
        for shield in shields { shield.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 1); shield.orderFrontRegardless() }
        NSApp.activate(ignoringOtherApps: true); shields.first?.makeKeyAndOrderFront(nil)
    }
    private func lockSession() {
        guard accessibilityAvailable else { returnToShield(); return }
        // Fixed macOS Lock Screen shortcut; no text capture or arbitrary automation.
        let down = CGEvent(keyboardEventSource: nil, virtualKey: 12, keyDown: true)
        let up = CGEvent(keyboardEventSource: nil, virtualKey: 12, keyDown: false)
        down?.flags = [.maskControl, .maskCommand]; up?.flags = [.maskControl, .maskCommand]
        down?.post(tap: .cghidEventTap); up?.post(tap: .cghidEventTap)
    }
    func shutdown() {
        invalidateSiteActions()
        clearSlowDown()
        updateFreeze(nil)
        veilClear?.cancel(); noticeClear?.cancel()
        for work in terminations.values { work.cancel() }; terminations.removeAll()
        veil?.close(); veil = nil; veilHost = nil; veilPresentation = nil; notice?.close(); notice = nil
        // mainApp is shared with LaunchAtLoginManager. Keep registration: ownership may
        // have become the member's preference since this backend first registered it.
    }
    private func makePanel(frame: CGRect) -> NSPanel {
        let panel = BlockingPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        configure(panel); panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        return panel
    }
    private func configure(_ panel: NSPanel) {
        panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = false; panel.hasShadow = false
    }
    private func host<V: View>(_ view: V, frame: CGRect) -> NSView {
        let host = NSHostingView(rootView: view.tint(LHTheme.accent).goalongControls())
        host.sizingOptions = []; host.frame = CGRect(origin: .zero, size: frame.size)
        host.autoresizingMask = [.width, .height]; return host
    }
    static func appKitFrame(_ frame: CGRect) -> CGRect {
        CGRect(x: frame.minX, y: (NSScreen.screens.first?.frame.maxY ?? 0) - frame.maxY, width: frame.width, height: frame.height)
    }
    func invalidateSiteActions() { tabRuleAuthority.invalidate(); tabPermit?.revoke(); tabPermit = nil; renouncedTarget = nil }

    private func closeTab(_ target: BlockingObservation, renounce: Bool = false) {
        guard accessibilityAvailable, let application = NSRunningApplication(processIdentifier: target.pid),
              application.bundleIdentifier == target.bundleIdentifier, !application.isTerminated else { return }
        invalidateSiteActions()
        guard let deadline = siteActionDeadline?(target), deadline > Date() else { return }
        let rulePermit = tabRuleAuthority.permit(until: deadline)
        let permit = AXRequestPermit(); tabPermit = permit
        tabIsRenounce = renounce
        if renounce { renouncedTarget = target }
        tabLane.request(target, permit: permit, rulePermit: rulePermit, stillCurrent: {
            !application.isTerminated && application.bundleIdentifier == target.bundleIdentifier
                && NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid
                && ForegroundSessionAvailability.isAvailable() && AXIsProcessTrusted()
        }, revalidate: { [weak self] completion in
            guard let self, permit.isValid else { completion(false); return }
            let veiled = self.veilTarget.map {
                $0.pid == target.pid && $0.windowBoundary == target.windowBoundary && $0.url == target.url
                    && $0.privateWindow == target.privateWindow && (self.veilPresentation?.end ?? .distantPast) > Date()
            } ?? false
            let renounced = self.renouncedTarget.map {
                $0.pid == target.pid && $0.windowBoundary == target.windowBoundary && $0.url == target.url

            } ?? false
            completion((veiled || renounced) && self.accessibilityAvailable
                && (self.siteActionStillRequired?(target) ?? true))
        }, fallback: {
            let down = CGEvent(keyboardEventSource: nil, virtualKey: 13, keyDown: true)
            let up = CGEvent(keyboardEventSource: nil, virtualKey: 13, keyDown: false)
            down?.flags = .maskCommand; up?.flags = .maskCommand
            down?.postToPid(target.pid); up?.postToPid(target.pid)
        })
    }
}
#endif
