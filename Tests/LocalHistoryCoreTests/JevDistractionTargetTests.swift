import XCTest
@testable import LocalHistoryCore

final class JevDistractionTargetTests: XCTestCase {
    func testRegistrableDomainsIncludePublicPrivateWildcardAndExceptionRules() {
        let examples = [
            "M.YouTube.COM.": "youtube.com", "a.b.amazon.co.uk": "amazon.co.uk",
            "a.member.github.io": "member.github.io", "a.member.blogspot.com": "member.blogspot.com",
            "a.b.ck": "a.b.ck", "a.www.ck": "www.ck", "a.city.kawasaki.jp": "city.kawasaki.jp",
            "www.école.fr": "xn--cole-9oa.fr", "news.google.com": "google.com"
        ]
        for (host, expected) in examples { XCTAssertEqual(JevRegistrableDomain.domain(host), expected, host) }
        for host in ["com", "co.uk", "github.io", "b.ck", "localhost", "a.local", "127.0.0.1",
                     "a..com", "-a.com", "https://youtube.com", "youtube.com/path", "a.invalid", "home.arpa"] {
            XCTAssertNil(JevRegistrableDomain.domain(host), host)
        }
    }
    func testLocalIdentityDoesNotChangeRemotePayload() throws {
        let now = Date(timeIntervalSince1970: 1000), target = JevDistractionTarget.site(host: "m.youtube.com")!
        func payload(_ local: JevDistractionTarget?) throws -> Data {
            try JevPayload.build(.init(start: now, end: now.addingTimeInterval(15), samples: [
                .init(date: now, resource: "youtube.com", title: "Feed", action: "scroll", surface: "video-feed",
                      isActivity: true, distractionTarget: local)
            ]))
        }
        XCTAssertEqual(try payload(nil), try payload(target))
        let app = JevDistractionTarget.app(bundleIdentifier: "com.example.Game", name: "Game\nname")!
        XCTAssertEqual(app.value, "com.example.Game"); XCTAssertEqual(app.name, "Game name")
        XCTAssertTrue(app.isValid)
        XCTAssertEqual(try JSONDecoder().decode(JevDistractionTarget.self, from: JSONEncoder().encode(app)), app)
        for id in ["", "app", "com..Game", "com.Game/path", "com.Game token"] {
            XCTAssertNil(JevDistractionTarget.app(bundleIdentifier: id, name: "Game"))
        }
    }
}
