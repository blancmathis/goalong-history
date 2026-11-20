import Foundation
@testable import LocalHistoryApp
import XCTest

final class PersoReleaseGateTests: XCTestCase {
    private let commit = String(repeating: "a1", count: 20)
    private let merge = String(repeating: "b2", count: 20)
    private let tag = "main-43622541811-1"

    func testBuildInfoNeedsAFullLowercaseCommit() throws {
        XCTAssertNil(PersoBuildInfo(info: nil))
        XCTAssertNil(PersoBuildInfo(info: [:]))
        XCTAssertNil(PersoBuildInfo(info: [PersoBuildInfo.commitKey: "abc123"]))
        XCTAssertNil(PersoBuildInfo(info: [PersoBuildInfo.commitKey: commit.uppercased()]))
        let info = try XCTUnwrap(PersoBuildInfo(info: [PersoBuildInfo.commitKey: commit,
                                                       PersoBuildInfo.branchKey: "feat/x",
                                                       PersoBuildInfo.builtAtKey: "unknown"]))
        XCTAssertEqual(info.shortCommit, "a1a1a1a1")
        XCTAssertEqual(info.label, "Build perso · feat/x · a1a1a1a1")
        XCTAssertNil(info.builtAt)
        XCTAssertEqual(PersoBuildInfo(info: [PersoBuildInfo.commitKey: commit])?.label, "Build perso · a1a1a1a1")
    }

    func testReleaseTagComesOnlyFromAnImmutableReleaseDownload() {
        func tag(_ string: String) -> String? { PersoReleaseGate.releaseTag(enclosure: URL(string: string)) }
        XCTAssertEqual(tag("https://github.com/blancmathis/goalong-history/releases/download/main-1-1/Goalong.zip"), "main-1-1")
        XCTAssertNil(tag("https://github.com/blancmathis/goalong-history/releases/download/latest-main/Goalong.zip"))
        XCTAssertNil(tag("https://github.com/other/repo/releases/download/main-1-1/Goalong.zip"))
        XCTAssertNil(tag("https://github.com/blancmathis/goalong-history/releases/download/main-1-1/a/b.zip"))
        XCTAssertNil(tag("https://github.com/blancmathis/goalong-history/releases/download/..%2F/x.zip"))
        XCTAssertNil(PersoReleaseGate.releaseTag(enclosure: nil))
    }

    func testCompareVerdicts() {
        func body(_ status: String) -> Data { Data("{\"status\":\"\(status)\"}".utf8) }
        XCTAssertEqual(PersoReleaseGate.compareVerdict(status: 200, body: body("ahead")), .contains)
        XCTAssertEqual(PersoReleaseGate.compareVerdict(status: 200, body: body("identical")), .contains)
        XCTAssertEqual(PersoReleaseGate.compareVerdict(status: 200, body: body("behind")), .lacks)
        XCTAssertEqual(PersoReleaseGate.compareVerdict(status: 200, body: body("diverged")), .lacks)
        guard case .unknown = PersoReleaseGate.compareVerdict(status: 200, body: Data("x".utf8)) else { return XCTFail() }
        guard case .unknown = PersoReleaseGate.compareVerdict(status: 404, body: Data()) else { return XCTFail() }
        guard case .unknown = PersoReleaseGate.compareVerdict(status: 403, body: Data()) else { return XCTFail() }
        XCTAssertNil(PersoReleaseGate.compareURL(base: "abc", tag: tag))
        XCTAssertEqual(PersoReleaseGate.compareURL(base: commit, tag: tag)?.absoluteString,
                       "https://api.github.com/repos/blancmathis/goalong-history/compare/\(commit)...\(tag)?per_page=1")
    }

    func testMergedMainCommitsKeepsOnlyMergedPullRequestsIntoMain() throws {
        let list: [[String: Any]] = [
            ["merged_at": "2026-11-20T10:00:00Z", "base": ["ref": "main"], "merge_commit_sha": merge],
            ["merged_at": NSNull(), "base": ["ref": "main"], "merge_commit_sha": commit],
            ["merged_at": "2026-11-20T10:00:00Z", "base": ["ref": "other"], "merge_commit_sha": commit],
        ]
        let data = try JSONSerialization.data(withJSONObject: list)
        XCTAssertEqual(PersoReleaseGate.mergedMainCommits(status: 200, body: data), [merge])
        XCTAssertNil(PersoReleaseGate.mergedMainCommits(status: 500, body: data))
    }

