#if os(macOS)
import Foundation
import XCTest
@testable import LocalHistoryApp

/// T-048 C2: old installer `.app` copies become zips once; foreign bundles and links stay untouched.
final class AppBackupArchiverTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("app-backups-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    @discardableResult
    private func bundle(_ name: String, id: String) throws -> URL {
        let app = folder.appendingPathComponent(name, isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": id, "CFBundlePackageType": "APPL", "CFBundleExecutable": "x"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        try Data("binary".utf8).write(to: contents.appendingPathComponent("MacOS/x"))
        return app
    }

    func testOurCopiesBecomeZipsAndOthersStay() throws {
        try bundle("Goalong History-5000.0.12-old.app", id: "ai.goalong.localhistory")
        try bundle("Other.app", id: "com.example.other")
        try bundle("Goalong History 5000.0.7.app.backup", id: "ai.goalong.localhistory")
        let target = try bundle("Target.app", id: "ai.goalong.localhistory")
        let elsewhere = folder.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: target, to: elsewhere.appendingPathComponent("Target.app"))
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("Link.app"),
                                                   withDestinationURL: elsewhere.appendingPathComponent("Target.app"))

        XCTAssertEqual(AppBackupArchiver.copies(in: folder).map(\.lastPathComponent), ["Goalong History-5000.0.12-old.app"])
        let outcome = AppBackupArchiver.archive(folder: folder)
        XCTAssertEqual(outcome, .init(archived: ["Goalong History-5000.0.12-old.app"], failed: []))

        let names = Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
        XCTAssertEqual(names, ["Goalong History-5000.0.12-old.app.zip", "Other.app", "Goalong History 5000.0.7.app.backup", "Link.app", "elsewhere"])
        let zip = try Data(contentsOf: folder.appendingPathComponent("Goalong History-5000.0.12-old.app.zip"))
        XCTAssertEqual(Array(zip.prefix(2)), Array("PK".utf8), "a real zip archive")
        XCTAssertTrue(FileManager.default.fileExists(atPath: elsewhere.appendingPathComponent("Target.app/Contents/Info.plist").path))
        XCTAssertEqual(AppBackupArchiver.archive(folder: folder), .init(), "nothing left to archive")
    }

    func testRunsOncePerMac() throws {
        let suite = "app-backup-archiver-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        AppBackupArchiver.runOnce(defaults: defaults, folder: folder)
        XCTAssertTrue(defaults.bool(forKey: AppBackupArchiver.doneKey))
        try bundle("Late.app", id: "ai.goalong.localhistory")
        AppBackupArchiver.runOnce(defaults: defaults, folder: folder)
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Late.app").path), "second run does nothing")
    }

    func testMissingFolderIsNoop() {
        XCTAssertEqual(AppBackupArchiver.archive(folder: folder.appendingPathComponent("absent")), .init())
    }
}
#endif
