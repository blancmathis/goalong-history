#if os(macOS)
import AppKit
import CryptoKit
import Foundation
import GoalongHeadlessTestSupport
import SwiftUI
@testable import LocalHistoryApp

/// One rendered image and what the manifest says about it.
struct GalleryImage {
    enum Status: String { case ok, unstable, notReady = "not-ready", leaky, timeout, failed }
    let png: Data
    let pixelHash: String
    let pointSize: NSSize
    let pixelSize: (width: Int, height: Int)
    let backingScale: CGFloat
    var status: Status
    var detail: String?
    /// Raw RGBA bytes, kept for in-memory checks (smoke test).
    let bitmap: NSBitmapImageRep
}

/// Renders a gallery entry in a window that is never ordered on screen (`defer: true`): no window appears, the app
/// never activates. The only rendering helper of the gallery (spec C §4).
@MainActor enum GalleryRenderer {
    static let maximumFullHeight: CGFloat = 6_000
    static let fallbackFullHeight: CGFloat = 1_500

    /// Preferences of the process-wide services the pages reach (one throwaway suite per process).
    static let processDefaults = UserDefaults(suiteName: "goalong-gallery-" + UUID().uuidString)!

    static func prepareApplication() {
        let app = NSApplication.shared
        if app.activationPolicy() != .accessory { app.setActivationPolicy(.accessory) }
        NSTimeZone.default = GalleryClock.timeZone
        GoalongToastCenter.suppressedForTesting = true
        ProductIdentity.galleryOverride = ProductIdentity.GalleryIdentity()
        // History's analysis passes: a throwaway suite (the hook deletes it) and the frozen clock.
        ActivityAnalysisRuntime.shared.preferences = processDefaults
        ActivityAnalysisRuntime.shared.clock = { GalleryClock.now }
        warmSingletons()
    }

    /// Singletons that read `UserDefaults.standard` once, in their initializer, and that the catalog's views touch.
    /// They are built here, before any guard window, from the shard's empty throwaway HOME: every shard and every
    /// relaunch builds them the same way, and the first entry that touches them is not marked `leaky` for it.
    static func warmSingletons() {
        _ = SoftwareUpdateManager.shared
        _ = BackgroundContinuityController.shared
        _ = ChatGPTRecapRuntime.shared
        _ = GoalongWebsiteAutoSender.shared
        _ = JevInterventionPreferences.shared
        _ = SupportDiagnostics.shared
        _ = JevMonitoringPreferences.shared
        _ = GoalongModuleStore.shared
        _ = EnvironmentValues().goalongDefaults
    }

    /// The root modifiers every entry gets: its preferences, French dates, no animation, active controls.
    static func root(_ entry: GalleryEntry, _ ctx: GalleryContext, size: GallerySize) throws -> AnyView {
        var content = try entry.view(ctx)
        if entry.pageBackground && !entry.dashboardWindow {
            content = AnyView(content.background(LHTheme.pageBackground).foregroundStyle(LHTheme.text)
                .tint(LHTheme.accent).accentColor(LHTheme.accent).goalongControls())
        }
        switch size {
        case let .fixed(width, height): content = AnyView(content.frame(width: width, height: height))
        case let .fitWidth(width): content = AnyView(content.frame(width: width).fixedSize(horizontal: false, vertical: true))
        case let .full(width): content = AnyView(content.frame(width: width).frame(maxHeight: .infinity))
        }
        return AnyView(content
            .defaultAppStorage(ctx.defaults)
            .environment(\.goalongDefaults, ctx.defaults)
            .environment(\.sourceAccessCheck, { [environment = ctx.environment] capability, done in
                DispatchQueue.main.async { done(environment.sourceAccess(for: capability)) }
            })
            .environment(\.goalongReduceMotion, true)
            // The window's high-contrast appearance alone leaves SwiftUI's contrast at the Mac's setting.
            .environment(\._colorSchemeContrast, ctx.theme.isContrast ? .increased : .standard)
            .environment(\.controlActiveState, .key)
            .environment(\.locale, GalleryClock.locale)
            .environment(\.timeZone, GalleryClock.timeZone)
            .environment(\.calendar, GalleryClock.calendar)
            .transaction { $0.disablesAnimations = true; $0.animation = nil })
    }

