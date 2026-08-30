#if os(macOS)
    import AppleScreenTime
    @testable import AppleSystemScreenTime
    import Foundation
    import SQLite3
    import XCTest

    final class AppleScreenTimeDeviceIdentityTests: XCTestCase {
        func testResolvesFriendlyNamesForIPhoneIPadAndAppleWatch() throws {
            let now = Date(timeIntervalSince1970: 1_786_900_000)
            let reports = [
                report(id: "PHONE-PEER", name: "iPhone14,2 · PHONE-PEER", kind: .iPhone),
                report(id: "TABLET-PEER", name: "iPad14,8 · TABLET-PEER", kind: .iPad),
                report(
                    id: "WATCH-PEER",
                    name: "Apple device · WATCH-PEER",
                    kind: .unknown,
                    bundleIdentifier: "com.apple.carousel.home-screen"
                ),
            ]
            let account = [
                metadata("iPhone Mathis", model: "iPhone14,2", os: "iOS", at: now),
                metadata("iPad de Mathis", model: "iPad14,8", os: "iOS", at: now),
                metadata("Apple Watch de Mathis", model: "Watch6,7", os: "watchOS", at: now),
            ]

            let resolved = AppleScreenTimeDeviceIdentityResolver.resolve(
                reports: reports,
                accountDevices: account,
                currentMacID: "MAC",
                now: now
            )
            let devices = Dictionary(uniqueKeysWithValues: resolved.map { ($0.device.id, $0.device) })

            XCTAssertEqual(devices["PHONE-PEER"]?.displayName, "iPhone Mathis")
            XCTAssertEqual(devices["PHONE-PEER"]?.kind, .iPhone)
            XCTAssertEqual(devices["TABLET-PEER"]?.displayName, "iPad de Mathis")
            XCTAssertEqual(devices["TABLET-PEER"]?.kind, .iPad)
            XCTAssertEqual(devices["WATCH-PEER"]?.displayName, "Apple Watch de Mathis")
            XCTAssertEqual(devices["WATCH-PEER"]?.kind, .appleWatch)
        }

        func testAmbiguousIOSPeersAreNotGuessedAndKeepStableLabels() {
            let now = Date(timeIntervalSince1970: 1_786_900_000)
            let first = report(id: "BBBBBBBB-2222", name: "iPhone or iPad", kind: .unknown)
            let second = report(id: "AAAAAAAA-1111", name: "Apple device", kind: .unknown)
            let account = [
                metadata("My iPhone", model: "iPhone14,2", os: "iOS", at: now),
                metadata("My iPad", model: "iPad14,8", os: "iOS", at: now),
            ]

            let forward = AppleScreenTimeDeviceIdentityResolver.resolve(
                reports: [first, second],
                accountDevices: account,
                currentMacID: "MAC",
                now: now
            )
            let reversed = AppleScreenTimeDeviceIdentityResolver.resolve(
                reports: [second, first],
                accountDevices: account,
                currentMacID: "MAC",
                now: now
            )
            let forwardNames = Dictionary(uniqueKeysWithValues: forward.map { ($0.device.id, $0.device.displayName) })
            let reversedNames = Dictionary(uniqueKeysWithValues: reversed.map { ($0.device.id, $0.device.displayName) })

            XCTAssertEqual(forwardNames, reversedNames)
            XCTAssertEqual(forwardNames["BBBBBBBB-2222"], "iPhone or iPad · BBBBBBBB")
            XCTAssertEqual(forwardNames["AAAAAAAA-1111"], "Apple device · AAAAAAAA")
            XCTAssertTrue(forward.allSatisfy { $0.device.kind == .unknown })
        }

        func testTwoTrustedDevicesWithSameModelAreNotCollapsedOrMisnamed() {
            let now = Date(timeIntervalSince1970: 1_786_900_000)
            let input = report(
                id: "PHONE-PEER",
                name: "iPhone14,2 · PHONE-PEER",
                kind: .iPhone
            )
            let account = [
                metadata("Personal iPhone", model: "iPhone14,2", os: "iOS", at: now),
                metadata("Work iPhone", model: "iPhone14,2", os: "iOS", at: now),
            ]

            let resolved = AppleScreenTimeDeviceIdentityResolver.resolve(
                reports: [input],
                accountDevices: account,
                currentMacID: "MAC",
                now: now
            )

            XCTAssertEqual(resolved.first?.device.kind, .iPhone)
            XCTAssertEqual(resolved.first?.device.displayName, "iPhone14,2 · PHONE-PE")
        }

        func testWatchSignatureIsTypedWithoutAccountCatalog() {
            let now = Date(timeIntervalSince1970: 1_786_900_000)
            let input = report(
                id: "F8143FC0-351F",
                name: "Apple device",
                kind: .unknown,
                bundleIdentifier: "com.strava.stravaride.watchapp"
            )

            let resolved = AppleScreenTimeDeviceIdentityResolver.resolve(
                reports: [input],
                accountDevices: [],
                currentMacID: "MAC",
                now: now
            )

            XCTAssertEqual(resolved.first?.device.kind, .appleWatch)
            XCTAssertEqual(resolved.first?.device.displayName, "Apple Watch · F8143FC0")
        }

        func testBiomePlatformValuesIdentifyEverySupportedAppleDeviceFamily() {
            let expected: [(Int, AppleScreenTimeDeviceKind)] = [
                (1, .iPad),
                (2, .iPhone),
                (3, .mac),
                (4, .mac),
                (5, .appleTV),
                (6, .appleWatch),
                (7, .homePod),
                (8, .visionPro),
            ]

            for (platform, kind) in expected {
                XCTAssertEqual(
                    AppleSystemScreenTimeSource.deviceKind(platform: platform),
                    kind,
                    "Unexpected mapping for BMDevicePlatform value \(platform)"
                )
            }
            XCTAssertEqual(AppleSystemScreenTimeSource.deviceKind(platform: nil), .unknown)
            XCTAssertEqual(AppleSystemScreenTimeSource.deviceKind(platform: 99), .unknown)
        }

        func testTypedBiomePeersReceiveDistinctNamesBeforeFriendlyNameResolution() {
            let iPad = AppleSystemScreenTimeSource.preferredRemoteDevice(
                id: "9BF58DC5-AAAA",
                descriptors: [AppleBiomeDeviceDescriptor(hardwareIdentifier: nil, platform: 1)]
            )
            let iPhone = AppleSystemScreenTimeSource.preferredRemoteDevice(
                id: "C9E4CC3D-BBBB",
                descriptors: [AppleBiomeDeviceDescriptor(hardwareIdentifier: nil, platform: 2)]
            )
            let watch = AppleSystemScreenTimeSource.preferredRemoteDevice(
                id: "F8143FC0-CCCC",
                descriptors: [AppleBiomeDeviceDescriptor(hardwareIdentifier: nil, platform: 6)]
            )

            XCTAssertEqual(iPad.kind, .iPad)
            XCTAssertEqual(iPad.displayName, "iPad · 9BF58DC5")
            XCTAssertEqual(iPhone.kind, .iPhone)
            XCTAssertEqual(iPhone.displayName, "iPhone · C9E4CC3D")
            XCTAssertEqual(watch.kind, .appleWatch)
            XCTAssertEqual(watch.displayName, "Apple Watch · F8143FC0")
        }

        func testSelectableDevicesKeepTrustedIdleIPadAndWatchWithoutOldGenericPeers() {
            let now = Date(timeIntervalSince1970: 1_786_900_000)
            let mac = AppleScreenTimeDevice(id: "MAC", name: "MacBook Pro", kind: .mac)
            let reports = [
                report(id: "PHONE-PEER", name: "iPhone Mathis", kind: .iPhone),
            ]
            let catalog = [
                AppleScreenTimeDevice(id: "PHONE-PEER", name: "iPhone · PHONE-PEER", kind: .iPhone),
                AppleScreenTimeDevice(id: "TABLET-PEER", name: "iPad · TABLET-P", kind: .iPad),
                AppleScreenTimeDevice(id: "WATCH-PEER", name: "Apple Watch · WATCH-PE", kind: .appleWatch),
                AppleScreenTimeDevice(id: "OLD-UNKNOWN", name: "Apple device · OLD-UNKN", kind: .unknown),
            ]
            let account = [
                metadata("iPhone Mathis", model: "iPhone14,2", os: "iOS", at: now),
                metadata("iPad de Mathis", model: "iPad14,8", os: "iOS", at: now),
                metadata("Apple Watch de Mathis", model: "Watch6,7", os: "watchOS", at: now),
            ]

            let selectable = AppleScreenTimeDeviceIdentityResolver.selectableDevices(
                catalogDevices: catalog,
                reports: reports,
                accountDevices: account,
                currentMac: mac,
                now: now
            )
            let byID = Dictionary(uniqueKeysWithValues: selectable.map { ($0.id, $0) })

            XCTAssertEqual(byID["MAC"]?.displayName, "MacBook Pro")
            XCTAssertEqual(byID["PHONE-PEER"]?.displayName, "iPhone Mathis")
            XCTAssertEqual(byID["TABLET-PEER"]?.displayName, "iPad de Mathis")
            XCTAssertEqual(byID["TABLET-PEER"]?.kind, .iPad)
            XCTAssertEqual(byID["WATCH-PEER"]?.displayName, "Apple Watch de Mathis")
            XCTAssertNil(byID["OLD-UNKNOWN"])
        }

        func testSelectableDevicesDoNotReuseReportedAccountMatchForIdleAlias() {
            let now = Date(timeIntervalSince1970: 1_786_900_000)
            let mac = AppleScreenTimeDevice(id: "MAC", name: "MacBook Pro", kind: .mac)
            let reports = [
                report(id: "CURRENT-PHONE", name: "iPhone Mathis", kind: .iPhone),
            ]
            let catalog = [
                AppleScreenTimeDevice(id: "CURRENT-PHONE", name: "iPhone · CURRENT-", kind: .iPhone),
                AppleScreenTimeDevice(id: "OLD-PHONE", name: "iPhone · OLD-PHON", kind: .iPhone),
            ]

            let selectable = AppleScreenTimeDeviceIdentityResolver.selectableDevices(
                catalogDevices: catalog,
                reports: reports,
                accountDevices: [metadata("iPhone Mathis", model: "iPhone14,2", os: "iOS", at: now)],
                currentMac: mac,
                now: now
            )
            let ids = Set(selectable.map(\.id))

            XCTAssertTrue(ids.contains("CURRENT-PHONE"))
            XCTAssertFalse(ids.contains("OLD-PHONE"))
        }

        func testSelectableDevicesDoNotGuessBetweenAmbiguousIdlePeers() {
            let now = Date(timeIntervalSince1970: 1_786_900_000)
            let mac = AppleScreenTimeDevice(id: "MAC", name: "MacBook Pro", kind: .mac)
            let catalog = [
                AppleScreenTimeDevice(id: "IPAD-A", name: "iPad · IPAD-A", kind: .iPad),
                AppleScreenTimeDevice(id: "IPAD-B", name: "iPad · IPAD-B", kind: .iPad),
            ]
            let account = [
                metadata("My iPad", model: "iPad14,8", os: "iOS", at: now),
            ]

            let selectable = AppleScreenTimeDeviceIdentityResolver.selectableDevices(
                catalogDevices: catalog,
                reports: [],
                accountDevices: account,
                currentMac: mac,
                now: now
            )

            XCTAssertEqual(selectable, [mac])
        }

        func testSelectableDevicesIgnoreAccountEntriesOlderThanFreshnessWindow() {
            let now = Date(timeIntervalSince1970: 1_786_900_000)
            let mac = AppleScreenTimeDevice(id: "MAC", name: "MacBook Pro", kind: .mac)
            let stale = now.addingTimeInterval(-(367 * 24 * 60 * 60))
            let catalog = [
                AppleScreenTimeDevice(id: "IPAD", name: "iPad · IPAD", kind: .iPad),
            ]

            let selectable = AppleScreenTimeDeviceIdentityResolver.selectableDevices(
                catalogDevices: catalog,
                reports: [],
                accountDevices: [metadata("Old iPad", model: "iPad14,8", os: "iOS", at: stale)],
                currentMac: mac,
                now: now
            )

            XCTAssertEqual(selectable, [mac])
        }

        func testSelectableDevicesRejectUndatedAccountEntryForIdlePeer() {
            let now = Date(timeIntervalSince1970: 1_786_900_000)
            let mac = AppleScreenTimeDevice(id: "MAC", name: "MacBook Pro", kind: .mac)
            let catalog = [
                AppleScreenTimeDevice(id: "IPAD", name: "iPad · IPAD", kind: .iPad),
            ]
            let account = AppleAccountDeviceMetadata(
                name: "Undated iPad",
                model: "iPad14,8",
                operatingSystem: "iOS",
                lastUpdatedAt: nil
            )

            let selectable = AppleScreenTimeDeviceIdentityResolver.selectableDevices(
                catalogDevices: catalog,
                reports: [],
                accountDevices: [account],
                currentMac: mac,
                now: now
            )

            XCTAssertEqual(selectable, [mac])
        }

        func testSelectablePeerIDStaysStableBetweenIdleAndActiveDays() {
            let now = Date(timeIntervalSince1970: 1_786_900_000)
            let mac = AppleScreenTimeDevice(id: "MAC", name: "MacBook Pro", kind: .mac)
            let peer = AppleScreenTimeDevice(id: "TABLET-PEER", name: "iPad · TABLET-P", kind: .iPad)
            let account = [metadata("My iPad", model: "iPad14,8", os: "iOS", at: now)]
            let idle = AppleScreenTimeDeviceIdentityResolver.selectableDevices(
                catalogDevices: [peer],
                reports: [],
                accountDevices: account,
                currentMac: mac,
                now: now
            )
            let activeReport = report(id: peer.id, name: "My iPad", kind: .iPad)
            let active = AppleScreenTimeDeviceIdentityResolver.selectableDevices(
                catalogDevices: [peer],
                reports: [activeReport],
                accountDevices: account,
                currentMac: mac,
                now: now
            )

            XCTAssertTrue(idle.contains { $0.id == peer.id })
            XCTAssertTrue(active.contains { $0.id == peer.id })
        }

        func testSelectableDevicesKeepReportedPeerWithoutRecentAccountMatch() {
            let now = Date(timeIntervalSince1970: 1_786_900_000)
            let mac = AppleScreenTimeDevice(id: "MAC", name: "MacBook Pro", kind: .mac)
            let activeReport = report(id: "OLD-IPAD", name: "iPad · OLD-IPAD", kind: .iPad)

            let selectable = AppleScreenTimeDeviceIdentityResolver.selectableDevices(
                catalogDevices: [],
                reports: [activeReport],
                accountDevices: [],
                currentMac: mac,
                now: now
            )

            XCTAssertTrue(selectable.contains { $0.id == "OLD-IPAD" })
        }

        func testDuplicateDevicePeerRowsPreferRichDescriptorRegardlessOfOrder() {
            let generic = AppleBiomeDeviceDescriptor(hardwareIdentifier: nil, platform: 2)
            let rich = AppleBiomeDeviceDescriptor(hardwareIdentifier: "iPad14,8", platform: 2)

            let forward = AppleSystemScreenTimeSource.preferredRemoteDevice(
                id: "PEER",
                descriptors: [generic, rich]
            )
            let reversed = AppleSystemScreenTimeSource.preferredRemoteDevice(
                id: "PEER",
                descriptors: [rich, generic]
            )

            XCTAssertEqual(forward, reversed)
            XCTAssertEqual(forward.kind, .iPad)
            XCTAssertEqual(forward.displayName, "iPad14,8 · PEER")
        }

        func testConflictingRichDevicePeerRowsDoNotInventAType() {
            let device = AppleSystemScreenTimeSource.preferredRemoteDevice(
                id: "PEER-12345678",
                descriptors: [
                    AppleBiomeDeviceDescriptor(hardwareIdentifier: "iPhone14,2", platform: 2),
                    AppleBiomeDeviceDescriptor(hardwareIdentifier: "iPad14,8", platform: 2),
                ]
            )

            XCTAssertEqual(device.kind, .unknown)
            XCTAssertEqual(device.displayName, "Apple device · PEER-123")
        }

        func testKnowledgeStreamReferenceUsesCurrentAndLegacySchemas() throws {
            let current = try AppleSystemScreenTimeSource.knowledgeStreamReference(
                objectColumns: ["ZSTREAMNAME"],
                metadataColumns: []
            )
            XCTAssertEqual(current.column, "ZOBJECT.ZSTREAMNAME")
            XCTAssertTrue(current.join.isEmpty)

            let legacy = try AppleSystemScreenTimeSource.knowledgeStreamReference(
                objectColumns: [],
                metadataColumns: ["ZSTREAMNAME"]
            )
            XCTAssertEqual(legacy.column, "ZSTRUCTUREDMETADATA.ZSTREAMNAME")
            XCTAssertTrue(legacy.join.contains("LEFT JOIN ZSTRUCTUREDMETADATA"))

            XCTAssertThrowsError(
                try AppleSystemScreenTimeSource.knowledgeStreamReference(
                    objectColumns: [],
                    metadataColumns: []
                )
            )
        }

        func testAppleAccountCatalogIsBoundedReadOnlyAndCachedByFingerprint() throws {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("apple-device-catalog-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let database = root.appendingPathComponent("devicelist.db")
            try createAccountDeviceDatabase(database)
            let before = try Data(contentsOf: database)
            let beforeAttributes = try FileManager.default.attributesOfItem(atPath: database.path)
            let missing = root.appendingPathComponent("missing")
            let paths = AppleSystemScreenTimePaths(
                knowledgeDatabase: missing.appendingPathComponent("knowledgeC.db"),
                biomeSyncDatabase: missing.appendingPathComponent("sync.db"),
                biomeLocalDirectory: missing.appendingPathComponent("local"),
                biomeRemoteDirectory: missing.appendingPathComponent("remote"),
                appleAccountDeviceDatabase: database
            )
            let source = AppleSystemScreenTimeSource(deviceID: "test", paths: paths)

            let first = source.readAppleAccountDeviceCatalog()
            XCTAssertLessThanOrEqual(first.count, 64)
            XCTAssertTrue(first.contains { $0.name == "iPhone Mathis" && $0.model == "iPhone14,2" })
            XCTAssertFalse(first.contains { $0.name == "Untrusted iPad" })
            XCTAssertFalse(first.contains { $0.name == "Old PC" })

            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: database.path)
            let cached = source.readAppleAccountDeviceCatalog()
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: database.path)
            XCTAssertEqual(cached, first)

            let after = try Data(contentsOf: database)
            let afterAttributes = try FileManager.default.attributesOfItem(atPath: database.path)
            XCTAssertEqual(after, before)
            XCTAssertEqual(afterAttributes[.size] as? NSNumber, beforeAttributes[.size] as? NSNumber)
            XCTAssertEqual(
                afterAttributes[.modificationDate] as? Date,
                beforeAttributes[.modificationDate] as? Date
            )
        }

        func testAppleWatchKindRoundTripsThroughJSON() throws {
            let original = AppleScreenTimeDevice(
                id: "watch",
                name: "Apple Watch de Mathis",
                kind: .appleWatch
            )
            let data = try JSONEncoder().encode(original)
            XCTAssertEqual(try JSONDecoder().decode(AppleScreenTimeDevice.self, from: data), original)
        }

        private func report(
            id: String,
            name: String,
            kind: AppleScreenTimeDeviceKind,
            bundleIdentifier: String = "com.example.app"
        ) -> AppleScreenTimeDeviceReport {
            let start = Date(timeIntervalSince1970: 1_786_800_000)
            let end = start.addingTimeInterval(60)
            return AppleScreenTimeDeviceReport(
                device: AppleScreenTimeDevice(id: id, name: name, kind: kind),
                lastUpdatedAt: end,
                segments: [
                    AppleScreenTimeSegment(
                        start: start,
                        end: end,
                        totalScreenOnDuration: 60,
                        applications: [
                            AppleScreenTimeApplicationUsage(
                                bundleIdentifier: bundleIdentifier,
                                displayName: nil,
                                duration: 60
                            )
                        ]
                    )
                ]
            )
        }

        private func metadata(
            _ name: String,
            model: String,
            os: String,
            at date: Date
        ) -> AppleAccountDeviceMetadata {
            AppleAccountDeviceMetadata(
                name: name,
                model: model,
                operatingSystem: os,
                lastUpdatedAt: date
            )
        }

        private func createAccountDeviceDatabase(_ url: URL) throws {
            var database: OpaquePointer?
            XCTAssertEqual(sqlite3_open(url.path, &database), SQLITE_OK)
            guard let database else { throw NSError(domain: "SQLiteTest", code: 1) }
            defer { sqlite3_close(database) }

            try execute(
                database,
                """
                CREATE TABLE device_list (
                  name TEXT,
                  model TEXT,
                  os TEXT,
                  trusted INTEGER,
                  last_updated_date REAL,
                  serial_number TEXT,
                  additional_info BLOB
                );
                """
            )
            let recent: Double = 1_786_900_000
            try execute(
                database,
                "INSERT INTO device_list VALUES ('iPhone Mathis','iPhone14,2','iOS',1,\(recent + 100),'never-read',X'00');"
            )
            try execute(
                database,
                "INSERT INTO device_list VALUES ('Untrusted iPad','iPad14,8','iOS',0,\(recent),'never-read',X'00');"
            )
            try execute(
                database,
                "INSERT INTO device_list VALUES ('Old PC','PC','Windows',1,\(recent),'never-read',X'00');"
            )
            for index in 0..<70 {
                try execute(
                    database,
                    "INSERT INTO device_list VALUES ('Watch \(index)','Watch6,7','watchOS',1,\(recent - Double(index)),'never-read',X'00');"
                )
            }
        }

        private func execute(_ database: OpaquePointer, _ sql: String) throws {
            var message: UnsafeMutablePointer<CChar>?
            let result = sqlite3_exec(database, sql, nil, nil, &message)
            defer { sqlite3_free(message) }
            guard result == SQLITE_OK else {
                throw NSError(
                    domain: "SQLiteTest",
                    code: Int(result),
                    userInfo: [
                        NSLocalizedDescriptionKey: message.map { String(cString: $0) } ?? "SQLite error"
                    ]
                )
            }
        }
    }
#endif
