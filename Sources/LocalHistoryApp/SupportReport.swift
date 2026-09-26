#if os(macOS)
import AppKit
import Foundation
import Security
import Darwin
import LocalHistoryCore

struct SupportBuild: Codable {
    let version: String?
    let build: String?
    let revision: String?
    let signatureKind: BuildSignatureKind
    let codeHash: String?
    let signatureValidation: Int32
    let installation: Installation
    let runningCopies: Int
    enum Installation: String, Codable { case applications, userApplications, diskImage, translocated, other }

    static func installation(path: String, home: String = NSHomeDirectory()) -> Installation {
        if path.contains("/AppTranslocation/") { return .translocated }
        if path.hasPrefix("/Volumes/") { return .diskImage }
        if path.hasPrefix("/Applications/") { return .applications }
        if path.hasPrefix(home + "/Applications/") { return .userApplications }
        return .other
    }
    static func validated(_ value: String?, pattern: String) -> String? {
        guard let value, value.utf8.count <= 128, value.range(of: pattern, options: .regularExpression) != nil else { return nil }
        return value
    }
    static func current() -> SupportBuild {
        let identity = BuildIdentityReader.current()
        var code: SecCode?
        let copied = SecCodeCopySelf(SecCSFlags(rawValue: 0), &code)
        let validity = code.map { SecCodeCheckValidity($0, SecCSFlags(rawValue: 0), nil) } ?? copied
        return SupportBuild(
            version: validated(identity.displayVersion, pattern: #"^[0-9]+(?:\.[0-9]+){1,3}$"#),
            build: validated(identity.buildNumber, pattern: #"^[0-9]+(?:\.[0-9]+){0,3}$"#),
            revision: validated(Bundle.main.object(forInfoDictionaryKey: "GoalongSourceRevision") as? String, pattern: #"^[0-9a-f]{7,64}$"#),
            signatureKind: identity.signatureKind,
            codeHash: validated(identity.codeDirectoryHash, pattern: #"^[0-9a-f]{40,64}$"#),
            signatureValidation: validity, installation: installation(path: Bundle.main.bundleURL.path),
            runningCopies: NSRunningApplication.runningApplications(withBundleIdentifier: "ai.goalong.localhistory").count)
    }
}

struct SupportEnvironment: Codable {
    let osMajor: Int; let osMinor: Int; let osPatch: Int
    let architecture: Architecture
    let uptimeSeconds: Int
    let processorCount: Int
    enum Architecture: String, Codable { case arm64, x86_64, other }
    static func current() -> Self {
        let p = ProcessInfo.processInfo; let os = p.operatingSystemVersion
        #if arch(arm64)
        let architecture = Architecture.arm64
        #elseif arch(x86_64)
        let architecture = Architecture.x86_64
        #else
        let architecture = Architecture.other
        #endif
        return Self(osMajor: os.majorVersion, osMinor: os.minorVersion, osPatch: os.patchVersion,
                    architecture: architecture, uptimeSeconds: Int(p.systemUptime), processorCount: p.processorCount)
    }
}

/// Only structural crash facts for our own binary. No .ips attachment, stack symbols,
/// paths, register values, memory contents, identifiers, or exception descriptions.
struct SupportCrash: Codable {
    let type: CrashType
    let binaryUUID: UUID?
    let faultingThread: Int?
    let ownBinaryOffsets: [UInt64]
    enum CrashType: String, Codable { case EXC_BAD_ACCESS, EXC_CRASH, EXC_BREAKPOINT, EXC_RESOURCE, EXC_GUARD, EXC_BAD_INSTRUCTION, unknown }

    static func parse(_ data: Data) -> SupportCrash? {
        guard data.count <= 2 * 1_024 * 1_024 else { return nil }
        // Modern IPS files have a one-line JSON header followed by a JSON body.
        let newline = data.firstIndex(of: 10)
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            ?? newline.flatMap { (try? JSONSerialization.jsonObject(with: Data(data.suffix(from: data.index(after: $0))))) as? [String: Any] }
        guard let body,
              let bundle = body["bundleInfo"] as? [String: Any],
              bundle["CFBundleIdentifier"] as? String == "ai.goalong.localhistory",
              ["Goalong History", "LocalHistory"].contains(body["procName"] as? String ?? "") else { return nil }
        let exception = body["exception"] as? [String: Any]
        let type = (exception?["type"] as? String).flatMap(CrashType.init(rawValue:)) ?? .unknown
        let images = body["usedImages"] as? [[String: Any]] ?? []
        let index = images.firstIndex { ["Goalong History", "LocalHistory"].contains($0["name"] as? String ?? "") }
        let uuid = index.flatMap { (images[$0]["uuid"] as? String).flatMap(UUID.init(uuidString:)) }
        let thread = body["faultingThread"] as? Int
        let threads = body["threads"] as? [[String: Any]] ?? []
        var offsets: [UInt64] = []
        if let thread, threads.indices.contains(thread), let index,
           let frames = threads[thread]["frames"] as? [[String: Any]] {
            for frame in frames.prefix(128) where frame["imageIndex"] as? Int == index {
                if let offset = frame["imageOffset"] as? NSNumber,
                   offset.doubleValue >= 0, offset.doubleValue <= Double(UInt32.max) { offsets.append(offset.uint64Value) }
                if offsets.count == 32 { break }
            }
        }
        return SupportCrash(type: type, binaryUUID: uuid,
            faultingThread: thread.flatMap { (0..<100_000).contains($0) ? $0 : nil }, ownBinaryOffsets: offsets)
    }

    static func recent(now: Date = Date()) -> [SupportCrash] {
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports")
        // Explicit export only; neither creates a watcher nor requests Full Disk Access.
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { return [] }
        let candidates = urls.filter { $0.pathExtension == "ips" && ($0.lastPathComponent.hasPrefix("Goalong History-") || $0.lastPathComponent.hasPrefix("LocalHistory-")) }
            .prefix(200).compactMap { url -> (URL, Date)? in
                guard let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                      date >= now.addingTimeInterval(-7 * 86400), date <= now.addingTimeInterval(60) else { return nil }
                return (url, date)
            }.sorted { $0.1 > $1.1 }.prefix(5)
        return candidates.compactMap { url, _ in
            guard let bytes = try? SupportDiagnostics.readPrivateFile(url, maximum: 2 * 1_024 * 1_024) else { return nil }
            return parse(bytes)
        }
    }
}

struct SupportReport: Codable {
    let schema: Int
    let createdAt: Date
    let reportID: UUID
    let privacy: [String]
    let limitations: [String]
    let build: SupportBuild
    let environment: SupportEnvironment
    let current: [String: SupportValue]
    let diagnosticsEnabled: Bool
    let droppedEvents: Int
    let rejectedRecords: Int
    let writeFailures: Int
    let diskSnapshotIncomplete: Bool
    let crashSummaries: [SupportCrash]
    let timeline: [SupportRecord]

    static func build(journal: SupportDiagnostics = .shared, live: [SupportKey: SupportValue], crashLoader: () -> [SupportCrash] = { SupportCrash.recent() }) -> Self {
        let snapshot = journal.snapshot()
        return Self(schema: 1, createdAt: Date(), reportID: UUID(), privacy: [
            "Rapport technique local. Aucun envoi automatique.",
            "Exclus : historique d’activité, noms d’apps tierces, URLs, titres, texte visible ou saisi, conversations, captures d’écran, audio, presse-papiers.",
            "Exclus : noms d’utilisateur, chemins personnels, e-mails, clés, jetons, cookies, identifiants de compte ou d’appareil, configuration brute.",
            "Les anciens diagnostics.log, bases de données, journaux système et rapports de crash bruts ne sont jamais joints.",
            "Inclus : horaires techniques, compteurs, états, version et signature de Goalong, version de macOS, erreurs numériques, emplacements dans le code et résumés structurels de crash."
        ], limitations: [
            "Au maximum sept dates UTC, deux segments de 256 Kio par jour. La rotation peut raccourcir la période disponible.",
            "Un arrêt sans fermeture propre peut être un crash, une fermeture forcée ou une extinction ; ce signal ne tranche pas entre ces causes.",
            "Un événement legacyLocation donne l’emplacement du code, jamais le texte potentiellement privé de l’ancien message.",
            "Les résumés de crash couvrent jusqu’à cinq rapports IPS récents de Goalong accessibles sans permission supplémentaire. Une liste vide ne prouve pas l’absence de crash.",
            "Si le disque échoue ou reste bloqué, diskSnapshotIncomplete est vrai et le rapport conserve les derniers événements disponibles en mémoire (128 au maximum). Un arrêt ou un export n’attend pas indéfiniment le journal.",
            "Les délais de réponse et arrêts anormaux sont des indices, pas une preuve de leur cause. La veille peut retarder les minuteries.",
            "Ce rapport aide à diagnostiquer les pannes ; il ne garantit pas de reproduire tous les bugs."
        ], build: .current(), environment: .current(),
        current: Dictionary(uniqueKeysWithValues: live.map { ($0.key.rawValue, $0.value) }),
        diagnosticsEnabled: snapshot.enabled, droppedEvents: snapshot.dropped, rejectedRecords: snapshot.rejected,
        writeFailures: snapshot.writeFailures, diskSnapshotIncomplete: snapshot.diskSnapshotIncomplete, crashSummaries: crashLoader(), timeline: snapshot.records)
    }
    func data() throws -> Data {
        let encoder = SupportDiagnostics.encoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}

@MainActor final class SupportDiagnosticsRuntime {
    static let shared = SupportDiagnosticsRuntime()
    private var timer: Timer?
    private let responsiveness = SupportResponsivenessMonitor()
    private var lastTick = ProcessInfo.processInfo.systemUptime
    var provider: (() -> [SupportKey: SupportValue])?

    func start(provider: @escaping () -> [SupportKey: SupportValue]) {
        self.provider = provider
        responsiveness.start()
        SupportDiagnostics.shared.start()
        timer?.invalidate()
        lastTick = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.heartbeat() }
        }
        RunLoop.main.add(timer, forMode: .common); self.timer = timer
        heartbeat()
    }
    func snapshot() -> [SupportKey: SupportValue] {
        var values = provider?() ?? [:]
        values[.liveSnapshotAvailable] = .flag(provider != nil)
        values[.lowPower] = .flag(ProcessInfo.processInfo.isLowPowerModeEnabled)
        values[.thermalState] = .count(ProcessInfo.processInfo.thermalState.rawValue)
        values[.updateConfigured] = .flag(SoftwareUpdateManager.shared.isConfigured)
        values[.updateChecking] = .flag(SoftwareUpdateManager.shared.isChecking)
        return values
    }
    private func heartbeat() {
        let now = ProcessInfo.processInfo.systemUptime
        let delay = max(0, now - lastTick - 60); lastTick = now
        var values = snapshot(); values[.elapsedMS] = .number(delay * 1000)
        SupportDiagnostics.shared.record(delay > 15 ? .mainThreadDelayed : .heartbeat,
            component: .app, level: delay > 15 ? .warning : .info, values: values)
        // A delayed timer is evidence only; sleep and App Nap can also cause this.
    }
    func stop() { responsiveness.stop(); timer?.invalidate(); timer = nil; SupportDiagnostics.shared.stop() }
}
#endif
