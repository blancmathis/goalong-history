#if os(macOS)
import AppKit
import SwiftUI

/// Display copy is source-specific. It never infers permission from a simulated checkbox.
struct PermissionSetupCopy {
    let capability: GoalongCapability
    let status: SourceAccessStatus

    var symbol: String { capability == .appleScreenTime ? "chart.bar.xaxis" : capability == .aiConversations ? "bubble.left.and.bubble.right" : "desktopcomputer" }
    var permission: String {
        switch status {
        case .inputMonitoring: return "Input Monitoring"
        case .fullDiskAccess: return "Full Disk Access"
        case .screenTimeSetup: return "App & Website Activity"
        default: return capability == .appleScreenTime ? "Full Disk Access" : "Accessibility"
        }
    }
    var permissionSymbol: String {
        switch status {
        case .fullDiskAccess: return "internaldrive"
        case .inputMonitoring: return "keyboard"
        case .screenTimeSetup: return "hourglass"
        default: return capability == .appleScreenTime ? "internaldrive" : "accessibility"
        }
    }
    var purpose: String {
        switch capability {
        case .appleScreenTime: return "Retrouver le temps passé dans vos applications Apple."
        case .aiConversations: return "Retrouver les conversations des dossiers choisis."
        default: return "Reconnaître les applications et fenêtres utilisées."
        }
    }
    var permissionDetail: String {
        switch status {
        case .inputMonitoring: return "Compter les interactions, sans les caractères tapés."
        case .screenTimeSetup: return "Apple doit d’abord disposer de données d’usage."
        default:
            return capability == .appleScreenTime ? "Nécessaire pour lire les données d’usage protégées d’Apple." : "Reconnaître l’application et la fenêtre actives."
        }
    }
    var privacy: String {
        switch capability {
        case .appleScreenTime: return "L’accès complet au disque est large. Goalong l’utilise ici pour lire le temps d’écran Apple. Aucun envoi n’est autorisé."
        case .aiConversations: return "Les conversations restent dans leurs fichiers d’origine. Analyser et envoyer sont des choix séparés."
        default: return "Pas de captures d’écran ni de caractères tapés. Cet accès n’autorise aucun envoi."
        }
    }
    var settingsPath: String { status == .screenTimeSetup ? "System Settings  ›  Screen Time" : "Privacy & Security  ›  \(permission)" }
}

struct PermissionSetupHeader: View {
    let copy: PermissionSetupCopy
    let ready: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: ready ? "checkmark" : copy.symbol)
                .font(.system(size: 23, weight: .medium))
                .foregroundStyle(LHTheme.accent)
                .frame(width: 56, height: 56)
                .background(LHTheme.selectionBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text("AUTORISATIONS MACOS")
                    .font(.system(size: 10, weight: .semibold)).tracking(1.6)
                    .foregroundStyle(LHTheme.secondaryText)
                Text(ready ? "Accès disponible" : "Autoriser \(copy.capability.title)")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(LHTheme.text)
                    .accessibilityAddTraits(.isHeader)
                Text(copy.purpose).font(.system(size: 13))
                    .foregroundStyle(LHTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}

struct PermissionSetupStatusCard: View {
    let copy: PermissionSetupCopy
    let checking: Bool
    let ready: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: copy.permissionSymbol).font(.system(size: 20))
                .foregroundStyle(LHTheme.secondaryText).frame(width: 26)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(copy.permission).font(.system(size: 13, weight: .semibold))
                Text(copy.permissionDetail).font(.system(size: 11))
                    .foregroundStyle(LHTheme.secondaryText).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            HStack(spacing: 5) {
                if checking { ProgressView().controlSize(.mini) }
                else { Image(systemName: ready ? "checkmark.circle.fill" : "circle.dashed").font(.system(size: 11)) }
                Text(checking ? "Vérification" : ready ? "Autorisé" : "À autoriser")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(ready ? LHTheme.success : LHTheme.secondaryText)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(ready ? LHTheme.selectionBackground : LHTheme.elevatedBackground, in: Capsule())
            .accessibilityElement(children: .combine)
        }
        .padding(16)
        .background(LHTheme.cardBackground, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(LHTheme.separator, lineWidth: 1))
    }
}

