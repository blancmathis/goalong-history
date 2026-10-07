#if os(macOS)
import AppKit
import Combine
import Foundation

/// Owns the module while it is on. Created by `BlockingRuntime` only when
/// `goalong.module.blocking.enabled` is true; destroyed when it is turned off.
/// Contract for the page: docs/BLOCKING.md « API for the UI ».
@MainActor final class BlockingController: ObservableObject {
    @Published private(set) var lists: [BlockList]
    @Published private(set) var activeBlocks: [BlockingActiveBlock] = []
    @Published private(set) var scheduledBlocks: [BlockSession] = []
    @Published private(set) var hasPassword = false
    @Published private(set) var quitRequiresPassword = false
    @Published private(set) var freeze: BlockFreeze?
    @Published private(set) var nextProgramStart: (listID: UUID, date: Date)?
    @Published private(set) var siteBlockingAvailable = true
    @Published private(set) var browsers: [BlockingBrowserSupport] = []
    @Published private(set) var protection = BlockingProtectionState()
    @Published var error: String?
    @Published private(set) var friction: BlockingFrictionPresentation?
    @Published private(set) var frictionUsage: BlockDayUsage?
    private var frictionTarget: BlockingObservation?
    private var frictionAllowances: [String: Date] = [:]
    private var suppressedAppFriction: Set<String> = []

    private var document: BlockingDocument
    private let clock: () -> Date
    private let store: BlockingStore?
    private let backend: BlockingEnforcementBackend?
    private let calendar: Calendar
    private let continuous: () -> Double
    private let boot: () -> String
    private let runsTimers: Bool
    private var timer: Timer?
    private var lastClock: BlockingClockState?
    private var lastSavedAt = Date.distantPast
    private var lastRefresh = Date.distantPast
    private var storeFailed = false
    /// Last end written for uninstall.sh; `.none` until the first refresh writes it.
    private var lockMarker: Date?? = .none
    private var lastGood: BlockingDocument?
    private var lastObservation: BlockingObservation?
    private var unreadableSince: [Int32: Date] = [:]
    var onObservationRequirementChanged: ((Bool) -> Void)?
    private var observing = false
    private var quitAuthorization: (blocks: Set<BlockingActiveBlock>, expires: Date)?
    var hasTimer: Bool { timer != nil }
    var snapshot: BlockingDocument { document }
    var needsObservation: Bool {
        guard !activeBlocks.isEmpty || freeze != nil || nextProgramStart.map({ $0.date.timeIntervalSince(clock()) <= 60 }) == true else { return false }
        return freeze != nil || lists.contains { list in
            (activeBlocks.contains { $0.listIDs.contains(list.id) }
             || document.sessions.contains { $0.listIDs.contains(list.id) && $0.start > clock() && $0.start.timeIntervalSince(clock()) <= 60 }
             || BlockingSchedule.nextStart(of: list.program, after: clock(), calendar: calendar).map({ $0.timeIntervalSince(clock()) <= 60 }) == true)
             && (list.mode == .allowOnly || !list.apps.isEmpty || !list.sites.isEmpty)
        }
    }

    init(document: BlockingDocument = BlockingDocument(), clock: @escaping () -> Date = Date.init,
         store: BlockingStore? = nil, backend: BlockingEnforcementBackend? = nil,
         calendar: Calendar = .current, continuous: @escaping () -> Double = BlockingClock.continuous,
         boot: @escaping () -> String = BlockingClock.bootID, runsTimers: Bool = false) {
        self.document = document; self.lists = document.lists; self.freeze = document.freeze
        self.clock = clock; self.store = store; self.backend = backend; self.calendar = calendar
        self.continuous = continuous; self.boot = boot; self.runsTimers = runsTimers
        if let store {
            do {
                let loaded = try store.loadRecovering()
                self.document = loaded.document
                switch loaded.recovery {
                case .none: break
                case .previous: self.error = "Le fichier de blocage était abîmé : Goalong a repris sa copie de secours. La dernière modification peut manquer."
                case .reset: self.error = "Le fichier de blocage et sa copie de secours étaient illisibles : Goalong repart sans listes. Les fichiers abîmés restent dans son dossier."
                }
            } catch { failStore() }
        }
        lastGood = self.document
        lastClock = self.document.clock
        backend?.appStillBlocked = { [weak self] target in
            guard let self else { return false }
            self.refresh(enforceLast: false)
            let now = self.clock(), usage = self.todayUsage()
            return self.lists.contains { list in
                list.effectiveAction == .block &&
                self.activeBlocks.contains { $0.listIDs.contains(list.id) }
                    && usage.breakEnds[list.id].map({ $0 > now }) != true
                    && (list.quotaMinutesPerDay.map { (usage.quotaSecondsUsed[list.id] ?? 0) >= Double($0 * 60) } ?? true)
                    && BlockingRules.wouldBlock(target, list: list)
            }
        }
        backend?.siteActionStillRequired = { [weak self] in self?.siteActionStillRequired($0) == true }
        backend?.siteActionDeadline = { [weak self] in self?.siteActionDeadline($0) }
        refresh()
    }

    func shutdown() {
        refresh(enforceLast: false)
        if !hasLocks {
            let hadSessions = !document.sessions.isEmpty
            // Quitting before a one-off start must preserve the scheduled commitment.
            document.sessions.removeAll { $0.start <= clock() }
            if hadSessions, let store {
                do { try store.save(document) } catch { failStore() }
            }
        }
        timer?.invalidate(); timer = nil
        onObservationRequirementChanged?(false); onObservationRequirementChanged = nil
        clearFriction(); frictionAllowances.removeAll()
        backend?.shutdown()
    }

    /// Anything the member committed to and cannot undo before its end.
    var hasLocks: Bool { lockedUntil != nil }
    /// End of the latest commitment. A store error is not a lock: it refuses edits, never quitting.
    var lockedUntil: Date? {
        let now = clock()
        let ends = activeBlocks.filter { $0.lock.protectsLists }.map(\.end)
            + document.sessions.filter { effectiveLock($0.lock).protectsLists }.map(\.end)
            + lists.compactMap { $0.program.lockedUntil } + [freeze?.end].compactMap { $0 }
        return ends.filter { $0 > now }.max()
    }

