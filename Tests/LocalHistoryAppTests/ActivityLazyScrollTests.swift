#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import LocalHistoryApp

/// R14a step 3: Activité is a lazy stack (the page) holding a lazy stack (the summary). Coming back from a named
/// view scrolls to « activity-explore », a section far under the window that the lazy stack has not built yet.
/// Same structure as GoalongAnalyticsPage / GoalongActivityContent: the scroll must still reach it.
@MainActor
final class ActivityLazyScrollTests: XCTestCase {
    private struct Summary: View {
        var body: some View {
            LazyVStack(alignment: .leading, spacing: 24) {
                ForEach(0..<12, id: \.self) { index in
                    Color.gray.frame(height: 300).accessibilityIdentifier("block-\(index)")
                }
                Text("Explorer").frame(height: 80).id("activity-explore").accessibilityIdentifier("explore")
                Color.gray.frame(height: 600)
            }
        }
    }

    private final class Target: ObservableObject { @Published var id: String? }

    private struct Page: View {
        @ObservedObject var target: Target
        var body: some View {
            ScrollViewReader { scroller in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        Color.clear.frame(height: 0).id("activity-top")
                        Summary()
                    }
                }
                .onChange(of: target.id) { id in
                    DispatchQueue.main.async { if let id { scroller.scrollTo(id, anchor: .center) } }
                }
            }
        }
    }

    func testScrollingToASectionTheLazyStacksHaveNotBuiltYetReachesIt() throws {
        try GalleryRenderer.withPreparedApplication {
            let target = Target()
            let window = GalleryWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
                                       styleMask: [.titled], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            defer { window.contentView = nil; window.close() }
            let host = NSHostingView(rootView: Page(target: target))
            window.contentView = host
            spin(host, 0.2)
            XCTAssertNil(ViewSwitchAX.first(in: host) { $0 == "explore" }, "the section under the window was built eagerly")
            target.id = "activity-explore"
            let start = Date()
            while ViewSwitchAX.first(in: host, where: { $0 == "explore" }) == nil && Date().timeIntervalSince(start) < 5 {
                spin(host, 0.05)
            }
            spin(host, 0.2)
            let scroll = try XCTUnwrap(Self.scrollView(in: host))
            let visible = scroll.contentView.documentVisibleRect
            // The section sits at 12 × 324 = 3888 pt from the top; centred, the window shows it.
            XCTAssertNotNil(ViewSwitchAX.first(in: host) { $0 == "explore" }, "the scroll did not reach the lazy section")
            XCTAssertGreaterThan(visible.minY, 3000, "the scroll stayed near the top: \(visible)")
            XCTAssertLessThan(visible.minY, 3928, "the section is above the window: \(visible)")
        }
    }

    private func spin(_ host: NSView, _ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
            host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        }
    }

    private static func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for child in view.subviews { if let scroll = scrollView(in: child) { return scroll } }
        return nil
    }
}
#endif
