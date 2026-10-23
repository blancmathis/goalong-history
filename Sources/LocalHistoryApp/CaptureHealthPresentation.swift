#if os(macOS)
    import LocalHistoryCore

    // LocalHistoryCore keeps stable English diagnostics for the CLI and support
    // reports; the French interface explains each state in plain words.
    extension CaptureHealthState {
        var frenchTitle: String {
            switch self {
            case .ready: return "Enregistrement opérationnel"
            case .permissionRequired: return "Autorisation Accessibilité requise"
            case .permissionAppearsEnabledButStaleForBuild: return "Autorisation liée à une ancienne version de l’app"
            case .inputTapUnavailable: return "Interactions non reçues"
            case .accessibilityContextUnavailable: return "Contexte de la fenêtre illisible"
            case .paused: return "Enregistrement en pause"
            case .excludedPrivateOrSecure: return "Détails masqués (exclusion, fenêtre privée ou champ sécurisé)"
            case .healthyButIdle: return "Enregistrement opérationnel, sans activité récente"
            case .awaitingInputEvidence: return "En attente de la première interaction"
            case .storageUnavailable: return "Enregistrement interrompu"
            }
        }

        var frenchDetail: String {
            switch self {
            case .ready:
                return "Une vraie interaction et le contexte de la fenêtre active ont été observés."
            case .permissionRequired:
                return "L’accessibilité n’est pas activée pour cette copie de Goalong. Rien n’est enregistré en attendant."
            case .permissionAppearsEnabledButStaleForBuild:
                return "macOS semble associer l’autorisation à une version précédente de Goalong. Réaccordez l’accès à cette version ; l’historique existant reste lisible."
            case .inputTapUnavailable:
                return "Les clics et la frappe ne parviennent pas à Goalong. Vérifiez la Surveillance de l’entrée dans Réglages Système."
            case .accessibilityContextUnavailable:
                return "L’accessibilité semble activée, mais Goalong ne parvient pas à lire l’app au premier plan."
            case .paused:
                return "L’enregistrement est volontairement en pause. L’historique existant reste consultable."
            case .excludedPrivateOrSecure:
                return "Le suivi détaillé est volontairement masqué : app ou site exclu, navigation privée ou saisie sécurisée active (mot de passe, terminal). L’enregistrement reprend automatiquement."
            case .healthyButIdle:
                return "Tout fonctionne ; aucune interaction n’a été reçue depuis quelques minutes."
            case .awaitingInputEvidence:
                return "La capture est prête ; elle sera confirmée dès la première interaction réelle (clic ou frappe)."
            case .storageUnavailable:
                return "L’historique ne peut pas être écrit (disque plein ?). L’enregistrement reprendra tout seul dès que possible."
            }
        }
    }

    extension SuppressionReason {
        var frenchLabel: String {
            switch self {
            case .privateBrowserWindow: return "fenêtre privée"
            case .excludedApplication: return "app exclue"
            case .excludedDomain: return "site exclu"
            case .secureInput: return "saisie sécurisée"
            case .sessionUnavailable: return "session indisponible"
            case .manualPause: return "pause manuelle"
            case .accessibilityUnavailable: return "Accessibilité indisponible"
            }
        }
    }

    extension CaptureEventTapLifecycle {
        var frenchLabel: String {
            switch self {
            case .neverAttempted: return "jamais essayée"
            case .creationFailed: return "création impossible"
            case .createdDisabled: return "créée, désactivée"
            case .createdEnabled: return "active"
            }
        }
    }

    extension BuildSignatureKind {
        var frenchLabel: String {
            switch self {
            case .adHoc: return "signature locale"
            case .appleDevelopment: return "développement Apple"
            case .developerID: return "Developer ID"
            case .appStore: return "App Store"
            case .other: return "autre signature"
            case .unsigned: return "non signée"
            }
        }
    }
#endif