    /// A password cannot override an overlapping hard lock or a freeze.
    var quitIsLocked: Bool {
        activeBlocks.contains { $0.lock == .locked && $0.end > clock() }
            || lists.contains { $0.program.isLocked(at: clock()) } || (freeze?.end ?? .distantPast) > clock()
    }
    var requiresLaunchAtLogin: Bool {
        hasLocks || document.sessions.contains { $0.end > clock() && ($0.start > clock() || $0.lock != .free) }
            || lists.contains { !$0.program.ranges.isEmpty }
    }
    private func effectiveLock(_ lock: BlockLock) -> BlockLock {
        lock == .password && document.passwordLock?.isValid != true ? .locked : lock
    }

    var suggestions: [BlockSuggestion] { BlockSuggestion.catalog }

    func list(_ id: UUID) -> BlockList? { lists.first { $0.id == id } }

    // MARK: Lists

    func editCheck(_ next: BlockList) -> BlockingEditCheck {
        if storeFailed { return .refused("Le fichier de blocage doit être réparé avant toute modification.") }
        let existing = list(next.id)
        if next.program.ranges.contains(where: { $0.effectiveLock == .password }), !hasPassword,
           next.program.ranges != existing?.program.ranges {
            return .refused("Définissez d’abord le mot de passe de blocage.")
        }
        guard let current = existing else { return .allowed }
        guard isStricterOnly(current.id) else { return .allowed }
        let passwordProtected = activeBlocks.contains { $0.lock == .password && $0.listIDs.contains(current.id) }
        let prefix = passwordProtected ? "Pendant un blocage par mot de passe, " : "Pendant un verrou, "
        if (current.effectiveAction == .block && next.effectiveAction == .slowDown)
            || next.delaySeconds < current.delaySeconds || next.allowanceMinutes > current.allowanceMinutes {
            return .refused(prefix + "Ralentir peut seulement devenir plus strict.")
        }
        if next.mode != current.mode { return .refused("Le mode ne change pas pendant un verrou.") }
        let oldSites = Set(current.sites.map(\.pattern)), newSites = Set(next.sites.map(\.pattern))
        let oldApps = Set(current.apps.map(\.bundleIdentifier)), newApps = Set(next.apps.map(\.bundleIdentifier))
        let sitesSafe = current.mode == .block ? oldSites.isSubset(of: newSites) : newSites.isSubset(of: oldSites)
        let appsSafe = current.mode == .block ? oldApps.isSubset(of: newApps) : newApps.isSubset(of: oldApps)
        if !sitesSafe || !appsSafe { return .refused(prefix + "la liste peut seulement devenir plus stricte.") }
        if (next.quotaMinutesPerDay ?? 0) > (current.quotaMinutesPerDay ?? 0) {
            return .refused("Pendant un verrou, le temps permis peut seulement baisser.")
        }
        if let breaks = next.breaks {
            let old = current.breaks ?? BlockBreaks(count: 0, minutes: 0)
            if breaks.count > old.count || breaks.minutes > old.minutes {
                return .refused("Pendant un verrou, les pauses peuvent seulement diminuer.")
            }
        }
        if current.program.isLocked(at: clock()), (next.program.lockedUntil ?? .distantPast) < (current.program.lockedUntil ?? .distantPast) {
            return .refused("Le verrou du programme ne peut pas être raccourci.")
        }
        let oldMinutes = Self.programCoverage(current.program), newMinutes = Self.programCoverage(next.program)
        if !oldMinutes.isSubset(of: newMinutes) { return .refused("Pendant un verrou, le programme peut seulement s’allonger.") }
        for lock in BlockLock.allCases where lock != .free {
            let old = Self.programCoverage(BlockProgram(ranges: current.program.ranges.filter { effectiveLock($0.effectiveLock).strength >= lock.strength }))
            let new = Self.programCoverage(BlockProgram(ranges: next.program.ranges.filter { effectiveLock($0.effectiveLock).strength >= lock.strength }))
            if !old.isSubset(of: new) { return .refused(prefix + "le verrou d’une plage peut seulement monter.") }
        }
        return .allowed
    }

    func save(_ value: BlockList) {
        guard admitEdit() else { return }
        var next = value
        guard !next.program.ranges.contains(where: { $0.effectiveLock == .password }) || hasPassword
            || document.lists.first(where: { $0.id == next.id })?.program.ranges == next.program.ranges else {
            error = "Définissez d’abord le mot de passe de blocage."; return
        }
        guard next.sites.allSatisfy({ BlockingRules.normalize($0.pattern) != nil }) else { error = "Adresse de site invalide."; return }
        next.sites = Array(Set(next.sites.compactMap { BlockingRules.normalize($0.pattern).map { BlockSiteRule(pattern: $0) } })).sorted { $0.pattern < $1.pattern }
        var candidate = document
        candidate.lists.removeAll { $0.id == next.id }; candidate.lists.append(next)
        guard BlockingRules.validate(candidate) else { error = "Vérifiez la liste, les horaires, le quota et les pauses."; return }
        if case .refused(let reason) = editCheck(next) { error = reason; return }
        if let index = document.lists.firstIndex(where: { $0.id == next.id }) {
            let old = document.lists[index]
            if old.effectiveAction != next.effectiveAction || old.delaySeconds != next.delaySeconds || old.allowanceMinutes != next.allowanceMinutes {
                frictionAllowances = frictionAllowances.filter { !$0.key.hasPrefix(next.id.uuidString + "|") }
                if friction?.listID == next.id { clearFriction() }
            }
            document.lists[index] = next
        } else {
            document.lists.append(next)
        }
        commit()
    }

    func delete(_ id: UUID) {
        guard admitEdit() else { return }
        if isStricterOnly(id) { error = "Une liste verrouillée ne peut pas être supprimée."; return }
        if document.sessions.contains(where: { $0.start > clock() && $0.lock != .free && $0.listIDs.contains(id) }) {
            error = "Annulez d’abord le blocage programmé avec son défi ou son mot de passe."; return
        }
        document.lists.removeAll { $0.id == id }
        document.sessions = document.sessions.compactMap { session in
            var session = session
            session.listIDs.removeAll { $0 == id }
            return session.listIDs.isEmpty ? nil : session
        }
        commit()
    }

    func lockProgram(listID: UUID, until date: Date) {
        guard admitEdit(), date > clock() else { return }
        guard let index = document.lists.firstIndex(where: { $0.id == listID }) else { return }
        let current = document.lists[index].program.lockedUntil ?? .distantPast
        document.lists[index].program.lockedUntil = max(current, date)
        commit()
    }