struct PermissionSetupSteps: View {
    let copy: PermissionSetupCopy
    let openedSettings: Bool
    let ready: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            step(1, title: "Ouvrir les réglages macOS", detail: copy.settingsPath, done: openedSettings || ready, active: !openedSettings && !ready)
            step(2, title: copy.status == .screenTimeSetup ? "Activer le temps d’écran" : "Autoriser Goalong History",
                 detail: copy.status == .screenTimeSetup ? "Apple commencera à mesurer votre usage." : "Activez Goalong History dans la liste.",
                 done: ready, active: openedSettings && !ready)
            step(3, title: "Revenir dans Goalong", detail: "Vérification automatique au retour. Relancez Goalong si macOS le demande.", done: ready, active: false)
        }
        .padding(.horizontal, 4).padding(.vertical, 2)
    }

    private func step(_ number: Int, title: String, detail: String, done: Bool, active: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Group {
                if done { Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)) }
                else { Text(String(number)).font(.system(size: 11, weight: .semibold)) }
            }
            .frame(width: 26, height: 26)
            .foregroundStyle(done || active ? LHTheme.accent : LHTheme.secondaryText)
            .background(done || active ? LHTheme.selectionBackground : LHTheme.cardBackground, in: Circle())
            .overlay(Circle().strokeBorder(done || active ? LHTheme.accent.opacity(0.25) : LHTheme.separator, lineWidth: 1))
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(LHTheme.text)
                Text(detail).font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.accessibilityElement(children: .combine)
    }
}

struct PermissionPrivacyNote: View {
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "lock.shield").font(.system(size: 13)).foregroundStyle(LHTheme.accent).accessibilityHidden(true)
            Text(text).font(.system(size: 11)).foregroundStyle(LHTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Recovery is secondary, not the normal path. No demand to remove and re-add an app.
struct PermissionRecoveryView: View {
    let status: SourceAccessStatus
    var capability: GoalongCapability? = nil
    var expandOnFailure = false
    @State private var expanded = false
    @State private var restarting = false
    @State private var restartError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if expandOnFailure {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "arrow.clockwise").foregroundStyle(LHTheme.accent).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Déjà autorisé ?").font(.system(size: 12, weight: .semibold))
                        Text("Relancez Goalong pour appliquer l’accès. Vous reviendrez ici.")
                            .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Button(restarting ? "Relancement…" : "Relancer Goalong") {
                    if let capability { PermissionRecovery.rememberSetup(capability) }
                    restarting = true
                    PermissionRecovery.restart { error in restartError = error; restarting = error == nil }
                }
                .buttonStyle(.bordered).disabled(restarting)
            }
            GoalongDisclosureGroup("Résoudre un problème", isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Vérifiez que l’autorisation correspond à cette application.")
                        .font(.system(size: 11)).foregroundStyle(LHTheme.secondaryText)
                    Button("Afficher Goalong dans le Finder") { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }
                        .buttonStyle(.bordered)
                    Text(Bundle.main.bundleURL.path).font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(LHTheme.secondaryText).textSelection(.enabled)
                    Text("Relancer ne change ni les sources ni les envois.")
                        .font(.system(size: 11)).foregroundStyle(LHTheme.secondaryText)
                    PermissionRepairControl(status: status, capability: capability)
                }.padding(.top, 8).fixedSize(horizontal: false, vertical: true)
            }.font(.system(size: 11, weight: .medium))
            if !expanded { SupportDiagnosticsExportButton() }
            if let restartError { Text(restartError).font(.system(size: 12)).foregroundStyle(LHTheme.danger).fixedSize(horizontal: false, vertical: true) }
        }
    }
}
#endif
