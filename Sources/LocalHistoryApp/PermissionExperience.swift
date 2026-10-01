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
        case .inputMonitoring: return "Surveillance de l’entrée"
        case .fullDiskAccess: return "Accès complet au disque"
        case .screenTimeSetup: return "Activité des apps et des sites web"
        default: return capability == .appleScreenTime ? "Accès complet au disque" : "Accessibilité"
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
    var settingsPath: String { status == .screenTimeSetup ? "Réglages Système  ›  Temps d’écran" : "Confidentialité et sécurité  ›  \(permission)" }
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

/// Recovery advances according to actions actually taken. It never grants access,
/// changes source consent, or repeats reset/relaunch loops automatically.
@MainActor struct PermissionRecoveryView: View {
    let status: SourceAccessStatus
    var capability: GoalongCapability? = nil
    var expandOnFailure = false
    var resumedAfterRestart = false
    @State private var expanded = false
    @State private var restarting = false
    @State private var restartError: String?
    @State private var signatureValid: Bool?
    @State private var advice = PermissionRecoveryAdvice.checking
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: advice == .available ? "checkmark.circle" : "wrench.and.screwdriver")
                .font(.system(size: 13, weight: .semibold))
                .accessibilityIdentifier("permission-recovery-diagnosis")
            Text(detail).font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            switch advice {
            case .repair:
                // Deliberately visible here, not hidden in an already-collapsed disclosure.
                PermissionRepairControl(status: status, capability: capability)
            case .grant:
                Button("Ouvrir les réglages") { openSettings() }.buttonStyle(LHSecondaryButtonStyle())
                Button("J’ai déjà activé cet accès dans macOS") {
                    // This is a report from the user, not an OS permission result.
                    PermissionRecoveryLedger.record(.settingsOpened, for: status)
                    refreshAdvice()
                }.buttonStyle(.plain).font(.system(size: 11))
            case .relaunch:
                restartButton("Relancer et vérifier")
            case .reauthorize:
                Button("Ouvrir les réglages pour réautoriser") { openSettings() }.buttonStyle(LHSecondaryButtonStyle())
                restartButton("Relancer après autorisation")
            case .manualRepair:
                Button("Afficher la copie exacte à ajouter") { reveal() }.buttonStyle(LHSecondaryButtonStyle())
                Button("Ouvrir les réglages") { openSettings() }.buttonStyle(LHSecondaryButtonStyle())
                restartButton("Relancer après remplacement de l’entrée")
            case .installStableCopy, .replaceInvalidBuild, .closeOtherCopy:
                Button("Afficher cette copie dans le Finder") { reveal() }.buttonStyle(LHSecondaryButtonStyle())
            case .checking, .available: EmptyView()
            }
            GoalongDisclosureGroup("Détails de cette installation", isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(Bundle.main.bundleURL.path).font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Text("Une autorisation macOS et votre choix d’enregistrer sont deux contrôles distincts. La réparation ne change ni l’historique, ni les sources, ni les envois.")
                        .font(.system(size: 11)).foregroundStyle(LHTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }.padding(.top, 8)
            }.font(.system(size: 11, weight: .medium))
            if advice != .repair { SupportDiagnosticsExportButton() }
            if let restartError {
                Text(restartError).font(.system(size: 12)).foregroundStyle(LHTheme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear {
            refreshAdvice()
            DispatchQueue.global(qos: .utility).async {
                let valid = SupportBuild.current().signatureValidation == 0
                DispatchQueue.main.async { signatureValid = valid; refreshAdvice() }
            }
        }
        .onReceive(timer) { _ in refreshAdvice() }
        .onChange(of: status) { _ in refreshAdvice() }
    }

    private var title: String {
        switch advice {
        case .checking: return "Vérification en cours"
        case .available: return "Accès reconnu par Goalong"
        case .installStableCopy: return "Installer cette copie dans Applications"
        case .replaceInvalidBuild: return "L’intégrité de cette copie n’est pas confirmée"
        case .closeOtherCopy: return "Plusieurs copies de Goalong sont ouvertes"
        case .grant: return "Autoriser cette application"
        case .relaunch: return "Appliquer l’autorisation au processus actuel"
        case .repair: return "Réparer l’autorisation de cette copie"
        case .reauthorize: return "Réautoriser après la réinitialisation"
        case .manualRepair: return "Le refus persiste après la réparation"
        }
    }
    private var detail: String {
        switch advice {
        case .checking: return "La vérification n’est pas encore terminée. Aucun accès n’est déduit d’un ancien résultat."
        case .available: return "La dernière vérification a reconnu l’accès. Le suivi des interactions est vérifié séparément ; vos choix d’enregistrement restent inchangés."
        case .installStableCopy: return "Placez Goalong History dans Applications, puis ouvrez cette copie avant de lui accorder l’accès. Ne réinitialisez pas les permissions d’une copie temporaire."
        case .replaceInvalidBuild: return "Réinstallez la version officielle avant de modifier les autorisations. Une réinitialisation ne répare pas une application dont la signature n’est pas valide."
        case .closeOtherCopy: return "Quittez les autres copies de Goalong et gardez uniquement celle que vous souhaitez autoriser. Rien ne sera fermé automatiquement."
        case .grant: return "Ouvrez la rubrique correspondant à cet accès et ajoutez la copie de Goalong affichée dans le Finder. Une case déjà cochée peut appartenir à une ancienne copie."
        case .relaunch: return "Après avoir activé l’accès dans macOS, relancez une fois Goalong. Si le refus persiste, le dépannage proposera l’étape suivante plutôt que de répéter les mêmes relancements."
        case .repair: return "L’accès reste indisponible après un relancement ou un changement d’identité de l’app. Une ancienne autorisation est une cause possible, pas une certitude. La réparation ciblée ci-dessous nécessite votre confirmation."
        case .reauthorize: return "macOS a confirmé la suppression de l’ancienne autorisation, pas l’octroi d’un nouvel accès. Autorisez la copie actuelle avec le bouton + si nécessaire, puis relancez Goalong."
        case .manualRepair: return "Ne répétez pas les réinitialisations. Dans les réglages, supprimez uniquement l’entrée Goalong avec −, ajoutez la copie exacte avec + puis autorisez-la. Si les commandes sont verrouillées, vérifiez avec l’administrateur du Mac. Si le refus continue, exportez le diagnostic ; l’app ne peut pas déterminer à elle seule la cause interne du refus macOS."
        }
    }
    private func refreshAdvice() {
        let snapshot = PermissionManager.shared.snapshot
        var progress = PermissionRecoveryLedger.load(status)
        if resumedAfterRestart { progress.relaunches = max(1, progress.relaunches) }
        let available = status == .accessibility ? snapshot.accessibility
            : status == .inputMonitoring ? snapshot.inputMonitoringDirectlyGranted : false
        let runtime = SupportDiagnosticsRuntime.shared.snapshot()
        advice = PermissionRecoveryAdvice.resolve(accessAvailable: available,
            observationPending: status == .fullDiskAccess ? false : snapshot.observationPending,
            stableInstallation: PermissionRepair.canResetInstallation(path: Bundle.main.bundleURL.path),
            signatureValid: signatureValid,
            runningCopies: NSRunningApplication.runningApplications(withBundleIdentifier: PermissionRepair.bundleIdentifier).count,
            identityChanged: status == .accessibility && runtime[.permissionIdentityChanged] == .flag(true),
            progress: progress)
    }
    private func reveal() { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }
    private func openSettings() {
        if let capability { PermissionRecovery.rememberSetup(capability) }
        SourceAccessService.openAccess(status)
        refreshAdvice()
    }
    private func restartButton(_ title: String) -> some View {
        Button(restarting ? "Préparation du relancement…" : title) {
            if let capability { PermissionRecovery.rememberSetup(capability) }
            restarting = true
            PermissionRecovery.restart(permission: status) { error in
                restartError = error; restarting = error == nil
                refreshAdvice()
            }
        }.buttonStyle(LHSecondaryButtonStyle()).disabled(restarting)
    }
}
#endif