    // MARK: Sessions

    func start(listIDs: [UUID], until end: Date, lock: BlockLock) {
        _ = createSession(listIDs: listIDs, start: nil, end: end, lock: lock)
    }

    @discardableResult
    func schedule(listIDs: [UUID], start: Date, end: Date, lock: BlockLock) -> UUID? {
        createSession(listIDs: listIDs, start: start, end: end, lock: lock)
    }
    private func createSession(listIDs: [UUID], start: Date?, end: Date, lock: BlockLock) -> UUID? {
        guard admitEdit() else { return nil }
        let now = clock()
        let start = start ?? now
        guard !listIDs.isEmpty, Set(listIDs).count == listIDs.count, listIDs.count <= 200,
              Set(listIDs).isSubset(of: Set(lists.map(\.id))), start >= now, end > start else {
            error = "Choisissez une liste, un début présent ou futur et une fin après le début."; return nil
        }
        guard lock != .password || hasPassword else { error = "Définissez d’abord le mot de passe de blocage."; return nil }
        let session = BlockSession(listIDs: listIDs, start: start, end: end, lock: lock)
        document.sessions.append(session)
        commit()
        return storeFailed ? nil : session.id
    }

    func startFocusBlock(id: UUID, listIDs: [UUID], until end: Date, lock: BlockLock) throws {
        refresh(enforceLast: false)
        guard !storeFailed else { throw FocusFailure.storageFailed }
        guard lock != .password || hasPassword else { throw FocusFailure.locked }
        guard !listIDs.isEmpty, end > clock(), Set(listIDs).isSubset(of: Set(lists.map(\.id))) else { throw FocusFailure.notFound }
        if let existing = document.sessions.first(where: { $0.id == id }) {
            guard existing.origin == .manual else { throw FocusFailure.locked }; return
        }
        document.sessions.append(BlockSession(id: id, listIDs: listIDs, start: clock(), end: end, lock: lock))
        commit()
        guard !storeFailed else { throw FocusFailure.storageFailed }
    }

    /// `id` is the commitment ID; persistent ownership makes relaunch/replay idempotent.
    func startCommitmentBlock(id: UUID, listIDs: [UUID], until end: Date) throws {
        refresh(enforceLast: false)
        guard !storeFailed else { throw FocusFailure.storageFailed }
        if let existing = document.sessions.first(where: { $0.id == id }) {
            guard existing.origin == .commitment(id), existing.lock == .locked else { throw FocusFailure.locked }
            return
        }
        guard end > clock(), !listIDs.isEmpty, listIDs.count <= 200, Set(listIDs).count == listIDs.count,
              Set(listIDs).isSubset(of: Set(lists.map(\.id))) else { throw FocusFailure.invalidArgument }
        document.sessions.append(BlockSession(id: id, listIDs: listIDs, start: clock(), end: end, lock: .locked, origin: .commitment(id)))
        commit()
        guard !storeFailed else { throw FocusFailure.storageFailed }
    }
    /// Only the Concentration joker/declaration writer calls this early-release path.
    func endCommitmentBlock(id: UUID) throws {
        refresh(enforceLast: false)
        guard !storeFailed else { throw FocusFailure.storageFailed }
        guard let existing = document.sessions.first(where: { $0.id == id }) else { return }
        guard existing.origin == .commitment(id) else { throw FocusFailure.locked }
        document.sessions.removeAll { $0.id == id }; commit()
        guard !storeFailed else { throw FocusFailure.storageFailed }
    }

    /// The same admission protects manual blocks, future sessions and program skips.
    func stop(_ id: UUID, typed: String? = nil, password: String? = nil) {
        _ = endBlock(id, typed: typed, password: password)
    }

    @discardableResult
    func cancelScheduled(id: UUID, typed: String? = nil, password: String? = nil) -> BlockingPasswordResult {
        guard admitEdit() else { return refusePassword("Le fichier de blocage doit être réparé.") }
        guard document.sessions.contains(where: { $0.id == id && $0.start > clock() }) else {
            return refusePassword("Ce blocage n’est plus programmé : actualisez la page.")
        }
        return endBlock(id, typed: typed, password: password)
    }

    private func endBlock(_ id: UUID, typed: String?, password: String?) -> BlockingPasswordResult {
        guard admitEdit() else { return refusePassword("Le fichier de blocage doit être réparé.") }
        let block = activeBlocks.first { $0.id == id }
        let session = document.sessions.first { $0.id == id }
        guard let lock = block?.lock ?? session.map({ effectiveLock($0.lock) }) else {
            return refusePassword("Ce blocage est terminé ou introuvable.")
        }
        if let session, case .commitment = session.origin {
            return refusePassword("L’enjeu est verrouillé : utilisez un joker ou une déclaration dans Concentration.")
        }
        switch lock {
        case .locked: return refusePassword("Ce blocage est verrouillé jusqu’à la fin.")
        case .typing:
            guard typed == typingChallenge(for: id) else { return refusePassword("Le texte ne correspond pas.") }
        case .password:
            guard let password else { return refusePassword("Le mot de passe de blocage est exigé.") }
            let result = verifyPassword(password)
            guard result == .ok else { return result }
        case .free: break
        }
        if let block, case .program = block.origin {
            document.programSkips = document.programSkips ?? [:]
            document.programSkips?[id] = block.end
            document.heldPrograms?.removeAll { $0.id == id }
        } else {
            document.sessions.removeAll { $0.id == id }
        }
        challenges[id] = nil
        commit()
        return storeFailed ? refusePassword("L’arrêt n’a pas pu être enregistré.") : .ok
    }

    private var challenges: [UUID: String] = [:]

    // MARK: Global blocking password

    private var hasPasswordBlocks: Bool {
        (document.sessions + (document.heldPrograms ?? [])).contains { $0.lock == .password && $0.end > clock() }
            || document.lists.contains { $0.program.ranges.contains { $0.effectiveLock == .password } }
    }

    @discardableResult
    func setPassword(_ password: String) -> Bool {
        guard admitEdit() else { return false }
        guard document.passwordLock == nil, !hasPasswordBlocks else {
            error = "Le mot de passe existe déjà, ou un blocage par mot de passe doit d’abord finir."; return false
        }
        guard let credential = BlockPasswordLock.make(password, at: clock()) else {
            error = "Choisissez un mot de passe non vide de 4 096 octets maximum."; return false
        }
        document.passwordLock = credential; commit(); return !storeFailed
    }

