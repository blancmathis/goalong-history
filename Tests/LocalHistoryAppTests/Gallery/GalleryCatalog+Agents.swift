#if os(macOS)
import AgentActivity
import Foundation
import SwiftUI
@testable import LocalHistoryApp

/// Conversations IA with indexed conversations: the index the app keeps (one entry per conversation), written through
/// `AgentActivityStore` before the page opens. Nothing is read from a real tool's folder.
extension GalleryCatalog {
    /// Two tools, three conversations touched this morning, the way the scanner indexes them.
    private static func seedAgentIndex(_ ctx: GalleryContext) throws {
        let store = try AgentActivityStore(rootDirectory: AppPaths.agentActivityDirectory)
        let codexRoot = ctx.home.appendingPathComponent(".codex/sessions", isDirectory: true)
        let claudeRoot = ctx.home.appendingPathComponent(".claude/projects", isDirectory: true)
        let codex = AgentWatchedFolder(id: "galerie-codex", displayName: "Codex", path: codexRoot.path, provider: .codex,
                                       addedAt: GalleryClock.at(8, 0))
        let claude = AgentWatchedFolder(id: "galerie-claude", displayName: "Claude Code", path: claudeRoot.path,
                                        provider: .claudeCode, addedAt: GalleryClock.at(8, 0))
        _ = try store.saveConfiguration(AgentActivityConfiguration(watchedFolders: [codex, claude]))
        let rows: [(AgentWatchedFolder, URL, String, Int, Int, Int64)] = [
            (codex, codexRoot, "2026/10/23/rollout-atlas-planning.jsonl", 9, 12, 184_320),
            (claude, claudeRoot, "atlas/session-vue-planning.jsonl", 8, 47, 96_256),
            (codex, codexRoot, "2026/10/23/rollout-revue-tests.jsonl", 8, 20, 52_480),
        ]
        for (index, row) in rows.enumerated() {
            let (folder, root, relative, hour, minute, bytes) = row
            let entry = AgentSourceIndexEntry(
                id: "galerie-\(index)", stableConversationID: "galerie-conversation-\(index)", watchedFolderID: folder.id,
                watchedFolderName: folder.displayName, provider: folder.provider,
                reference: AgentSourceReference(kind: .file, path: root.appendingPathComponent(relative).path),
                relativePath: relative, sourceCreatedAt: GalleryClock.at(hour - 1, minute),
                sourceModifiedAt: GalleryClock.at(hour, minute), firstIndexedAt: GalleryClock.at(hour, minute),
                lastObservedAt: GalleryClock.at(hour, minute), byteCount: bytes,
                sha256: String(repeating: String(index + 1), count: 64))
            _ = try store.upsert(AgentCaptureRecord(index: entry, isAnalyzed: false), maximumEntries: 100)
        }
    }

    static var agentEntries: [GalleryEntry] {
        [
            dashboard("conversations-ia/indexees", section: .agentActivity, fixture: .recordingOn,
                      note: "trois conversations indexées (Codex et Claude Code), sans lecture de leur contenu",
                      prepare: { ctx in
                GoalongCapabilityConsentStore.shared.set(.aiConversations, enabled: true, surface: .settings)
                try seedAgentIndex(ctx)
                AgentActivityPage.galleryShowsHomeAsTilde = true
                ctx.cleanups.append { AgentActivityPage.galleryShowsHomeAsTilde = false }
            }),
        ]
    }
}
#endif
