import Foundation

/// The only door to Goalong's preferences (T-043 T1). The app gets `UserDefaults.standard` (same domain, same keys,
/// same values as before). An XCTest process (unit tests, `make gallery`) gets a throwaway suite instead: under
/// `swift test` the standard domain is xctest's real domain on this Mac (cfprefsd ignores CFFIXED_USER_HOME), so a
/// test would read the owner's settings or write into them. `make audit` refuses `UserDefaults.standard` anywhere else.
public enum GoalongDefaults {
    /// Environment variable that carries the throwaway suite's name: the headless test hook
    /// (`Tests/GoalongHeadlessTestSupport`) sets it at load and routes `+[NSUserDefaults standardUserDefaults]` (SwiftUI
    /// `@AppStorage` included) to the same suite, so the whole test process sees one domain.
    public static let isolatedSuiteEnvironmentKey = "GOALONG_TEST_DEFAULTS_SUITE"

    /// Set to 1 by the hook once `+standardUserDefaults` is routed (R-286 F2).
    static let hookEnvironmentKey = "GOALONG_TEST_DEFAULTS_HOOK"

    /// The throwaway suite's name under XCTest, nil in the app. An absolute path in a temporary folder (the throwaway
    /// HOME with the hook): cfprefsd then writes its plist there, never in ~/Library/Preferences (R-286 F1).
    public static let isolatedSuiteName: String? = {
        guard GoalongTestEnvironment.isXCTest else { return nil }
        if let value = getenv(isolatedSuiteEnvironmentKey), let name = String(validatingUTF8: value), !name.isEmpty {
            return name
        }
        let name = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("goalong-tests-defaults-\(getpid())-\(UUID().uuidString)")
        setenv(isolatedSuiteEnvironmentKey, name, 1)
        return name
    }()

    private static let hookRoutesStandard = getenv(hookEnvironmentKey).map { String(cString: $0) } == "1"
    private static let unhookedSuite: UserDefaults? = isolatedSuiteName.flatMap { UserDefaults(suiteName: $0) }

    /// What the app calls `UserDefaults.standard`. Under XCTest with the hook it is `UserDefaults.standard` too, so
    /// the hook decides: the throwaway suite, or in a gallery session that session's fresh suite, read counted
    /// (R-286 F2). Without the hook: the throwaway suite directly.
    public static var standard: UserDefaults {
        guard isolatedSuiteName != nil, !hookRoutesStandard else { return UserDefaults.standard }
        return unhookedSuite ?? UserDefaults.standard
    }

    /// The app's domain read from another process (the query CLI). Under XCTest: the same throwaway suite.
    public static func appDomain(_ bundleIdentifier: String) -> UserDefaults? {
        isolatedSuiteName == nil ? UserDefaults(suiteName: bundleIdentifier) : standard
    }
}
