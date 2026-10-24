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
    /// One-line fields whose height is not their own text height (`GalleryRenderer.misMeasuredFields`).
    var misMeasuredFields: [String] = []
    /// Raw RGBA bytes, kept for in-memory checks (smoke test).
    let bitmap: NSBitmapImageRep
}

/// Renders a gallery entry in a window that is never ordered on screen (`defer: true`): no window appears, the app
/// never activates. The only rendering helper of the gallery (spec C §4).
@MainActor enum GalleryRenderer {
    static let maximumFullHeight: CGFloat = 6_000
    static let fallbackFullHeight: CGFloat = 1_500
    /// A whole page is measured in a window of the dashboard's height: a shorter page keeps that height instead of
    /// an empty band down to the fallback height.
    static let fullStartHeight: CGFloat = 790

    /// Preferences of the process-wide services the pages reach (one throwaway suite per process).
    static let processDefaults = UserDefaults(suiteName: "goalong-gallery-" + UUID().uuidString)!

    static func prepareApplication() {
        let app = NSApplication.shared
        if app.activationPolicy() != .accessory { app.setActivationPolicy(.accessory) }
        NSTimeZone.default = GalleryClock.timeZone
        GoalongToastCenter.suppressedForTesting = true
        ProductIdentity.galleryOverride = ProductIdentity.GalleryIdentity()
        GoalongApplicationCatalog.galleryApplications = GalleryFixtures.installedApplications
        // No LaunchServices read: the invented apps decide what is installed, every icon is the app's initial
        // (C2-outil-01, C2-couverture-05).
        AppIconView.galleryHidesHostIcons = true
        AppIconView.galleryIconProvider = { GalleryFixtures.applicationIcon(bundleIdentifier: $0) }
        // History's analysis passes: a throwaway suite (the hook deletes it) and the frozen clock.
        ActivityAnalysisRuntime.shared.preferences = processDefaults
        ActivityAnalysisRuntime.shared.clock = { GalleryClock.now }
        // « Aujourd’hui » in the views is the gallery day, whatever the real date (C2-couverture-02).
        GoalongToday.galleryClock = { GalleryClock.now }
        warmSingletons()
    }

    /// The process-wide values `prepareApplication` changes. The gallery's own process never restores them; a test
    /// inside `make test` must, since every later test class runs in the same process (C1-outil-04).
    struct ProcessGlobals {
        let timeZone: TimeZone
        let toastsSuppressed: Bool
        let identity: ProductIdentity.GalleryIdentity?
        let analysisPreferences: UserDefaults
        let analysisClock: () -> Date
        let applications: [GoalongApplicationChoice]?
        let today: (() -> Date)?
        let hidesHostIcons: Bool
        let iconProvider: ((String) -> NSImage?)?
        let activationPolicy: NSApplication.ActivationPolicy
    }

    static func saveGlobals() -> ProcessGlobals {
        ProcessGlobals(timeZone: NSTimeZone.default, toastsSuppressed: GoalongToastCenter.suppressedForTesting,
                       identity: ProductIdentity.galleryOverride,
                       analysisPreferences: ActivityAnalysisRuntime.shared.preferences,
                       analysisClock: ActivityAnalysisRuntime.shared.clock,
                       applications: GoalongApplicationCatalog.galleryApplications,
                       today: GoalongToday.galleryClock, hidesHostIcons: AppIconView.galleryHidesHostIcons,
                       iconProvider: AppIconView.galleryIconProvider,
                       activationPolicy: NSApplication.shared.activationPolicy())
    }

    static func restoreGlobals(_ saved: ProcessGlobals) {
        NSTimeZone.default = saved.timeZone
        GoalongToastCenter.suppressedForTesting = saved.toastsSuppressed
        ProductIdentity.galleryOverride = saved.identity
        ActivityAnalysisRuntime.shared.preferences = saved.analysisPreferences
        ActivityAnalysisRuntime.shared.clock = saved.analysisClock
        GoalongApplicationCatalog.galleryApplications = saved.applications
        GoalongToday.galleryClock = saved.today
        AppIconView.galleryHidesHostIcons = saved.hidesHostIcons
        AppIconView.galleryIconProvider = saved.iconProvider
        let app = NSApplication.shared
        if app.activationPolicy() != saved.activationPolicy { app.setActivationPolicy(saved.activationPolicy) }
    }

