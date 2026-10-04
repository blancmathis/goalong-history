import Foundation
import XCTest
@testable import Ambiance

final class AmbianceAudioNetworkTests: XCTestCase {
    func testDownloaderAllowsOnlyPinnedReleaseAndExactAssetHost() throws {
        let pack = try XCTUnwrap(AmbiancePackCatalog.packs.first)
        XCTAssertTrue(AmbiancePackDownloader.allows(pack.url, pack: pack, redirect: false))
        for value in [
            "http://github.com/blancmathis/goalong-history/releases/download/ambiance-packs-v1/orchestra.tar",
            pack.url.absoluteString + "?member=1", pack.url.absoluteString + "#fragment",
            "https://user@github.com/blancmathis/goalong-history/releases/download/ambiance-packs-v1/orchestra.tar",
            "https://github.com:444/blancmathis/goalong-history/releases/download/ambiance-packs-v1/orchestra.tar",
            "https://github.com/other/releases/download/ambiance-packs-v1/orchestra.tar",
            "https://release-assets.githubusercontent.com.evil.invalid/asset",
            "https://evil.invalid/asset", "file:///tmp/orchestra.tar",
        ] {
            let url = try XCTUnwrap(URL(string: value))
            XCTAssertFalse(AmbiancePackDownloader.allows(url, pack: pack, redirect: false), value)
            XCTAssertFalse(AmbiancePackDownloader.allows(url, pack: pack, redirect: true), value)
        }
        let asset = try XCTUnwrap(URL(string: "https://release-assets.githubusercontent.com/asset"))
        XCTAssertFalse(AmbiancePackDownloader.allows(asset, pack: pack, redirect: false))
        XCTAssertTrue(AmbiancePackDownloader.allows(asset, pack: pack, redirect: true))
        XCTAssertTrue(AmbiancePackDownloader.allows(URL(string: asset.absoluteString + "?sig=github-signed")!, pack: pack, redirect: true))
    }

    func testSignedRedirectPreservesURLAndDropsForwardedHeaders() throws {
        let pack = try XCTUnwrap(AmbiancePackCatalog.packs.first)
        let signed = try XCTUnwrap(URL(string: "https://release-assets.githubusercontent.com:443/asset?sig=a%2Bb%2Fc%3D&jwt=x.y.z&key=1&key=2&empty=&plus=+"))
        var request = try XCTUnwrap(AmbiancePackDownloader.redirectRequest(.init(url: signed), responseURL: pack.url,
            initialURL: pack.url, pack: pack, redirectCount: 1))
        request.httpMethod = "GET"
        request.setValue("discard", forHTTPHeaderField: "Authorization")
        request.setValue("discard", forHTTPHeaderField: "Cookie")
        let clean = try XCTUnwrap(AmbiancePackDownloader.redirectRequest(request, responseURL: pack.url,
            initialURL: pack.url, pack: pack, redirectCount: 1))
        XCTAssertEqual(clean.url?.absoluteString, signed.absoluteString)
        XCTAssertEqual(clean.url?.query, signed.query)
        XCTAssertEqual(clean.httpMethod, "GET")
        XCTAssertNil(clean.httpBody)
        XCTAssertNil(clean.httpBodyStream)
        XCTAssertTrue(clean.allHTTPHeaderFields?.isEmpty ?? true)
        XCTAssertFalse(clean.httpShouldHandleCookies)
        XCTAssertEqual(clean.cachePolicy, .reloadIgnoringLocalCacheData)
    }

    func testRedirectRejectsQueryOnGitHub() throws {
        let pack = try XCTUnwrap(AmbiancePackCatalog.packs.first)
        let queried = try XCTUnwrap(URL(string: pack.url.absoluteString + "?sig=forbidden"))
        XCTAssertNil(AmbiancePackDownloader.redirectRequest(.init(url: queried), responseURL: pack.url,
            initialURL: pack.url, pack: pack, redirectCount: 1))
        let asset = URL(string: "https://release-assets.githubusercontent.com/asset?sig=synthetic")!
        XCTAssertNil(AmbiancePackDownloader.redirectRequest(.init(url: asset), responseURL: queried,
            initialURL: queried, pack: pack, redirectCount: 1))
    }

    func testRedirectRejectsOtherHostHTTPAndOtherPort() throws {
        let pack = try XCTUnwrap(AmbiancePackCatalog.packs.first)
        for value in ["https://evil.invalid/asset?sig=synthetic",
                      "https://release-assets.githubusercontent.com.evil.invalid/asset?sig=synthetic",
                      "http://release-assets.githubusercontent.com/asset?sig=synthetic",
                      "https://release-assets.githubusercontent.com:444/asset?sig=synthetic",
                      "https://user@release-assets.githubusercontent.com/asset?sig=synthetic",
                      "https://release-assets.githubusercontent.com/asset?sig=synthetic#fragment",
                      pack.url.absoluteString] {
            XCTAssertNil(AmbiancePackDownloader.redirectRequest(.init(url: try XCTUnwrap(URL(string: value))), responseURL: pack.url,
                initialURL: pack.url, pack: pack, redirectCount: 1), value)
        }
    }

