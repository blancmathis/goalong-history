#if os(macOS)
import ApplicationServices
import Foundation
import LocalHistoryCore
import XCTest
@testable import LocalHistoryApp

final class BlockingExceptionsKeywordsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_791_158_400)
    private func target(url: String? = "example.com/work", matches: Set<String> = []) -> BlockingObservation {
        var value = BlockingObservation(bundleIdentifier: "com.apple.Safari", pid: 42_000, windowFrame: nil,
                                        isBrowser: true, url: url, privateWindow: false, at: now)
        value.titleKeywordMatches = matches
        return value
    }
    private func parameters(keywords: [String] = [], bundle: String = "com.apple.Safari") -> ContextReadParameters {
        let app = ForegroundAXApplication(pid: 42, name: "Fixture", bundleIdentifier: bundle)
        var input = ContextReadParameters(foregroundApplication: app, applications: [42: app], config: .default,
            accessibilityAvailable: true, blockingAXTrusted: true, sessionAvailable: true, idleSeconds: 1,
            privacy: GoalongPrivacyPolicy(), pauseRevision: nil)
        input.blockingKeywords = keywords
        return input
    }

    func testExceptionBeatsSiteAndKeywordWithinItsList() {
        let list = BlockList(name: "Vidéo", sites: [.init(pattern: "youtube.com")],
                             exceptions: [.init(pattern: "youtube.com/work")], keywords: ["video"])
        for url in ["youtube.com/work", "m.youtube.com/work/lesson"] {
            let result = BlockingRules.explain(target(url: url, matches: ["video"]), list: list)
            XCTAssertFalse(result.blocked)
            XCTAssertEqual(result.reason, .exception("youtube.com/work"))
        }
        XCTAssertTrue(BlockingRules.wouldBlock(target(url: "youtube.com/works"), list: list))
    }
    @MainActor func testExceptionDoesNotUnblockAnotherActiveList() {
        let exempting = BlockList(name: "Vidéo", sites: [.init(pattern: "youtube.com")], exceptions: [.init(pattern: "youtube.com/work")])
        let blocking = BlockList(name: "Tout", sites: [.init(pattern: "youtube.com")])
        let backend = ExceptionsKeywordsBackend()
        let controller = BlockingController(document: .init(lists: [exempting, blocking]), clock: { self.now }, backend: backend)
        controller.start(listIDs: [exempting.id, blocking.id], until: now.addingTimeInterval(600), lock: .free)
        controller.observe(target(url: "youtube.com/work"))
        XCTAssertEqual(backend.siteBlocks, 1)
        XCTAssertEqual(backend.lastList, "Tout")
    }
    func testBrowserAppBlockWinsEvenOnInternalOrExceptedPage() {
        let list = BlockList(name: "Navigateur", apps: [.init(bundleIdentifier: "com.apple.Safari", name: "Safari")],
                             exceptions: [.init(pattern: "example.com")])
        var value = target()
        XCTAssertEqual(BlockingRules.explain(value, list: list).reason, .appRule)
        value.isInternalPage = true
        XCTAssertTrue(BlockingRules.wouldBlock(value, list: list))
    }
    func testAllowOnlyIgnoresExceptionsAndKeywordBeatsAllowedSite() {
        let list = BlockList(name: "Travail", mode: .allowOnly, sites: [.init(pattern: "example.com")],
                             exceptions: [.init(pattern: "other.com")], keywords: ["video"])
        XCTAssertTrue(BlockingRules.wouldBlock(target(url: "other.com"), list: list))
        XCTAssertFalse(BlockingRules.wouldBlock(target(), list: list))
        XCTAssertTrue(BlockingRules.wouldBlock(target(url: "example.com/video"), list: list))
        XCTAssertTrue(BlockingRules.wouldBlock(target(matches: ["video"]), list: list))
    }
    func testInternalPagesStayAllowedBeforeExceptionsAndKeywords() {
        let list = BlockList(name: "Travail", mode: .allowOnly, keywords: ["video"])
        var value = target(url: "chrome://newtab", matches: ["video"]); value.isInternalPage = true
        XCTAssertFalse(BlockingRules.wouldBlock(value, list: list))
        XCTAssertEqual(BlockingRules.explain(value, list: list).reason, .internalPage)
    }
    func testKeywordWholeWordBoundariesAndDiacriticsTable() {
        for (keyword, text, expected) in [
            ("sex", "sex", true), ("sex", "SEX!", true), ("sex", "essex", false),
            ("sex", "sex2", false), ("sex", "2sex", false), ("sex", "asexb", false),
            ("école", "ÉCOLE", true), ("école", "ecole", true), ("ecole", "e\u{301}cole", true),
            ("école", "écoles", false), ("jeux vidéo", "Jeux   VIDÉO", true),
            ("jeux vidéo", "jeux/vidéo", true), ("jeux vidéo", "jeux de vidéo", false),
            ("jeux vidéo", "enjeux vidéo", false), ("c++", "learn c++ today", true),
            ("c++", "learn c today", false), ("c++", "c++17", false)
        ] { XCTAssertEqual(BlockingRules.matchesKeyword(keyword, text: text), expected, "\(keyword): \(text)") }
    }
    func testURLTokensNeverIncludeQueryFragmentCredentialsOrPort() {
        let list = BlockList(name: "Mots", keywords: ["video", "jeux video"])
        for url in ["video.example.com", "example.com/video", "example.com/a-video_b", "example.com/jeux-vidéo", "example.com/jeux_vidéo"] {
            XCTAssertTrue(BlockingRules.wouldBlock(target(url: url), list: list), url)
        }
        for url in ["example.com/videotape", "example.com/?q=video", "example.com/#video", "https://video:video@example.com/work"] {
            XCTAssertFalse(BlockingRules.wouldBlock(target(url: url), list: list), url)
        }
    }
    func testPureControllerExplanationConsumesGoogleTitleOnlyForTheCall() {
        let list = BlockList(name: "Mots", keywords: ["école"])
        let result = BlockingController.explain(url: "https://google.com/search?q=ecole", title: "École - Recherche Google", list: list)
        XCTAssertTrue(result.blocked)
        XCTAssertEqual(result.reason, .keyword("école", .title))
        XCTAssertTrue(result.message.contains("titre"))
        XCTAssertFalse(BlockingController.explain(url: "https://google.com/search?q=ecole", list: list).blocked)
        XCTAssertFalse(BlockingController.explain(url: "about:blank", title: "école", list: list).blocked)
    }
    func testKeywordsNeverApplyToNonBrowserAppsOrPrivateTargets() {
        let list = BlockList(name: "Mots", keywords: ["video"])
        var value = target(url: "example.com/video", matches: ["video"])
        value.isBrowser = false
        XCTAssertFalse(BlockingRules.explain(value, list: list, title: "video").blocked)
        value.isBrowser = true; value.privateWindow = true
        XCTAssertFalse(BlockingRules.explain(value, list: list, title: "video").blocked)
    }
    func testTitleMatchWorksWhenAddressIsMissing() {
        let list = BlockList(name: "Mots", keywords: ["video"])
        XCTAssertTrue(BlockingRules.wouldBlock(target(url: nil, matches: ["video"]), list: list))
        XCTAssertFalse(BlockingRules.wouldBlock(target(url: nil), list: list))
    }
    func testTitleReadGateDoesNotInvokeReaderWithoutKeywordsOrInPrivate() {
        var reads = 0
        let read = { reads += 1; return Optional("Video - Recherche Google") }
        XCTAssertTrue(BlockingRules.matchingTitleKeywords([], readTitle: read, privateWindow: false).isEmpty)
        XCTAssertTrue(BlockingRules.matchingTitleKeywords(["video"], readTitle: read, privateWindow: true).isEmpty)
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(BlockingRules.matchingTitleKeywords(["video"], readTitle: read, privateWindow: false), ["video"])
        XCTAssertEqual(reads, 1)
    }
    func testReaderWithoutKeywordsAddsNoTitleReadToExistingPrivateClassifier() {
        let tree = ScriptedAXTree(browser: true), reader = ContextAXReader(), input = parameters()
        _ = AXAccess.withClient(tree.client) { reader.captureBlocking(parameters: input) }
        tree.reads = [] // warm the unchanged private classifier, then measure the keyword path
        let result = AXAccess.withClient(tree.client) { reader.captureBlocking(parameters: input) }
        XCTAssertTrue(result?.titleKeywordMatches.isEmpty == true)
        XCTAssertFalse(tree.reads.contains("AXTitle"))
    }
    func testReaderPublishesOnlyConfiguredMatchesNeverTitleAndDoesNotCacheMatch() {
        let tree = ScriptedAXTree(browser: true), reader = ContextAXReader(), input = parameters(keywords: ["école", "video"])
        tree.attributes[Int(CFHash(tree.window))]?["AXTitle"] = "École - Recherche Google" as CFString
        let first = AXAccess.withClient(tree.client) { reader.captureBlocking(parameters: input) }
        XCTAssertEqual(first?.titleKeywordMatches, ["ecole"])
        XCTAssertEqual(first?.url, "example.com/work")
        XCTAssertFalse(Mirror(reflecting: first!).children.contains { $0.label == "title" || $0.label == "windowTitle" })
        tree.attributes[Int(CFHash(tree.window))]?["AXTitle"] = "Travail" as CFString
        let next = AXAccess.withClient(tree.client) { reader.captureBlocking(parameters: input) }
        XCTAssertTrue(next?.titleKeywordMatches.isEmpty == true)
    }
    func testPrivateReaderAddsNoKeywordTitleReadAndDoesNotReadAddress() {
        let baseline = ScriptedAXTree(browser: true), withKeywords = ScriptedAXTree(browser: true)
        for tree in [baseline, withKeywords] { tree.attributes[Int(CFHash(tree.window))]?["AXTitle"] = "Private Browsing video" as CFString }
        let first = AXAccess.withClient(baseline.client) { ContextAXReader().captureBlocking(parameters: parameters()) }
        let second = AXAccess.withClient(withKeywords.client) { ContextAXReader().captureBlocking(parameters: parameters(keywords: ["video"])) }
        XCTAssertTrue(first?.privateWindow == true); XCTAssertTrue(second?.privateWindow == true)
        XCTAssertEqual(withKeywords.reads, baseline.reads)
        XCTAssertFalse(withKeywords.reads.contains("AXDocument")); XCTAssertFalse(withKeywords.reads.contains("AXValue"))
        XCTAssertTrue(second?.titleKeywordMatches.isEmpty == true)
    }
    func testKeywordReaderRechecksPrivateFlagBeforeEachTitleMatch() {
        let tree = ScriptedAXTree(browser: true), reader = ContextAXReader(), input = parameters(keywords: ["video"])
        tree.attributes[Int(CFHash(tree.window))]?["AXTitle"] = "video" as CFString
        XCTAssertEqual(AXAccess.withClient(tree.client) { reader.captureBlocking(parameters: input) }?.titleKeywordMatches, ["video"])
        tree.attributes[Int(CFHash(tree.window))]?["AXTitle"] = "Private Browsing video" as CFString
        tree.reads = []
        let result = AXAccess.withClient(tree.client) { reader.captureBlocking(parameters: input) }
        XCTAssertTrue(result?.privateWindow == true)
        XCTAssertTrue(result?.titleKeywordMatches.isEmpty == true)
        XCTAssertFalse(tree.reads.contains("AXDocument"))
    }
    func testNativeReaderNeverRequestsKeywordTitle() {
        let tree = ScriptedAXTree(), input = parameters(keywords: ["video"], bundle: "test.native")
        let result = AXAccess.withClient(tree.client) { ContextAXReader().captureBlocking(parameters: input) }
        XCTAssertFalse(result?.isBrowser == true)
        XCTAssertFalse(tree.reads.contains("AXTitle"))
    }
    func testProviderConnectsKeywordRequirementOnlyToBlockingSink() {
        let tree = ScriptedAXTree(browser: true), input = parameters()
        let provider = ContextProvider(client: tree.client, backend: .legacy, parameters: { input })
        tree.attributes[Int(CFHash(tree.window))]?["AXTitle"] = "video" as CFString
        var keywords = ["video"]; provider.blockingKeywords = { keywords }
        XCTAssertEqual(provider.captureBlocking()?.titleKeywordMatches, ["video"])
        keywords = []
        XCTAssertTrue(provider.captureBlocking()?.titleKeywordMatches.isEmpty == true)
    }
    func testProviderDiscardsPendingKeywordReadWhenRequirementChanges() {
        let tree = ScriptedAXTree(browser: true), input = parameters()
        let provider = ContextProvider(client: tree.client, parameters: { input })
        tree.attributes[Int(CFHash(tree.window))]?["AXTitle"] = "video" as CFString
        var keywords = ["video"]; provider.blockingKeywords = { keywords }
        tree.beforeRead = { attribute in
            if attribute == "AXTitle" { DispatchQueue.main.async { keywords = [] } }
        }
        let done = expectation(description: "revoked keyword sample")
        provider.requestBlocking { result in XCTAssertNil(result); done.fulfill() }
        wait(for: [done], timeout: 3)
    }
    @MainActor func testKeywordOnlyListIsObservedOnlyWhenActiveAndExpires() {
        var current = now
        let list = BlockList(name: "Mots", keywords: ["video"]), empty = BlockList(name: "Exceptions", exceptions: [.init(pattern: "example.com")])
        XCTAssertFalse(list.isEmpty); XCTAssertTrue(empty.isEmpty)
        XCTAssertTrue(BlockingRules.hasSites(list))
        let controller = BlockingController(document: .init(lists: [list]), clock: { current }, continuous: { current.timeIntervalSince1970 })
        XCTAssertFalse(controller.needsObservation); XCTAssertTrue(controller.activeKeywords.isEmpty)
        controller.start(listIDs: [list.id], until: now.addingTimeInterval(60), lock: .free)
        XCTAssertTrue(controller.needsObservation); XCTAssertEqual(controller.activeKeywords, ["video"])
        current = now.addingTimeInterval(60); controller.refresh()
        XCTAssertFalse(controller.needsObservation); XCTAssertTrue(controller.activeKeywords.isEmpty)
    }
    @MainActor func testProgramAndManualLocksPermitOnlyAddingKeywordsAndRemovingExceptions() {
        for programLock in [false, true] {
            var list = BlockList(name: "Mots", exceptions: [.init(pattern: "example.com/work")], keywords: ["video"])
            if programLock { list.program.lockedUntil = now.addingTimeInterval(600) }
            let controller = BlockingController(document: .init(lists: [list]), clock: { self.now })
            if !programLock { controller.start(listIDs: [list.id], until: now.addingTimeInterval(600), lock: .locked) }
            XCTAssertEqual(controller.addKeyword("école", to: list.id), .allowed)
            XCTAssertNotEqual(controller.removeKeyword("video", from: list.id), .allowed)
            XCTAssertNotEqual(controller.addException("other.com", to: list.id), .allowed)
            var edited = controller.list(list.id)!
            edited.exceptions = [.init(pattern: "example.com")]
            XCTAssertNotEqual(controller.editCheck(edited), .allowed) // widening
            edited.exceptions = [.init(pattern: "example.com/work/lesson")]
            XCTAssertNotEqual(controller.editCheck(edited), .allowed) // remove + add, even narrowing
            XCTAssertEqual(controller.removeException(.init(pattern: "example.com/work"), from: list.id), .allowed)
            XCTAssertEqual(controller.list(list.id)?.keywords, ["video", "école"])
        }
    }
    @MainActor func testUnlockedEditingNormalizesAndDeduplicatesWithoutChangingSchema() {
        let list = BlockList(name: "Mots")
        let controller = BlockingController(document: .init(lists: [list]), clock: { self.now })
        XCTAssertEqual(controller.addException(" HTTPS://WWW.EXAMPLE.COM/WORK/?q=ignored ", to: list.id), .allowed)
        XCTAssertEqual(controller.list(list.id)?.exceptions, [.init(pattern: "example.com/work")])
        XCTAssertEqual(controller.addKeyword(" E\u{301}COLE ", to: list.id), .allowed)
        XCTAssertEqual(controller.addKeyword("ecole", to: list.id), .allowed)
        XCTAssertEqual(controller.list(list.id)?.keywords, ["école"])
        XCTAssertEqual(controller.removeKeyword("ÉCOLE", from: list.id), .allowed)
        XCTAssertEqual(controller.removeException(.init(pattern: "example.com/work"), from: list.id), .allowed)
        XCTAssertTrue(controller.list(list.id)?.keywords?.isEmpty == true)
        XCTAssertEqual(controller.snapshot.version, 1)
        XCTAssertNotEqual(controller.addKeyword("x", to: list.id), .allowed)
        XCTAssertNotEqual(controller.addException("localhost", to: list.id), .allowed)
        XCTAssertNotEqual(controller.addKeyword("valid", to: UUID()), .allowed)
    }
    func testValidateLimitsCanonicalStorageAndFoldedDuplicates() {
        for keywords in [["ab"], [String(repeating: "a", count: 40)], (0..<50).map { "word\($0)" }] {
            XCTAssertTrue(BlockingRules.validate(.init(lists: [BlockList(name: "Mots", keywords: keywords)])))
        }
        for keywords in [[""], [" "], ["a"], [String(repeating: "a", count: 41)], [" Video"], ["VIDEO"], ["e\u{301}cole"], ["école", "ecole"], (0..<51).map { "word\($0)" }] {
            XCTAssertFalse(BlockingRules.validate(.init(lists: [BlockList(name: "Mots", keywords: keywords)])), "\(keywords.count) entries")
        }
        XCTAssertFalse(BlockingRules.validate(.init(lists: [BlockList(name: "Mots", exceptions: [.init(pattern: "localhost")])])) )
        XCTAssertFalse(BlockingRules.validate(.init(lists: [BlockList(name: "Mots", exceptions: [.init(pattern: "HTTPS://EXAMPLE.COM")])])) )
    }
    func testOldSchemaOneDecodesWithoutNewFieldsAndRoundTripsOptionalFields() throws {
        let original = BlockingDocument(lists: [BlockList(name: "Ancienne", sites: [.init(pattern: "example.com")])])
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        let oldData = try encoder.encode(original)
        XCTAssertFalse(String(decoding: oldData, as: UTF8.self).contains("keywords"))
        let old = try decoder.decode(BlockingDocument.self, from: oldData)
        XCTAssertNil(old.lists[0].keywords); XCTAssertNil(old.lists[0].exceptions)
        XCTAssertTrue(BlockingRules.validate(old))
        var next = old; next.lists[0].keywords = ["école"]; next.lists[0].exceptions = [.init(pattern: "example.com/work")]
        XCTAssertEqual(try decoder.decode(BlockingDocument.self, from: encoder.encode(next)), next)
    }
    @MainActor func testTitleMatchedKeywordDispatchAndQuotaUsesOnlyConsecutiveMatchingSamples() {
        var current = now
        let backend = ExceptionsKeywordsBackend(), list = BlockList(name: "Mots", quotaMinutesPerDay: 1, keywords: ["video"])
        let controller = BlockingController(document: .init(lists: [list]), clock: { current }, backend: backend, continuous: { current.timeIntervalSince1970 })
        controller.start(listIDs: [list.id], until: now.addingTimeInterval(600), lock: .free)
        var value = target(matches: ["video"]); controller.observe(value)
        current = now.addingTimeInterval(10); value.at = current; controller.observe(value)
        XCTAssertEqual(controller.snapshot.usage?.quotaSecondsUsed[list.id], 10)
        current = now.addingTimeInterval(20); value.at = current; value.titleKeywordMatches = []; controller.observe(value)
        XCTAssertEqual(controller.snapshot.usage?.quotaSecondsUsed[list.id], 10)
        XCTAssertEqual(backend.siteBlocks, 0)
        let immediate = BlockList(name: "Immédiat", keywords: ["video"])
        controller.save(immediate); controller.start(listIDs: [immediate.id], until: now.addingTimeInterval(600), lock: .free)
        value.titleKeywordMatches = ["video"]; controller.observe(value)
        XCTAssertEqual(backend.siteBlocks, 1)
        XCTAssertTrue(controller.siteActionStillRequired(value))
        value.titleKeywordMatches = []; controller.observe(value)
        XCTAssertFalse(controller.siteActionStillRequired(value))
    }

    func testAllowOnlyStillBlocksAddressesThatDoNotNormalize() {
        let list = BlockList(name: "Travail", mode: .allowOnly, sites: [.init(pattern: "github.com")])
        for url in ["192.168.1.10/admin", "localhost/app", "[::1]/x"] {
            XCTAssertTrue(BlockingRules.explain(url: url, list: list).blocked, url)
        }
        XCTAssertFalse(BlockingRules.explain(url: "192.168.1.10/admin", list: BlockList(name: "Vidéo", sites: [.init(pattern: "youtube.com")])).blocked)
    }
}

@MainActor private final class ExceptionsKeywordsBackend: BlockingEnforcementBackend {
    var accessibilityAvailable = true
    var canLockScreen = true
    var browsers: [BlockingBrowserSupport] = []
    var appStillBlocked: ((BlockingObservation) -> Bool)?
    var siteBlocks = 0
    var lastList: String?
    func observeBrowser(_ target: BlockingObservation) {}
    func updateProtection(locked: Bool) -> BlockingProtectionState { .init() }
    func blockApp(_ target: BlockingObservation, app: BlockAppRule, block: BlockingActiveBlock, listName: String) {}
    func blockSite(_ target: BlockingObservation, presentation: BlockingVeilPresentation, onBreak: @escaping () -> Void) { siteBlocks += 1; lastList = presentation.listName }
    func clearSite() {}
    func updateFreeze(_ freeze: BlockFreeze?) {}
    func returnToShield() {}
    func shutdown() {}
}
#endif
