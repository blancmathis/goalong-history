#if os(macOS)
import AppKit
import Foundation
import Security
import CryptoKit
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
    let designatedRequirementSHA256: String?
    let previousSignatureKind: BuildSignatureKind?
    let previousVersion: String?
    let previousRequirementValidation: Int32?
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
    static func current(previousWorkingBuild: CaptureBuildIdentity? = nil) -> SupportBuild {
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
            runningCopies: NSRunningApplication.runningApplications(withBundleIdentifier: "ai.goalong.localhistory").count,
            designatedRequirementSHA256: identity.designatedRequirement.map { text in
                SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
            },
            previousSignatureKind: previousWorkingBuild?.signatureKind,
            previousVersion: validated(previousWorkingBuild?.displayVersion, pattern: #"^[0-9]+(?:\.[0-9]+){1,3}$"#),
            previousRequirementValidation: BuildIdentityReader.evaluatePreviousRequirement(previousWorkingBuild?.designatedRequirement))
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

/// Sizes of Goalong's own top-level stores (fixed names, never user paths) and the
/// free space of their volume. A full disk is the most common cause of silent gaps.
struct SupportStorage: Codable {
    let freeMB: Int?
    let lowSpace: Bool
    let storesMB: [String: Int]
    let eventDayFiles: Int
    let enumerationTruncated: Bool

    static let knownStores = [
        "events", "seals", "receipts", "semantic", "analysis", "memories", "computer-history",
        "apple-screen-time", "agent-activity-v2", "chatgpt", "shares", "app-backups", "setup-backups",
        "SupportDiagnostics", "jev",
    ]

    static func current(root: URL = AppPaths.applicationSupportDirectory, fileBudget: Int = 60_000) -> SupportStorage {
        let free = StorageHealth.availableBytes(at: root)
        var stores: [String: Int] = [:]
        var remaining = fileBudget
        var truncated = false
        for name in knownStores {
            let url = root.appendingPathComponent(name, isDirectory: true)
            var status = stat()
            guard lstat(url.path, &status) == 0, status.st_mode & S_IFMT == S_IFDIR else { continue }
            var bytes: Int64 = 0
            if let enumerator = FileManager.default.enumerator(at: url,
                includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isSymbolicLinkKey], options: [], errorHandler: { _, _ in true }) {
                for case let file as URL in enumerator {
                    remaining -= 1
                    if remaining < 0 { truncated = true; break }
                    let values = try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isSymbolicLinkKey])
                    if values?.isSymbolicLink == true { enumerator.skipDescendants(); continue }
                    bytes += Int64(values?.totalFileAllocatedSize ?? 0)
                }
            }
            stores[name] = Int((bytes + 1_048_575) / 1_048_576)
            if truncated { break }
        }
        let eventFiles = (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("events").path))?
            .filter { $0.hasSuffix(".jsonl") }.count ?? 0
        return SupportStorage(freeMB: free.map { Int($0 / 1_048_576) }, lowSpace: StorageHealth.isLow(free),
                              storesMB: stores, eventDayFiles: eventFiles, enumerationTruncated: truncated)
    }
}

/// A plain-language problem detected automatically. `code` is a fixed identifier for
/// tooling; title and detail are French templates filled with numbers and codes only.
struct SupportFinding: Codable, Equatable {
    enum Code: String, Codable {
        case recordingInterrupted, recordingWasInterrupted, lowDiskSpace, uncleanExit, crashes
        case updateFailed, monitoringPaymentRequired, monitoringAuthentication, monitoringUnavailable
        case repeatedError, permissionMissing, interfaceFroze, diagnosticsDisabled, noProblemDetected
    }
    let severity: SupportLevel
    let code: Code
    let title: String
    let detail: String
}

