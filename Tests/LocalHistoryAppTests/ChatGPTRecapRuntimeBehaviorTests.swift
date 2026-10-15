#if os(macOS)
    import Foundation
    import XCTest
    @testable import LocalHistoryApp

    final class ChatGPTRecapRuntimeBehaviorTests: XCTestCase {
        private func makeContainer() throws -> URL {
            let path = FileManager.default.temporaryDirectory.path
            var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
            let resolved = buffer.withUnsafeMutableBufferPointer { pointer in
                path.withCString { Darwin.realpath($0, pointer.baseAddress) }
            }
            guard resolved != nil else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            let temporary = URL(fileURLWithPath: String(cString: buffer), isDirectory: true)
            let directory = temporary
                .appendingPathComponent("goalong-recap-behavior-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            return directory
        }

        private func makeRuntime(
            container: URL,
            executable: URL? = nil,
            sessionFactory: @escaping (URL) throws -> CodexAppServerSession = { _ in
                throw NSError(domain: "ChatGPTRecapRuntimeBehaviorTests", code: 1)
            }
        ) -> ChatGPTRecapRuntime {
            ChatGPTRecapRuntime(
                chatHistoryStore: ChatGPTHistoryStore(
                    rootDirectory: container.appendingPathComponent("history", isDirectory: true)
                ),
                recapsDirectory: container.appendingPathComponent("recaps", isDirectory: true),
                executableLocator: { executable },
                sessionFactory: sessionFactory,
                directoryOpener: { _ in },
                fileRevealer: { _ in },
                delayedAutomaticScheduler: { _ in },
                automaticRetryScheduler: { _, _ in },
                analysisConsentProvider: { true }
            )
        }

        func testDayChangeKeepsAutomaticRunButStopsManualRun() throws {
            let container = try makeContainer()
            defer { try? FileManager.default.removeItem(at: container) }
            let runtime = makeRuntime(container: container)
            let today = Calendar.current.startOfDay(for: Date())
            let yesterday = today.addingTimeInterval(-86_400)
            runtime.selectDay(today)

            runtime.beginRunForTesting(streamed: "", automatic: true, day: yesterday)
            runtime.selectDay(today.addingTimeInterval(-2 * 86_400))
            XCTAssertTrue(runtime.hasActiveRunForTesting)
            XCTAssertTrue(runtime.isGenerating)
            XCTAssertFalse(runtime.isGeneratingSelectedDay)
            XCTAssertEqual(runtime.generatingDay, yesterday)

            runtime.selectDay(yesterday)
            XCTAssertTrue(runtime.isGeneratingSelectedDay)

            runtime.stop()
            XCTAssertFalse(runtime.hasActiveRunForTesting)
            XCTAssertFalse(runtime.isGenerating)
            XCTAssertNil(runtime.generatingDay)

            runtime.beginRunForTesting(streamed: "", automatic: false, day: yesterday)
            runtime.selectDay(today)
            XCTAssertFalse(runtime.hasActiveRunForTesting)
            XCTAssertFalse(runtime.isGenerating)
            XCTAssertNil(runtime.generatingDay)

            runtime.beginRunForTesting(streamed: "", automatic: true, day: today)
            runtime.prepareForHistoryClear()
            XCTAssertFalse(runtime.hasActiveRunForTesting)
        }

        func testSignedOutErrorIsFrenchNotRetryableAndNeverMentionsBilling() {
            let error = CodexAppServerError.signedOut
            let text = error.localizedDescription
            XCTAssertFalse(text.contains("signed-out"))
            XCTAssertFalse(text.contains("API"))
            XCTAssertTrue(text.contains("ChatGPT"))
            XCTAssertFalse(ChatGPTRecapRuntime.isRetryableAutomaticError(error))
            XCTAssertTrue(
                CodexAppServerError.accountNotChatGPT("apiKey").localizedDescription.contains("API"))
            XCTAssertTrue(ChatGPTRecapRuntime.isRetryableAutomaticError(CodexAppServerError.homeBusy))
        }

        func testUserVisibleCodexErrorsContainNoEnglishSentences() {
            let errors: [CodexAppServerError] = [
                .generationFailed("ChatGPT n’a pas pu terminer l’analyse."),
                .timeout("analyse de la sélection vérifiée"),
                .timeout("génération du bilan"),
                .signedOut,
                .homeBusy,
            ]
            for error in errors {
                let text = error.localizedDescription
                for phrase in ["could not", "did not", "analyzing", "generating the", "requires", "returned"] {
                    XCTAssertFalse(text.contains(phrase), "\(phrase) in \(text)")
                }
            }
        }

        func testGoalongWrittenErrorDetailsAreFrench() throws {
            var messages: [String] = []
            func capture(_ body: () throws -> Void) {
                do { try body(); XCTFail("expected an error") } catch { messages.append(error.localizedDescription) }
            }
            capture { _ = try ChatGPTDailyAssessment(productivityScore: 50, confidenceScore: 50, summaryLines: ["a", "b", "c", "d"]) }
            capture { _ = try ChatGPTDailyAssessment(productivityScore: 101, confidenceScore: 50, summaryLines: ["a", "b", "c", "d", "e"]) }
            capture { _ = try ChatGPTDailyAssessment(productivityScore: 50, confidenceScore: 50, summaryLines: ["a", "b", "c", "d", " "]) }
            capture { _ = try ChatGPTDailyAssessment.decode("{}") }
            capture { _ = try CodexAppServerMessageRouter.notificationMethod(in: ["id": 2]) }
            var decoder = CodexAppServerMessageDecoder(limits: .production)
            capture { try decoder.append(Data("[1]\n".utf8)); _ = try decoder.popMessage() }
            XCTAssertEqual(messages.count, 6)
            for text in messages {
                for token in ["is missing", "must", "did not", "was not", "Unknown", "exceeded", "is not"] {
                    XCTAssertFalse(text.contains(token), "\(token) in \(text)")
                }
            }
        }

        func testCodexHomeLeaseSerializesSessionsOnTheSameHome() throws {
            let container = try makeContainer()
            defer { try? FileManager.default.removeItem(at: container) }
            let home = container.appendingPathComponent("home", isDirectory: true)
            let other = container.appendingPathComponent("other", isDirectory: true)

            let first = try CodexHomeLease.acquire(for: home, waiting: 0)
            XCTAssertThrowsError(try CodexHomeLease.acquire(for: home, waiting: 0)) { error in
                guard case CodexAppServerError.homeBusy = error else {
                    return XCTFail("unexpected \(error)")
                }
            }
            let independent = try CodexHomeLease.acquire(for: other, waiting: 0)
            independent.release()
            first.release()
            first.release()
            let again = try CodexHomeLease.acquire(for: home, waiting: 0)
            again.release()
        }

        func testSessionHoldsHomeLeaseUntilItsProcessHasExited() throws {
            let container = try makeContainer()
            defer { try? FileManager.default.removeItem(at: container) }
            let home = container.appendingPathComponent("codex-home", isDirectory: true)
            let executable = container.appendingPathComponent("codex-fixture")
            let script = """
                #!/bin/sh
                IFS= read -r initialize_request
                printf '%s\\n' '{"id":1,"result":{"codexHome":"\(home.path)"}}'
                IFS= read -r initialized_notification
                exec sleep 30
                """
            try Data(script.utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

            let session = try CodexAppServerSession(executableURL: executable, codexHomeURL: home)
            XCTAssertThrowsError(
                try CodexAppServerSession(executableURL: executable, codexHomeURL: home, homeLeaseWait: 0)
            ) { error in
                guard case CodexAppServerError.homeBusy = error else {
                    return XCTFail("unexpected \(error)")
                }
            }
            session.close()
            let deadline = Date().addingTimeInterval(10)
            var lease: CodexHomeLease?
            while lease == nil, Date() < deadline {
                lease = try? CodexHomeLease.acquire(for: home, waiting: 0.2)
            }
            XCTAssertNotNil(lease, "the lease must be released once the process exits")
            lease?.release()
        }

        func testPruneOnOneHomeLeavesAnotherHomeUntouched() throws {
            let container = try makeContainer()
            defer { try? FileManager.default.removeItem(at: container) }
            let homeA = container.appendingPathComponent("a", isDirectory: true)
            let homeB = container.appendingPathComponent("b", isDirectory: true)
            try CodexAppServerSession.prepareCodexHome(at: homeB, siteAnalysisOnly: false)
            let state = homeB.appendingPathComponent("state_1.sqlite")
            try Data("x".utf8).write(to: state)
            let configB = try Data(contentsOf: homeB.appendingPathComponent("config.toml"))

            try CodexAppServerSession.prepareCodexHome(at: homeA, siteAnalysisOnly: true)

            XCTAssertTrue(FileManager.default.fileExists(atPath: state.path))
            XCTAssertEqual(try Data(contentsOf: homeB.appendingPathComponent("config.toml")), configB)
        }

        func testBackgroundDebounceSitsBelowTheTimerPeriod() {
            let minimum = ActivityAnalysisCycleCoordinator.minimumBackgroundRefreshInterval
            // A tick that fires on schedule, 30 s early and after a slow load, is not deferred.
            XCTAssertLessThan(minimum, ActivityAnalysisRuntime.backgroundRefreshInterval - 30 - 30)
            // Closely spaced non-forced refreshes are still debounced.
            XCTAssertGreaterThan(minimum, 5 * 60)
        }

        func testAccountEnablementFollowsConnectionState() throws {
            let container = try makeContainer()
            defer { try? FileManager.default.removeItem(at: container) }
            let runtime = makeRuntime(container: container)
            runtime.setConnectionStateForTesting(.signedOut)
            XCTAssertFalse(runtime.isAccountConnected)
            runtime.setConnectionStateForTesting(.connected(email: nil, plan: nil))
            XCTAssertTrue(runtime.isAccountConnected)
        }

        func testConnectionCanBeCancelledAndSurvivesDayChange() throws {
            let container = try makeContainer()
            defer { try? FileManager.default.removeItem(at: container) }
            let home = container.appendingPathComponent("codex-home", isDirectory: true)
            let executable = container.appendingPathComponent("codex-fixture")
            let marker = container.appendingPathComponent("login-started")
            let script = """
                #!/bin/sh
                IFS= read -r initialize_request
                printf '%s\\n' '{"id":1,"result":{"codexHome":"\(home.path)"}}'
                IFS= read -r initialized_notification
                IFS= read -r login_request
                printf '%s\\n' '{"id":2,"result":{"loginId":"login-1","authUrl":"https://example.com/not-opened"}}'
                touch '\(marker.path)'
                exec sleep 30
                """
            try Data(script.utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

            let runtime = makeRuntime(
                container: container, executable: executable,
                sessionFactory: { try CodexAppServerSession(executableURL: $0, codexHomeURL: home) })
            let today = Calendar.current.startOfDay(for: Date())
            runtime.selectDay(today)

            runtime.connectChatGPT()
            XCTAssertTrue(runtime.isConnecting)
            try waitUntil { FileManager.default.fileExists(atPath: marker.path) }

            runtime.selectDay(today.addingTimeInterval(-86_400))
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            XCTAssertTrue(runtime.isConnecting, "a day change must not close the sign-in session")

            runtime.cancelChatGPTConnection()
            try waitUntil { !runtime.isConnecting }
            XCTAssertEqual(runtime.connectionState, .signedOut)
            XCTAssertNil(runtime.alert)
        }

        func testFailedDisconnectKeepsAutomaticRecapsAndFreesTheCodexHome() throws {
            let container = try makeContainer()
            defer { try? FileManager.default.removeItem(at: container) }
            let key = "chatgptRecap.automaticEnabled"
            let saved = UserDefaults.standard.object(forKey: key)
            defer { UserDefaults.standard.set(saved, forKey: key) }
            let runtime = makeRuntime(
                container: container, executable: container.appendingPathComponent("codex"),
                sessionFactory: { _ in throw CodexAppServerError.homeBusy })
            runtime.automaticRecapsEnabled = true
            runtime.setConnectionStateForTesting(.connected(email: nil, plan: nil))

            runtime.disconnectChatGPT()
            XCTAssertTrue(runtime.isBusyWithCodex, "the work agent must not start during the logout")
            try waitUntil { runtime.alert != nil }
            XCTAssertEqual(runtime.alert?.title, "ChatGPT n’a pas pu être déconnecté")
            XCTAssertTrue(runtime.automaticRecapsEnabled, "a failed logout keeps the automatic setting")
            XCTAssertFalse(runtime.isCheckingAccount)
            XCTAssertTrue(runtime.isAccountConnected)
            runtime.stop()
        }

        private func waitUntil(timeout: TimeInterval = 15, _ condition: () -> Bool) throws {
            let deadline = Date().addingTimeInterval(timeout)
            while !condition() {
                guard Date() < deadline else { return XCTFail("timed out") }
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            }
        }
    }
#endif
