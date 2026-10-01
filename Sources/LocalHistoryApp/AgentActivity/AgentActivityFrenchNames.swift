#if os(macOS)
    import AgentActivity

    // The shared AgentActivity module keeps its stable English names for the CLI
    // and stored metadata; the French interface uses these labels instead.
    extension AgentProvider {
        var frenchName: String { self == .custom ? "Autre agent" : displayName }
    }

    extension AgentSourceAvailability {
        var frenchName: String {
            switch self {
            case .available: return "Disponible"
            case .missing: return "Source absente"
            case .inaccessible: return "Inaccessible"
            }
        }
    }

    extension AgentCaptureMode {
        var frenchName: String {
            switch self {
            case .transcriptsAndLogs: return "Conversations et journaux"
            case .everyFile: return "Tous les fichiers pris en charge"
            }
        }
    }

    extension AgentIntegrationKind {
        var frenchName: String {
            switch self {
            case .codexHooks: return "Hooks Codex"
            case .claudeCodeHooks: return "Hooks Claude Code"
            case .cursorHooks: return "Hooks Cursor"
            case .openCodePlugin: return "Plugin OpenCode"
            }
        }
    }
#endif
