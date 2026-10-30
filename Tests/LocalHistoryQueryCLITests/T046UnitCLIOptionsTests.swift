import XCTest
@testable import LocalHistoryQueryCLI

/// T-046 L9 : chaque option et commande de la matrice « sans test unitaire » est lue par l'analyseur
/// de la ligne de commande. Une option reconnue n'échoue jamais avec le message d'usage ; une option
/// inconnue ou un argument en trop échoue avec lui, avant toute lecture de données.
final class T046UnitCLIOptionsTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("goalong-t046-cli-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("events"), withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func failure(_ arguments: [String]) -> String {
        var message = "no error"
        _ = CLIStdoutCapture.capture {
            do { try GoalongQueryCLI.run(arguments: ["--root", root.path] + arguments) }
            catch { message = "\(error)" }
        }
        return message
    }

    private func printed(_ arguments: [String]) -> String {
        let result = CLIStdoutCapture.capture { try? GoalongQueryCLI.run(arguments: ["--root", root.path] + arguments) }
        return String(decoding: result.out, as: UTF8.self)
    }

    // --help (J-0181)
    func testHelpPrintsUsageAndJsonAndRejectsExtraArguments() {
        XCTAssertTrue(printed(["--help"]).contains("goalong"))
        XCTAssertEqual(printed(["help"]), printed(["-h"]))
        XCTAssertTrue(printed(["help", "--json"]).hasPrefix("{"))
        XCTAssertEqual(failure(["--help", "extra"]), "help accepts only --json")
    }

    // recent --gaps-only / --semantic-only (J-0186, J-0187)
    func testRecentAcceptsGapsOnlyAndSemanticOnlyAndRejectsUnknownFlags() {
        XCTAssertEqual(failure(["recent", "--gaps-only", "--semantic-only"]), "no error")
        XCTAssertEqual(failure(["recent", "--gaps-only"]), "no error")
        XCTAssertEqual(failure(["recent", "--semantic-only"]), "no error")
        XCTAssertTrue(failure(["recent", "--bogus"]).hasPrefix("recent accepts --minutes N and the optional --actions-only, --gaps-only, --semantic-only"))
    }

    // day / summary (J-0157)
    func testDayAndSummaryTakeOneDayAndRejectExtraArguments() {
        XCTAssertEqual(failure(["day", "2026-01-02", "extra"]), "Use day [today|yesterday|YYYY-MM-DD]")
        XCTAssertEqual(failure(["summary", "2026-01-02", "extra"]), "Use summary [today|yesterday|YYYY-MM-DD]")
        XCTAssertEqual(failure(["day", "2026-01-02"]), "no error")
        XCTAssertEqual(failure(["summary"]), "no error")
    }

    // analysis-evidence --include-rich-context / --include-conversations / --conversations-only (J-0195…J-0197)
    func testAnalysisEvidenceFlagsAreValidatedBeforeAnyRead() {
        let range = ["--start-utc", "2026-01-02T00:00:00Z", "--end-utc", "2026-01-03T00:00:00Z"]
        XCTAssertTrue(failure(["analysis-evidence", "--include-rich-context"]).hasPrefix("analysis-evidence --start-utc"))
        XCTAssertTrue(failure(["analysis-evidence"] + range + ["--conversations-from", "2026-01-01"]).hasPrefix("--conversations-from requires"))
        XCTAssertTrue(failure(["analysis-evidence"] + range + ["--conversations-only", "--include-rich-context"]).hasPrefix("--conversations-from requires"))
        XCTAssertTrue(failure(["analysis-evidence"] + range + ["--include-rich-context"]).contains("Computer History"))
        XCTAssertTrue(failure(["analysis-evidence"] + range + ["--include-conversations", "--conversations-from", "2026-01-01"]).contains("Computer History"))
    }

    // export-site / send-site options (J-0202…J-0213)
    func testExportSiteReadsEveryOptionAndStopsOnTheMissingSourceConsent() {
        let flags = ["--include-apps", "--include-hourly", "--include-websites", "--include-recap", "--structured", "--rhythm-timeline", "--rhythm-times"]
        let valued = [["--mask-apps", "A,B"], ["--rhythm-project", "P"], ["--rhythm-apps", "A,B"]]
        for flag in flags {
            let message = failure(["export-site", "2026-01-02", flag])
            XCTAssertFalse(message.hasPrefix("Use export-site"), "\(flag): \(message)")
        }
        for pair in valued {
            let message = failure(["export-site", "2026-01-02"] + pair)
            XCTAssertFalse(message.hasPrefix("Use export-site"), "\(pair[0]): \(message)")
        }
        XCTAssertTrue(failure(["export-site", "2026-01-02", "--bogus"]).hasPrefix("Use export-site DAY"))
    }

    func testSendSiteRequiresUrlAndTokenFileAndExportSiteRefusesThem() {
        XCTAssertTrue(failure(["send-site", "2026-01-02"]).hasPrefix("send-site requires --url and --token-file"))
        XCTAssertTrue(failure(["send-site", "2026-01-02", "--url", "https://exemple.fr"]).hasPrefix("send-site requires --url and --token-file"))
        XCTAssertTrue(failure(["send-site", "2026-01-02", "--token-file", "/tmp/x"]).hasPrefix("send-site requires --url and --token-file"))
        XCTAssertTrue(failure(["export-site", "2026-01-02", "--url", "https://exemple.fr"]).hasPrefix("Use export-site DAY"))
        XCTAssertTrue(failure(["export-site", "2026-01-02", "--token-file", "/tmp/x"]).hasPrefix("Use export-site DAY"))
        XCTAssertFalse(failure(["send-site", "2026-01-02", "--url", "http://exemple.fr", "--token-file", "/tmp/absent"]).hasPrefix("send-site requires"))
    }

    // export-health / import-health --timezone / --groups (J-0165, J-0216, J-0217)
    func testHealthCommandsValidateTimezoneGroupsAndDates() {
        let base = ["--file", "/tmp/absent.xml", "--from", "2026-01-01", "--to", "2026-01-02"]
        for command in ["export-health", "import-health"] {
            XCTAssertTrue(failure([command]).hasPrefix("Use \(command) --file PATH"))
            XCTAssertTrue(failure([command] + base + ["--timezone", "Nowhere/Nope"]).hasPrefix("Use \(command)"))
            XCTAssertTrue(failure([command] + base + ["--groups", "sleep,unknown"]).hasPrefix("Use \(command)"))
            XCTAssertTrue(failure([command] + base + ["--groups", "sleep,sleep"]).hasPrefix("Use \(command)"))
            XCTAssertEqual(failure([command, "--file", "/tmp/absent.xml", "--from", "01/01", "--to", "2026-01-02"]), "Health dates must use YYYY-MM-DD.")
            let valid = failure([command] + base + ["--groups", "sleep,heart", "--timezone", "Europe/Paris"])
            XCTAssertFalse(valid.hasPrefix("Use \(command)"), valid)
            XCTAssertFalse(valid.hasPrefix("Health dates"), valid)
        }
    }

    // ask (J-0175)
    func testAskRequiresAQuestion() {
        XCTAssertEqual(failure(["ask"]), "ask requires a natural-language question")
        XCTAssertEqual(failure(["ask", "--days", "7"]), "ask requires a natural-language question")
    }
}
