import Foundation

/// How a configuration path is shown: under the home folder it reads `~/…`.
enum AgentActivityPathLabel {
    static func abbreviated(_ path: String, home: String = NSHomeDirectory()) -> String {
        let home = home.hasSuffix("/") ? String(home.dropLast()) : home
        guard !home.isEmpty else { return path }
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}

/// 6-CODEX: Codex has one row; its sessions folder state is one line in it.
enum AgentActivityCodexFolder {
    static func label(found: Bool, enabled: Bool) -> String {
        guard found else { return "Dossier des conversations non détecté" }
        return enabled ? "Dossier des conversations lu" : "Dossier des conversations détecté, désactivé"
    }
}
