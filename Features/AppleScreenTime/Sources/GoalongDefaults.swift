import Foundation

/// The only door to Goalong's preferences (T-043 T1). The app gets `UserDefaults.standard` (same domain, same keys,
/// same values as before). An XCTest process (unit tests, `make gallery`) gets one throwaway suite instead: under
/// `swift test` the standard domain is xctest's real domain on this Mac (cfprefsd ignores CFFIXED_USER_HOME), so a
/// test would read the owner's settings or write into them. `make audit` refuses `UserDefaults.standard` anywhere else.
public enum GoalongDefaults {
    /// Environment variable that carries the throwaway suite's name: the headless test hook
    /// (`Tests/GoalongHeadlessTestSupport`) sets it at load and routes `+[NSUserDefaults standardUserDefaults]` (SwiftUI
    /// `@AppStorage` included) to the same suite, so the whole test process sees one domain.
    public static let isolatedSuiteEnvironmentKey = "GOALONG_TEST_DEFAULTS_SUITE"

    /// The throwaway suite's name under XCTest, nil in the app. It holds a UUID: the hook deletes its plist at exit.
    public static let isolatedSuiteName: String? = {
        guard GoalongTestEnvironment.isXCTest else { return nil }
        if let value = getenv(isolatedSuiteEnvironmentKey), let name = String(validatingUTF8: value), !name.isEmpty {
            return name
        }
        let name = "goalong-tests-defaults-\(UUID().uuidString)"
        setenv(isolatedSuiteEnvironmentKey, name, 1)
        return name
    }()

    /// What the app calls `UserDefaults.standard`.
    public static let standard: UserDefaults = {
        guard let name = isolatedSuiteName, let suite = UserDefaults(suiteName: name) else { return UserDefaults.standard }
        return suite
    }()

    /// The app's domain read from another process (the query CLI). Under XCTest: the same throwaway suite.
    public static func appDomain(_ bundleIdentifier: String) -> UserDefaults? {
        isolatedSuiteName == nil ? UserDefaults(suiteName: bundleIdentifier) : standard
    }
}
