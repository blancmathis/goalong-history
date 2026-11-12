#if os(macOS)
import Foundation
import LocalAuthentication
import LocalHistoryCore
import Security

/// T-059 lot 2: a copy of the protected rules kept outside their files, in the login keychain. Each engine writes it
/// after a save; at launch, a file that lost or weakened a protected rule (edited, replaced or deleted while Goalong was
/// closed or stopped) gets that rule back from this copy. Weakening goes through the stop in the app, never through
/// the files. Limit: the member can still delete the keychain item too; without a copy the files are taken as they are.
protocol ProtectedFloorBacking: AnyObject {
    func read(_ key: String) -> Data?
    @discardableResult func write(_ key: String, _ data: Data?) -> Bool
}

/// Tests and previews: nothing leaves the process.
final class MemoryFloorBacking: ProtectedFloorBacking {
    var items: [String: Data] = [:]
    func read(_ key: String) -> Data? { items[key] }
    func write(_ key: String, _ data: Data?) -> Bool { items[key] = data; return true }
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

    func read(_ key: String) -> Data? {
        var request = query(key)
        request[kSecReturnData as String] = true; request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
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

    /// The app's copy, per bundle (Goalong Dev keeps its own). Nil under tests: they inject a memory backing.
    static let standard: ProtectedFloor? = {
        guard NSClassFromString("XCTestCase") == nil else { return nil }
        let bundle = Bundle.main.bundleIdentifier ?? "ai.goalong.localhistory"
        return ProtectedFloor(backing: KeychainFloorBacking(service: "\(bundle).protected-floor"))
    }()

    static func memory() -> ProtectedFloor { ProtectedFloor(backing: MemoryFloorBacking()) }

    func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        backing.read(key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    /// Nil removes the copy (nothing protected any more).
    func save<T: Encodable>(_ value: T?, key: String) {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        backing.write(key, value.flatMap { try? encoder.encode($0) })
    }

    static let restoredText = "Des règles protégées avaient été retirées ou affaiblies hors de Goalong : elles sont rétablies. Pour les affaiblir, passez par leur arrêt dans Goalong."
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
        floor.lists = document.lists.filter { isProtected($0, now: now) }
        floor.sessions = document.sessions.filter { $0.lock != .free && $0.end > now }
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
        for old in floor.lists {
            guard let index = next.lists.firstIndex(where: { $0.id == old.id }) else { next.lists.append(old); count += 1; continue }
            let new = next.lists[index]
            let lockLost = (old.program.lockedUntil ?? .distantPast) > max(now, new.program.lockedUntil ?? .distantPast)
            if lockLost || BlockingController.protectedWeakening(old, new, effectiveLock: { $0 }) != nil {
                next.lists[index] = old; count += 1
            }
        }
        for old in floor.sessions where old.end > now {
            guard let index = next.sessions.firstIndex(where: { $0.id == old.id }) else { next.sessions.append(old); count += 1; continue }
            let new = next.sessions[index]
            if new.lock.strength < old.lock.strength || new.end < old.end || !Set(old.listIDs).isSubset(of: new.listIDs) {
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
