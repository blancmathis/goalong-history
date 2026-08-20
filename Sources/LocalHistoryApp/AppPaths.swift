#if os(macOS)
    import Foundation
    import LocalHistoryCore

    enum AppPaths {
        static let applicationSupportDirectory: URL = {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            return base.appendingPathComponent("LocalHistory", isDirectory: true)
        }()

        static let eventsDirectory = applicationSupportDirectory.appendingPathComponent("events", isDirectory: true)
        static let sealsDirectory = applicationSupportDirectory.appendingPathComponent("seals", isDirectory: true)
        static let receiptsDirectory = applicationSupportDirectory.appendingPathComponent("receipts", isDirectory: true)
        static let sharesDirectory = applicationSupportDirectory.appendingPathComponent("shares", isDirectory: true)
        static let screenTimeDirectory = applicationSupportDirectory.appendingPathComponent(
            "apple-screen-time", isDirectory: true)
        static let agentActivityDirectory = applicationSupportDirectory.appendingPathComponent(
            "agent-activity", isDirectory: true)
        static let integrityStateFile = applicationSupportDirectory.appendingPathComponent(
            "integrity-state.json", isDirectory: false)
        static let configFile = applicationSupportDirectory.appendingPathComponent("config.json", isDirectory: false)
        static let sharingRulesFile = applicationSupportDirectory.appendingPathComponent(
            "sharing-rules.json", isDirectory: false)
        static let softwareSigningKeyFile = applicationSupportDirectory.appendingPathComponent(
            "device-signing-key-v2.bin", isDirectory: false)
        static let diagnosticsFile = applicationSupportDirectory.appendingPathComponent(
            "diagnostics.log", isDirectory: false)

        static func prepare() throws {
            let fileManager = FileManager.default
            try fileManager.createDirectory(
                at: applicationSupportDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            for directory in [
                eventsDirectory,
                sealsDirectory,
                receiptsDirectory,
                sharesDirectory,
                agentActivityDirectory,
            ] {
                try fileManager.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            }
            try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: applicationSupportDirectory.path)
        }

        static func localDayString(for date: Date = Date()) -> String {
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter.string(from: date)
        }

        static func eventFileURL(for date: Date = Date()) -> URL {
            eventsDirectory.appendingPathComponent(localDayString(for: date) + ".jsonl")
        }

        static func sealFileURL(for date: Date = Date()) -> URL {
            sealsDirectory.appendingPathComponent(localDayString(for: date) + ".seals.jsonl")
        }

        static func receiptFileURL(for date: Date = Date()) -> URL {
            receiptsDirectory.appendingPathComponent(localDayString(for: date) + ".receipts.jsonl")
        }

        static func defaultShareFileURL(for date: Date = Date()) -> URL {
            sharesDirectory.appendingPathComponent(localDayString(for: date) + ".share.json")
        }
    }

    final class ConfigManager {
        private(set) var config: RecorderConfig

        init() {
            do {
                try AppPaths.prepare()
                if FileManager.default.fileExists(atPath: AppPaths.configFile.path) {
                    config = try RecorderConfig.load(from: AppPaths.configFile)
                    try? FileManager.default.setAttributes(
                        [.posixPermissions: 0o600], ofItemAtPath: AppPaths.configFile.path)
                } else {
                    config = .default
                    try config.write(to: AppPaths.configFile)
                    try? FileManager.default.setAttributes(
                        [.posixPermissions: 0o600], ofItemAtPath: AppPaths.configFile.path)
                }
            } catch {
                config = .default
                Diagnostics.write("Failed to load config; using defaults: \(error)")
            }
        }

        func reload() {
            do {
                config = try RecorderConfig.load(from: AppPaths.configFile)
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: AppPaths.configFile.path)
                Diagnostics.write("Configuration reloaded")
            } catch {
                Diagnostics.write("Configuration reload failed: \(error)")
            }
        }

        @discardableResult
        func save(_ newConfig: RecorderConfig) throws -> RecorderConfig {
            let validated = newConfig.validated()
            try validated.write(to: AppPaths.configFile)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: AppPaths.configFile.path)
            config = validated
            Diagnostics.write("Configuration saved from the dashboard")
            return validated
        }
    }

    enum Diagnostics {
        private static let queue = DispatchQueue(label: "ai.goalong.localhistory.diagnostics")

        static func write(_ message: String) {
            queue.async {
                let timestamp = ISO8601DateFormatter().string(from: Date())
                let line = "[\(timestamp)] \(message)\n"
                guard let data = line.data(using: .utf8) else { return }

                do {
                    try AppPaths.prepare()
                    if !FileManager.default.fileExists(atPath: AppPaths.diagnosticsFile.path) {
                        FileManager.default.createFile(
                            atPath: AppPaths.diagnosticsFile.path,
                            contents: nil,
                            attributes: [.posixPermissions: 0o600]
                        )
                    }
                    try? FileManager.default.setAttributes(
                        [.posixPermissions: 0o600], ofItemAtPath: AppPaths.diagnosticsFile.path)
                    let handle = try FileHandle(forWritingTo: AppPaths.diagnosticsFile)
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                    try handle.close()
                } catch {
                    if let data = "LocalHistory diagnostic failure: \(error)\n".data(using: .utf8) {
                        try? FileHandle.standardError.write(contentsOf: data)
                    }
                }
            }
        }
    }
#endif
