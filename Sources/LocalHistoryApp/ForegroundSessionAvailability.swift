#if os(macOS)
import AppKit
import Carbon
import CoreGraphics

/// Read-only state. No screen pixels, camera, microphone or extra permission.
/// Notifications provide immediate cutoffs; a fresh query also covers launch
/// while locked and missed notifications. An unavailable session fails closed.
enum ForegroundSessionAvailability {
    static func permitsCapture(session: [String: Any]?, hasAwakeDisplay: Bool) -> Bool {
        guard let session, hasAwakeDisplay,
              (session[kCGSessionOnConsoleKey as String] as? Bool) == true,
              (session[kCGSessionLoginDoneKey as String] as? Bool) == true else { return false }
        // Supplemental WindowServer lock state; the notification gate remains
        // independent because this dictionary key is not an API guarantee.
        return (session["CGSSessionScreenIsLocked"] as? Bool) != true
    }

    static func isAvailable() -> Bool {
        var displays = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(UInt32(displays.count), &displays, &count) == .success else { return false }
        let awake = displays.prefix(Int(count)).contains { CGDisplayIsActive($0) != 0 && CGDisplayIsAsleep($0) == 0 }
        return permitsCapture(session: CGSessionCopyCurrentDictionary() as? [String: Any], hasAwakeDisplay: awake)
    }
}

/// Host state that can close capture: screen lock, display sleep and Secure Input.
/// Production uses `.live`; tests inject fixed values. Values are never cached.
struct HostCaptureGate {
    var sessionAvailable: () -> Bool
    var secureInput: () -> Bool
    /// Sets the poll cadence. Tests pin it: a CI runner gets no input and looks idle for hours.
    var secondsSinceLastInput: () -> TimeInterval = { UserInputActivityClock.secondsSinceLastInput() }
    static let live = HostCaptureGate(
        sessionAvailable: { ForegroundSessionAvailability.isAvailable() },
        secureInput: { IsSecureEventInputEnabled() })
}
#endif