    /// `prepareApplication`, `body`, then the process globals as they were, even when `body` throws.
    static func withPreparedApplication<T>(_ body: () throws -> T) rethrows -> T {
        let saved = saveGlobals()
        defer { restoreGlobals(saved) }
        prepareApplication()
        return try body()
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
        switch size {
        case let .fixed(width, height): content = AnyView(content.frame(width: width, height: height))
        case let .fitWidth(width):
            // Top-aligned in a frame that fills the window: the window height is rounded up to a whole point, and
            // the page colour below covers that rest instead of a transparent row (C2-couverture-04).
            content = AnyView(content.frame(width: width).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top))
        case let .full(width): content = AnyView(content.frame(width: width).frame(maxHeight: .infinity))
        }
        if entry.pageBackground && !entry.dashboardWindow {
            // After the size frame: a panel smaller than its fixed size sits on the page colour, not on
            // transparent margins (spec C §4.5).
            content = AnyView(content.background(LHTheme.pageBackground).foregroundStyle(LHTheme.text)
                .tint(LHTheme.accent).accentColor(LHTheme.accent).goalongControls())
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

    /// Renders one image. SwiftUI sizes a one-line field once, while it builds it, and now and then from another
    /// field's font: 15 pt for a 13 pt field, 16 pt for a 12 pt one (about one image in 40 for
    /// programme/feuille-liste-verrouillee, in any process, loaded or not). It never measures it again, so the text
    /// or every row below it sits half a point or a point off. Such a render is made again from a new view.
    static func render(_ entry: GalleryEntry, theme: GalleryTheme, size: GallerySize, ctx: GalleryContext) throws -> GalleryImage {
        var image = try renderOnce(entry, theme: theme, size: size, ctx: ctx)
        for _ in 1..<6 where image.status == .ok && !image.misMeasuredFields.isEmpty {
            FileHandle.standardError.write(Data(("[gallery] render again, \(entry.id) \(theme.rawValue): "
                + image.misMeasuredFields.joined(separator: ", ") + "\n").utf8))
            image = try renderOnce(entry, theme: theme, size: size, ctx: ctx)
        }
        if !image.misMeasuredFields.isEmpty && image.status == .ok {
            image.status = .unstable
            image.detail = "field sized from another font in 6 renders: " + image.misMeasuredFields.joined(separator: ", ")
        }
        return image
    }

    /// One render. Never orders the window; the window is closed and released before returning.
    private static func renderOnce(_ entry: GalleryEntry, theme: GalleryTheme, size: GallerySize, ctx: GalleryContext) throws -> GalleryImage {
        ctx.theme = theme
        let start: NSSize
        switch size {
        case let .fixed(width, height): start = NSSize(width: width, height: height)
        case let .fitWidth(width): start = NSSize(width: width, height: 900)
        case let .full(width): start = NSSize(width: width, height: fullStartHeight)
        }
        let window = GalleryWindow(contentRect: NSRect(origin: .zero, size: start),
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
        // Data first: the entry's own predicate (20 ms polls, 6 s at most: under load, with builds running beside, data can take more than 3 s).
        if let ready = entry.ready {
            let deadline = Date().addingTimeInterval(6)
            var isReady = ready(ctx)
            while !isReady && Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
                isReady = ready(ctx)
            }
            if !isReady {
                let capture = try capture(host, window: window)
                return image(capture, host: host, window: window, status: .notReady, detail: "ready predicate not met in 6 s")
            }
        }
        pump(0.05)
        _ = fitContent(size, window: window, host: host, start: start)
        // A screen at rest: no field keeps the focus (its placeholder and caret change with it, at random times).
        window.makeFirstResponder(nil)
        // Stability: two identical captures in a row, confirmed by a third 150 ms later (a late AppKit redraw under a
        // loaded Mac once slipped between two captures 50 ms apart), at most 10 rounds.
        var previous = try capture(host, window: window)
        for _ in 0..<10 {
            pump(0.05)
            // A late layout (a row that appears or leaves after the first measure) changes the fitted height: the
            // window follows it before the capture counts, else one run in two kept 10 pt of empty page (C2-outil-02).
            if fitContent(size, window: window, host: host, start: start) {
                previous = try capture(host, window: window)
                continue
            }
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

    /// Sets a fitted or whole-page window to its content's current height; true when the size changed.
    static func fitContent(_ size: GallerySize, window: NSWindow, host: NSView, start: NSSize) -> Bool {
        let target: NSSize
        switch size {
        case .fitWidth(let width):
            let height = ceil(host.fittingSize.height)
            target = NSSize(width: width, height: max(60, min(height, maximumFullHeight)))
        case .full(let width):
            let height = fullHeight(host) ?? fallbackFullHeight  // floor: start.height, the window's
            target = NSSize(width: width, height: min(maximumFullHeight, max(start.height, height)))
        case .fixed: return false
        }
        guard host.bounds.size != target else { return false }
        window.setContentSize(target)
        host.layoutSubtreeIfNeeded()
        return true
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

    /// One-line fields (scrolling, not wrapping) whose height differs from their own text height. A field always
    /// gets that height when SwiftUI measures it right (`GoalongFieldStyle` fixes it); a wrapping field may be taller.
    static func misMeasuredFields(_ view: NSView) -> [String] {
        var fields: [String] = []
        func visit(_ view: NSView) {
            if let field = view as? NSTextField, let cell = field.cell, cell.isScrollable, !cell.wraps,
               field.intrinsicContentSize.height > 0, field.bounds.height != field.intrinsicContentSize.height {
                fields.append("« \((field.placeholderString ?? field.stringValue).prefix(24)) » \(field.bounds.height) pt"
                              + " for \(field.intrinsicContentSize.height)")
            }
            view.subviews.forEach(visit)
        }
        visit(view)
        return fields
    }

    static func markNeedsDisplay(_ view: NSView) {
        view.needsDisplay = true
        view.subviews.forEach(markNeedsDisplay)
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
        // Every view draws again with the current state: a layer-backed text field kept, about once in 700 images,
        // a placeholder drawn in an earlier state (slightly other grey).
        markNeedsDisplay(host)
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
                            status: status, detail: detail, misMeasuredFields: misMeasuredFields(host), bitmap: capture.rep)
    }
}

/// The gallery's window never hands the focus to a view. A field that held it once, even for a moment before the
/// capture cleared it, could keep its text drawn half a point lower (one image in about 650, C2-outil-02).
final class GalleryWindow: NSWindow {
    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        guard responder == nil || responder === self else { return false }
        return super.makeFirstResponder(responder)
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