    @discardableResult
    func changePassword(old: String, new: String) -> BlockingPasswordResult {
        guard admitEdit() else { return refusePassword("Le fichier de blocage doit être réparé.") }
        guard !hasPasswordBlocks else { return refusePassword("Le mot de passe ne change pas tant qu’un blocage par mot de passe est actif ou à venir.") }
        let result = verifyPassword(old)
        guard result == .ok else { return result }
        guard let credential = BlockPasswordLock.make(new, at: clock()) else { return refusePassword("Choisissez un mot de passe non vide de 4 096 octets maximum.") }
        document.passwordLock = credential; commit()
        return storeFailed ? refusePassword("Le mot de passe n’a pas pu être enregistré.") : .ok
    }

    @discardableResult
    func removePassword(old: String) -> BlockingPasswordResult {
        guard admitEdit() else { return refusePassword("Le fichier de blocage doit être réparé.") }
        guard !hasPasswordBlocks else { return refusePassword("Le mot de passe reste nécessaire pour un blocage actif ou à venir.") }
        let result = verifyPassword(old)
        guard result == .ok else { return result }
        document.passwordLock = nil; quitAuthorization = nil; commit()
        return storeFailed ? refusePassword("Le retrait du mot de passe n’a pas pu être enregistré.") : .ok
    }

    @discardableResult
    func unlockWithPassword(_ password: String, blockID: UUID) -> BlockingPasswordResult {
        guard admitEdit() else { return refusePassword("Le fichier de blocage doit être réparé.") }
        let lock = activeBlocks.first(where: { $0.id == blockID })?.lock
            ?? document.sessions.first(where: { $0.id == blockID }).map { effectiveLock($0.lock) }
        guard lock == .password else { return refusePassword("Ce blocage ne peut pas être arrêté par mot de passe.") }
        return endBlock(blockID, typed: nil, password: password)
    }

    @discardableResult
    func authorizeQuit(password: String) -> BlockingPasswordResult {
        refresh(enforceLast: false)
        quitAuthorization = nil
        guard !quitIsLocked else { return refusePassword("Un verrou sans arrêt possible ou un gel du Mac reste actif.") }
        guard quitRequiresPassword else { return .ok }
        let result = verifyPassword(password)
        if result == .ok {
            quitAuthorization = (Set(activeBlocks.filter { $0.lock == .password }), clock().addingTimeInterval(30))
        }
        return result
    }

    /// The app consumes a single authorization at the final termination hook.
    func consumeQuitAuthorization() -> Bool {
        refresh(enforceLast: false)
        defer { quitAuthorization = nil }
        guard !quitIsLocked else { return false }
        guard quitRequiresPassword else { return true }
        guard let authorization = quitAuthorization, authorization.expires > clock() else { return false }
        return authorization.blocks == Set(activeBlocks.filter { $0.lock == .password })
    }

    func revokeQuitAuthorization() { quitAuthorization = nil }

    private func refusePassword(_ reason: String) -> BlockingPasswordResult {
        error = reason; return .refused(reason: reason)
    }

    private func verifyPassword(_ password: String) -> BlockingPasswordResult {
        guard !storeFailed else { return refusePassword("Le fichier de blocage doit être réparé avant un essai.") }
        guard var credential = document.passwordLock, credential.isValid else {
            return refusePassword("Le mot de passe est illisible : les blocages restent verrouillés jusqu’à leur fin.")
        }
        if let until = credential.retryAfter, until > clock() { return .wait(until: until) }
        let matches = credential.matches(password)
        if matches { credential.failedAttempts = 0; credential.retryAfter = nil }
        else {
            credential.failedAttempts = min(credential.failedAttempts, 16) + 1
            if credential.failedAttempts >= 5 {
                let delay = min(3_600.0, 60 * pow(2, Double(min(credential.failedAttempts - 5, 6))))
                credential.retryAfter = clock().addingTimeInterval(delay)
            }
        }
        document.passwordLock = credential; commit()
        guard !storeFailed else { return refusePassword("L’essai de mot de passe n’a pas pu être enregistré.") }
        if matches { return .ok }
        if let until = credential.retryAfter { error = "Trop d’essais : attendez avant de réessayer."; return .wait(until: until) }
        error = "Le mot de passe ne correspond pas."
        return .wrong(remaining: max(0, 5 - credential.failedAttempts))
    }

    func typingChallenge(for id: UUID) -> String {
        if let value = challenges[id] { return value }
        let alphabet = Array("abcdefghjkmnpqrstuvwxyzABCDEFGHJKMNPQRSTUVWXYZ23456789")
        let value = String((0..<120).map { _ in alphabet.randomElement()! })
        challenges[id] = value
        return value
    }

