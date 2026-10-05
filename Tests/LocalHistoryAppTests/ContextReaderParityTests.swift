#if os(macOS)
import ApplicationServices
import Foundation
import LocalHistoryCore
import XCTest
@testable import LocalHistoryApp

final class ContextReaderParityTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_791_158_400.125)

    private func parameters(bundle: String = "test.native", name: String = "Fixture",
                            config edit: (inout RecorderConfig) -> Void = { _ in },
                            accessibility: Bool = true, pause: String? = "initial") -> ContextReadParameters {
        var config = RecorderConfig.default
        config.captureWindowTitles = true; config.captureElementLabels = true; config.captureURLs = true
        config.excludedBundleIdentifiers = []
        edit(&config)
        var privacy = GoalongPrivacyPolicy(); privacy.revision = "none"
        let app = ForegroundAXApplication(pid: 42, name: name, bundleIdentifier: bundle)
        return ContextReadParameters(foregroundApplication: app, applications: [42: app], config: config,
            accessibilityAvailable: accessibility, blockingAXTrusted: true, sessionAvailable: true,
            idleSeconds: 1, privacy: privacy, pauseRevision: pause)
    }

    private func expected(_ parameters: ContextReadParameters, url: String? = nil,
                          window: Bool = true, labels: Bool = true, secure: Bool = false,
                          suppression: SuppressionReason? = nil) -> ContextSnapshot {
        let application = parameters.foregroundApplication!
        return ContextSnapshot(app: AppSnapshot(name: application.localizedName!, bundleIdentifier: application.bundleIdentifier, processIdentifier: application.processIdentifier),
            window: window ? WindowSnapshot(title: "Document", role: "AXWindow", subrole: nil) : nil,
            focusedElement: window ? ElementSnapshot(role: "AXTextField", subrole: secure ? "AXSecureTextField" : "AXTextField",
                title: labels && !secure ? "Name" : nil, label: labels && !secure ? "Editor" : nil,
                identifier: labels && !secure ? "editor" : nil, isSecure: secure) : nil,
            url: url.map { URLSnapshot(value: $0, host: URLComponents(string: $0)?.host, redactionApplied: false) },
            suppressionReason: suppression, privacyRevision: "none", globalPauseRevision: "initial")
    }

    func testPublicCorpusMatchesIndependentBaselineFieldForField() throws {
        let scenarios: [(String, ContextReadParameters, ScriptedAXTree, ContextSnapshot)] = [
            ("native", parameters(), ScriptedAXTree(), expected(parameters())),
            ("known_browser", parameters(bundle: "com.apple.Safari"), ScriptedAXTree(browser: true),
             expected(parameters(bundle: "com.apple.Safari"), url: "https://example.com/work")),
            ("wrapper", parameters(bundle: "test.wrapper"), ScriptedAXTree(browser: true),
             expected(parameters(bundle: "test.wrapper"), url: "https://example.com/work")),
            ("no_labels", parameters(config: { $0.captureElementLabels = false }), ScriptedAXTree(),
             expected(parameters(config: { $0.captureElementLabels = false }), labels: false)),
            ("secure", parameters(), ScriptedAXTree(secure: true), expected(parameters(), secure: true)),
            ("own_application", parameters(bundle: "ai.goalong.localhistory", name: "Goalong"), ScriptedAXTree(),
             expected(parameters(bundle: "ai.goalong.localhistory", name: "Goalong"))),
            ("missing_permission_browser", parameters(bundle: "com.apple.Safari", accessibility: false), ScriptedAXTree(),
             expected(parameters(bundle: "com.apple.Safari", accessibility: false), window: false, suppression: .accessibilityUnavailable)),
            ("excluded_app", parameters(config: { $0.excludedBundleIdentifiers = ["test.native"] }), ScriptedAXTree(),
             expected(parameters(config: { $0.excludedBundleIdentifiers = ["test.native"] }), window: false, suppression: .excludedApplication)),
            ("excluded_domain", parameters(bundle: "com.apple.Safari", config: { $0.excludedDomains = ["example.com"] }), ScriptedAXTree(browser: true),
             expected(parameters(bundle: "com.apple.Safari"), window: false, suppression: .excludedDomain)),
        ]
        for (name, input, tree, baseline) in scenarios {
            var effects: [Bool] = []
            let facade = ContextProvider(client: tree.client, backend: .legacy, parameters: { input }, privateWindowSink: { effects.append($0) })
            var completed = false
            facade.requestCapture { snapshot in
                XCTAssertEqual(snapshot, baseline, name)
                completed = true
            }
            XCTAssertTrue(completed, "Legacy completion remains inline: \(name)")
            let direct = AXAccess.withClient(tree.client) { ContextAXReader().capture(parameters: input) }
            XCTAssertEqual(direct.snapshot, baseline, name)
            XCTAssertEqual(effects, direct.privateWindowUpdate.map { [$0] } ?? [], name)
            if name == "excluded_app" {
                XCTAssertFalse(tree.reads.contains("AXTitle")); XCTAssertFalse(tree.reads.contains("AXDocument"))
            }
        }
    }

    func testPausedReadDoesNotTouchAXAndDoesNotApplyEffects() {
        let tree = ScriptedAXTree(), input = parameters(pause: nil)
        var effects = 0
        let facade = ContextProvider(client: tree.client, backend: .legacy, parameters: { input }, privateWindowSink: { _ in effects += 1 })
        facade.requestCapture { XCTAssertNil($0) }
        XCTAssertTrue(tree.reads.isEmpty); XCTAssertEqual(effects, 0)
    }

    func testPureReaderReturnsPrivateEffectWithoutExecutingIt() {
        let tree = ScriptedAXTree(browser: true), input = parameters(bundle: "com.apple.Safari")
        tree.attributes[Int(CFHash(tree.window))]?["AXTitle"] = "Private Browsing" as CFString
        let result = AXAccess.withClient(tree.client) { ContextAXReader().capture(parameters: input) }
        XCTAssertEqual(result.privateWindowUpdate, true)
        XCTAssertEqual(result.snapshot?.suppressionReason, .privateBrowserWindow)
        XCTAssertNil(result.snapshot?.window); XCTAssertNil(result.snapshot?.url)
        XCTAssertFalse(tree.reads.contains("AXValue")); XCTAssertFalse(tree.reads.contains("AXSelectedText"))
    }

    func testFreshSecureSuppressionAndHitTestUseImmutableConfiguration() {
        let tree = ScriptedAXTree(secure: true), input = parameters()
        let facade = ContextProvider(client: tree.client, backend: .legacy, parameters: { input })
        facade.requestSuppression { XCTAssertEqual($0, .secureInput) }
        tree.reads.removeAll()
        facade.requestElement(at: .zero, expectedProcessIdentifier: 42) { snapshot in
            XCTAssertTrue(snapshot?.isSecure == true)
            XCTAssertNil(snapshot?.title); XCTAssertNil(snapshot?.label)
        }
        XCTAssertTrue(Set(tree.reads).isSubset(of: ["AXRole", "AXSubrole", "AXProtectedContent"]))
        facade.requestElement(at: .zero, expectedProcessIdentifier: 84) { XCTAssertNil($0) }
    }

    func testFocusedSystemSurfaceUsesDescriptorCatalogue() {
        let tree = ScriptedAXTree()
        tree.client.getPID = { _, result in result.pointee = 84; return .success }
        let original = parameters()
        let surface = ForegroundAXApplication(pid: 84, name: "Control Center", bundleIdentifier: "com.apple.controlcenter")
        let input = ContextReadParameters(foregroundApplication: original.foregroundApplication, applications: [84: surface],
            config: original.config, accessibilityAvailable: true, blockingAXTrusted: true,
            sessionAvailable: true, idleSeconds: 1, privacy: original.privacy, pauseRevision: "initial")
        let result = AXAccess.withClient(tree.client) { ContextAXReader().capture(parameters: input) }
        XCTAssertEqual(result.snapshot?.app.processIdentifier, 84)
        XCTAssertEqual(result.snapshot?.app.bundleIdentifier, "com.apple.controlcenter")
    }

    func testSeparateBlockingCacheKeepsDiscoveredWrapperCapability() {
        let tree = ScriptedAXTree(browser: true), input = parameters(bundle: "test.wrapper")
        let facade = ContextProvider(client: tree.client, backend: .legacy, parameters: { input })
        XCTAssertEqual(facade.capture()?.url?.host, "example.com")
        // A wrapper's following private/internal window may expose no web area.
        tree.attributes[Int(CFHash(tree.window))]?.removeValue(forKey: "AXDocument")
        tree.attributes[Int(CFHash(tree.window))]?["AXTitle"] = "Private Browsing" as CFString
        let observation = facade.captureBlocking()
        XCTAssertTrue(observation?.privateWindow == true)
        XCTAssertNil(observation?.url)
    }

    func testUncataloguedSystemFocusResolvesInBridgeWithoutRepeatingAXProbe() {
        let tree = ScriptedAXTree(), input = parameters()
        tree.client.getPID = { _, result in result.pointee = 84; return .success }
        var resolutions: [pid_t] = []
        let facade = ContextProvider(client: tree.client, backend: .legacy, parameters: { input }, applicationResolver: { pid in
            XCTAssertTrue(Thread.isMainThread)
            resolutions.append(pid)
            return ForegroundAXApplication(pid: pid, name: "Control Center", bundleIdentifier: "com.apple.controlcenter")
        })
        facade.requestCapture {
            XCTAssertEqual($0?.app.processIdentifier, 84)
            XCTAssertEqual($0?.app.bundleIdentifier, "com.apple.controlcenter")
        }
        XCTAssertEqual(resolutions, [84])
        XCTAssertEqual(tree.reads.filter { $0 == "AXFocusedApplication" }.count, 1)
    }

    func testBlockingOnlyReadsNoHistoricalLabelsOrJevEffects() {
        let tree = ScriptedAXTree(), input = parameters()
        var effects = 0
        let facade = ContextProvider(client: tree.client, backend: .legacy, parameters: { input }, privateWindowSink: { _ in effects += 1 })
        var observations = 0
        facade.requestCapture(blockingSink: { _ in observations += 1 }, historyEnabled: false) { XCTAssertNil($0) }
        XCTAssertEqual(observations, 1); XCTAssertEqual(effects, 0)
        XCTAssertFalse(tree.reads.contains("AXValue")); XCTAssertFalse(tree.reads.contains("AXSelectedText"))
        XCTAssertFalse(tree.reads.contains("AXIdentifier"))
    }

    func testPublicInteractionEventFieldsAndJSONLHashChainMatchBaseline() throws {
        let tree = ScriptedAXTree(browser: true), input = parameters(bundle: "com.apple.Safari")
        let actual = try XCTUnwrap(ContextProvider(client: tree.client, backend: .legacy, parameters: { input }).capture())
        let baseline = expected(input, url: "https://example.com/work")
        let kinds: [EventKind] = [.applicationActivated, .heartbeat, .mouseClick, .mouseClick,
                                 .mouseClick, .scrollBurst, .typingBurst, .keyPressed, .keyboardShortcut,
                                 .windowChanged, .urlChanged, .focusChanged, .captureResumed]
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".perf-work/parity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var streams: [Data] = []
        for (label, context) in [("baseline", baseline), ("reader", actual)] {
            let state = IntegrityStateStore(fileURL: root.appendingPathComponent(label + ".state.json"), prepareStorage: {})
            let journal = IntegrityJournal(stateStore: state, saltBytes: { Data(repeating: 7, count: $0) })
            var stream = Data()
            for (index, kind) in kinds.enumerated() {
                let pointer = kind == .mouseClick ? PointerSnapshot(button: "left", x: 23, y: 45, clickCount: index == 3 ? 2 : 1) : nil
                let keyboard = [.typingBurst, .keyPressed, .keyboardShortcut].contains(kind)
                    ? KeyboardSnapshot(category: kind.rawValue, key: kind == .keyboardShortcut ? "c" : nil, modifiers: [], isRepeat: kind == .keyPressed) : nil
                let event = HistoryEvent(schemaVersion: 4, id: "event-\(index)", sessionID: "session-fixture", timestamp: date.addingTimeInterval(Double(index)),
                    kind: kind, app: context.app, window: context.window, element: context.focusedElement, url: context.url,
                    pointer: pointer, keyboard: keyboard, scroll: kind == .scrollBurst ? ScrollSnapshot(deltaX: 1, deltaY: 2, eventCount: 3) : nil,
                    metadata: ["input_sequence": String(index + 1), "interaction_id": "interaction-\(index)",
                               "observed_unix_ms": "\(Int64(date.timeIntervalSince1970 * 1000))"])
                let signed = journal.prepare(event)
                stream.append(try encoder.encode(signed)); stream.append(10)
                try journal.commitPersisted(signed)
            }
            try stream.write(to: root.appendingPathComponent(label + ".jsonl"))
            streams.append(stream)
        }
        XCTAssertEqual(streams[0], streams[1], "No field, date, ID, ordering or integrity field is filtered out")
        XCTAssertEqual(streams[0].filter { $0 == 10 }.count, kinds.count)
    }
}
#endif
