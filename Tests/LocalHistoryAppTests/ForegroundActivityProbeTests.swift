#if os(macOS)
import AppKit
import IOKit.pwr_mgt
import LocalHistoryCore
import XCTest
@testable import LocalHistoryApp

final class ForegroundActivityProbeTests: XCTestCase {
    func testOSEvidenceEligibilityDoesNotRequireControlOrTitlePermission() {
        func context(_ suppression: SuppressionReason? = nil) -> ContextSnapshot {
            .init(app: .init(name: "Zoom", bundleIdentifier: "us.zoom.xos", processIdentifier: 42),
                  window: nil, focusedElement: nil, url: nil, suppressionReason: suppression)
        }
        XCTAssertTrue(ForegroundActivityProbe.isEligibleForeground(context(), frontmostPID: 42, isHidden: false))
        XCTAssertFalse(ForegroundActivityProbe.isEligibleForeground(context(), frontmostPID: 77, isHidden: false))
        XCTAssertFalse(ForegroundActivityProbe.isEligibleForeground(context(), frontmostPID: 42, isHidden: true))
        XCTAssertFalse(ForegroundActivityProbe.isEligibleForeground(context(.privateBrowserWindow), frontmostPID: 42, isHidden: false))
        XCTAssertFalse(ForegroundActivityProbe.isEligibleForeground(context(.excludedApplication), frontmostPID: 42, isHidden: false))
    }