    /// Renders one image. Never orders the window; the window is closed and released before returning.
    static func render(_ entry: GalleryEntry, theme: GalleryTheme, size: GallerySize, ctx: GalleryContext) throws -> GalleryImage {
        ctx.theme = theme
        let start: NSSize
        switch size {
        case let .fixed(width, height): start = NSSize(width: width, height: height)
        case let .fitWidth(width): start = NSSize(width: width, height: 900)
        case let .full(width): start = NSSize(width: width, height: fallbackFullHeight)
        }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: start),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: true)
        if entry.dashboardWindow {
            DashboardWindowController.configure(window)
        } else {
            window.isReleasedWhenClosed = false
            window.backgroundColor = NSColor(LHTheme.pageBackground)
        }
        window.minSize = NSSize(width: 100, height: 100)
        window.appearance = theme.appearance
        let host = NSHostingView(rootView: try root(entry, ctx, size: size))
        window.contentView = host
        window.setContentSize(start)
        defer {
            window.contentView = nil
            window.close()
        }
        host.layoutSubtreeIfNeeded()
        // Data first: the entry's own predicate (20 ms polls, 3 s at most).
        if let ready = entry.ready {
            let deadline = Date().addingTimeInterval(3)
            var isReady = ready(ctx)
            while !isReady && Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
                isReady = ready(ctx)
            }
            if !isReady {
                let capture = try capture(host, window: window)
                return image(capture, host: host, window: window, status: .notReady, detail: "ready predicate not met in 3 s")
            }
        }
        pump(0.05)
        switch size {
        case .fitWidth(let width):
            let height = ceil(host.fittingSize.height)
            window.setContentSize(NSSize(width: width, height: max(60, min(height, maximumFullHeight))))
        case .full(let width):
            let height = fullHeight(host) ?? fallbackFullHeight
            window.setContentSize(NSSize(width: width, height: min(maximumFullHeight, max(start.height, height))))
        case .fixed: break
        }
        // A screen at rest: no field keeps the focus (its placeholder and caret change with it, at random times).
        window.makeFirstResponder(nil)
        // Stability: two identical captures in a row, confirmed by a third 150 ms later (a late AppKit redraw under a
        // loaded Mac once slipped between two captures 50 ms apart), at most 10 rounds.
        var previous = try capture(host, window: window)
        for _ in 0..<10 {
            pump(0.05)
            let next = try capture(host, window: window)
            if next.bitmapData == previous.bitmapData {
                pump(0.15)
                let confirmation = try capture(host, window: window)
                if confirmation.bitmapData == next.bitmapData {
                    return image(confirmation, host: host, window: window, status: .ok)
                }
                previous = confirmation
                continue
            }
            previous = next
        }
        return image(previous, host: host, window: window, status: .unstable, detail: "no two identical captures in 10 tries")
    }

    /// Height of the main scroll view's content after the first layout, scrolled back to the top.
    static func fullHeight(_ host: NSView) -> CGFloat? {
        host.layoutSubtreeIfNeeded()
        guard let scroll = largestScrollView(in: host), let document = scroll.documentView else { return nil }
        let extra = host.bounds.height - scroll.frame.height
        let height = document.frame.height + max(0, extra)
        return height > 1 ? ceil(height) : nil
    }

    static func largestScrollView(in view: NSView) -> NSScrollView? {
        var best: NSScrollView?
        func visit(_ view: NSView) {
            if let scroll = view as? NSScrollView, scroll.hasVerticalScroller || scroll.documentView != nil {
                if best == nil || scroll.frame.width * scroll.frame.height > best!.frame.width * best!.frame.height { best = scroll }
            }
            view.subviews.forEach(visit)
        }
        visit(view)
        return best
    }

    static func scrollToTop(_ view: NSView) {
        func visit(_ view: NSView) {
            if let scroll = view as? NSScrollView, let document = scroll.documentView {
                // The top is under the content inset (SwiftUI's safe-area bars), not at y = 0: scrolling to .zero
                // pushed Settings panes under their back bar and left them blank.
                let insets = scroll.contentInsets
                let y = document.isFlipped ? -insets.top
                    : document.frame.maxY - scroll.contentView.bounds.height + insets.top
                if scroll.contentView.bounds.origin != NSPoint(x: -insets.left, y: y) {
                    scroll.contentView.scroll(to: NSPoint(x: -insets.left, y: y))
                    scroll.reflectScrolledClipView(scroll.contentView)
                }
            }
            view.subviews.forEach(visit)
        }
        visit(view)
    }

    static func pump(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private struct Capture { let rep: NSBitmapImageRep; let bitmapData: Data }

    /// macOS 26 puts a « scroll pocket » (edge blur over a backdrop) under a scroll view's top bar. A backdrop
    /// samples the screen behind the window; in a never-ordered window `cacheDisplay` then draws the whole scroll
    /// view blank. The pocket is hidden: the bar shows on the page background, without the blur.
    static func hideScrollPockets(_ view: NSView) {
        if String(describing: type(of: view)).contains("ScrollPocket") {
            if !view.isHidden { view.isHidden = true }
            return
        }
        view.subviews.forEach(hideScrollPockets)
    }

    private static func capture(_ host: NSView, window: NSWindow) throws -> Capture {
        // A screen at rest, before every capture: AppKit may hand the focus to a field after the first layout.
        if window.firstResponder !== window { window.makeFirstResponder(nil) }
        hideScrollPockets(host)
        scrollToTop(host)
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        let scale = window.backingScaleFactor
        let bounds = host.bounds
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int((bounds.width * scale).rounded()),
                                         pixelsHigh: Int((bounds.height * scale).rounded()), bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 32) else {
            throw GalleryError.render("bitmap allocation failed for \(bounds.size)")
        }
        rep.size = bounds.size
        host.cacheDisplay(in: bounds, to: rep)
        guard let bytes = rep.bitmapData else { throw GalleryError.render("empty bitmap") }
        return Capture(rep: rep, bitmapData: Data(bytes: bytes, count: rep.bytesPerRow * rep.pixelsHigh))
    }

    private static func image(_ capture: Capture, host: NSView, window: NSWindow, status: GalleryImage.Status,
                              detail: String? = nil) -> GalleryImage {
        let png = capture.rep.representation(using: .png, properties: [:]) ?? Data()
        let digest = SHA256.hash(data: capture.bitmapData).map { String(format: "%02x", $0) }.joined()
        return GalleryImage(png: png, pixelHash: digest, pointSize: host.bounds.size,
                            pixelSize: (capture.rep.pixelsWide, capture.rep.pixelsHigh), backingScale: window.backingScaleFactor,
                            status: status, detail: detail, bitmap: capture.rep)
    }
}