    private func fetch(_ answers: [String: (Int, String)]) -> PersoFetch {
        { url in
            let key = url.absoluteString
            guard let match = answers.first(where: { key.contains($0.key) }) else { return nil }
            return (match.value.0, Data(match.value.1.utf8))
        }
    }

    func testVerdictDirectAncestor() async {
        let verdict = await PersoReleaseGate.verdict(commit: commit, tag: tag,
                                                     fetch: fetch(["compare/\(commit)": (200, #"{"status":"ahead"}"#)]))
        XCTAssertEqual(verdict, .contains)
    }

    func testVerdictSquashMergeThroughPullRequest() async {
        let pulls = #"[{"merged_at":"2026-11-20T10:00:00Z","base":{"ref":"main"},"merge_commit_sha":"\#(merge)"}]"#
        let verdict = await PersoReleaseGate.verdict(commit: commit, tag: tag, fetch: fetch([
            "compare/\(commit)": (200, #"{"status":"diverged"}"#),
            "commits/\(commit)/pulls": (200, pulls),
            "compare/\(merge)": (200, #"{"status":"ahead"}"#),
        ]))
        XCTAssertEqual(verdict, .contains)
    }

    func testVerdictLacksWhenNoMergedPullRequestIsInTheRelease() async {
        let verdict = await PersoReleaseGate.verdict(commit: commit, tag: tag, fetch: fetch([
            "compare/\(commit)": (200, #"{"status":"diverged"}"#),
            "commits/\(commit)/pulls": (200, "[]"),
        ]))
        XCTAssertEqual(verdict, .lacks)
    }

    func testVerdictUnknownOnNetworkFailureOrUnpushedCommit() async {
        let offline = await PersoReleaseGate.verdict(commit: commit, tag: tag, fetch: { _ in nil })
        guard case .unknown = offline else { return XCTFail("\(offline)") }
        let unpushed = await PersoReleaseGate.verdict(commit: commit, tag: tag, fetch: fetch([
            "compare/\(commit)": (404, "{}"),
            "commits/\(commit)/pulls": (422, "{}"),
        ]))
        guard case .unknown = unpushed else { return XCTFail("\(unpushed)") }
        let noPulls = await PersoReleaseGate.verdict(commit: commit, tag: tag, fetch: fetch([
            "compare/\(commit)": (200, #"{"status":"diverged"}"#),
            "commits/\(commit)/pulls": (403, "{}"),
        ]))
        guard case .unknown = noPulls else { return XCTFail("\(noPulls)") }
    }

    @MainActor
    func testCheckerSkipsUntilAFinalAnswerAndCachesIt() throws {
        let build = try XCTUnwrap(PersoBuildInfo(info: [PersoBuildInfo.commitKey: commit]))
        let checker = PersoReleaseChecker(build: build, fetch: { _ in nil })
        XCTAssertEqual(checker.decide(tag: nil, version: "0.7.1"),
                       .skip("Release 0.7.1 ignorée : sa version d’origine est illisible."))
        XCTAssertEqual(checker.decide(tag: tag, version: "0.7.1"),
                       .skip("Release 0.7.1 ignorée pour l’instant : vérification de ton commit a1a1a1a1 en cours."))
        checker.finish(tag: tag, verdict: .unknown("GitHub injoignable"))
        XCTAssertEqual(checker.decide(tag: tag, version: "0.7.1"),
                       .skip("Release 0.7.1 ignorée pour l’instant : GitHub injoignable. Nouvel essai à la prochaine vérification."))
        checker.finish(tag: tag, verdict: .lacks)
        XCTAssertEqual(checker.decide(tag: tag, version: "0.7.1"),
                       .skip("Release 0.7.1 ignorée : ne contient pas ton commit a1a1a1a1."))
        checker.finish(tag: "main-2-1", verdict: .contains)
        XCTAssertEqual(checker.decide(tag: "main-2-1", version: "0.7.2"), .install)
    }
}