    func testAnOpenMeetingAppAloneIsNotAnActiveCall() {
        XCTAssertNil(ForegroundActivityProbe.resolve(isBrowser: false, isCallApplication: true,
            control: .unknown, holdsDisplayAssertion: false))
        XCTAssertEqual(ForegroundActivityProbe.resolve(isBrowser: false, isCallApplication: true,
            control: .unknown, holdsDisplayAssertion: true), .call)
    }
    func testMutedCallAndSilentVideoDoNotRequireAudioOrKeyboard() {
        XCTAssertEqual(ForegroundActivityProbe.resolve(isBrowser: true, isCallApplication: false,
            control: .call, holdsDisplayAssertion: false), .call)
        XCTAssertEqual(ForegroundActivityProbe.resolve(isBrowser: true, isCallApplication: false,
            control: .playing, holdsDisplayAssertion: false), .mediaPlayback)
    }
    func testBrowserProcessEvidenceNeverPretendsToKnowThePlayingTab() {
        XCTAssertEqual(ForegroundActivityProbe.resolve(isBrowser: true, isCallApplication: false,
            control: .unknown, holdsDisplayAssertion: true), .displayAssertion)
        XCTAssertNil(ForegroundActivityProbe.resolve(isBrowser: true, isCallApplication: false,
            control: .stopped, holdsDisplayAssertion: true))
        XCTAssertNil(ForegroundActivityProbe.resolve(isBrowser: true, isCallApplication: false,
            control: .unknown, holdsDisplayAssertion: false))
    }
    func testOnlyTheExactForegroundProcessOrItsEmbeddedHelperCanExtendTime() {
        XCTAssertTrue(ForegroundActivityProbe.assertionOwnerMatches(ownerPID: 42, foregroundPID: 42,
            ownerExecutable: nil, foregroundBundlePath: nil))
        XCTAssertFalse(ForegroundActivityProbe.assertionOwnerMatches(ownerPID: 77, foregroundPID: 42,
            ownerExecutable: "/Applications/Other.app/Contents/MacOS/Other", foregroundBundlePath: "/Applications/Zoom.app"))
        XCTAssertTrue(ForegroundActivityProbe.assertionOwnerMatches(ownerPID: 77, foregroundPID: 42,
            ownerExecutable: "/Applications/Zoom.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper",
            foregroundBundlePath: "/Applications/Zoom.app"))
        for executable in ["/usr/bin/caffeinate", "/usr/sbin/coreaudiod", "/Applications/Zoom.app.evil/Contents/MacOS/Helper"] {
            XCTAssertFalse(ForegroundActivityProbe.assertionOwnerMatches(ownerPID: 77, foregroundPID: 42,
                ownerExecutable: executable, foregroundBundlePath: "/Applications/Zoom.app"))
        }
        XCTAssertFalse(ForegroundActivityProbe.assertionOwnerMatches(ownerPID: 0, foregroundPID: 0,
            ownerExecutable: nil, foregroundBundlePath: nil))
    }
    func testDownloadsBackgroundAudioAndDisabledAssertionsAreNotDisplayEvidence() {
        XCTAssertTrue(ForegroundActivityProbe.isDisplayAssertion(type: "PreventUserIdleDisplaySleep", level: 255))
        for type in ["PreventUserIdleSystemSleep", "PreventSystemSleep", "NetworkClientActive", "UserIsActive"] {
            XCTAssertFalse(ForegroundActivityProbe.isDisplayAssertion(type: type, level: 255))
        }
        XCTAssertFalse(ForegroundActivityProbe.isDisplayAssertion(type: "PreventUserIdleDisplaySleep", level: 0))
        XCTAssertFalse(ForegroundActivityProbe.isDisplayAssertion(type: nil, level: 255))
    }
    func testPlaybackControlsRequireEnabledButtonsAndExactLabels() {
        for label in ["Pause", "Pause (k)", "Mettre en pause", "Mettre en pause (k)"] {
            XCTAssertEqual(ForegroundPlaybackControls.state(role: "AXButton", labels: [label]), .playing)
        }
        for label in ["Leave meeting", "Quitter la réunion", "Raccrocher", "End call"] {
            XCTAssertEqual(ForegroundPlaybackControls.state(role: "AXButton", labels: [label]), .call)
        }
        XCTAssertEqual(ForegroundPlaybackControls.state(role: "AXButton", labels: ["Leave"], nativeCall: true), .call)
        XCTAssertEqual(ForegroundPlaybackControls.state(role: "AXButton", labels: ["Leave"]), .unknown)
        XCTAssertEqual(ForegroundPlaybackControls.state(role: "AXStaticText", labels: ["Pause"]), .unknown)
        XCTAssertEqual(ForegroundPlaybackControls.state(role: "AXButton", labels: ["Pause"], enabled: false), .unknown)
        XCTAssertEqual(ForegroundPlaybackControls.state(role: "AXButton", labels: ["How to pause a video"]), .unknown)
        XCTAssertEqual(ForegroundPlaybackControls.state(role: "AXButton", labels: ["Play (k)"]), .stopped)
    }
    func testRealMacOSAssertionRoundTripWithoutAudioOrVideoCapture() throws {
        var assertion: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn), "Goalong foreground evidence test" as CFString, &assertion)
        guard result == kIOReturnSuccess else { throw XCTSkip("Power assertions unavailable on this runner: \(result)") }
        defer { IOPMAssertionRelease(assertion) }
        XCTAssertTrue(ForegroundActivityProbe.holdsDisplayAssertion(pid: getpid(), bundleURL: nil))
        XCTAssertFalse(ForegroundActivityProbe.holdsDisplayAssertion(pid: -1, bundleURL: nil))
    }
    func testBrowserAndWebWrapperDetectionIsConservative() {
        func context(_ name: String, _ id: String, _ url: String? = nil) -> ContextSnapshot {
            .init(app: .init(name: name, bundleIdentifier: id, processIdentifier: 1), window: nil,
                focusedElement: nil, url: url.map { .init(value: $0, host: "example.org", redactionApplied: false) }, suppressionReason: nil)
        }
        XCTAssertTrue(ForegroundActivityProbe.isBrowser(context("Safari", "com.apple.Safari")))
        XCTAssertTrue(ForegroundActivityProbe.isBrowser(context("New wrapper", "new.app", "https://example.org")))
        XCTAssertFalse(ForegroundActivityProbe.isBrowser(context("Zoom", "us.zoom.xos")))
    }
}
#endif
