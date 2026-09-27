#if os(macOS)
import Foundation
import CryptoKit

/// Remembers only user-requested recovery steps, not permission grants or consent.
/// Bound to this installation/build and expiring after one day; never exported raw.
enum PermissionRecoveryLedger {
    enum Action: String, Codable { case settingsOpened, relaunchPrepared, resetSucceeded }
    struct Progress: Codable, Equatable {
        var settingsVisits = 0
        var relaunches = 0
        var resets = 0
        var relaunchesAfterReset = 0
    }
    private struct Record: Codable {
        let scope: String
        let updatedAt: Date
        let progress: Progress
    }
    private static let prefix = "goalong.permissions.recovery.v1."
    private static let lock = NSRecursiveLock()
    static var currentScope: String {
        let bundle = Bundle.main
        let input = [bundle.bundleURL.resolvingSymlinksInPath().path,
                     bundle.bundleIdentifier ?? "",
                     bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""].joined(separator: "|")
        return SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func load(_ permission: SourceAccessStatus, defaults: UserDefaults = .standard,
                     now: Date = Date(), scope: String = currentScope) -> Progress {
        lock.lock(); defer { lock.unlock() }
        guard let service = PermissionRepair.service(for: permission),
              let data = defaults.data(forKey: prefix + service), data.count <= 2048,
              let record = try? JSONDecoder().decode(Record.self, from: data),
              record.scope == scope, now.timeIntervalSince(record.updatedAt) >= 0,
              now.timeIntervalSince(record.updatedAt) < 86400,
              [record.progress.settingsVisits, record.progress.relaunches,
               record.progress.resets, record.progress.relaunchesAfterReset].allSatisfy({ (0...9).contains($0) })
        else { return Progress() }
        return record.progress
    }
    static func record(_ action: Action, for permission: SourceAccessStatus,
                       defaults: UserDefaults = .standard, now: Date = Date(), scope: String = currentScope) {
        guard let service = PermissionRepair.service(for: permission) else { return }
        lock.lock(); defer { lock.unlock() }
        var progress = load(permission, defaults: defaults, now: now, scope: scope)
        switch action {
        case .settingsOpened: progress.settingsVisits = min(9, progress.settingsVisits + 1)
        case .relaunchPrepared:
            progress.relaunches = min(9, progress.relaunches + 1)
            if progress.resets > 0 { progress.relaunchesAfterReset = min(9, progress.relaunchesAfterReset + 1) }
        case .resetSucceeded:
            progress.resets = min(9, progress.resets + 1)
            progress.relaunchesAfterReset = 0
        }
        if let data = try? JSONEncoder().encode(Record(scope: scope, updatedAt: now, progress: progress)) {
            defaults.set(data, forKey: prefix + service)
            defaults.set(service, forKey: prefix + "active")
        }
        SupportDiagnostics.shared.record(.permissionRecoveryAction, component: .permissions, values: [
            .permission: .state(PermissionRepair.diagnosticState(for: permission)),
            .state: .state(SupportState(rawValue: action.rawValue) ?? .unknown),
            .attempt: .count(action == .resetSucceeded ? progress.resets : progress.relaunches)
        ])
    }
    static func clear(_ permission: SourceAccessStatus, defaults: UserDefaults = .standard) {
        guard let service = PermissionRepair.service(for: permission) else { return }
        lock.lock(); defer { lock.unlock() }
        defaults.removeObject(forKey: prefix + service)
        if defaults.string(forKey: prefix + "active") == service { defaults.removeObject(forKey: prefix + "active") }
    }
    static func activePermission(defaults: UserDefaults = .standard) -> SourceAccessStatus? {
        lock.lock(); defer { lock.unlock() }
        let status: SourceAccessStatus
        switch defaults.string(forKey: prefix + "active") {
        case "Accessibility": status = .accessibility
        case "ListenEvent": status = .inputMonitoring
        case "SystemPolicyAllFiles": status = .fullDiskAccess
        default: return nil
        }
        return load(status, defaults: defaults) == Progress() ? nil : status
    }
}

/// Pure policy: an enabled checkbox, a restart or a successful reset NEVER grants access.
enum PermissionRecoveryAdvice: Equatable {
    case checking, available, installStableCopy, closeOtherCopy, replaceInvalidBuild
    case grant, relaunch, repair, reauthorize, manualRepair

    static func resolve(accessAvailable: Bool, observationPending: Bool = false,
                        stableInstallation: Bool, signatureValid: Bool?, runningCopies: Int,
                        identityChanged: Bool, progress: PermissionRecoveryLedger.Progress) -> Self {
        // Do not recommend a destructive repair for a broken installation or duplicate process.
        guard stableInstallation else { return .installStableCopy }
        if signatureValid == false { return .replaceInvalidBuild }
        if runningCopies > 1 { return .closeOtherCopy }
        if observationPending || signatureValid == nil { return .checking }
        if accessAvailable { return .available }
        if progress.resets > 0 { return progress.relaunchesAfterReset == 0 ? .reauthorize : .manualRepair }
        if identityChanged || progress.relaunches > 0 { return .repair }
        return progress.settingsVisits > 0 ? .relaunch : .grant
    }
}
#endif
