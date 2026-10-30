import AppleScreenTime
import AppleSystemScreenTime
import Darwin
import Foundation
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
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { Darwin.close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, length) == 0 && Darwin.getsockname(fd, $0, &length) == 0 }
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

    /// Runner helper, not a check: the hard-case runner has no Apple Screen Time data, and the site export
    /// reads it. With `T046_SCREEN_TIME_FIXTURE_DIR` set, writes synthetic days (today, active; the two days
    /// before, completed) in the archive format, for `qa/hard/hard_d.sh`. Without it, does nothing.
    func testWritesSyntheticScreenTimeDaysWhenAsked() throws {
        guard let path = ProcessInfo.processInfo.environment["T046_SCREEN_TIME_FIXTURE_DIR"], !path.isEmpty else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let calendar = Calendar.current, now = Date()
        let formatter = DateFormatter()
        formatter.calendar = calendar; formatter.timeZone = calendar.timeZone; formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let today = calendar.startOfDay(for: now)
        for back in 0 ... 2 {
            let start = try XCTUnwrap(calendar.date(byAdding: .day, value: -back, to: today))
            let end = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: start))
            let updated = back == 0 ? now : end
            let devices = [AppleScreenTimeDevice(id: "mac", name: "Mac", kind: .mac)]
            let app = AppleScreenTimeApplicationUsage(bundleIdentifier: "com.apple.Safari", displayName: "Safari", duration: 600)
            let segment = AppleScreenTimeSegment(start: start, end: start.addingTimeInterval(600), totalScreenOnDuration: 600, applications: [app])
            let stored = AppleScreenTimeStoredExport(verification: .unsigned, envelope: .init(
                requestedStart: start, requestedEnd: back == 0 ? now : end, requestedScope: .allDevices,
                provenance: .init(api: AppleScreenTimeProvenance.screenTimeAgentAggregateAPI, collectorBundleIdentifier: "t046", collectorVersion: "t046",
                                  collectorPlatform: "macOS", authorization: .unknown, fetchPolicy: .cached, euCustomerRequirementAcknowledged: false),
                reports: devices.map { AppleScreenTimeDeviceReport(device: $0, lastUpdatedAt: updated, segments: [segment]) }))
            let collection = AppleSystemScreenTimeCollection(storedExport: stored, availableDevices: devices,
                status: .init(kind: .ready, title: "T-046", message: "Synthetic"), deviceSourceLabels: [:], latestAppleUpdate: updated,
                knowledgeIntervalCount: 0, biomeIntervalCount: 0)
            let record = AppleSystemScreenTimeDailyArchiveRecord(dayStart: start, dayEnd: end, timeZoneIdentifier: calendar.timeZone.identifier,
                state: back == 0 ? .active : .completed, storedAt: updated, collection: collection)
            try AppleScreenTimeJSON.encode(record).write(to: directory.appendingPathComponent(formatter.string(from: start) + ".json"))
        }
    }
}
