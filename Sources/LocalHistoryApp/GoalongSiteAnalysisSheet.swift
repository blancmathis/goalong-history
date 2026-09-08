#if os(macOS)
import AppKit
import Combine
import Darwin
import Foundation
import LocalHistoryCore
import SwiftUI

/// Holds only the file explicitly selected for this operation. No native history store is consulted.
final class GoalongSiteAnalysisModel: ObservableObject {
    @Published private(set) var request: GoalongSiteAnalysisRequest?
    @Published private(set) var busy = false
    @Published private(set) var connected = false
    @Published private(set) var accountLabel = "Connexion locale non vérifiée"
    @Published private(set) var hasDraft = false
    @Published var reviewed = false
    @Published var title = ""
    @Published var summary = ""
    @Published var outcomes = ""
    @Published var error: String?
    @Published var status: String?

    private let queue = DispatchQueue(label: "ai.goalong.selected-site-analysis", qos: .userInitiated)
    private let sessionLock = NSLock()
    private var activeSession: CodexAppServerSession?
    private var activeOperationID: UUID?
    private var operationID = UUID()
    private let consent: () -> Bool
    private let makeSession: () throws -> CodexAppServerSession

    init(
        consent: @escaping () -> Bool = { GoalongCapabilityConsentStore.shared.isEnabled(.chatGPTAnalysis) },
        makeSession: @escaping () throws -> CodexAppServerSession = {
            guard let executable = CodexExecutableLocator.locate() else {
                throw CodexAppServerError.executableUnavailable
            }
            try ChatGPTSecureStorage.prepareDirectory(AppPaths.chatGPTDirectory)
            return try CodexAppServerSession(
                executableURL: executable,
                codexHomeURL: AppPaths.chatGPTDirectory.appendingPathComponent("site-analysis-codex-home", isDirectory: true),
                siteAnalysisOnly: true
            )
        }
    ) {
        self.consent = consent
        self.makeSession = makeSession
    }

    func load(_ url: URL) {
        guard !busy else { return }
        request = nil
        clearDraft()
        let id = begin()
        queue.async {
            let result = Result { try GoalongSiteAnalysisRequest.readSelectedFile(url) }
            DispatchQueue.main.async {
                guard self.operationID == id else { return }
                self.busy = false
                switch result {
                case .success(let selected): self.request = selected
                case .failure: self.error = "Cette demande est invalide ou ne peut pas être lue en sécurité. Choisissez le fichier JSON téléchargé depuis le site, de 256 Kio maximum."
                }
            }
        }
    }

    func connect() {
        guard !busy, consent() else {
            error = "Activez d’abord ChatGPT analysis dans les capacités facultatives des Réglages."
            return
        }
        let id = begin()
        queue.async {
            do {
                let session = try self.makeSession()
                try self.attach(session, for: id)
                defer { self.detach(session) }
                var account = try session.readAccount()
                if account?.isManagedChatGPT != true {
                    let login = try session.beginChatGPTLogin()
                    let opened = DispatchQueue.main.sync {
                        self.operationID == id && self.consent()
                            && GoalongWorkspaceOpenPolicy.open(login.authorizationURL, purpose: .accountAuthorization)
                    }
                    guard opened else { throw CodexAppServerError.loginFailed("The official login page could not be opened.") }
                    account = try session.waitForChatGPTLogin(loginID: login.loginID)
                }
                guard let account, account.isManagedChatGPT else {
                    throw CodexAppServerError.accountNotChatGPT("non-ChatGPT")
                }
                DispatchQueue.main.async {
                    guard self.operationID == id else { return }
                    self.busy = false
                    self.connected = true
                    self.accountLabel = "ChatGPT connecté" + (account.displayPlan.map { " · \($0)" } ?? "")
                }
            } catch { self.fail(id, "La connexion ChatGPT n’a pas abouti. Vérifiez que Codex est installé et à jour, puis réessayez.") }
        }
    }

    func disconnect() {
        guard !busy else { return }
        let id = begin()
        queue.async {
            do {
                let session = try self.makeSession()
                try self.attach(session, for: id)
                defer { self.detach(session) }
                try session.logout()
                DispatchQueue.main.async {
                    guard self.operationID == id else { return }
                    self.busy = false
                    self.connected = false
                    self.reviewed = false
                    self.accountLabel = "ChatGPT déconnecté de cette fonction"
                }
            } catch { self.fail(id, "La déconnexion n’a pas abouti. Réessayez avant de fermer cette fenêtre.") }
        }
    }

