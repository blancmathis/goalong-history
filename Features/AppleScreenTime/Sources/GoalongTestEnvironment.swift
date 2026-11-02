import Foundation

/// True when the process is an XCTest run. The one detection for the whole package: Screen Time paths,
/// real home, TCC grants and system prompts all use it. Tests must never read this Mac's real account
/// state (the answer would depend on the machine and could touch personal data) nor show a system prompt.
public enum GoalongTestEnvironment {
    public static let isXCTest: Bool = {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }()
}
