import Foundation
import ApplicationServices
import AppleScreenTime

/// `AXIsProcessTrusted()` reads this Mac's TCC grant. Under XCTest it answers « not granted »
/// (what a clean CI machine says), so no test result depends on the machine it runs on.
enum GoalongAccessibilityTrust {
    static var isTrusted: Bool { GoalongTestEnvironment.isXCTest ? false : AXIsProcessTrusted() }
}
