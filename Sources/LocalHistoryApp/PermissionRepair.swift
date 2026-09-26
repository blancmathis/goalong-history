#if os(macOS)
import AppKit
import Foundation
import SwiftUI

/// A narrowly scoped, user-confirmed recovery. Never resets All, other apps,
/// modifies TCC databases, resigns a bundle, or enables a permission by itself.
enum PermissionRepair {
    static let bundleIdentifier = "ai.goalong.localhistory"
    static func service(for status: SourceAccessStatus) -> String? {
        switch status {
        case .accessibility: return "Accessibility"
        case .inputMonitoring: return "ListenEvent"
        case .fullDiskAccess: return "SystemPolicyAllFiles"
        default: return nil
        }
    }
    static func arguments(for status: SourceAccessStatus, bundleID: String?) -> [String]? {
        guard bundleID == bundleIdentifier, let service = service(for: status) else { return nil }
        return ["reset", service, bundleIdentifier]
    }
    static func diagnosticState(for status: SourceAccessStatus) -> SupportState {
        switch status {
        case .accessibility: return .accessibility
        case .inputMonitoring: return .inputMonitoring
        case .fullDiskAccess: return .fullDiskAccess
        default: return .unknown
        }
    }

    static func canResetInstallation(path: String) -> Bool {
        let location = SupportBuild.installation(path: path)
        return URL(fileURLWithPath: path).pathExtension == "app" && location != .diskImage && location != .translocated
    }

    @MainActor static func reset(_ status: SourceAccessStatus, completion: @escaping (Bool) -> Void) {
        guard canResetInstallation(path: Bundle.main.bundleURL.path),
              let arguments = arguments(for: status, bundleID: Bundle.main.bundleIdentifier) else { completion(false); return }
        SupportDiagnostics.shared.record(.permissionRepairStarted, component: .permissions,
            values: [.permission: .state(diagnosticState(for: status))])
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        // The command is fixed and receives no secret/environment dump.
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()]
        var finished = false
        let finish: (Bool, Int32) -> Void = { success, code in
            guard !finished else { return }; finished = true
            SupportDiagnostics.shared.record(.permissionRepairFinished, component: .permissions,
                level: success ? .info : .warning,
                values: [.permission: .state(diagnosticState(for: status)), .success: .flag(success), .errorCode: .count(Int(code))])
            completion(success)
        }
        process.terminationHandler = { process in
            DispatchQueue.main.async { finish(process.terminationStatus == 0, process.terminationStatus) }
        }
        do { try process.run() }
        catch {
            SupportDiagnostics.shared.failure(error, component: .permissions)
            finish(false, -1); return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            guard !finished else { return }
            if process.isRunning { process.terminate() }
            finish(false, -2)
        }
    }
}

@MainActor struct PermissionRepairControl: View {
    let status: SourceAccessStatus
    var capability: GoalongCapability?
    @State private var confirming = false
    @State private var resetting = false
    @State private var result: String?
    @State private var resetSucceeded = false
    private var stableLocation: Bool { PermissionRepair.canResetInstallation(path: Bundle.main.bundleURL.path) }
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if !stableLocation {
                Text("Cette copie n’est pas installée dans un emplacement stable. Placez Goalong History dans Applications, ouvrez cette copie puis réaccordez l’accès. Ne réinitialisez pas les accès depuis l’image disque.")
                    .font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
            }
            Text("Toujours bloqué après relancement ? Une ancienne entrée macOS peut correspondre à une autre copie. Réinitialisez uniquement cet accès, puis autorisez à nouveau cette application.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button(resetting ? "Réinitialisation…" : "Réinitialiser cet accès…") { confirming = true }
                .buttonStyle(.bordered).disabled(resetting || !stableLocation || PermissionRepair.service(for: status) == nil)
                .accessibilityIdentifier("permission-targeted-repair")
            if resetSucceeded {
                Button("Relancer Goalong après autorisation") {
                    PermissionRecovery.restart { error in if let error { result = error } }
                }.buttonStyle(.bordered)
            }
            if let result { Text(result).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true) }
            SupportDiagnosticsExportButton()
        }
        .confirmationDialog("Réinitialiser cette autorisation de Goalong ?", isPresented: $confirming) {
            Button("Réinitialiser et ouvrir les réglages") {
                resetting = true
                if let capability { PermissionRecovery.rememberSetup(capability) }
                PermissionRepair.reset(status) { success in
                    resetting = false
                    resetSucceeded = success
                    result = success
                        ? "Ancienne autorisation supprimée. Activez Goalong History dans les réglages ; si l’entrée a disparu, ajoutez cette copie avec le bouton +. Relancez ensuite Goalong. Votre historique et vos choix sont conservés."
                        : "macOS n’a pas confirmé la réinitialisation. Supprimez l’ancienne entrée avec le bouton − dans les réglages, puis ajoutez la copie affichée dans le Finder. Exportez le diagnostic si le problème persiste."
                    if success { SourceAccessService.openAccess(status) }
                }
            }
        } message: {
            Text("Cela retire uniquement cet accès pour Goalong History. Vous devrez l’autoriser à nouveau. Les autres applications, les autres autorisations, l’historique et les préférences ne sont pas modifiés.")
        }
    }
}
#endif
