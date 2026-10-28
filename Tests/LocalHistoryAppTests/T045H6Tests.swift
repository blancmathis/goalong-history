#if os(macOS)
@testable import LocalHistoryApp
import XCTest

/// T-045 H6: Apple Santé preview and « Installer la commande ».
final class T045H6Tests: XCTestCase {
    /// The preview named most workouts in English (« Soccer », « HighIntensityIntervalTraining », « CrossTraining »).
    func testWorkoutNamesAreFrenchForCommonSports() {
        let expected = ["HKWorkoutActivityTypeSoccer": "Football", "HKWorkoutActivityTypeHighIntensityIntervalTraining": "Fractionné (HIIT)",
                        "HKWorkoutActivityTypeTennis": "Tennis", "HKWorkoutActivityTypeElliptical": "Elliptique",
                        "HKWorkoutActivityTypeRowing": "Aviron", "HKWorkoutActivityTypeDance": "Danse",
                        "HKWorkoutActivityTypeCoreTraining": "Gainage", "HKWorkoutActivityTypeCrossTraining": "Entraînement croisé"]
        for (raw, french) in expected { XCTAssertEqual(GoalongHealthImportSheet.sport(raw), french, raw) }
    }

    /// An unknown sport must never show its English identifier.
    func testUnknownWorkoutFallsBackToGenericFrenchName() {
        XCTAssertEqual(GoalongHealthImportSheet.sport("HKWorkoutActivityTypePickleball"), "Entraînement")
        XCTAssertEqual(GoalongHealthImportSheet.sport(""), "Entraînement")
    }

    /// A relative link to this very app is « ready » for the page, so install must say « déjà installée »
    /// instead of refusing it as « un autre programme ».
    func testInstallAcceptsARelativeLinkToThisApp() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("h6-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("Goalong History", isDirectory: false)
        try Data("x".utf8).write(to: executable)
        XCTAssertEqual(chmod(executable.path, 0o700), 0)
        let link = bin.appendingPathComponent("goalong", isDirectory: false)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "../Goalong History")
        XCTAssertEqual(GoalongCLIInstallation.inspect(linkURL: link, expectedExecutableURL: executable, isDevelopment: false).state, .ready)
        let outcome = GoalongCLIInstallation.install(linkURL: link, executableURL: executable, directoryOnPath: { _ in true }, isDevelopment: false)
        XCTAssertTrue(outcome.succeeded, outcome.message)
        XCTAssertTrue(outcome.message.contains("déjà installée"), outcome.message)
    }
}
#endif
