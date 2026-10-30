import XCTest

/// T-046 L9 : les cibles `make` documentées existent, ont une recette, sont déclarées `.PHONY`, et les
/// scripts qu'elles appellent existent. Le test lit le Makefile ; il ne lance aucune cible.
final class T046UnitMakefileTests: XCTestCase {
    private let repo = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func makefile() throws -> String {
        try String(contentsOf: repo.appendingPathComponent("Makefile"), encoding: .utf8)
    }

    private func recipe(of target: String, in text: String) -> [String] {
        let lines = text.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.hasPrefix("\(target):") }) else { return [] }
        return lines[(start + 1)...].prefix { $0.hasPrefix("\t") }.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    func testEveryDocumentedTargetHasARecipeAndIsPhony() throws {
        let text = try makefile()
        let targets = ["check", "test", "test-ui", "gallery-diff", "gallery-accept", "gallery-index", "gallery-compare",
                       "gallery-clean", "build", "app", "dev-stop", "dev-status", "dmg", "audit", "install",
                       "install-source", "uninstall", "clean"]
        let phony = text.replacingOccurrences(of: "\\\n", with: " ")
            .components(separatedBy: "\n").filter { $0.hasPrefix(".PHONY") }.joined(separator: " ")
        for target in targets {
            XCTAssertFalse(recipe(of: target, in: text).isEmpty, "make \(target) n'a pas de recette")
            XCTAssertTrue(phony.split(whereSeparator: \.isWhitespace).contains(Substring(target)), "make \(target) n'est pas .PHONY")
        }
    }

    func testScriptsCalledByTheTargetsExist() throws {
        let text = try makefile()
        let pattern = try NSRegularExpression(pattern: #"\./(scripts/[A-Za-z0-9_./-]+\.(?:sh|py|swift))|bash (scripts/[A-Za-z0-9_./-]+\.sh)"#)
        let range = NSRange(text.startIndex..., in: text)
        var seen = Set<String>()
        for match in pattern.matches(in: text, range: range) {
            for group in 1...2 where match.range(at: group).location != NSNotFound {
                seen.insert(String(text[Range(match.range(at: group), in: text)!]))
            }
        }
        XCTAssertFalse(seen.isEmpty)
        for path in seen {
            XCTAssertTrue(FileManager.default.fileExists(atPath: repo.appendingPathComponent(path).path), "\(path) manque")
        }
    }

    func testCheckAndTestUseTheIsolatedRunnerAndNeverBareSwiftTest() throws {
        let text = try makefile()
        XCTAssertTrue(recipe(of: "check", in: text).joined().contains("run_swift_tests.sh check"))
        XCTAssertTrue(recipe(of: "test", in: text).joined().contains("run_swift_tests.sh full"))
        XCTAssertFalse(recipe(of: "test", in: text).contains { $0.hasPrefix("swift test") })
    }

    func testInstallScriptsDelegateToInstallShAndTheShellScriptsAreExecutable() throws {
        let install = try String(contentsOf: repo.appendingPathComponent("Install.command"), encoding: .utf8)
        XCTAssertTrue(install.hasPrefix("#!/bin/bash"))
        XCTAssertTrue(install.contains("./install.sh"))
        let uninstall = try String(contentsOf: repo.appendingPathComponent("Uninstall.command"), encoding: .utf8)
        XCTAssertTrue(uninstall.hasPrefix("#!/bin/bash"))
        for name in ["Install.command", "Uninstall.command", "install.sh"] {
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: repo.appendingPathComponent(name).path), "\(name) n'est pas exécutable")
        }
    }
}