    func testRedirectRejectsSecondRedirectAndUnexpectedResponseOrigin() throws {
        let pack = try XCTUnwrap(AmbiancePackCatalog.packs.first)
        let asset = URL(string: "https://release-assets.githubusercontent.com/asset?sig=synthetic")!
        for count in [0, 2, 3] {
            XCTAssertNil(AmbiancePackDownloader.redirectRequest(.init(url: asset), responseURL: pack.url,
                initialURL: pack.url, pack: pack, redirectCount: count))
        }
        XCTAssertNil(AmbiancePackDownloader.redirectRequest(.init(url: asset), responseURL: asset,
            initialURL: pack.url, pack: pack, redirectCount: 1))
    }

    func testRedirectRejectsAssetHostAsFirstRequestAndNonGET() throws {
        let pack = try XCTUnwrap(AmbiancePackCatalog.packs.first)
        let asset = URL(string: "https://release-assets.githubusercontent.com/asset?sig=synthetic")!
        var request = try XCTUnwrap(AmbiancePackDownloader.redirectRequest(.init(url: asset), responseURL: pack.url,
            initialURL: pack.url, pack: pack, redirectCount: 1))
        XCTAssertFalse(AmbiancePackDownloader.allows(asset, pack: pack, redirect: false))
        XCTAssertNil(AmbiancePackDownloader.redirectRequest(request, responseURL: asset,
            initialURL: asset, pack: pack, redirectCount: 1))
        request.httpMethod = "POST"
        XCTAssertNil(AmbiancePackDownloader.redirectRequest(request, responseURL: pack.url,
            initialURL: pack.url, pack: pack, redirectCount: 1))
        request.httpMethod = "GET"; request.httpBody = Data([1])
        XCTAssertNil(AmbiancePackDownloader.redirectRequest(request, responseURL: pack.url,
            initialURL: pack.url, pack: pack, redirectCount: 1))
        request.httpBody = nil; request.httpBodyStream = InputStream(data: Data([1]))
        XCTAssertNil(AmbiancePackDownloader.redirectRequest(request, responseURL: pack.url,
            initialURL: pack.url, pack: pack, redirectCount: 1))
    }

    @MainActor func testExplicitHTTPDownloadInstallsAndRejectsBadResponses() async throws {
        guard ProcessInfo.processInfo.environment["GOALONG_AMBIANCE_PACK_TEST_URL"] != nil,
              let modeFile = ProcessInfo.processInfo.environment["GOALONG_AMBIANCE_HTTP_MODE_FILE"] else {
            throw XCTSkip("Explicit loopback pack-server test required")
        }
        let pack = try XCTUnwrap(AmbiancePackCatalog.packs.first)
        for mode in ["good", "corrupt", "size", "redirect", "slow"] {
            try mode.write(toFile: modeFile, atomically: true, encoding: .utf8)
            let support = FileManager.default.temporaryDirectory.appendingPathComponent("ambiance-http-\(UUID())")
            defer { try? FileManager.default.removeItem(at: support) }
            let name = "goalong.ambiance.http.\(UUID())", defaults = UserDefaults(suiteName: name)!
            defer { defaults.removePersistentDomain(forName: name) }
            let settings = AmbianceSettings(defaults: defaults); settings.isEnabled = true
            let module = AmbianceModule(settings: settings) { support }
            let controller = try XCTUnwrap(module.controller)
            let done = expectation(description: mode)
            var completed = false
            let token = controller.$packs.sink { packs in
                guard let status = packs.first(where: { $0.id == pack.id })?.status, !completed else { return }
                switch status {
                case .installed, .failed: completed = true; done.fulfill()
                default: break
                }
            }
            // Enabling and observing the module have issued no request. Only this
            // action invokes the downloader, including cancellation/error cases.
            controller.download(pack.id)
            if mode == "slow" {
                try await Task.sleep(nanoseconds: 100_000_000)
                controller.cancelDownload(pack.id)
            }
            await fulfillment(of: [done], timeout: 45)
            token.cancel()
            let store = AmbiancePackStore(supportDirectory: support)
            XCTAssertEqual(store.isInstalled(pack), mode == "good", mode)
            if mode != "good" {
                if case .failed = controller.packs.first?.status {} else { XCTFail("Expected failure for \(mode)") }
                XCTAssertFalse(FileManager.default.fileExists(atPath: store.root.path), mode)
            }
            module.setEnabled(false)
        }
    }

}