enum SupportFindings {
    static func detect(live: [String: SupportValue], timeline: [SupportRecord], storage: SupportStorage?,
                       crashes: [SupportCrash], diagnosticsEnabled: Bool) -> [SupportFinding] {
        var findings: [SupportFinding] = []
        func flag(_ key: SupportKey) -> Bool { if case .flag(let v)? = live[key.rawValue] { return v }; return false }
        func count(_ values: [String: SupportValue], _ key: SupportKey) -> Int? {
            if case .count(let v)? = values[key.rawValue] { return v }; return nil
        }
        func state(_ values: [String: SupportValue], _ key: SupportKey) -> SupportState? {
            if case .state(let v)? = values[key.rawValue] { return v }; return nil
        }
        func symbol(_ values: [String: SupportValue], _ key: SupportKey) -> String? {
            if case .symbol(let v)? = values[key.rawValue] { return v }; return nil
        }

        if flag(.storageInterrupted) {
            let cause = state(live, .storageFailure) == .diskFull ? "le disque est plein" : "le dossier d’historique refuse l’écriture"
            findings.append(SupportFinding(severity: .error, code: .recordingInterrupted,
                title: "L’enregistrement est interrompu",
                detail: "Goalong ne peut plus écrire son historique : \(cause). Il reprendra automatiquement dès que l’écriture sera de nouveau possible."))
        }
        let interruptions = timeline.filter { $0.event == .storageInterrupted }
        if !interruptions.isEmpty {
            let lost = timeline.filter { $0.event == .storageRecovered }.compactMap { count($0.values, .lostEvents) }.reduce(0, +)
            let diskFull = interruptions.contains { state($0.values, .state) == .diskFull }
            findings.append(SupportFinding(severity: .warning, code: .recordingWasInterrupted,
                title: "Enregistrement interrompu \(interruptions.count) fois",
                detail: (diskFull ? "Au moins une coupure venait d’un disque plein. " : "")
                    + "\(lost) observation(s) n’ont pas pu être enregistrées ; chaque coupure est marquée dans l’historique."))
        }
        if let storage, storage.lowSpace, let free = storage.freeMB {
            findings.append(SupportFinding(severity: .warning, code: .lowDiskSpace,
                title: "Espace disque faible",
                detail: "Il reste \(free) Mo sur le disque. Sous environ 1 Go, macOS peut refuser les écritures de Goalong."))
        }
        let unclean = timeline.filter { $0.event == .appStarted && $0.values[SupportKey.previousExitUnclean.rawValue] == .flag(true) }.count
        if unclean > 0 {
            findings.append(SupportFinding(severity: .warning, code: .uncleanExit,
                title: "Arrêt inattendu \(unclean) fois",
                detail: "Goalong ne s’est pas fermé normalement avant un lancement : plantage, arrêt forcé ou extinction du Mac."))
        }
        if !crashes.isEmpty {
            findings.append(SupportFinding(severity: .error, code: .crashes,
                title: "\(crashes.count) rapport(s) de plantage récent(s)",
                detail: "Types : " + Set(crashes.map(\.type.rawValue)).sorted().joined(separator: ", ") + "."))
        }
        let updateFailures = timeline.filter { $0.component == .updates && $0.event == .operationFailed }
        if let last = updateFailures.last {
            findings.append(SupportFinding(severity: .warning, code: .updateFailed,
                title: "Échec de mise à jour (\(updateFailures.count))",
                detail: "Dernier code : \(symbol(last.values, .errorType) ?? "erreur") \(count(last.values, .errorCode) ?? 0)."))
        }
        let statuses = timeline.filter { $0.component == .monitoring && $0.event == .requestFinished }
            .compactMap { count($0.values, .httpStatus) }
        if statuses.contains(402) {
            findings.append(SupportFinding(severity: .warning, code: .monitoringPaymentRequired,
                title: "Surveillance temps réel : crédit épuisé",
                detail: "Le service d’analyse a répondu 402 (paiement requis) : la surveillance s’est mise en pause. Rechargez le compte TypeSafe puis cliquez sur Réessayer."))
        } else if statuses.contains(where: { $0 == 401 || $0 == 403 }) {
            findings.append(SupportFinding(severity: .warning, code: .monitoringAuthentication,
                title: "Surveillance temps réel : clé refusée", detail: "Le service d’analyse refuse la clé configurée."))
        } else if statuses.contains(where: { $0 >= 500 }) {
            findings.append(SupportFinding(severity: .info, code: .monitoringUnavailable,
                title: "Surveillance temps réel : service indisponible",
                detail: "\(statuses.filter { $0 >= 500 }.count) réponse(s) serveur en erreur."))
        }
        var repeated: [String: Int] = [:]
        for record in timeline where record.level == .error {
            let label = [symbol(record.values, .errorType)?.split(separator: ".").last.map(String.init),
                         symbol(record.values, .errorCase)].compactMap { $0 }.joined(separator: ".")
            let key = "\(record.component.rawValue) · " + (label.isEmpty ? "\(record.event.rawValue) \(count(record.values, .errorCode) ?? 0)" : label)
            let extra = record.event == .repeatSummary ? (count(record.values, .suppressedCount) ?? 0) - 1 : 0
            repeated[key, default: 0] += 1 + max(0, extra)
        }
        for (label, total) in repeated.sorted(by: { $0.value > $1.value }).prefix(3) where total >= 10 {
            findings.append(SupportFinding(severity: .warning, code: .repeatedError,
                title: "Erreur répétée \(total) fois", detail: label))
        }
        if let current = state(live, .state), [.permissionRequired, .permissionAppearsEnabledButStaleForBuild,
                                                 .accessibilityContextUnavailable].contains(current), flag(.localSource) {
            findings.append(SupportFinding(severity: .warning, code: .permissionMissing,
                title: "Autorisation macOS à vérifier", detail: "État de capture : \(current.rawValue)."))
        }
        let froze = timeline.filter { $0.event == .mainThreadUnresponsive }.count
        if froze > 0 {
            findings.append(SupportFinding(severity: .warning, code: .interfaceFroze,
                title: "L’interface a cessé de répondre \(froze) fois", detail: "Blocage de plus de 30 secondes détecté."))
        }
        if !diagnosticsEnabled {
            findings.append(SupportFinding(severity: .info, code: .diagnosticsDisabled,
                title: "Journal technique désactivé", detail: "Le rapport ne contient que l’état actuel."))
        }
        if findings.isEmpty {
            findings.append(SupportFinding(severity: .info, code: .noProblemDetected,
                title: "Aucun problème détecté automatiquement",
                detail: "Décrivez ce que vous avez fait et ce que vous attendiez dans votre message."))
        }
        return findings
    }
}

