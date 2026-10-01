#if os(macOS)
import AppKit
import LocalHistoryCore
import SwiftUI

/// One calm line at the top of every page when something needs the user: nothing is
/// being recorded, the disk is nearly full, or an update just finished. Each state
/// says what happens next and offers the single most useful action.
struct GoalongAttentionBanner: View {
    @ObservedObject var model: DashboardViewModel
    @ObservedObject private var updates = SoftwareUpdateManager.shared
    @ObservedObject private var consents = GoalongCapabilityConsentStore.shared

    private enum Notice: Equatable {
        case storage(CaptureStorageFailureKind)
        case lowSpace(Int64)
        case updated(from: String, to: String)
    }

    private var notice: Notice? {
        if consents.isEnabled(.localComputerHistory), let kind = model.runtime.storageFailure { return .storage(kind) }
        if consents.isEnabled(.localComputerHistory), let free = model.freeDiskBytes, StorageHealth.isLow(free) { return .lowSpace(free) }
        if let previous = updates.updatedFromVersion { return .updated(from: previous, to: updates.currentVersion) }
        return nil
    }

    var body: some View {
        if let notice {
            VStack(spacing: 0) {
                HStack(alignment: .center, spacing: 14) {
                    Image(systemName: symbol(notice)).font(.system(size: 16, weight: .semibold)).foregroundStyle(tint(notice))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title(notice)).font(.system(size: 13, weight: .semibold))
                        Text(detail(notice)).font(.system(size: 12)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    actions(notice)
                }
                .padding(.horizontal, LHTheme.pageInset).padding(.vertical, 12)
                .background(tint(notice).opacity(0.08))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("attention-banner")
                Divider()
            }
        }
    }

    private func symbol(_ notice: Notice) -> String {
        switch notice {
        case .storage: return "externaldrive.badge.exclamationmark"
        case .lowSpace: return "externaldrive.badge.minus"
        case .updated: return "checkmark.seal.fill"
        }
    }

    private func tint(_ notice: Notice) -> Color {
        switch notice {
        case .storage: return LHTheme.danger
        case .lowSpace: return LHTheme.warning
        case .updated: return LHTheme.success
        }
    }

    private func title(_ notice: Notice) -> String {
        switch notice {
        case .storage(.diskFull): return "Enregistrement interrompu : le disque est plein"
        case .storage: return "Enregistrement interrompu"
        case .lowSpace: return "Espace disque presque plein"
        case .updated(_, let version): return "Goalong est à jour · version \(version)"
        }
    }

    private func detail(_ notice: Notice) -> String {
        switch notice {
        case .storage(.diskFull):
            return "Libérez un peu d’espace : l’enregistrement reprendra tout seul et la coupure sera indiquée dans votre historique."
        case .storage:
            return "Goalong réessaie automatiquement. Si cela dure, envoyez-nous un rapport : il contient la cause technique, pas votre activité."
        case .lowSpace(let free):
            return "Il reste \(StorageHealth.formatted(free)). En dessous d’environ 1 Go, macOS peut empêcher Goalong d’enregistrer."
        case .updated(let previous, _):
            return "La mise à jour depuis la version \(previous) s’est bien déroulée. Vos réglages et votre historique sont conservés."
        }
    }

    @ViewBuilder private func actions(_ notice: Notice) -> some View {
        switch notice {
        case .storage(let kind):
            HStack(spacing: 8) {
                if kind == .diskFull { manageStorageButton(primary: true) }
                Button("Signaler le problème…") { SupportRequestController.shared.present() }
                    .buttonStyle(LHSecondaryButtonStyle())
            }
        case .lowSpace:
            manageStorageButton(primary: false)
        case .updated:
            HStack(spacing: 8) {
                Button("Nouveautés") { updates.openRollingReleasePage() }.buttonStyle(LHSecondaryButtonStyle())
                Button { updates.acknowledgeUpdateConfirmation() } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(LHQuietButtonStyle())
                .accessibilityLabel("Masquer")
            }
        }
    }

    @ViewBuilder private func manageStorageButton(primary: Bool) -> some View {
        let button = Button("Gérer le stockage…") {
            GoalongWorkspaceOpenPolicy.open(URL(string: "x-apple.systempreferences:com.apple.settings.Storage")!, purpose: .systemSettings)
        }
        if primary { button.buttonStyle(LHPrimaryButtonStyle()) } else { button.buttonStyle(LHSecondaryButtonStyle()) }
    }
}
#endif
