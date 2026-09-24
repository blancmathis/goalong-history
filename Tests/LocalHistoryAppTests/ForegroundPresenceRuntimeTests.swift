#if os(macOS)
import AppKit
import CoreGraphics
import Foundation
import LocalHistoryCore
import XCTest
@testable import LocalHistoryApp

final class ForegroundPresenceRuntimeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_250_000)
    private func context(idle: Double = 200, evidence: ForegroundActivityEvidence? = nil) -> ContextSnapshot {
        ContextSnapshot(app: .init(name: "Reader", bundleIdentifier: "test.reader", processIdentifier: 42),
            window: nil, focusedElement: nil, url: nil, suppressionReason: nil,
            foregroundUsage: .init(observedAt: now, idleSeconds: idle, isForegroundVisible: true, evidence: evidence))
    }
    func testRecorderPropagatesReadingPresenceWithoutCapturingLabelsOrTyping() {
        let meta = EventRecorder.metadataForObservation(context: context(), kind: .heartbeat,
            timestamp: now.addingTimeInterval(30), metadata: nil, inputOrigin: nil)
        XCTAssertEqual(meta?[ForegroundUsageObservation.policyKey], ForegroundUsageObservation.policyVersion)
        XCTAssertEqual(meta?[ForegroundUsageObservation.visibleKey], "true")
        XCTAssertEqual(meta?["idle_seconds"], "230.000")
        XCTAssertEqual(meta?[ForegroundUsageObservation.idleLimitKey], "300")
    }
    func testInputRenewsButAutomaticContextChangesDoNot() {
        for kind in [EventKind.mouseClick, .scrollBurst, .typingBurst, .keyPressed, .keyboardShortcut] {
            let meta = EventRecorder.metadataForObservation(context: context(), kind: kind,
                timestamp: now.addingTimeInterval(10), metadata: nil, inputOrigin: nil)
            XCTAssertEqual(meta?["idle_seconds"], "0.000")
        }
        for kind in [EventKind.windowChanged, .focusChanged, .applicationActivated, .semanticSnapshot] {
            let meta = EventRecorder.metadataForObservation(context: context(), kind: kind,
                timestamp: now.addingTimeInterval(10), metadata: nil, inputOrigin: nil)
            XCTAssertEqual(meta?["idle_seconds"], "210.000")
        }
    }
    func testStaleContextAndPlaybackCannotBeReusedByDelayedEvents() {
        let meta = EventRecorder.metadataForObservation(context: context(evidence: .call), kind: .semanticSnapshot,
            timestamp: now.addingTimeInterval(61), metadata: [ForegroundActivityEvidence.metadataKey: "call"], inputOrigin: nil)
        XCTAssertEqual(meta?[ForegroundUsageObservation.visibleKey], "false")
        XCTAssertNil(meta?[ForegroundActivityEvidence.metadataKey])
    }
    func testDiagnosticHeartbeatConfigurationCannotCreateReadingHoles() {
        for configured in [0, 10, 30, 60, 3600, Int.max] {
            XCTAssertLessThanOrEqual(ContextMonitor.heartbeatInterval(configuredSeconds: configured), 30)
            XCTAssertGreaterThanOrEqual(ContextMonitor.heartbeatInterval(configuredSeconds: configured), 10)
        }
    }
    func testScreenSleepSystemSleepAndLockAreIndependentGates() {
        let state = CaptureState()
        state.setDisplaysAwake(false)
        state.setSystemAwake(true)
        XCTAssertFalse(state.isCapturing)
        state.setDisplaysAwake(true)
        state.setScreenUnlocked(false)
        state.setUserSessionActive(true)
        XCTAssertFalse(state.isCapturing)
        state.setScreenUnlocked(true)
        state.setSystemAwake(false)
        state.setDisplaysAwake(true)
        XCTAssertFalse(state.isCapturing)
        state.setSystemAwake(true)
        state.setManualPaused(true)
        XCTAssertFalse(state.isCapturing)
    }
    func testSessionQueryRejectsLockedOffscreenSleepingAndUnknownStates() {
        let session: [String: Any] = [kCGSessionOnConsoleKey as String: true, kCGSessionLoginDoneKey as String: true]
        XCTAssertTrue(ForegroundSessionAvailability.permitsCapture(session: session, hasAwakeDisplay: true))
        XCTAssertFalse(ForegroundSessionAvailability.permitsCapture(session: session, hasAwakeDisplay: false))
        XCTAssertFalse(ForegroundSessionAvailability.permitsCapture(session: nil, hasAwakeDisplay: true))
        XCTAssertFalse(ForegroundSessionAvailability.permitsCapture(session: [:], hasAwakeDisplay: true))
        for field in [kCGSessionOnConsoleKey as String, kCGSessionLoginDoneKey as String] {
            var next = session; next[field] = false
            XCTAssertFalse(ForegroundSessionAvailability.permitsCapture(session: next, hasAwakeDisplay: true))
        }
        var locked = session; locked["CGSSessionScreenIsLocked"] = true
        XCTAssertFalse(ForegroundSessionAvailability.permitsCapture(session: locked, hasAwakeDisplay: true))
    }
    func testOptInMonitoringUsesTheSameReadingPresenceWithoutClaimingPlayback() {
        XCTAssertTrue(JevIngress.shouldSampleForeground(presence: context(idle: 120).foregroundUsage, evidence: nil))
        XCTAssertFalse(JevIngress.shouldSampleForeground(presence: context(idle: 600).foregroundUsage, evidence: nil))
        XCTAssertFalse(JevIngress.shouldSampleForeground(presence: context(idle: 600).foregroundUsage, evidence: .displayAssertion))
        XCTAssertTrue(JevIngress.shouldSampleForeground(presence: context(idle: 600).foregroundUsage, evidence: .call))
        XCTAssertFalse(JevIngress.shouldSampleForeground(presence: .init(observedAt: now, idleSeconds: 0,
            isForegroundVisible: false), evidence: .call))
    }
    func testMonitoringRejectsAutomaticChangesAfterReadingExpires() {
        for idle in [120.0, 600.0] {
            let ctx = context(idle: idle)
            let event = HistoryEvent(schemaVersion: 4, sessionID: "test", timestamp: now, kind: .windowChanged,
                app: ctx.app, metadata: ctx.foregroundUsage!.metadata(at: now))
            XCTAssertEqual(JevIngress.sample(event) != nil, idle < 300)
        }
    }
    func testReadingSettingsRoundTripPreservesAllCaptureChoices() {
        let original = RecorderConfig.default
        for seconds in [120, 300, 600, 900, 1800, 0] {
            var draft = DashboardSettingsDraft(config: original)
            draft.foregroundIdleSeconds = seconds
            let restored = draft.applying(to: original)
            XCTAssertEqual(restored.effectiveForegroundIdleSeconds, seconds)
            XCTAssertEqual(restored.captureElementLabels, original.captureElementLabels)
            XCTAssertEqual(restored.captureWindowTitles, original.captureWindowTitles)
            XCTAssertEqual(restored.captureKeyboardActivity, original.captureKeyboardActivity)
        }
    }
}
#endif