struct SupportReport: Codable {
    let schema: Int
    let createdAt: Date
    let reportID: UUID
    let summary: [SupportFinding]
    let privacy: [String]
    let limitations: [String]
    let build: SupportBuild
    let environment: SupportEnvironment
    let storage: SupportStorage?
    let current: [String: SupportValue]
    let diagnosticsEnabled: Bool
    let droppedEvents: Int
    let rejectedRecords: Int
    let writeFailures: Int
    let suppressedRepeats: Int
    let diskSnapshotIncomplete: Bool
    let crashSummaries: [SupportCrash]
    let timeline: [SupportRecord]

    static func build(journal: SupportDiagnostics = .shared, live: [SupportKey: SupportValue], previousWorkingBuild: CaptureBuildIdentity? = nil,
                      crashLoader: () -> [SupportCrash] = { SupportCrash.recent() },
                      storageLoader: () -> SupportStorage? = { SupportStorage.current() }) -> Self {
        journal.flushRepeatSummaries(force: true)
        journal.flush(timeout: 1)
        let snapshot = journal.snapshot()
        let current = Dictionary(uniqueKeysWithValues: live.map { ($0.key.rawValue, $0.value) })
        let crashes = crashLoader()
        let storage = storageLoader()
        return Self(schema: 2, createdAt: Date(), reportID: UUID(),
        summary: SupportFindings.detect(live: current, timeline: snapshot.records, storage: storage,
                                        crashes: crashes, diagnosticsEnabled: snapshot.enabled),
        privacy: [
            "Rapport technique local. Aucun envoi automatique : vous choisissez à qui l’envoyer.",
            "Exclus : historique d’activité, noms d’apps tierces, URLs, titres, texte visible ou saisi, conversations, captures d’écran, audio, presse-papiers.",
            "Exclus : noms d’utilisateur, chemins personnels, e-mails, clés, jetons, cookies, identifiants de compte ou d’appareil, configuration brute.",
            "Les anciens diagnostics.log, bases de données, journaux système et rapports de crash bruts ne sont jamais joints.",
            "Inclus : horaires techniques, compteurs, états, version et signature de Goalong, version de macOS, codes d’erreur numériques avec leur type et leur cas (identifiants du code source de Goalong), emplacements dans le code, espace disque libre, taille des dossiers internes de Goalong, sources activées (oui/non) et résumés structurels de crash."
        ], limitations: [
            "Au maximum sept dates UTC. Par jour : deux segments de 256 Kio pour les événements courants et deux de 128 Kio réservés aux avertissements, erreurs et changements d’état.",
            "Les répétitions identiques sont regroupées : trois occurrences par tranche de dix minutes, puis un résumé repeatSummary avec le nombre exact.",
            "Un arrêt sans fermeture propre peut être un crash, une fermeture forcée ou une extinction ; ce signal ne tranche pas entre ces causes.",
            "Un événement legacyLocation donne l’emplacement du code, jamais le texte potentiellement privé de l’ancien message.",
            "Les résumés de crash couvrent jusqu’à cinq rapports IPS récents de Goalong accessibles sans permission supplémentaire. Une liste vide ne prouve pas l’absence de crash.",
            "Si le disque échoue ou reste bloqué, diskSnapshotIncomplete est vrai et le rapport conserve les derniers événements disponibles en mémoire (128 au maximum). Un arrêt ou un export n’attend pas indéfiniment le journal.",
            "Les délais de réponse et arrêts anormaux sont des indices, pas une preuve de leur cause. La veille peut retarder les minuteries.",
            "Le résumé est une détection automatique ; il ne remplace pas la description du problème.",
            "previousRequirementValidation compare la signature actuelle à l’ancienne identité ; ce résultat ne prouve pas qu’un accès a été accordé par macOS."
        ], build: .current(previousWorkingBuild: previousWorkingBuild), environment: .current(), storage: storage,
        current: current,
        diagnosticsEnabled: snapshot.enabled, droppedEvents: snapshot.dropped, rejectedRecords: snapshot.rejected,
        writeFailures: snapshot.writeFailures, suppressedRepeats: snapshot.suppressedRepeats,
        diskSnapshotIncomplete: snapshot.diskSnapshotIncomplete, crashSummaries: crashes, timeline: snapshot.records)
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
    var previousWorkingBuildProvider: (() -> CaptureBuildIdentity?)?

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
        let updates = SoftwareUpdateManager.shared
        values[.updateConfigured] = .flag(updates.isConfigured)
        values[.updateChecking] = .flag(updates.isChecking)
        values[.automaticChecks] = .flag(updates.automaticallyChecksForUpdates)
        values[.updateResult] = .state(updates.lastCheckResult)
        if let available = updates.availableVersion { values[.availableVersion] = .symbol(available) }
        if let free = StorageHealth.availableBytes() { values[.freeSpaceMB] = .count(Int(free / 1_048_576)) }
        values[.monitoringEnabled] = .flag(GoalongCapabilityConsentStore.shared.isEnabled(.jevMonitoring))
        values[.websiteAutoSend] = .flag(GoalongWebsiteAutoSender.shared.enabled)
        let connections = AppPaths.applicationSupportDirectory.appendingPathComponent("website-connections").path
        values[.websiteLinked] = .flag(((try? FileManager.default.contentsOfDirectory(atPath: connections)) ?? [])
            .contains { !$0.hasPrefix(".") })
        return values
    }
    private func heartbeat() {
        let now = ProcessInfo.processInfo.systemUptime
        let delay = max(0, now - lastTick - 60); lastTick = now
        var values = snapshot(); values[.elapsedMS] = .number(delay * 1000)
        // A delayed timer is evidence only; sleep and App Nap can also cause this.
        if delay > 15 {
            SupportDiagnostics.shared.record(.mainThreadDelayed, component: .app, level: .warning, values: values)
        } else {
            SupportDiagnostics.shared.recordIfChanged(.heartbeat, component: .app, values: values)
        }
        SupportDiagnostics.shared.flushRepeatSummaries()
        checkDiskSpace(values[.freeSpaceMB])
    }

    private var lowSpaceReported = false
    /// Warns once per crossing, before the journal starts refusing writes.
    private func checkDiskSpace(_ value: SupportValue?) {
        guard case .count(let freeMB)? = value else { return }
        let low = Int64(freeMB) * 1_048_576 < StorageHealth.lowSpaceThreshold
        if low && !lowSpaceReported {
            SupportDiagnostics.shared.record(.lowDiskSpace, component: .storage, level: .warning,
                values: [.freeSpaceMB: .count(freeMB)])
        }
        lowSpaceReported = low
    }
    func stop() { responsiveness.stop(); timer?.invalidate(); timer = nil; SupportDiagnostics.shared.stop() }
}
#endif
