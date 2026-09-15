import XCTest
@testable import LocalHistoryQueryCLI
final class GoalongPublicDomainTests: XCTestCase {
    func testPublicDomainsAreNormalizedWithoutAcceptingURLsOrLocalNames() {
        XCTAssertEqual(GoalongPublicDomain.normalized("  EXAMPLE.ORG.  "), "example.org")
        XCTAssertEqual(GoalongPublicDomain.normalized("docs.example.org"), "docs.example.org")
        for invalid in ["localhost", "127.0.0.1", "192.168.1.1", "[::1]", "machine.local", "project.internal", "https://example.org/private", "name@example.org", "foo..com", "-bad.com", "example.org/path", "example.org?secret=1"] {
            XCTAssertNil(GoalongPublicDomain.normalized(invalid), invalid)
        }
    }
}
