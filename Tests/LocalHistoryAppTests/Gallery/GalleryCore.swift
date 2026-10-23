#if os(macOS)
import AppKit
import Foundation
import SwiftUI
@testable import LocalHistoryApp
@testable import LocalHistoryCore

/// Fixed clock of the gallery: Friday 23 October 2026, 09:41, Europe/Paris.
/// `GOALONG_GALLERY_CLOCK_PROBE=1` moves it one day later (proof that no real `Date()` reaches an entry).
enum GalleryClock {
    static let base = Date(timeIntervalSince1970: 1_792_741_260)
    static var now: Date {
        ProcessInfo.processInfo.environment["GOALONG_GALLERY_CLOCK_PROBE"] == "1" ? base.addingTimeInterval(86_400) : base
    }
    static let timeZone = TimeZone(identifier: "Europe/Paris")!
    static let locale = Locale(identifier: "fr_FR")
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.locale = locale
        calendar.firstWeekday = 2
        return calendar
    }
    static var today: Date { calendar.startOfDay(for: now) }
    /// A time of the gallery day.
    static func at(_ hour: Int, _ minute: Int = 0, dayOffset: Int = 0) -> Date {
        let day = calendar.date(byAdding: .day, value: dayOffset, to: today)!
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
    }
}

enum GalleryTheme: String, CaseIterable {
    case light, dark, lightContrast = "light-contrast", darkContrast = "dark-contrast"
    var appearance: NSAppearance {
        switch self {
        case .light: return NSAppearance(named: .aqua)!
        case .dark: return NSAppearance(named: .darkAqua)!
        case .lightContrast: return NSAppearance(named: .accessibilityHighContrastAqua)!
        case .darkContrast: return NSAppearance(named: .accessibilityHighContrastDarkAqua)!
        }
    }
    var isDark: Bool { self == .dark || self == .darkContrast }
    static let standard: [GalleryTheme] = [.light, .dark]
    static let withContrast: [GalleryTheme] = [.light, .dark, .lightContrast, .darkContrast]
}

/// How big an image is. Panels and sheets take their fitting height at a given width.
enum GallerySize: Equatable {
    case fixed(CGFloat, CGFloat)
    case fitWidth(CGFloat)
    /// Scrolling page rendered whole: the height of the main scroll view's content (max 6000 pt).
    case full(CGFloat)

    static let window = GallerySize.fixed(1240, 790)
    static let minimum = GallerySize.fixed(900, 620)
    static let large = GallerySize.fixed(1600, 1000)

    /// File-name suffix; the dashboard's real size has none.
    var label: String? {
        switch self {
        case .fixed(1240, 790), .fitWidth: return nil
        case let .fixed(w, h): return "\(Int(w))x\(Int(h))"
        case .full: return "full"
        }
    }
}

/// Whether an entry shows "now" through an injected clock, or shows no date at all.
enum GalleryClockUse { case injected, none }

/// Simulated system state (permissions, disk, identity, CLI, protection service), one per entry.
struct GalleryEnvironment {
    var permissions = PermissionStatus.galleryAllGranted
    var freeBytes: Int64? = 120_000_000_000
    var identity = ProductIdentity.GalleryIdentity()
}

extension PermissionStatus {
    static var galleryAllGranted: PermissionStatus {
        PermissionStatus.resolved(accessibilityPreflight: true, accessibilityFunctionalProbe: true,
                                  inputMonitoringDirectlyGranted: true, accessibilityCrossProcessProbe: true,
                                  accessibilityProbeError: nil)
    }
    static var galleryMissing: PermissionStatus {
        PermissionStatus.resolved(accessibilityPreflight: false, accessibilityFunctionalProbe: false,
                                  inputMonitoringDirectlyGranted: false, accessibilityCrossProcessProbe: false,
                                  accessibilityProbeError: nil)
    }
}

/// What an entry gets: its own preferences, home, environment and theme.
@MainActor final class GalleryContext {
    let defaults: UserDefaults
    let suiteName: String
    let home: URL
    var environment: GalleryEnvironment
    var theme: GalleryTheme = .light
    /// Objects the entry keeps alive while it renders (models, runtimes), released after.
    var retained: [AnyObject] = []
    /// Called once after the render (stop timers, runtimes).
    var cleanups: [() -> Void] = []

    init(environment: GalleryEnvironment = GalleryEnvironment()) {
        suiteName = "goalong-gallery-" + UUID().uuidString
        defaults = UserDefaults(suiteName: suiteName)!
        home = FileManager.default.homeDirectoryForCurrentUser
        self.environment = environment
    }

    var now: Date { GalleryClock.now }

    @discardableResult func keep<T: AnyObject>(_ object: T) -> T { retained.append(object); return object }

    func finish() {
        for cleanup in cleanups.reversed() { cleanup() }
        cleanups = []
        retained = []
    }
}

/// One surface in one state. Rendered for every theme × size it lists.
struct GalleryEntry {
    let id: String
    var sizes: [GallerySize]
    var themes: [GalleryTheme] = GalleryTheme.standard
    var clock: GalleryClockUse = .none
    /// The page draws on the dashboard window (title, background, minimum size) rather than a bare panel.
    var dashboardWindow = false
    /// Background painted behind a panel's content (sheets render alone on the page background).
    var pageBackground = true
    /// Ready before capture (data loaded). Polled every 20 ms, at most 3 s.
    var ready: (@MainActor (GalleryContext) -> Bool)?
    /// Known render limits shown in the index (for example a flat grey behind-window material).
    var note: String?
    /// Dashboard destination or Settings pane the entry shows (coverage guard).
    var section: DashboardSection?
    var pane: SettingsPane?
    /// Catalog file that declares the entry (manifest, index).
    var source: String
    let view: @MainActor (GalleryContext) throws -> AnyView

    init(_ id: String, sizes: [GallerySize], themes: [GalleryTheme] = GalleryTheme.standard, clock: GalleryClockUse = .none,
         dashboardWindow: Bool = false, pageBackground: Bool = true, note: String? = nil,
         section: DashboardSection? = nil, pane: SettingsPane? = nil,
         ready: (@MainActor (GalleryContext) -> Bool)? = nil, file: String = #fileID,
         view: @escaping @MainActor (GalleryContext) throws -> AnyView) {
        self.id = id; self.sizes = sizes; self.themes = themes; self.clock = clock
        self.dashboardWindow = dashboardWindow; self.pageBackground = pageBackground
        self.note = note; self.section = section; self.pane = pane
        self.ready = ready; self.view = view
        self.source = String(file.split(separator: "/").last ?? Substring(file))
    }

    var surface: String { String(id.split(separator: "/").first ?? "") }
    var state: String { String(id.split(separator: "/").dropFirst().first ?? "") }

    /// Stable shard of an id: FNV-1a 64 (not `hashValue`, which changes with each process).
    static func shard(of id: String, count: Int) -> Int {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in id.utf8 { hash ^= UInt64(byte); hash = hash &* 0x0000_0100_0000_01b3 }
        return Int(hash % UInt64(max(1, count)))
    }
}
#endif