enum GalleryError: Error, CustomStringConvertible {
    case render(String), fixture(String), guardRefused(String)
    var description: String {
        switch self {
        case let .render(text): return "render: \(text)"
        case let .fixture(text): return "fixture vide: \(text)"
        case let .guardRefused(text): return "guard: \(text)"
        }
    }
}

/// Counters of the hook's gallery guards for one image (spec C §5.2, §5.4).
struct GalleryGuardReport {
    var violations: [String] = []
    var network = 0
    var tasks = 0
    var standardDefaults = 0
    var standardStack: String?

    static func begin() { GoalongGalleryGuardsBegin() }

    static func take() -> GalleryGuardReport {
        let raw = GoalongGalleryGuardsTake() as [String: Any]
        var report = GalleryGuardReport()
        report.violations = raw["violations"] as? [String] ?? []
        report.network = (raw["network"] as? NSNumber)?.intValue ?? 0
        report.tasks = (raw["tasks"] as? NSNumber)?.intValue ?? 0
        report.standardDefaults = (raw["standardDefaults"] as? NSNumber)?.intValue ?? 0
        report.standardStack = raw["standardStack"] as? String
        return report
    }

    var isClean: Bool { violations.isEmpty && network == 0 && tasks == 0 && standardDefaults == 0 }

    /// Window orders, network and processes fail the image; a `standard` read makes it `leaky`.
    var status: GalleryImage.Status? {
        if !violations.isEmpty || network > 0 || tasks > 0 { return .failed }
        if standardDefaults > 0 { return .leaky }
        return nil
    }

    var summary: String {
        var parts: [String] = []
        if !violations.isEmpty { parts.append("violations: " + violations.joined(separator: "; ")) }
        if network > 0 { parts.append("network requests: \(network)") }
        if tasks > 0 { parts.append("processes: \(tasks)") }
        if standardDefaults > 0 { parts.append("UserDefaults.standard reads: \(standardDefaults)") }
        return parts.joined(separator: ", ")
    }
}
#endif
