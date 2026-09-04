#if os(macOS)
    import Darwin
    import Foundation
    import XCTest
    import AppleScreenTime
    import AppleSystemScreenTime
    @testable import LocalHistoryQueryCLI

    final class GoalongReadOnlyQueryBrokerTests: XCTestCase {
        func testScreenTimeCLIExposesPrivateAggregateAssuranceWithoutParityClaim() throws {
            let calendar = Calendar.current
            let start = try XCTUnwrap(
                calendar.date(from: DateComponents(year: 2026, month: 9, day: 2))
            )
            let end = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: start))
            let mac = AppleScreenTimeDevice(id: "mac", name: "Mac", kind: .mac)
            let provenance = AppleScreenTimeProvenance(
                api: AppleScreenTimeProvenance.screenTimeAgentAggregateAPI,
                collectorBundleIdentifier: "ai.goalong.localhistory",
                collectorVersion: "test",
                collectorPlatform: "macOS test",
                authorization: .unknown,
                fetchPolicy: .live,
                euCustomerRequirementAcknowledged: false
            )
            let stored = AppleScreenTimeStoredExport(
                verification: .unsigned,
                envelope: AppleScreenTimeExportEnvelope(
                    requestedStart: start,
                    requestedEnd: end,
                    requestedScope: .allDevices,
                    provenance: provenance,
                    reports: [
                        AppleScreenTimeDeviceReport(
                            device: mac,
                            lastUpdatedAt: start,
                            segments: [
                                AppleScreenTimeSegment(
                                    start: start,
                                    end: end,
                                    totalScreenOnDuration: 600,
                                    applications: []
                                )
                            ]
                        )
                    ]
                )
            )
            let collection = AppleSystemScreenTimeCollection(
                storedExport: stored,
                availableDevices: [mac],
                status: AppleSystemScreenTimeStatus(
                    kind: .localOnly,
                    title: "Apple Screen Time aggregate for this Mac",
                    message: "Private aggregate; parity is not certified."
                ),
                deviceSourceLabels: [mac.id: "Apple Screen Time aggregate (private format)"],
                latestAppleUpdate: start,
                knowledgeIntervalCount: 0,
                biomeIntervalCount: 0
            )

            let payload = try GoalongQueryCLI.screenTimePayload(
                day: "2026-09-02",
                macOnly: false,
                collectionProvider: { _ in collection },
                currentMacProvider: { mac }
            )
            let json = try XCTUnwrap(
                JSONSerialization.jsonObject(with: payload) as? [String: Any]
            )

            XCTAssertEqual(json["sourceAssurance"] as? String, "privateAppleAggregateStore")
            XCTAssertEqual(
                json["freshness"] as? String,
                "collectedOnDemandForThisRequest"
            )
            XCTAssertTrue(
                (json["limitation"] as? String)?.contains("exact parity is not certified") == true
            )
        }

        func testIndirectScreenTimeIntentRecognizesUsageQuestionsWithoutOvermatchingWorkQuestions() {
            XCTAssertTrue(
                GoalongQueryCLI.questionRequiresFreshScreenTime(
                    "Combien de temps ai-je passé sur mes applications hier ?"
                )
            )
            XCTAssertTrue(
                GoalongQueryCLI.questionRequiresFreshScreenTime(
                    "Quelle était ma productivité et mon temps perdu sur l'ordinateur ?"
                )
            )
            XCTAssertTrue(
                GoalongQueryCLI.questionRequiresFreshScreenTime(
                    "Combien de temps ai-je passé sur ChatGPT ?"
                )
            )
            XCTAssertTrue(
                GoalongQueryCLI.questionRequiresFreshScreenTime(
                    "What was my Screen Time across my iPhone and iPad?"
                )
            )
            XCTAssertFalse(
                GoalongQueryCLI.questionRequiresFreshScreenTime(
                    "Sur quoi ai-je travaillé hier ?"
                )
            )
        }

        func testIndirectScreenTimeContextPerformsFreshRequestForEveryIncludedDay() throws {
            let calendar = Calendar(identifier: .gregorian)
            let firstDay = try XCTUnwrap(
                calendar.date(from: DateComponents(year: 2026, month: 9, day: 2))
            )
            let end = try XCTUnwrap(calendar.date(byAdding: .day, value: 2, to: firstDay))
            var requestedDays: [String] = []

            let context = GoalongQueryCLI.freshScreenTimeContext(
                root: URL(fileURLWithPath: "/unused", isDirectory: true),
                question: "Quel était mon temps d'écran sur mes appareils ?",
                firstDay: firstDay,
                endExclusive: end,
                maximumDays: 2,
                requestProvider: { _, day, macOnly, selectedDeviceIDs in
                    requestedDays.append(day)
                    XCTAssertFalse(macOnly)
                    XCTAssertTrue(selectedDeviceIDs.isEmpty)
                    return Data(
                        """
                        {
                          "schemaVersion": 1,
                          "day": "\(day)",
                          "generatedAt": "2026-09-03T12:00:00Z",
                          "freshness": "collectedOnDemandForThisRequest",
                          "scope": "allDevices",
                          "status": {"kind":"ready","title":"Ready","message":"Fresh"},
                          "summary": null,
                          "reports": [],
                          "availableDevices": [],
                          "deviceSourceLabels": {},
                          "latestAppleUpdate": null,
                          "screenTimeAppUsageIntervalCount": 0,
                          "knowledgeIntervalCount": 0,
                          "biomeIntervalCount": 0,
                          "limitation": "Test fixture"
                        }
                        """.utf8
                    )
                }
            )

            XCTAssertTrue(context.requested)
            XCTAssertEqual(context.refreshPolicy, "freshOnDemandAppleReadForEveryIncludedDay")
            XCTAssertEqual(context.days.map(\.day), requestedDays)
            XCTAssertEqual(requestedDays.count, 2)
            XCTAssertTrue(context.issues.isEmpty)
        }

        func testScreenTimeCLIUsesAppleAggregateWhenEveryPhysicalDeviceIsSelected() throws {
            let calendar = Calendar.current
            let start = try XCTUnwrap(
                calendar.date(from: DateComponents(year: 2026, month: 9, day: 3))
            )
            let end = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: start))
            let mac = AppleScreenTimeDevice(id: "mac", name: "MacBook Pro", kind: .mac)
            let iPhone = AppleScreenTimeDevice(id: "iphone", name: "iPhone", kind: .iPhone)
            let aggregate = AppleScreenTimeDevice(
                id: AppleScreenTimeProvenance.appleSettingsAllDevicesReportID,
                name: "All Devices",
                kind: .unknown
            )
            let provenance = AppleScreenTimeProvenance(
                api: AppleScreenTimeProvenance.appleSettingsAccessibilityAPI,
                collectorBundleIdentifier: "ai.goalong.localhistory",
                collectorVersion: "test",
                collectorPlatform: "macOS test",
                authorization: .unknown,
                fetchPolicy: .live,
                euCustomerRequirementAcknowledged: false
            )
            func report(
                _ device: AppleScreenTimeDevice,
                duration: TimeInterval
            ) -> AppleScreenTimeDeviceReport {
                AppleScreenTimeDeviceReport(
                    device: device,
                    lastUpdatedAt: start,
                    segments: [
                        AppleScreenTimeSegment(
                            start: start,
                            end: end,
                            totalScreenOnDuration: duration,
                            applications: []
                        )
                    ]
                )
            }
            let stored = AppleScreenTimeStoredExport(
                verification: .unsigned,
                envelope: AppleScreenTimeExportEnvelope(
                    requestedStart: start,
                    requestedEnd: end,
                    requestedScope: .allDevices,
                    provenance: provenance,
                    reports: [
                        report(mac, duration: 5_220),
                        report(iPhone, duration: 245),
                        report(aggregate, duration: 5_460),
                    ]
                )
            )
            let collection = AppleSystemScreenTimeCollection(
                storedExport: stored,
                availableDevices: [mac, iPhone],
                status: AppleSystemScreenTimeStatus(
                    kind: .ready,
                    title: "Matches Apple Screen Time",
                    message: "Visible values"
                ),
                deviceSourceLabels: [:],
                latestAppleUpdate: start,
                knowledgeIntervalCount: 0,
                biomeIntervalCount: 0
            )

            let payload = try GoalongQueryCLI.screenTimePayload(
                day: "2026-09-03",
                macOnly: false,
                selectedDeviceIDs: [mac.id, iPhone.id],
                collectionProvider: { _ in collection },
                currentMacProvider: { mac }
            )
            let json = try XCTUnwrap(
                JSONSerialization.jsonObject(with: payload) as? [String: Any]
            )
            let summary = try XCTUnwrap(json["summary"] as? [String: Any])
            let reports = try XCTUnwrap(json["reports"] as? [[String: Any]])

            XCTAssertEqual(summary["totalScreenOnDuration"] as? Double, 5_460)
            XCTAssertEqual(reports.count, 2)
        }

        func testBrokerReturnsTransientScreenTimePayloadAndRemovesSocket() throws {
            let root = try temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let expected = Data("{\"schemaVersion\":1,\"status\":{\"kind\":\"ready\"}}\n".utf8)
            let server = GoalongReadOnlyQueryServer(
                rootDirectory: root,
                screenTimeHandler: { day, macOnly, selectedDeviceIDs in
                    XCTAssertEqual(day, "2026-08-31")
                    XCTAssertTrue(macOnly)
                    XCTAssertEqual(selectedDeviceIDs, ["mac", "phone"])
                    return expected
                }
            )

            try server.start()
            let socketURL = GoalongReadOnlyQueryBroker.socketURL(rootDirectory: root)
            let attributes = try FileManager.default.attributesOfItem(atPath: socketURL.path)
            XCTAssertEqual(attributes[.type] as? FileAttributeType, .typeSocket)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)

            let actual = try GoalongReadOnlyQueryBroker.requestScreenTime(
                rootDirectory: root,
                day: "2026-08-31",
                macOnly: true,
                selectedDeviceIDs: ["mac", "phone"]
            )
            XCTAssertEqual(actual, expected)

            server.stop()
            XCTAssertFalse(FileManager.default.fileExists(atPath: socketURL.path))
        }

        func testBrokerRefusesToReplaceUnexpectedPath() throws {
            let root = try temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let socketURL = GoalongReadOnlyQueryBroker.socketURL(rootDirectory: root)
            try FileManager.default.createDirectory(
                at: socketURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let marker = Data("do-not-replace".utf8)
            try marker.write(to: socketURL, options: .withoutOverwriting)
            let server = GoalongReadOnlyQueryServer(
                rootDirectory: root,
                screenTimeHandler: { _, _, _ in Data() }
            )

            XCTAssertThrowsError(try server.start())
            XCTAssertThrowsError(
                try GoalongReadOnlyQueryServer.removeOwnedStaleSocket(rootDirectory: root)
            )
            XCTAssertEqual(try Data(contentsOf: socketURL), marker)
        }

        func testConsentOffCleanupRemovesOnlyOwnedSocket() throws {
            let root = try temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let server = GoalongReadOnlyQueryServer(
                rootDirectory: root,
                screenTimeHandler: { _, _, _ in Data() }
            )
            try server.start()
            let socketURL = GoalongReadOnlyQueryBroker.socketURL(rootDirectory: root)
            XCTAssertTrue(FileManager.default.fileExists(atPath: socketURL.path))

            try GoalongReadOnlyQueryServer.removeOwnedStaleSocket(rootDirectory: root)

            XCTAssertFalse(FileManager.default.fileExists(atPath: socketURL.path))
            server.stop()
            XCTAssertNoThrow(
                try GoalongReadOnlyQueryServer.removeOwnedStaleSocket(rootDirectory: root)
            )
        }

        func testCapabilityConsentFailsClosedAndRequiresExactCurrentDocument() throws {
            let root = try temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            XCTAssertFalse(
                GoalongQueryCLI.capabilityConsentEnabled(
                    rootDirectory: root,
                    capability: "aiConversations"
                )
            )

            let consent = root.appendingPathComponent("capability-consent.json")
            try Data(
                """
                {"schemaVersion":1,"policyVersion":1,"capabilities":{"aiConversations":{"enabled":true}}}
                """.utf8
            ).write(to: consent)
            XCTAssertTrue(
                GoalongQueryCLI.capabilityConsentEnabled(
                    rootDirectory: root,
                    capability: "aiConversations"
                )
            )

            try Data(
                """
                {"schemaVersion":1,"policyVersion":999,"capabilities":{"aiConversations":{"enabled":true}}}
                """.utf8
            ).write(to: consent, options: .atomic)
            XCTAssertFalse(
                GoalongQueryCLI.capabilityConsentEnabled(
                    rootDirectory: root,
                    capability: "aiConversations"
                )
            )
        }

        func testBrokerBuildsFreshScreenTimeForEveryRequest() throws {
            let root = try temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            var buildCount = 0
            let server = GoalongReadOnlyQueryServer(
                rootDirectory: root,
                screenTimeHandler: { _, _, _ in
                    buildCount += 1
                    return Data("{\"generation\":\(buildCount)}".utf8)
                }
            )
            try server.start()
            defer { server.stop() }

            let first = try GoalongReadOnlyQueryBroker.requestScreenTime(
                rootDirectory: root,
                day: "2026-09-01",
                macOnly: false
            )
            let second = try GoalongReadOnlyQueryBroker.requestScreenTime(
                rootDirectory: root,
                day: "2026-09-01",
                macOnly: false
            )

            XCTAssertEqual(first, Data("{\"generation\":1}".utf8))
            XCTAssertEqual(second, Data("{\"generation\":2}".utf8))
            XCTAssertEqual(buildCount, 2)
        }

        private func temporaryRoot() throws -> URL {
            let root = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent(
                "goalong-broker-\(UUID().uuidString.prefix(8))",
                isDirectory: true
            )
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            return root
        }
    }
#endif
