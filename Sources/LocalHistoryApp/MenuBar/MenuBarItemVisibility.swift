#if os(macOS)
import AppKit
import Combine
import os
import SwiftUI

/// T-048: macOS 26 can park the status item off screen (« Autoriser dans la barre des menus » off) or
/// hide it under the notch when the bar is full. The item still exists; only its window's frame tells.
enum MenuBarItemVisibility: String, Equatable {
    case shown, parkedBySystem, underNotch, unknown

    struct Screen: Equatable {
        var frame: CGRect
        var visibleFrame: CGRect
        var topLeftArea: CGRect?
        var topRightArea: CGRect?
        init(frame: CGRect, visibleFrame: CGRect? = nil, topLeftArea: CGRect? = nil, topRightArea: CGRect? = nil) {
            self.frame = frame; self.visibleFrame = visibleFrame ?? frame
            self.topLeftArea = topLeftArea; self.topRightArea = topRightArea
        }
        @MainActor init(_ screen: NSScreen) {
            self.init(frame: screen.frame, visibleFrame: screen.visibleFrame,
                      topLeftArea: screen.auxiliaryTopLeftArea, topRightArea: screen.auxiliaryTopRightArea)
        }
    }

    /// Pure: the item's window frame against the screens' top bands (menu bar height, 24 pt at least).
    static func state(itemFrame: CGRect, screens: [Screen]) -> MenuBarItemVisibility {
        guard !screens.isEmpty, !itemFrame.isNull, !itemFrame.isEmpty else { return .unknown }
        for screen in screens {
            let height = max(screen.frame.maxY - screen.visibleFrame.maxY, 24)
            let band = CGRect(x: screen.frame.minX, y: screen.frame.maxY - height, width: screen.frame.width, height: height)
            guard itemFrame.intersects(band) else { continue }
            if let left = screen.topLeftArea, let right = screen.topRightArea, right.minX > left.maxX,
               itemFrame.midX > left.maxX, itemFrame.midX < right.minX { return .underNotch }
            return .shown
        }
        return .parkedBySystem
    }

    var isHidden: Bool { self == .parkedBySystem || self == .underNotch }

    var message: String? {
        switch self {
        case .parkedBySystem:
            return "macOS masque l’icône de Goalong. Réglages Système › Barre des menus › Autoriser dans la barre des menus : active Goalong History."
        case .underNotch: return "L’icône de Goalong est cachée sous l’encoche : la barre des menus est trop pleine."
        case .shown, .unknown: return nil
        }
    }

    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension")!
}

/// Reads the item 3 s and 10 s after launch and at each screen change. The banner shows after two hidden
/// readings in a row, then a reading every 10 s hides it once the icon is back. `.unknown` never shows anything.
@MainActor final class MenuBarVisibilityWatch: ObservableObject {
    static let shared = MenuBarVisibilityWatch()
    @Published private(set) var banner: MenuBarItemVisibility?
    private var last: MenuBarItemVisibility?
    private var read: (@MainActor () -> (frame: CGRect, screens: [MenuBarItemVisibility.Screen]))?
    private var observer: NSObjectProtocol?
    private var recheck: Timer?
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ai.goalong.localhistory",
                                       category: "menubar-visibility")

    func start(read: @escaping @MainActor () -> (frame: CGRect, screens: [MenuBarItemVisibility.Screen])) {
        guard self.read == nil else { return }
        self.read = read
        for delay in [3.0, 10.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in MainActor.assumeIsolated { self?.check() } }
        }
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
    }

    func check() {
        guard let read else { return }
        let reading = read()
        record(MenuBarItemVisibility.state(itemFrame: reading.frame, screens: reading.screens), frame: reading.frame)
    }

    func record(_ state: MenuBarItemVisibility, frame: CGRect) {
        let f = frame
        Self.logger.notice("state=\(state.rawValue, privacy: .public) frame=\(Int(f.minX), privacy: .public),\(Int(f.minY), privacy: .public),\(Int(f.width), privacy: .public),\(Int(f.height), privacy: .public)")
        if state.isHidden { if last?.isHidden == true { banner = state } } else { banner = nil }
        last = state
        if banner != nil, recheck == nil, read != nil {
            let timer = Timer(timeInterval: 10, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.check() } }
            timer.tolerance = 2; RunLoop.main.add(timer, forMode: .common); recheck = timer
        } else if banner == nil { recheck?.invalidate(); recheck = nil }
    }
}

/// Top of the dashboard while the menu bar icon is hidden.
struct GoalongMenuBarVisibilityBanner: View {
    @ObservedObject var watch: MenuBarVisibilityWatch
    var body: some View {
        if let state = watch.banner { MenuBarVisibilityNotice(state: state) }
    }
}

struct MenuBarVisibilityNotice: View {
    let state: MenuBarItemVisibility
    var body: some View {
        if let message = state.message {
            GoalongBanner(symbol: "menubar.rectangle", title: "Icône Goalong masquée", detail: message, tone: .warning) {
                Button("Ouvrir les réglages") {
                    GoalongWorkspaceOpenPolicy.open(MenuBarItemVisibility.settingsURL, purpose: .systemSettings)
                }
                .accessibilityIdentifier("menubar-visibility-open-settings")
            }
            .padding(.horizontal, LHTheme.pageInset).padding(.top, 12)
        }
    }
}
#endif