    func takeBreak(listID: UUID, password: String? = nil) {
        guard admitEdit() else { return }
        guard freeze == nil else { error = "Aucune pause pendant le gel du Mac."; return }
        guard activeBlocks.contains(where: { $0.listIDs.contains(listID) }), let breaks = list(listID)?.breaks else { error = "Cette liste n’a pas de pause disponible."; return }
        var usage = todayUsage()
        guard usage.breakEnds[listID].map({ $0 > clock() }) != true else { error = "Une pause est déjà en cours."; return }
        let taken = usage.breaksTaken[listID] ?? 0
        if taken >= breaks.count {
            let locks = activeBlocks.filter { $0.listIDs.contains(listID) }.map(\.lock)
            guard locks.contains(.password), !locks.contains(.locked), let password else {
                error = "Toutes les pauses du jour sont utilisées. Un mot de passe est exigé pour une pause supplémentaire."; return
            }
            guard verifyPassword(password) == .ok else { return }
        }
        usage.breaksTaken[listID] = taken + 1
        let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: clock()))!
        usage.breakEnds[listID] = min(midnight, clock().addingTimeInterval(TimeInterval(breaks.minutes * 60)))
        document.usage = usage
        commit()
    }

    func endBreak(listID: UUID) {
        guard admitEdit() else { return }
        var usage = todayUsage()
        usage.breakEnds[listID] = nil
        document.usage = usage
        commit()
    }

    // MARK: Freeze

    func startFreeze(until end: Date, mode: BlockFreeze.Mode, allowedApps: [BlockAppRule]) {
        guard admitEdit() else { return }
        guard freeze == nil else { error = "Le gel en cours ne peut pas être remplacé."; return }
        if mode == .lockScreen, backend?.canLockScreen == false { error = "Le verrouillage de session nécessite l’accessibilité. Choisissez le bouclier."; return }
        let now = clock()
        let bounded = min(max(end, now.addingTimeInterval(5 * 60)), now.addingTimeInterval(24 * 3_600))
        document.freeze = BlockFreeze(start: now, end: bounded, mode: mode, allowedApps: allowedApps)
        commit()
    }

    // MARK: Apps

    nonisolated static func installedApps() async -> [BlockAppRule] {
        let manager = FileManager.default
        let roots = ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                     NSHomeDirectory() + "/Applications"].map { URL(fileURLWithPath: $0) }
        var seen = Set<String>(), apps: [BlockAppRule] = []
        for root in roots {
            let children = (try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            for url in children where url.pathExtension == "app" {
                guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier,
                      !BlockingRules.neverBlocked.contains(id), seen.insert(id).inserted else { continue }
                let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                    ?? url.deletingPathExtension().lastPathComponent
                apps.append(BlockAppRule(bundleIdentifier: id, name: name))
            }
        }
        return apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: State

    func refresh(enforceLast: Bool = true) {
        let now = clock()
        lastRefresh = now
        if let store, !storeFailed {
            do { _ = try store.load() } catch { restoreStore(store) }
        }
        let currentClock = BlockingClockState(wall: now, continuous: continuous(), boot: boot())
        if let previous = lastClock {
            let jump = BlockingClock.adjustment(previous: previous, now: currentClock)
            if jump != 0 { extendLocks(by: jump, at: previous.wall) }
        }
        lastClock = currentClock
        document.clock = currentClock
        if !storeFailed, let store, now.timeIntervalSince(lastSavedAt) >= 60, hasPersistedWork {
            do { try store.save(document); lastGood = document; lastSavedAt = now } catch { failStore() }
        }
        document.sessions.removeAll { $0.end <= now }
        document.heldPrograms = document.heldPrograms?.filter { $0.end > now }
        document.programSkips = document.programSkips?.filter { $0.value > now }
        if let freeze = document.freeze, freeze.end <= now { document.freeze = nil }
        // Publish only real changes: the page must not redraw on every sample.
        if lists != document.lists { lists = document.lists }
        if freeze != document.freeze { freeze = document.freeze }
        if let previous = document.usage, previous.day != Self.dayKey(now, calendar: calendar) {
            document.usageHistory = document.usageHistory ?? [:]
            document.usageHistory?[previous.day] = previous
            for day in (document.usageHistory?.keys.sorted().dropLast(366)) ?? [] { document.usageHistory?[day] = nil }
        }
        let usage = todayUsage()
        if frictionUsage != usage { frictionUsage = usage }
        document.usage = document.usage == nil && usage.quotaSecondsUsed.isEmpty && usage.breaksTaken.isEmpty && usage.slowDownShown == nil ? nil : usage
        let blocks = (document.sessions + (document.heldPrograms ?? [])).filter { $0.start <= now && $0.end > now }.map { session in
            var block = BlockingActiveBlock(id: session.id, listIDs: session.listIDs, start: session.start,
                                            end: session.end, lock: effectiveLock(session.lock), origin: session.origin)
            for id in session.listIDs {
                guard let list = list(id) else { continue }
                if let breaks = list.breaks { block.breaksLeft[id] = max(0, breaks.count - (usage.breaksTaken[id] ?? 0)) }
                if let end = usage.breakEnds[id], end > now { block.breakEnds[id] = end }
                if let quota = list.quotaMinutesPerDay {
                    block.quotaSecondsLeft[id] = max(0, Double(quota * 60) - (usage.quotaSecondsUsed[id] ?? 0))
                }
            }
            return block
        } + programBlocks(at: now, usage: usage)
        if activeBlocks != blocks { activeBlocks = blocks }
        let scheduled = document.sessions.filter { $0.start > now && $0.end > now }.sorted { $0.start < $1.start }
        if scheduledBlocks != scheduled { scheduledBlocks = scheduled }
        let passwordAvailable = document.passwordLock?.isValid == true
        if hasPassword != passwordAvailable { hasPassword = passwordAvailable }
        let needsPassword = blocks.contains { $0.lock == .password }
        if quitRequiresPassword != needsPassword { quitRequiresPassword = needsPassword }
        if let store, !storeFailed, lockMarker != .some(lockedUntil) {
            lockMarker = .some(lockedUntil); store.writeLockMarker(until: lockedUntil)
        }
        let next = nextStart(after: now)
        if nextProgramStart?.listID != next?.listID || nextProgramStart?.date != next?.date { nextProgramStart = next }
        let available = backend?.accessibilityAvailable ?? true
        if siteBlockingAvailable != available { siteBlockingAvailable = available }
        let support = backend?.browsers ?? []
        if browsers != support { browsers = support }
        if let backend {
            let state = backend.updateProtection(locked: requiresLaunchAtLogin)
            if protection != state { protection = state }
            if !storeFailed {
                let message: String?
                switch protection.component {
                case .awaitingApproval: message = "Autorisez Goalong dans les éléments d’ouverture pour reprendre les verrous à la connexion."
                case .failed(let reason): message = reason
                default: message = nil
                }
                if let message, error != message { error = message }
            }
            backend.updateFreeze(freeze)
        }
        let need = needsObservation
        if observing != need {
            observing = need
            if !need { lastObservation = nil; backend?.clearSite() }
            onObservationRequirementChanged?(need)
        }
        scheduleTimer(at: now)
        if enforceLast, var target = lastObservation { target.at = now; enforce(target) }
    }

    private var hasPersistedWork: Bool { !document.lists.isEmpty || !document.sessions.isEmpty || document.freeze != nil || document.passwordLock != nil }
    private func failStore() {
        storeFailed = true
        error = "Goalong ne peut pas enregistrer le blocage : les modifications sont refusées. Relancez Goalong pour réessayer."
    }
    /// A file changed under a running Goalong: the running state is the reference and is written back.
    private func restoreStore(_ store: BlockingStore) {
        do {
            try store.replaceDamaged(with: document); lastGood = document; lastSavedAt = clock()
            error = "Le fichier de blocage a été modifié hors de Goalong : Goalong l’a remis dans son état en cours."
        } catch { failStore() }
    }
    private func admitEdit() -> Bool { refresh(); return !storeFailed }
    private func commit(reenforce: Bool = true) {
        backend?.invalidateSiteActions()
        if let store {
            do { try store.save(document); lastGood = document; lastSavedAt = clock(); error = nil }
            catch { if let lastGood { document = lastGood }; failStore() }
        } else { error = nil }
        refresh(enforceLast: reenforce)
    }
    private func scheduleTimer(at now: Date) {
        timer?.invalidate(); timer = nil
        guard runsTimers else { return }
        var boundaries = activeBlocks.map(\.end) + document.sessions.map(\.start)
        boundaries += document.sessions.map { $0.start.addingTimeInterval(-60) }
        if let until = document.passwordLock?.retryAfter { boundaries.append(until) }
        boundaries += lists.compactMap { $0.program.lockedUntil }
        boundaries += (document.usage?.breakEnds.values).map(Array.init) ?? []
        if let end = freeze?.end { boundaries.append(end) }
        if let start = nextProgramStart?.date { boundaries += [start, start.addingTimeInterval(-60)] }
        if !activeBlocks.isEmpty || freeze != nil || needsObservation || hasLocks { boundaries.append(now.addingTimeInterval(15)) }
        guard let next = boundaries.filter({ $0 > now }).min() else { return }
        let value = Timer(timeInterval: max(0.05, next.timeIntervalSince(now)), repeats: false) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(value, forMode: .common); timer = value
    }
    private func extendLocks(by jump: Double, at oldWall: Date) {
        for index in document.sessions.indices where effectiveLock(document.sessions[index].lock).protectsLists {
            if jump < 0 || document.sessions[index].start > oldWall { document.sessions[index].start = document.sessions[index].start.addingTimeInterval(jump) }
            document.sessions[index].end = document.sessions[index].end.addingTimeInterval(jump)
        }
        document.heldPrograms = (document.heldPrograms ?? []).filter { $0.end > oldWall }.map { value in
            var value = value; if jump < 0 { value.start = value.start.addingTimeInterval(jump) }; value.end = value.end.addingTimeInterval(jump); return value
        }
        for index in document.lists.indices {
            let list = document.lists[index]
            for window in BlockingSchedule.windows(of: list.program, at: oldWall, calendar: calendar)
                where window.start <= oldWall && window.end > oldWall {
                let lock = list.program.isLocked(at: oldWall) ? BlockLock.locked
                    : effectiveLock(list.program.ranges.first { $0.id == window.rangeID }?.effectiveLock ?? .free)
                guard lock.protectsLists, document.programSkips?[window.rangeID].map({ $0 > oldWall }) != true,
                      document.heldPrograms?.contains(where: { $0.id == window.rangeID }) != true else { continue }
                document.heldPrograms = (document.heldPrograms ?? []) + [BlockSession(id: window.rangeID, listIDs: [list.id], start: window.start.addingTimeInterval(min(0, jump)),
                    end: window.end.addingTimeInterval(jump), lock: lock, origin: .program(window.rangeID))]
            }
            if list.program.isLocked(at: oldWall) { document.lists[index].program.lockedUntil = list.program.lockedUntil?.addingTimeInterval(jump) }
        }
        if let until = document.passwordLock?.retryAfter, until > oldWall {
            document.passwordLock?.retryAfter = until.addingTimeInterval(jump)
        }
        if var freeze = document.freeze { if jump < 0 { freeze.start = freeze.start.addingTimeInterval(jump) }; freeze.end = freeze.end.addingTimeInterval(jump); document.freeze = freeze }
    }

    func observe(_ target: BlockingObservation) {
        if target.isActivation { frictionActivation(target) }
        backend?.observeBrowser(target)
        // Samples arrive about every second; boundaries have their own timer, so a full refresh
        // (store check, protection, published state) runs at most every 5 s from here.
        if clock().timeIntervalSince(lastRefresh) >= 5 { refresh(enforceLast: false) }
        if !target.isForeground { enforce(target); return }
        if let previous = lastObservation, previous.pid == target.pid, previous.url == target.url,
           previous.windowIdentity == target.windowIdentity, previous.sessionAvailable, target.sessionAvailable,
           previous.idleSeconds <= 120, target.idleSeconds <= 120, !previous.privateWindow && !target.privateWindow {
            let from = max(previous.at, calendar.startOfDay(for: target.at))
            let seconds = min(15, max(0, target.at.timeIntervalSince(from)))
            var usage = todayUsage()
            for list in lists where list.quotaMinutesPerDay != nil && BlockingRules.wouldBlock(previous, list: list) {
                guard let block = activeBlocks.first(where: { $0.listIDs.contains(list.id) }),
                      block.start <= previous.at, usage.breakEnds[list.id].map({ $0 > previous.at }) != true else { continue }
                usage.quotaSecondsUsed[list.id] = min(Double(list.quotaMinutesPerDay! * 60), (usage.quotaSecondsUsed[list.id] ?? 0) + seconds)
            }
            if document.usage != usage && !usage.quotaSecondsUsed.isEmpty {
                document.usage = usage
                // Persist quota use every 15 s at most; enforcement reads the in-memory value.
                if store == nil || clock().timeIntervalSince(lastSavedAt) >= 15 { commit(reenforce: false) } else { publishQuota(usage) }
            }
        }
        lastObservation = target
        enforce(target)
    }

    private func enforce(_ target: BlockingObservation) {
        guard let backend else { return }
        guard target.sessionAvailable, !BlockingRules.exempt(target) else { backend.clearSite(); if frictionTarget?.isBrowser == true { clearFriction() }; return }
        if target.isForeground, let freeze, freeze.mode == .shield, !freeze.allowedApps.contains(where: { $0.bundleIdentifier == target.bundleIdentifier }) {
            clearFriction(); backend.returnToShield(); return
        }
        let blockedSite = false
        var slowCandidates: [(BlockList, BlockingActiveBlock)] = []
        for list in lists.sorted(by: { $0.effectiveAction == .block && $1.effectiveAction != .block }) {
            guard let block = activeBlocks.first(where: { $0.listIDs.contains(list.id) }) else { continue }
            let usage = todayUsage()
            if usage.breakEnds[list.id].map({ $0 > target.at }) == true { continue }
            if target.isBrowser, !target.isForeground,
               !list.apps.contains(where: { $0.bundleIdentifier == target.bundleIdentifier }) { continue }
            let siteRules = target.isBrowser && BlockingRules.hasSites(list)
            var special: BlockingVeilPresentation.Reason?
            if siteRules && target.privateWindow { special = .privateWindow }
            else if siteRules && !target.isInternalPage && target.url == nil {
                let first = unreadableSince[target.pid] ?? target.at; unreadableSince[target.pid] = first
                if !siteBlockingAvailable || target.at.timeIntervalSince(first) >= 3 { special = .unsupportedBrowser(target.bundleIdentifier) }
            } else { unreadableSince[target.pid] = nil }
            guard special != nil || BlockingRules.wouldBlock(target, list: list) else { continue }
            // Privacy/unreadable addresses cannot establish eligible quota use: fail closed.
            let quotaLeft = list.quotaMinutesPerDay.map { (usage.quotaSecondsUsed[list.id] ?? 0) < Double($0 * 60) } ?? true
            if special == nil, list.effectiveAction == .slowDown, quotaLeft, !storeFailed {
                if target.isForeground || target.isActivation { slowCandidates.append((list, block)) }
                continue
            }
            if special == nil, list.effectiveAction == .block, list.quotaMinutesPerDay != nil, quotaLeft { continue }
            clearFriction()
            if !target.isBrowser || (list.mode == .block && list.apps.contains(where: { $0.bundleIdentifier == target.bundleIdentifier })) {
                backend.clearSite()
                let app = list.apps.first { $0.bundleIdentifier == target.bundleIdentifier }
                    ?? BlockAppRule(bundleIdentifier: target.bundleIdentifier, name: target.bundleIdentifier)
                if list.effectiveAction == .slowDown { backend.blockSlowDownApp(target, app: app, block: block, listName: list.name) }
                else { backend.blockApp(target, app: app, block: block, listName: list.name) }
            } else {
                let reason = special ?? list.quotaMinutesPerDay.map { BlockingVeilPresentation.Reason.quotaUsed(target.url ?? "", minutes: $0) } ?? .site(target.url ?? "")
                let presentation = BlockingVeilPresentation(reason: reason, listName: list.name, start: block.start, end: block.end,
                    lock: block.lock, breakMinutes: list.breaks?.minutes, breaksLeft: block.breaksLeft[list.id] ?? 0)
                backend.blockSite(target, presentation: presentation) { [weak self] in self?.takeBreak(listID: list.id) }
            }
            return
        }
        if !blockedSite { backend.clearSite() }
        if let (list, _) = slowCandidates.first(where: { !isFrictionAllowed(target, list: $0.0) }) {
            showFriction(target, list: list)
        } else if frictionTarget?.isBrowser == true { clearFriction() }
        else if let current = friction, !activeBlocks.contains(where: { $0.listIDs.contains(current.listID) }) { clearFriction() }
    }

    /// Final action admission reads current main-owned rules without a disk read,
    /// AX RPC or history dependency. Expiry is checked even before the next timer.
    func siteActionStillRequired(_ target: BlockingObservation) -> Bool {
        siteActionDeadline(target) != nil
    }

    func siteActionDeadline(_ target: BlockingObservation) -> Date? {
        guard target.isBrowser, target.isForeground, target.sessionAvailable, !BlockingRules.exempt(target) else { return nil }
        if let freeze, freeze.mode == .shield, !freeze.allowedApps.contains(where: { $0.bundleIdentifier == target.bundleIdentifier }) { return nil }
        let now = clock(), usage = todayUsage()
        var deadline: Date?
        for list in lists {
            guard let end = activeBlocks.filter({ $0.listIDs.contains(list.id) && $0.start <= now && $0.end > now }).map(\.end).max(),
                  usage.breakEnds[list.id].map({ $0 > now }) != true else { continue }
            let special = BlockingRules.hasSites(list) && (target.privateWindow
                || (!target.isInternalPage && target.url == nil && (!siteBlockingAvailable
                    || unreadableSince[target.pid].map({ now.timeIntervalSince($0) >= 3 }) == true)))
            let required = special || (BlockingRules.wouldBlock(target, list: list)
                && (list.effectiveAction == .slowDown
                    || (list.quotaMinutesPerDay.map({ (usage.quotaSecondsUsed[list.id] ?? 0) >= Double($0 * 60) }) ?? true)))
            if required { deadline = max(deadline ?? end, end) }
        }
        return deadline
    }


    func frictionCounts(day: String) -> BlockDayUsage {
        let current = todayUsage()
        return current.day == day ? current : document.usageHistory?[day] ?? BlockDayUsage(day: day)
    }
    private func isFrictionAllowed(_ target: BlockingObservation, list: BlockList) -> Bool {
        frictionAllowances[BlockingFrictionPresentation.key(target, listID: list.id)].map { $0 > clock() } == true
    }
    private func clearFriction() {
        friction = nil; frictionTarget = nil; backend?.clearSlowDown()
    }
    private func showFriction(_ target: BlockingObservation, list: BlockList) {
        let key = BlockingFrictionPresentation.key(target, listID: list.id)
        if !target.isBrowser, suppressedAppFriction.contains(key) { return }
        if friction?.key != key {
            var usage = todayUsage(); usage.slowDownShown = usage.slowDownShown ?? [:]
            usage.slowDownShown?[list.id, default: 0] += 1
            document.usage = usage
            commit(reenforce: false)
            if storeFailed { enforce(target); return }
            friction = BlockingFrictionPresentation(listID: list.id, key: key, name: target.isBrowser ? (target.url?.split(separator: "/").first.map(String.init) ?? list.name) : (list.apps.first { $0.bundleIdentifier == target.bundleIdentifier }?.name ?? target.bundleIdentifier),
                shownAt: clock(), readyAt: clock().addingTimeInterval(Double(list.delaySeconds)), occurrence: usage.slowDownShown?[list.id] ?? 1)
        }
        frictionTarget = target
        guard let friction else { return }
        backend?.slowDown(target, presentation: friction, onRenounce: { [weak self] in self?.renounceFriction() }, onContinue: { [weak self] in self?.continueFriction() })
    }
    func renounceFriction() {
        guard let value = friction, let target = frictionTarget else { return }
        var usage = todayUsage(); usage.renounced = usage.renounced ?? [:]; usage.renounced?[value.listID, default: 0] += 1
        document.usage = usage; commit(reenforce: false)
        guard !storeFailed else { return }
        if !target.isBrowser { suppressedAppFriction.insert(value.key) }
        backend?.renounceSlowDown(target); clearFriction()
    }
    func continueFriction() {
        guard let value = friction, let target = frictionTarget, clock() >= value.readyAt, let list = list(value.listID) else { return }
        refresh(enforceLast: false)
        guard freeze == nil, activeBlocks.contains(where: { $0.listIDs.contains(list.id) }),
            !lists.contains(where: { candidate in candidate.effectiveAction == .block && activeBlocks.contains { $0.listIDs.contains(candidate.id) }
                && todayUsage().breakEnds[candidate.id].map { $0 > clock() } != true
                && (candidate.quotaMinutesPerDay.map { (todayUsage().quotaSecondsUsed[candidate.id] ?? 0) >= Double($0 * 60) } ?? true)
                && BlockingRules.wouldBlock(target, list: candidate) }) else { clearFriction(); return }
        var usage = todayUsage(); usage.continued = usage.continued ?? [:]; usage.continued?[list.id, default: 0] += 1
        document.usage = usage; commit(reenforce: false)
        guard !storeFailed else { return }
        frictionAllowances[value.key] = clock().addingTimeInterval(Double(list.allowanceMinutes * 60))
        backend?.continueSlowDown(target); clearFriction()
    }
    /// Only an explicit launch/activation releases a renounced hidden app, never an old sample.
    func frictionActivation(_ target: BlockingObservation) {
        suppressedAppFriction = suppressedAppFriction.filter { !$0.hasSuffix("|app:" + target.bundleIdentifier) }
    }

    private func publishQuota(_ usage: BlockDayUsage) {
        var blocks = activeBlocks
        for index in blocks.indices {
            for id in blocks[index].listIDs {
                guard let quota = list(id)?.quotaMinutesPerDay else { continue }
                blocks[index].quotaSecondsLeft[id] = max(0, Double(quota * 60) - (usage.quotaSecondsUsed[id] ?? 0))
            }
        }
        if blocks != activeBlocks { activeBlocks = blocks }
    }

    private func todayUsage() -> BlockDayUsage {
        let day = Self.dayKey(clock(), calendar: calendar)
        if let usage = document.usage, usage.day == day { return usage }
        return BlockDayUsage(day: day)
    }

    private func isStricterOnly(_ listID: UUID) -> Bool {
        let now = clock()
        if list(listID)?.program.isLocked(at: now) == true { return true }
        return activeBlocks.contains { $0.lock.protectsLists && $0.listIDs.contains(listID) }
    }

    private func programBlocks(at now: Date, usage: BlockDayUsage) -> [BlockingActiveBlock] {
        document.lists.flatMap { list -> [BlockingActiveBlock] in
            BlockingSchedule.windows(of: list.program, at: now, calendar: calendar).compactMap { window in
            guard window.start <= now, window.end > now else { return nil }
            guard document.programSkips?[window.rangeID].map({ $0 > now }) != true,
                  document.heldPrograms?.contains(where: { $0.id == window.rangeID && $0.end > now }) != true else { return nil }
            let rangeLock = effectiveLock(list.program.ranges.first { $0.id == window.rangeID }?.effectiveLock ?? .free)
            var block = BlockingActiveBlock(id: window.rangeID, listIDs: [list.id], start: window.start, end: window.end,
                                            lock: list.program.isLocked(at: now) ? .locked : rangeLock,
                                            origin: .program(window.rangeID))
            if let breaks = list.breaks { block.breaksLeft[list.id] = max(0, breaks.count - (usage.breaksTaken[list.id] ?? 0)) }
            if let end = usage.breakEnds[list.id], end > now { block.breakEnds[list.id] = end }
            if let quota = list.quotaMinutesPerDay {
                block.quotaSecondsLeft[list.id] = max(0, Double(quota * 60) - (usage.quotaSecondsUsed[list.id] ?? 0))
            }
            return block
            }
        }
    }

    private func nextStart(after now: Date) -> (listID: UUID, date: Date)? {
        let program = document.lists.compactMap { list in
            BlockingSchedule.nextStart(of: list.program, after: now, calendar: calendar).map { (list.id, $0) }
        }
        let sessions = document.sessions.filter { $0.start > now }.compactMap { session in session.listIDs.first.map { ($0, session.start) } }
        return (program + sessions).min { $0.1 < $1.1 }
    }

    /// Every (weekday, minute-of-week) the program covers, at minute resolution.
    static func programCoverage(_ program: BlockProgram) -> Set<Int> {
        var minutes = Set<Int>()
        for range in program.ranges {
            for day in range.weekdays {
                let base = (day - 1) * 1_440 + range.startMinute
                for offset in 0..<range.durationMinutes { minutes.insert((base + offset) % (7 * 1_440)) }
            }
        }
        return minutes
    }

    nonisolated static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
/// Holds the controller only while the module is on.
@MainActor final class BlockingRuntime: ObservableObject {
    static let shared = BlockingRuntime()
    @Published private(set) var controller: BlockingController?

    init(controller: BlockingController? = nil) { self.controller = controller }

    private var modules: GoalongModuleStore?
    private weak var monitor: ContextMonitor?
    func start(modules: GoalongModuleStore = .shared, monitor: ContextMonitor? = nil) {
        self.modules = modules; self.monitor = monitor
        apply(enabled: modules.isEnabled(.blocking))
        modules.blockingDisableCheck = { [weak self] in
            self?.controller?.refresh(enforceLast: false)
            if self?.controller?.hasLocks == true {
                self?.controller?.error = "Le module ne peut pas être désactivé pendant un verrou."
                return false
            }
            return true
        }
        modules.onBlockingEnabledChange = { [weak self] enabled in self?.apply(enabled: enabled) }
    }
    func apply(enabled: Bool) {
        if enabled, controller == nil {
            let value = BlockingController(store: .standard, backend: StandardBlockingBackend(), runsTimers: true)
            controller = value
            value.onObservationRequirementChanged = { [weak self] needed in self?.monitor?.setBlockingObservationEnabled(needed) }
            monitor?.blockingSink = { [weak value] target in value?.observe(target) }
            monitor?.setBlockingObservationEnabled(value.needsObservation)
        } else if !enabled, let controller {
            controller.refresh(enforceLast: false)
            if controller.hasLocks {
                controller.error = "Le module ne peut pas être désactivé pendant un verrou."
                modules?.setEnabled(.blocking, true)
                return
            }
            controller.shutdown()
            monitor?.blockingSink = nil
            monitor?.setBlockingObservationEnabled(false)
            self.controller = nil
        }
    }
}
#endif
