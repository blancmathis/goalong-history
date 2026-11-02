import Foundation
import ApplicationServices

/// True when the process is an XCTest run. Tests must never read this Mac's real account state
/// (real home, TCC grants): the answer would depend on the machine and could touch personal data.
/// Same detection as the Screen Time guard (`AppleSystemScreenTimePaths.default`).
enum GoalongTestEnvironment {
    static let isXCTest: Bool = {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }()
}

/// `AXIsProcessTrusted()` reads this Mac's TCC grant. Under XCTest it answers « not granted »
/// (what a clean CI machine says), so no test result depends on the machine it runs on.
enum GoalongAccessibilityTrust {
    static var isTrusted: Bool { GoalongTestEnvironment.isXCTest ? false : AXIsProcessTrusted() }
}
