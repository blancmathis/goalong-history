#if os(macOS)
import AppKit
import Foundation
import XCTest
import LocalHistoryCore
@testable import LocalHistoryApp

final class JevObservationRuntimeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_300_000)
    private func context(host: String = "youtube.com", path: String = "/watch", title: String = "Quiet video",
                         element: ElementSnapshot? = nil, suppressed: SuppressionReason? = nil) -> ContextSnapshot {
        .init(app: .init(name: "Synthetic Browser", bundleIdentifier: "test.browser", processIdentifier: 42),
              window: .init(title: title, role: nil, subrole: nil), focusedElement: element,
              url: .init(value: "https://\(host)\(path)?private=value", host: host, redactionApplied: true),
              suppressionReason: suppressed)
    }
    private func presence(_ date: Date, idle: Double = 120, evidence: ForegroundActivityEvidence? = nil,
                          visible: Bool = true) -> ForegroundUsageObservation {
        .init(observedAt: date, idleSeconds: idle, isForegroundVisible: visible, evidence: evidence)
    }
    private func inbox(text: Bool = false) -> JevIngress {
        let value = JevIngress(notificationCenter: NotificationCenter(), contextIsPermitted: {
            $0.suppressionReason == nil && $0.focusedElement?.isSecure != true
        })
        value.configure(enabled: true, includeText: text, now: now)
        return value
    }
    func testQuietVideoAndFeedProduceEvidenceInEveryAdjacentWindow() throws {
        for host in ["youtube.com", "x.com"] {
            let ingress = inbox(), ctx = context(host: host)
            for window in 0..<12 {
                for second in stride(from: window * 15, to: (window + 1) * 15, by: 5) {
                    let date = now.addingTimeInterval(Double(second))
                    ingress.observeContext(ctx, foregroundEvidence: nil, presence: presence(date), now: date)
                }
                let start = now.addingTimeInterval(Double(window * 15))
                let result = try XCTUnwrap(ingress.take(start: start, end: start.addingTimeInterval(15)))
                XCTAssertTrue(result.hasActivity)
                XCTAssertEqual(result.samples.count, 3)
                XCTAssertTrue(result.samples.allSatisfy { $0.surface == (host == "x.com" ? "social-feed" : "video") })
                XCTAssertTrue(result.samples.allSatisfy { !$0.resource.contains("private") && $0.action == "foreground" })
            }
        }
    }
    func testObservedPlaybackContinuesAfterReadingIdleLimitButBackgroundAssertionDoesNot() throws {
        for evidence in [ForegroundActivityEvidence.mediaPlayback, .displayAssertion] {
            let ingress = inbox(), date = now.addingTimeInterval(5)
            ingress.observeContext(context(), foregroundEvidence: evidence,
                presence: presence(date, idle: 3600, evidence: evidence), now: date)
            let window = try XCTUnwrap(ingress.take(start: now, end: now.addingTimeInterval(15)))
            XCTAssertEqual(window.hasActivity, evidence == .mediaPlayback)
        }
        let ingress = inbox()
        ingress.observeContext(context(), foregroundEvidence: .mediaPlayback,
            presence: presence(now, idle: 3600, evidence: .mediaPlayback, visible: false), now: now)
        XCTAssertFalse(try XCTUnwrap(ingress.take(start: now, end: now.addingTimeInterval(15))).hasActivity)
    }
    func testChangedContextIsNotLostInsideTheFiveSecondRefreshInterval() throws {
        let ingress = inbox()
        ingress.observeContext(context(), foregroundEvidence: nil, presence: presence(now), now: now)
        let changed = now.addingTimeInterval(1)
        ingress.observeContext(context(host: "x.com"), foregroundEvidence: nil, presence: presence(changed), now: changed)
        let window = try XCTUnwrap(ingress.take(start: now, end: now.addingTimeInterval(15)))
        XCTAssertEqual(window.samples.map(\.resource), ["youtube.com", "x.com"])
    }
    func testComposerSearchMessagingAndVideoFeedAreNotAllTheSameUse() {
        let composer = ElementSnapshot(role: "AXTextArea", subrole: nil, title: nil, label: "Post text", identifier: nil, isSecure: false)
        XCTAssertEqual(JevIngress.foregroundSample(context(host: "x.com", element: composer), evidence: nil, at: now).surface, "composer")
        XCTAssertEqual(JevIngress.foregroundSample(context(host: "x.com", path: "/compose/post"), evidence: nil, at: now).surface, "composer")
        XCTAssertEqual(JevIngress.foregroundSample(context(host: "x.com", path: "/search"), evidence: nil, at: now).surface, "social-search")
        XCTAssertEqual(JevIngress.foregroundSample(context(host: "x.com", path: "/messages/123"), evidence: nil, at: now).surface, "messaging")
        XCTAssertEqual(JevIngress.foregroundSample(context(path: "/"), evidence: nil, at: now).surface, "video-feed")
        XCTAssertEqual(JevIngress.foregroundSample(context(host: "studio.youtube.com"), evidence: nil, at: now).surface, "other")
    }
    func testPrivateBoundaryRevocationAndLateExcerptsFailClosed() throws {
        let ingress = inbox(text: true), ctx = context()
        let generation = ingress.generation
        ingress.observeContext(ctx, foregroundEvidence: nil, presence: presence(now), now: now)
        ingress.setPrivateWindow(true)
        ingress.offerVisibleText("This private text must never reach a request", context: ctx, at: now, generation: generation)
        XCTAssertNil(ingress.take(start: now, end: now.addingTimeInterval(15)))
        ingress.setPrivateWindow(false)
        ingress.configure(enabled: true, includeText: false, now: now)
        ingress.observeContext(ctx, foregroundEvidence: nil, presence: presence(now), now: now)
        ingress.offerVisibleText("Consent has been revoked", context: ctx, at: now, generation: ingress.generation)
        let window = try XCTUnwrap(ingress.take(start: now, end: now.addingTimeInterval(15)))
        XCTAssertTrue(window.samples.allSatisfy { $0.excerpt.isEmpty })
        ingress.configure(enabled: true, includeText: true, now: now)
        ingress.offerVisibleText("Late response from an earlier generation", context: ctx, at: now, generation: generation)
        XCTAssertTrue(try XCTUnwrap(ingress.take(start: now, end: now.addingTimeInterval(15))).samples.isEmpty)
    }
    func testFreshVisibleTextIsSeparateAndCannotCauseACheckByItself() throws {
        let ingress = inbox(text: true)
        ingress.offerVisibleText("Visible topic about football highlights", context: context(), at: now, generation: ingress.generation)
        let window = try XCTUnwrap(ingress.take(start: now, end: now.addingTimeInterval(15)))
        XCTAssertFalse(window.hasActivity)
        XCTAssertEqual(window.samples.first?.title, "Quiet video")
        XCTAssertEqual(window.samples.first?.excerpt, "Visible topic about football highlights")
    }
    func testBothConsentsAndSamePublicBoundaryAreRequired() {
        for remote in [false, true] {
            for local in [false, true] {
                XCTAssertEqual(JevVisibleContextSampler.eligible(remoteText: remote, localText: local,
                    context: context(), presence: presence(now)), remote && local)
            }
        }
        XCTAssertFalse(JevVisibleContextSampler.eligible(remoteText: true, localText: true,
            context: context(suppressed: .privateBrowserWindow), presence: presence(now)))
        XCTAssertFalse(JevVisibleContextSampler.sameBoundary(context(host: "x.com"), context()))
        XCTAssertTrue(JevVisibleContextSampler.sameBoundary(context(), context()))
    }
    func testVisibleTextReaderExcludesEditableProtectedHiddenAndOffscreenContent() {
        for role in ["AXTextArea", "AXTextField", "AXSecureTextField", "AXComboBox", "AXToolbar", "AXTabGroup"] {
            XCTAssertFalse(JevVisibleTextPolicy.permitsTraversal(role: role, hidden: false, protected: false, editable: false))
            XCTAssertFalse(JevVisibleTextPolicy.isText(role: role))
        }
        for flags in [(true, false, false), (false, true, false), (false, false, true)] {
            XCTAssertFalse(JevVisibleTextPolicy.permitsTraversal(role: "AXStaticText", hidden: flags.0, protected: flags.1, editable: flags.2))
        }
        let viewport = CGRect(x: 0, y: 0, width: 500, height: 300)
        XCTAssertFalse(JevVisibleTextPolicy.isVisible(nil, in: viewport))
        XCTAssertFalse(JevVisibleTextPolicy.isVisible(CGRect(x: 0, y: 600, width: 200, height: 50), in: viewport))
        XCTAssertTrue(JevVisibleTextPolicy.isVisible(CGRect(x: 20, y: 30, width: 200, height: 50), in: viewport))
        let value = JevVisibleTextPolicy.compact(["Notifications", "A post about SwiftUI development", "A post about SwiftUI development", "Contact person@example.com https://example.com/private"])
        XCTAssertLessThanOrEqual(value.utf8.count, 224)
        XCTAssertFalse(value.contains("person@example.com"))
        XCTAssertFalse(value.contains("https://"))
        XCTAssertFalse(value.contains("Notifications"))
    }
}
#endif