    func analyze() {
        guard !busy, let selected = request, reviewed, connected, consent() else {
            error = "Vérifiez la demande, la connexion ChatGPT et votre autorisation avant de lancer l’analyse."
            return
        }
        let id = begin()
        clearDraft()
        // The exact selected value is captured now. No path or native source enters this operation.
        queue.async {
            var directory: URL?
            defer { if let directory { try? FileManager.default.removeItem(at: directory) } }
            do {
                let workspace = try Self.makeWorkingDirectory()
                directory = workspace
                guard DispatchQueue.main.sync(execute: { self.operationID == id && self.consent() }) else {
                    throw CodexAppServerError.generationFailed("Analysis cancelled.")
                }
                let session = try self.makeSession()
                try self.attach(session, for: id)
                defer { self.detach(session) }
                let draft = try session.generateSiteAnalysis(request: selected, workingDirectory: workspace)
                DispatchQueue.main.async {
                    guard self.operationID == id else { return }
                    self.busy = false
                    guard self.consent() else { return }
                    self.title = draft.title
                    self.summary = draft.summary
                    self.outcomes = draft.outcomes.joined(separator: "\n")
                    self.hasDraft = true
                    self.status = "Brouillon prêt. Relisez-le avant de l’exporter ; rien n’a été envoyé au site."
                }
            } catch { self.fail(id, "L’analyse n’a pas abouti. Vérifiez la connexion, les limites du compte et la disponibilité de GPT-5.6 Luna High dans Codex. Aucun brouillon n’a été enregistré ni envoyé.") }
        }
    }

    func reviewedExport() throws -> Data {
        guard !busy, hasDraft, let request else {
            throw CodexAppServerError.generationFailed("No complete draft is ready to export.")
        }
        let draft = try GoalongSiteAnalysisDraft(
            title: title, summary: summary,
            outcomes: outcomes.split(separator: "\n").map(String.init)
        )
        return try draft.siteImport(for: request)
    }

    func cancel() {
        operationID = UUID()
        sessionLock.lock()
        let session = activeSession
        activeSession = nil
        activeOperationID = nil
        sessionLock.unlock()
        session?.close()
        busy = false
        reviewed = false
    }

    private func begin() -> UUID {
        operationID = UUID()
        sessionLock.lock(); activeOperationID = operationID; sessionLock.unlock()
        busy = true
        error = nil
        status = nil
        return operationID
    }

    static func makeWorkingDirectory() throws -> URL {
        // Foundation can preserve /var in this system path. Resolve it before the
        // existing secure storage walks every component with O_NOFOLLOW.
        var canonical = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(FileManager.default.temporaryDirectory.path, &canonical) != nil else {
            throw CocoaError(.fileReadUnknown)
        }
        let directory = URL(fileURLWithPath: String(cString: canonical), isDirectory: true)
            .appendingPathComponent("goalong-site-analysis-\(UUID().uuidString)", isDirectory: true)
        try ChatGPTSecureStorage.prepareDirectory(directory)
        return directory
    }

    private func clearDraft() {
        reviewed = false
        hasDraft = false
        title = ""; summary = ""; outcomes = ""
    }

    private func attach(_ session: CodexAppServerSession, for id: UUID) throws {
        sessionLock.lock()
        guard activeOperationID == id else {
            sessionLock.unlock()
            session.close()
            throw CodexAppServerError.generationFailed("Analysis cancelled.")
        }
        activeSession = session
        sessionLock.unlock()
    }

    private func detach(_ session: CodexAppServerSession) {
        session.close()
        sessionLock.lock()
        if activeSession === session { activeSession = nil }
        sessionLock.unlock()
    }

    private func fail(_ id: UUID, _ message: String) {
        DispatchQueue.main.async {
            guard self.operationID == id else { return }
            self.busy = false
            self.reviewed = false
            self.error = message
        }
    }
}

struct GoalongSiteAnalysisSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = GoalongSiteAnalysisModel()
    @StateObject private var windowHost = GoalongWebsiteWindowHost()
    @ObservedObject private var consents = GoalongCapabilityConsentStore.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Analyser une demande du site").font(.title2.weight(.semibold))
                Spacer()
                Button("Fermer") { model.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Votre abonnement ChatGPT est utilisé via Codex sur ce Mac. Cette connexion est propre aux demandes du site : vos identifiants restent gérés par Codex, sans être transmis à Goalong en ligne.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    if !consents.isEnabled(.chatGPTAnalysis) {
                        Text("Avant de vous connecter, activez ChatGPT analysis dans les capacités facultatives des Réglages. Vous pourrez ensuite autoriser chaque analyse ici.")
                            .font(.subheadline).foregroundStyle(LHTheme.warning)
                    }
                    HStack {
                        Text(model.accountLabel).font(.subheadline)
                        Spacer()
                        if model.connected {
                            Button("Se déconnecter", action: model.disconnect)
                        } else {
                            Button("Se connecter à ChatGPT", action: model.connect)
                                .disabled(!consents.isEnabled(.chatGPTAnalysis))
                        }
                    }.disabled(model.busy)
                    if model.busy {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("Opération en cours…").font(.caption)
                            Button("Annuler l’opération", action: model.cancel)
                        }
                    }
                    Button("Installer ou mettre à jour Codex") {
                        if let url = URL(string: "https://developers.openai.com/codex/cli") {
                            _ = GoalongWorkspaceOpenPolicy.open(url, purpose: .documentation)
                        }
                    }.buttonStyle(.borderless)
                    Text("1. Ouvrez le fichier téléchargé sur le site").font(.headline)
                    Button("Choisir la demande…", action: chooseRequest).disabled(model.busy)
                    if let selected = model.request {
                        Text("\(selected.date) · \(selected.timezone)").font(.subheadline.weight(.medium))
                        Text("2. Vérifiez les données qui seront envoyées").font(.headline)
                        Text("Ce fichier est la seule source de cette analyse. Les archives locales, conversations, notes et données Strava ne sont pas ajoutées.")
                            .font(.caption).foregroundStyle(.secondary)
                        ScrollView([.vertical, .horizontal]) {
                            Text(selected.previewJSON).font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled).padding(12)
                        }
                        .frame(height: 230)
                        .background(LHTheme.pageBackground, in: RoundedRectangle(cornerRadius: 8))
                        Toggle("J’autorise l’envoi des seules données affichées à ChatGPT pour cette analyse", isOn: $model.reviewed)
                            .disabled(model.busy)
                        Text("GPT-5.6 Luna · High · utilisation décomptée selon votre compte ChatGPT. La disponibilité et les limites dépendent de votre abonnement.")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("Analyser avec ChatGPT", action: model.analyze)
                                .buttonStyle(.borderedProminent)
                                .disabled(model.busy || !model.reviewed || !model.connected || !consents.isEnabled(.chatGPTAnalysis))
                        }
                    }
                    if model.hasDraft {
                        Divider()
                        Text("3. Relisez votre brouillon").font(.headline)
                        TextField("Titre", text: $model.title).textFieldStyle(.roundedBorder)
                        TextEditor(text: $model.summary).frame(minHeight: 150)
                            .accessibilityLabel("Résumé du brouillon")
                        Text("Résultats à retenir, un par ligne").font(.caption)
                        TextEditor(text: $model.outcomes).frame(minHeight: 80)
                            .accessibilityLabel("Résultats du brouillon")
                        Text("Le fichier exporté contiendra uniquement votre récap. Aucune mesure ni vérification n’est créée. Importez-le ensuite sur le site ; vos règles de partage s’y appliqueront.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Exporter le brouillon…", action: exportDraft).buttonStyle(.borderedProminent)
                    }
                    if let error = model.error {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(LHTheme.warning)
                    }
                    if let status = model.status {
                        Label(status, systemImage: "checkmark.circle").foregroundStyle(LHTheme.success)
                    }
                }.padding(24)
            }
        }
        .frame(width: 700, height: 780)
        .background(GoalongWebsiteWindowReader(host: windowHost).frame(width: 0, height: 0))
        .onDisappear { model.cancel() }
        .onChange(of: consents.document) { _ in
            if !consents.isEnabled(.chatGPTAnalysis) { model.cancel() }
        }
    }

    private func chooseRequest() {
        guard let window = windowHost.window else { return }
        let panel = NSOpenPanel()
        panel.title = "Choisir la demande d’analyse Goalong"
        panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false; panel.resolvesAliases = false
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let file = panel.url else { return }
            model.load(file)
        }
    }

    private func exportDraft() {
        guard let window = windowHost.window else { return }
        do {
            let data = try model.reviewedExport()
            let panel = NSSavePanel()
            panel.title = "Exporter le brouillon relu"
            panel.nameFieldStringValue = "goalong-analyse-\(model.request?.date ?? "jour").json"
            panel.beginSheetModal(for: window) { response in
                guard response == .OK, let file = panel.url else { return }
                do {
                    try GoalongSiteAnalysisExportWriter.write(data, to: file)
                    model.status = "Brouillon exporté. Vous pouvez maintenant l’importer sur le site."
                } catch { model.error = "Le brouillon n’a pas pu être enregistré dans le fichier choisi." }
            }
        } catch { model.error = "Vérifiez les limites : titre 160 caractères, résumé 3 000 caractères, et 12 résultats de 300 caractères maximum." }
    }
}

enum GoalongSiteAnalysisExportWriter {
    /// Only the selected output file changes. In particular, do not chmod Downloads or its parent.
    static func write(_ data: Data, to destination: URL) throws {
        guard destination.isFileURL else { throw CocoaError(.fileWriteInvalidFileName) }
        let parent = destination.deletingLastPathComponent()
        let temporary = parent.appendingPathComponent(".goalong-export-\(UUID().uuidString)")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        defer { close(fd); try? FileManager.default.removeItem(at: temporary) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw CocoaError(.fileWriteUnknown) }
                offset += count
            }
        }
        guard fsync(fd) == 0 else { throw CocoaError(.fileWriteUnknown) }
        var existing = stat()
        let exists = lstat(destination.path, &existing) == 0
        guard (!exists && errno == ENOENT) || (exists && (existing.st_mode & S_IFMT) == S_IFREG && existing.st_uid == geteuid()) else {
            throw CocoaError(.fileWriteNoPermission)
        }
        guard rename(temporary.path, destination.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
}
#endif
