#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import LocalHistoryApp

/// Opt-in renders of the Blocage page, its veils and the frozen shield, with fixed data only.
/// `GOALONG_BLOCKING_SNAPSHOTS=<dir> swift test --filter BlockingPageRenderingTests`
final class BlockingPageRenderingTests: XCTestCase {
    /// Monday 5 October 2026, 15:10.
    private let now = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: 15, minute: 10))!

    @MainActor func testRenderBlockingSurfaces() throws {
        guard let path = ProcessInfo.processInfo.environment["GOALONG_BLOCKING_SNAPSHOTS"] else {
            throw XCTSkip("Opt-in native rendering with fixed data only")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory); app.finishLaunching()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 800),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil); window.contentViewController = nil }
        let fixtures = Fixtures(now: now)

        func render(_ name: String, width: CGFloat, height: CGFloat? = nil, _ view: some View) throws {
            let root = view.frame(width: width).fixedSize(horizontal: false, vertical: height == nil)
                .frame(height: height)
                .background(LHTheme.pageBackground).foregroundStyle(LHTheme.text).tint(LHTheme.accent)
                .environment(\.goalongReduceMotion, true).goalongControls()
            let controller = NSHostingController(rootView: root)
            window.contentViewController = controller
            window.setContentSize(NSSize(width: width, height: height ?? 900))
            window.makeKeyAndOrderFront(nil)
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            let host = controller.view
            let fitted = height ?? max(400, host.fittingSize.height)
            window.setContentSize(NSSize(width: width, height: fitted))
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            XCTAssertGreaterThan(data.count, 4_000)
            try data.write(to: directory.appendingPathComponent("\(name).png"))
            print("BLOCKING_RENDER \(name) \(bitmap.pixelsWide)x\(bitmap.pixelsHigh)")
        }

        for dark in [true, false] {
            app.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.appearance = app.appearance
            let suffix = dark ? "dark" : "light"
            // The page is a scroll view: render its content at full height.
            func page(_ controller: BlockingController, expanded: UUID? = nil, at date: Date? = nil) -> some View {
                BlockingPageContent(controller: controller, now: date ?? now, expanded: expanded)
            }
            let sunday = now.addingTimeInterval(-86_400)
            try render("page-empty-\(suffix)", width: 900, height: 900, page(fixtures.empty()))
            try render("page-idle-\(suffix)", width: 900, height: 1_500, page(fixtures.idle(), at: sunday))
            try render("page-active-\(suffix)", width: 900, height: 1_500, page(fixtures.active()))
            let editing = fixtures.idle()
            try render("list-sheet-\(suffix)", width: 600, height: 900,
                       BlockListSheet(controller: editing, listID: fixtures.social.id, now: sunday, onDone: {}))
            let locked = fixtures.active()
            try render("list-sheet-locked-\(suffix)", width: 600, height: 900,
                       BlockListSheet(controller: locked, listID: fixtures.video.id, now: now, onDone: {}))
            try render("range-popover-\(suffix)", width: 400,
                       BlockingRangePopover(controller: editing,
                                            draft: BlockingRangeDraft(existing: nil, listIDs: [fixtures.social.id], days: [1, 2, 3, 4, 5],
                                                                      start: 540, end: 720),
                                            now: sunday, onClose: {}))
            try render("protection-\(suffix)", width: 440, BlockingProtectionDetails(controller: editing).padding(18))
            try render("modules-\(suffix)", width: 760, GoalongModulesSettings(onOpen: { _ in }).padding(32))
            try render("typing-\(suffix)", width: 560,
                       BlockingTypingChallengeSheet(text: String(repeating: "aB3kZ", count: 24), onSubmit: { _ in }, onCancel: {}))
            for (name, reason) in [("site", BlockingVeilPresentation.Reason.site("youtube.com")),
                                   ("private", .privateWindow),
                                   ("unsupported", .unsupportedBrowser("Firefox")),
                                   ("quota", .quotaUsed("instagram.com", minutes: 30))] {
                let veil = BlockingVeilPresentation(reason: reason, listName: "Réseaux sociaux",
                    start: now.addingTimeInterval(-50 * 60), end: now.addingTimeInterval(70 * 60),
                    lock: .locked, breakMinutes: 5, breaksLeft: 2)
                try render("veil-\(name)-\(suffix)", width: 1_100, height: 720, BlockedSiteVeil(presentation: veil, now: now))
            }
            try render("app-notice-\(suffix)", width: 420,
                       BlockedAppNotice(app: BlockAppRule(bundleIdentifier: "com.apple.Music", name: "Musique"),
                                        end: now.addingTimeInterval(4_200), lock: .locked, listName: "Distractions")
                        .padding(20))
            try render("freeze-\(suffix)", width: 1_280, height: 800, FrozenMacShield(freeze: fixtures.freeze, now: now))
        }
    }

    @MainActor private struct Fixtures {
        let now: Date

        var social: BlockList {
            BlockList(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, name: "Réseaux sociaux",
                      sites: ["x.com", "instagram.com", "facebook.com", "tiktok.com", "reddit.com"].map { BlockSiteRule(pattern: $0) },
                      apps: [BlockAppRule(bundleIdentifier: "com.apple.MobileSMS", name: "Messages")],
                      program: BlockProgram(ranges: [BlockProgramRange(weekdays: Set(1...5), startMinute: 540, endMinute: 1_080)],
                                            lockedUntil: nil),
                      quotaMinutesPerDay: 20, breaks: BlockBreaks(count: 3, minutes: 5))
        }
        var video: BlockList {
            BlockList(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, name: "Vidéo",
                      sites: ["youtube.com", "netflix.com", "twitch.tv"].map { BlockSiteRule(pattern: $0) },
                      apps: [BlockAppRule(bundleIdentifier: "com.apple.TV", name: "TV"),
                             BlockAppRule(bundleIdentifier: "com.apple.Music", name: "Musique")],
                      program: BlockProgram(ranges: [BlockProgramRange(weekdays: Set(1...7), startMinute: 1_290, endMinute: 420)],
                                            lockedUntil: now.addingTimeInterval(20 * 86_400)))
        }
        var focus: BlockList {
            BlockList(id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!, name: "Écriture", mode: .allowOnly,
                      sites: ["docs.google.com", "notion.so"].map { BlockSiteRule(pattern: $0) },
                      apps: [BlockAppRule(bundleIdentifier: "com.apple.Notes", name: "Notes"),
                             BlockAppRule(bundleIdentifier: "com.apple.iWork.Pages", name: "Pages")])
        }

        func empty() -> BlockingController { BlockingController(clock: { now }) }

        func idle() -> BlockingController {
            var document = BlockingDocument()
            document.lists = [social, video, focus]
            // Outside every program window: Sunday.
            let sunday = now.addingTimeInterval(-86_400)
            let controller = BlockingController(document: document, clock: { sunday })
            return controller
        }

        func active() -> BlockingController {
            var document = BlockingDocument()
            document.lists = [social, video, focus]
            document.sessions = [BlockSession(listIDs: [social.id, focus.id], start: now.addingTimeInterval(-50 * 60),
                                              end: now.addingTimeInterval(84 * 60), lock: .locked)]
            var usage = BlockDayUsage(day: BlockingController.dayKey(now))
            usage.quotaSecondsUsed[social.id] = 13 * 60
            usage.breaksTaken[social.id] = 1
            document.usage = usage
            return BlockingController(document: document, clock: { now })
        }

        var freeze: BlockFreeze {
            BlockFreeze(start: now.addingTimeInterval(-20 * 60), end: now.addingTimeInterval(64 * 60 + 12), mode: .shield,
                        allowedApps: [BlockAppRule(bundleIdentifier: "com.apple.Notes", name: "Notes"),
                                      BlockAppRule(bundleIdentifier: "com.apple.iCal", name: "Calendrier")])
        }
    }
}
#endif
