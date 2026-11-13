#if os(macOS)
import Foundation
import LocalAuthentication
import LocalHistoryCore
import Security

/// T-059 lot 2: a copy of the protected rules kept outside their files, in the login keychain. Each engine writes it
/// after a save; at launch, a file that lost or weakened a protected rule (edited, replaced or deleted while Goalong was
/// closed or stopped) gets that rule back from this copy. Weakening goes through the stop in the app, never through
/// the files. Limit: the member can still delete the keychain item too; without a copy the files are taken as they are.
/// T-059 lot 3 (F5): `read` returns nil only for an absent item and throws when the store cannot answer (keychain
/// locked, access refused); `write` says whether the copy was really written.
protocol ProtectedFloorBacking: AnyObject {
    func read(_ key: String) throws -> Data?
    @discardableResult func write(_ key: String, _ data: Data?) -> Bool
}

struct ProtectedFloorUnavailable: Error {}

/// Tests and previews: nothing leaves the process. `failsReads` / `failsWrites` stand for an unavailable keychain.
final class MemoryFloorBacking: ProtectedFloorBacking {
    var items: [String: Data] = [:]
    var failsReads = false, failsWrites = false
    func read(_ key: String) throws -> Data? {
        if failsReads { throw ProtectedFloorUnavailable() }
        return items[key]
    }
    func write(_ key: String, _ data: Data?) -> Bool {
        if failsWrites { return false }
        items[key] = data; return true
    }
}

/// Generic password items of this bundle. Never any keychain UI; an unchanged copy is not written again.
final class KeychainFloorBacking: ProtectedFloorBacking {
    let service: String
    private let lock = NSLock()
    private var written: [String: Data?] = [:]

    init(service: String) { self.service = service }

    private func query(_ key: String) -> [String: Any] {
        let context = LAContext(); context.interactionNotAllowed = true
        return [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                kSecAttrAccount as String: key, kSecUseAuthenticationContext as String: context]
    }

    func read(_ key: String) throws -> Data? {
        var request = query(key)
        request[kSecReturnData as String] = true; request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw ProtectedFloorUnavailable() }
        return data
    }

    func write(_ key: String, _ data: Data?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let known = written[key], known == data { return true }
        let ok: Bool
        if let data {
            let update = SecItemUpdate(query(key) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            if update == errSecItemNotFound {
                var add = query(key)
                add[kSecValueData as String] = data
                add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                ok = SecItemAdd(add as CFDictionary, nil) == errSecSuccess
            } else { ok = update == errSecSuccess }
        } else {
            let status = SecItemDelete(query(key) as CFDictionary)
            ok = status == errSecSuccess || status == errSecItemNotFound
        }
        if ok { written[key] = .some(data) }
        return ok
    }
}

struct ProtectedFloor {
    static let blockingKey = "blocking", redScreenKey = "red-screen", jevKey = "jev"
    let backing: ProtectedFloorBacking
    /// The copy this run last read or wrote, per key: `.some(nil)` = known absent; no entry = not known.
    private let memo = Memo()
    private final class Memo { let lock = NSLock(); var known: [String: Data?] = [:] }

    init(backing: ProtectedFloorBacking) { self.backing = backing }

    /// What the copy holds: absent, a value, or unavailable (the keychain did not answer, or the copy is unreadable).
    enum Copy<T> {
        case absent, value(T), unavailable
        var value: T? { if case .value(let v) = self { return v }; return nil }
    }

    /// The app's copy, per bundle (Goalong Dev keeps its own). Nil under tests: they inject a memory backing.
    static let standard: ProtectedFloor? = {
        guard NSClassFromString("XCTestCase") == nil else { return nil }
        let bundle = Bundle.main.bundleIdentifier ?? "ai.goalong.localhistory"
        return ProtectedFloor(backing: KeychainFloorBacking(service: "\(bundle).protected-floor"))
    }()

    static func memory() -> ProtectedFloor { ProtectedFloor(backing: MemoryFloorBacking()) }

    /// Reads the copy now. An absence and a failure are told apart (F5): a failure never passes for « nothing protected ».
    func read<T: Decodable>(_ type: T.Type, key: String) -> Copy<T> {
        let data: Data?
        do { data = try backing.read(key) } catch { return .unavailable }
        remember(key, data)
        guard let data else { return .absent }
        guard let value = try? JSONDecoder().decode(T.self, from: data) else { return .unavailable }
        return .value(value)
    }

    func load<T: Decodable>(_ type: T.Type, key: String) -> T? { read(type, key: key).value }

    /// The copy in place, as this run last saw it; read again when not known yet.
    func known<T: Decodable>(_ type: T.Type, key: String) -> Copy<T> {
        memo.lock.lock(); let entry = memo.known[key]; memo.lock.unlock()
        guard let entry else { return read(type, key: key) }
        guard let data = entry else { return .absent }
        return (try? JSONDecoder().decode(T.self, from: data)).map { .value($0) } ?? .unavailable
    }

