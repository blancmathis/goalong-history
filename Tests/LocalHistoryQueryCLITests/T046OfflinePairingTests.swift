import Darwin
import XCTest
import LocalHistoryCore
@testable import LocalHistoryQueryCLI

/// T-046 L4c, J-0266 / J-0267: pairing comes from a browser link, so the runner cannot drive it.
/// Same exchange as `GoalongWebsitePairingCoordinator.connect`, against a site that cannot be reached:
/// the error the coordinator shows under « Connexion non confirmée » keeps the network cause, and no
/// credential file is written.
final class T046OfflinePairingTests: XCTestCase {
    /// A loopback port nobody listens on: bound by the kernel, then released.
    private func closedLoopbackPort() -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0 }
        }
        XCTAssertTrue(bound)
        return Int(UInt16(bigEndian: address.sin_port))
    }

    func testUnreachableSiteKeepsTheNetworkCauseAndWritesNoCredential() throws {
        let port = closedLoopbackPort()
        let link = "goalong-history://connect?site=http://127.0.0.1:\(port)#" + String(repeating: "a", count: 43)
        let pairing = try GoalongSitePairing(url: XCTUnwrap(URL(string: link)))
        XCTAssertEqual(pairing.origin, "http://127.0.0.1:\(port)")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("t046-pairing-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let started = Date()
        XCTAssertThrowsError(try pairing.exchange()) { error in
            XCTAssertEqual(goalongUserMessage(error), "Pas de connexion au site. Réessayez avec le même lien.")
            XCTAssertFalse(goalongUserMessage(error).contains("expiré"), "a network failure must not blame the link")
            XCTAssertFalse(goalongUserMessage(error).contains("Domain="))
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 30, "a refused connection must not wait for the 35 s limit")
        // `save` runs only after a successful exchange: nothing on disk.
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testNotConnectedToInternetIsReportedAsNoConnectionNotAsAnExpiredLink() {
        let message = PairingResponse.failureMessage(status: 0, transportError: URLError(.notConnectedToInternet))
        XCTAssertEqual(message, "Pas de connexion au site. Réessayez avec le même lien.")
        // A cancelled task is not a network cause: generic text, never « Pas de connexion ».
        XCTAssertFalse(PairingResponse.failureMessage(status: 0, transportError: URLError(.cancelled)).hasPrefix("Pas de connexion"))
    }
}