    /// Nil removes the copy (nothing protected any more). False = the copy was not written (F5): the caller decides
    /// whether its file may still go ahead (`known` gives the copy still in place).
    @discardableResult func save<T: Encodable>(_ value: T?, key: String) -> Bool {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = value.flatMap { try? encoder.encode($0) }
        guard backing.write(key, data) else { return false }
        remember(key, data); return true
    }

    private func remember(_ key: String, _ data: Data?) {
        memo.lock.lock(); memo.known[key] = .some(data); memo.lock.unlock()
    }

    static let restoredText = "Des règles protégées avaient été retirées ou affaiblies hors de Goalong : elles sont rétablies. Pour les affaiblir, passez par leur arrêt dans Goalong."
    static let unavailableText = "La copie protégée des règles (trousseau) est indisponible : Goalong n’a pas pu vérifier que les règles protégées sont intactes."
    static let unsavedText = "Le trousseau est indisponible : ce changement n’est pas enregistré, sinon la règle protégée reviendrait au prochain lancement. Réessayez une fois la session déverrouillée."
    static let staleText = "La copie protégée des règles (trousseau) n’a pas pu être mise à jour : un changement fait maintenant pourrait être annulé au prochain lancement."
}

/// The protected part of the blocking document: lists with a protected range or a program lock, protected sessions,
/// the freeze, the password, the pause budgets used and the skipped program windows. Pure.
struct BlockingFloor: Codable, Equatable {
    var lists: [BlockList] = []
    var sessions: [BlockSession] = []
    var freeze: BlockFreeze?
    var password: BlockPasswordLock?
    var pauses: [UUID: PauseUsage]?
    var programSkips: [UUID: Date]?

    var isEmpty: Bool { lists.isEmpty && sessions.isEmpty && freeze == nil && password == nil }

    static func isProtected(_ list: BlockList, now: Date) -> Bool {
        list.program.ranges.contains { $0.effectiveLock != .free } || (list.program.lockedUntil ?? .distantPast) > now
    }

    static func of(_ document: BlockingDocument, now: Date) -> BlockingFloor? {
        var floor = BlockingFloor()
        floor.sessions = document.sessions.filter { $0.lock != .free && $0.end > now }
        // F2 (lot 3): the lists a protected session blocks are kept too, whatever their own program.
        let used = Set(floor.sessions.flatMap(\.listIDs))
        floor.lists = document.lists.filter { isProtected($0, now: now) || used.contains($0.id) }
        floor.freeze = document.freeze.flatMap { $0.end > now ? $0 : nil }
        floor.password = document.passwordLock
        guard !floor.isEmpty else { return nil }
        floor.pauses = document.pauses
        floor.programSkips = document.programSkips
        return floor
    }

    /// `document` with every protected item of `floor` it lost or weakened put back. Hardening kept. Count = items restored.
    static func restore(_ document: BlockingDocument, floor: BlockingFloor, now: Date) -> (document: BlockingDocument, restored: Int) {
        var next = document, count = 0
        let used = Set(floor.sessions.filter { $0.end > now }.flatMap(\.listIDs))
        for old in floor.lists where isProtected(old, now: now) || used.contains(old.id) {
            guard let index = next.lists.firstIndex(where: { $0.id == old.id }) else { next.lists.append(old); count += 1; continue }
            let new = next.lists[index]
            let lockLost = (old.program.lockedUntil ?? .distantPast) > max(now, new.program.lockedUntil ?? .distantPast)
            // F2: the content is compared for every kept list, not only for one with a protected range of its own.
            if lockLost || BlockingController.contentWeakening(old, new, prefix: "") != nil
                || BlockingController.protectedWeakening(old, new, effectiveLock: { $0 }) != nil {
                next.lists[index] = old; count += 1
            }
        }
        for old in floor.sessions where old.end > now {
            guard let index = next.sessions.firstIndex(where: { $0.id == old.id }) else { next.sessions.append(old); count += 1; continue }
            let new = next.sessions[index]
            // F2: a later start shortens the block as much as an earlier end; a looser pause too.
            let pauseLoosened = old.pause != new.pause && PauseEngine.weakening(old.pause, new.pause) != nil
            if new.lock.strength < old.lock.strength || new.end < old.end || new.start > old.start || pauseLoosened
                || !Set(old.listIDs).isSubset(of: new.listIDs) {
                next.sessions[index] = old; count += 1
            }
        }
        if let freeze = floor.freeze, freeze.end > now, (next.freeze?.end ?? .distantPast) < freeze.end {
            next.freeze = freeze; count += 1
        }
        if let password = floor.password, next.passwordLock?.hash != password.hash || next.passwordLock?.salt != password.salt {
            next.passwordLock = password; count += 1
        }
        // Pauses used and skipped windows only change through the app's saves: a difference was written outside it.
        if !floor.lists.isEmpty || !floor.sessions.isEmpty {
            if next.pauses != floor.pauses { next.pauses = floor.pauses; count += 1 }
            if next.programSkips != floor.programSkips { next.programSkips = floor.programSkips; count += 1 }
        }
        return (next, count)
    }
}
#endif
