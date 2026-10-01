#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Private copies of the reports the user prepared, so Mail, Messages or AirDrop can
/// attach a real file. Only the five most recent reports are kept.
enum SupportReportStore {
    static var directory: URL { AppPaths.applicationSupportDirectory.appendingPathComponent("SupportReports", isDirectory: true) }
    static let retainedReports = 5

    static func save(_ data: Data, createdAt: Date = Date(), in directory: URL = SupportReportStore.directory) throws -> URL {
        try SupportDiagnostics.preparePrivateDirectory(directory)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let url = directory.appendingPathComponent("Goalong-diagnostic-\(formatter.string(from: createdAt)).json")
        try SupportReportWriter.write(data, to: url)
        prune(in: directory)
        return url
    }

    static func prune(in directory: URL = SupportReportStore.directory) {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasPrefix("Goalong-diagnostic-") && $0.hasSuffix(".json") }
            .sorted(by: >)
        for name in names.dropFirst(retainedReports) {
            _ = unlink(directory.appendingPathComponent(name).path)
        }
    }
}

/// One entry point for every "something is wrong" path: Help menu, menu bar,
/// settings, permission recovery and startup failure. It prepares the report,
/// explains in plain French what was detected and what the file contains, then lets
/// the user send it with the tools they already use. Nothing is sent automatically.
@MainActor final class SupportRequestController: ObservableObject {
    static let shared = SupportRequestController()

    enum Phase: Equatable {
        case idle, preparing
        case ready(URL, [SupportFinding], byteCount: Int, eventCount: Int)
        case failed(String)
    }

    /// Driven by this controller; internal so isolated renders can show each state.
    @Published var phase: Phase = .idle
    @Published var feedback: String?
    private var window: NSWindow?
    private var onClose: (() -> Void)?
    private var closeObserver: NSObjectProtocol?

    var isPreparing: Bool { phase == .preparing }

    func present(onClose: (() -> Void)? = nil) {
        if let onClose { self.onClose = onClose }
        if let window {
            NSApplication.shared.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let host = NSHostingController(rootView: SupportRequestView(controller: self).goalongControls())
        let window = NSWindow(contentViewController: host)
        window.title = "Signaler un problème"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 580, height: 660))
        window.center()
        window.identifier = NSUserInterfaceItemIdentifier("goalong-support-request")
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                                               object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.windowDidClose() }
        }
        self.window = window
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        prepare()
    }

    func prepare() {
        guard phase != .preparing else { return }
        phase = .preparing; feedback = nil
        let live = SupportDiagnosticsRuntime.shared.snapshot()
        let previousBuild = SupportDiagnosticsRuntime.shared.previousWorkingBuildProvider?()
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<(URL, SupportReport, Int), Error> in
                Result {
                    let report = SupportReport.build(live: live, previousWorkingBuild: previousBuild)
                    let data = try report.data()
                    return (try SupportReportStore.save(data, createdAt: report.createdAt), report, data.count)
                }
            }.value
            switch result {
            case .success(let (url, report, bytes)):
                SupportDiagnostics.shared.record(.reportExported, component: .support, values: [.byteCount: .count(bytes)])
                phase = .ready(url, report.summary, byteCount: bytes, eventCount: report.timeline.count)
            case .failure(let error):
                SupportDiagnostics.shared.failure(error, component: .support)
                phase = .failed("Le rapport n’a pas pu être préparé (\(StorageHealth.failureKind(for: error) == .diskFull ? "disque plein" : "erreur d’écriture")). Rien n’a été envoyé.")
            }
        }
    }

    /// Opens a new message in the user's mail app with the report attached and a
    /// short, editable description template.
    func sendByEmail() {
        guard case .ready(let url, let findings, _, _) = phase else { return }
        let body = Self.messageBody(findings: findings, fileName: url.lastPathComponent)
        guard let service = NSSharingService(named: .composeEmail),
              service.canPerform(withItems: [body, url]) else {
            feedback = "Aucune app de messagerie n’est configurée. Utilisez « Partager » ou « Enregistrer une copie »."
            return
        }
        service.subject = "Goalong History \(SoftwareUpdateManager.shared.currentVersion) — rapport de diagnostic"
        service.perform(withItems: [body, url])
        feedback = "Un message avec le rapport en pièce jointe a été préparé. Décrivez le problème, puis envoyez-le."
    }

    func saveCopy() {
        guard case .ready(let url, _, _, _) = phase else { return }
        let panel = NSSavePanel()
        panel.title = "Enregistrer une copie du diagnostic"
        panel.nameFieldStringValue = url.lastPathComponent
        panel.allowedContentTypes = [.json]; panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url,
              let data = try? SupportDiagnostics.readPrivateFile(url, maximum: 16 * 1_024 * 1_024) else { return }
        do {
            try SupportReportWriter.write(data, to: destination)
            feedback = "Copie enregistrée."
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        } catch {
            SupportDiagnostics.shared.failure(error, component: .support)
            feedback = "La copie n’a pas pu être enregistrée. Essayez un autre dossier."
        }
    }

    func revealReport() {
        guard case .ready(let url, _, _, _) = phase else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func markIssue() {
        SupportDiagnostics.shared.record(.userMarkedIssue, component: .support)
        feedback = "Repère ajouté à \(DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short)). Reproduisez le problème puis cliquez sur « Actualiser le rapport »."
    }

    func close() { window?.close() }

    private func windowDidClose() {
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
        window = nil
        phase = .idle
        feedback = nil
        let callback = onClose; onClose = nil
        callback?()
    }

    static func messageBody(findings: [SupportFinding], fileName: String) -> String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let detected = findings.map { "• \($0.title) — \($0.detail)" }.joined(separator: "\n")
        return """
        Bonjour,

        [Décrivez en quelques mots ce que vous faisiez, ce qui s’est passé et ce que vous attendiez.]

        — Ce que Goalong a détecté —
        \(detected)

        Goalong History \(SoftwareUpdateManager.shared.currentVersion) · macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)
        Rapport joint : \(fileName) (aucun contenu d’activité, aucune adresse web, aucun texte saisi)
        """
    }
}

struct SupportRequestView: View {
    @ObservedObject var controller: SupportRequestController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    detected
                    contents
                    if let feedback = controller.feedback {
                        Label(feedback, systemImage: "checkmark.circle")
                            .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("support-feedback")
                    }
                }
                .padding(.horizontal, 28).padding(.top, 34).padding(.bottom, 20)
            }
            Divider()
            actions.padding(.horizontal, 28).padding(.vertical, 16)
        }
        .frame(minWidth: 540, minHeight: 600)
        .background(LHTheme.pageBackground)
        .foregroundStyle(LHTheme.text)
        .tint(LHTheme.accent)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "stethoscope")
                .font(.system(size: 22, weight: .medium)).foregroundStyle(LHTheme.accent)
                .frame(width: 44, height: 44)
                .background(LHTheme.elevatedBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 6) {
                Text("Signaler un problème").font(.system(size: 22, weight: .semibold))
                Text("Goalong prépare un rapport technique pour comprendre ce qui s’est passé. Vous le relisez et choisissez à qui l’envoyer : rien ne part automatiquement.")
                    .font(.system(size: 13)).foregroundStyle(LHTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var detected: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ce que Goalong a détecté").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
            LHCard(padding: 16) {
                switch controller.phase {
                case .idle, .preparing:
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Analyse des journaux techniques…").font(.system(size: 13)).foregroundStyle(LHTheme.secondaryText)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                case .failed(let message):
                    VStack(alignment: .leading, spacing: 10) {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 13)).foregroundStyle(LHTheme.danger)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Réessayer") { controller.prepare() }.buttonStyle(LHSecondaryButtonStyle())
                    }
                case .ready(_, let findings, _, _):
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(findings.enumerated()), id: \.offset) { _, finding in
                            SupportFindingRow(finding: finding)
                        }
                    }
                    .accessibilityIdentifier("support-findings")
                }
            }
        }
    }

    private var contents: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ce que contient le rapport").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
            LHCard(padding: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    contentLine("checkmark.circle.fill", LHTheme.success,
                                "Version de Goalong et de macOS, états des sources et des autorisations, erreurs et leurs codes, mises à jour, espace disque, indices de plantage — sur les 7 derniers jours.")
                    contentLine("xmark.circle.fill", LHTheme.danger,
                                "Jamais : votre historique, les apps ou sites visités, titres, textes, conversations, captures d’écran, e-mails, mots de passe ou clés.")
                    if case .ready(_, _, let bytes, let events) = controller.phase {
                        HStack(spacing: 12) {
                            Text("\(events) événements techniques · \(GoalongUIFormat.bytes(Int64(bytes)))")
                                .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                            Spacer()
                            Button("Afficher le fichier") { controller.revealReport() }
                                .buttonStyle(.link).font(.system(size: 12))
                                .accessibilityIdentifier("support-reveal")
                        }
                    }
                }
            }
        }
    }

    private func contentLine(_ symbol: String, _ tint: Color, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Image(systemName: symbol).foregroundStyle(tint).font(.system(size: 12))
            Text(text).font(.system(size: 12.5)).foregroundStyle(LHTheme.text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var actions: some View {
        let ready: URL? = { if case .ready(let url, _, _, _) = controller.phase { return url }; return nil }()
        return HStack(spacing: 10) {
            Menu {
                Button("Ajouter un repère maintenant") { controller.markIssue() }
                Button("Actualiser le rapport") { controller.prepare() }
                Divider()
                Button("Enregistrer une copie…") { controller.saveCopy() }.disabled(ready == nil)
            } label: { Text("Plus") }
            .menuStyle(.borderlessButton).fixedSize()
            .accessibilityIdentifier("support-more")
            Spacer()
            if let ready {
                ShareLink(item: ready, subject: Text("Goalong History — rapport de diagnostic")) {
                    Label("Partager…", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(LHSecondaryButtonStyle())
                .accessibilityIdentifier("support-share")
            }
            Button {
                controller.sendByEmail()
            } label: {
                Label("Envoyer par e-mail…", systemImage: "envelope")
            }
            .buttonStyle(LHPrimaryButtonStyle())
            .disabled(ready == nil)
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("support-email")
        }
    }
}

struct SupportFindingRow: View {
    let finding: SupportFinding

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint).font(.system(size: 14)).frame(width: 18)
                .accessibilityLabel(severityLabel)
            VStack(alignment: .leading, spacing: 3) {
                Text(finding.title).font(.system(size: 13, weight: .semibold))
                Text(finding.detail).font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private var symbol: String {
        switch finding.severity {
        case .error: return "exclamationmark.octagon.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .info: return finding.code == .noProblemDetected ? "checkmark.seal.fill" : "info.circle.fill"
        }
    }
    private var tint: Color {
        switch finding.severity {
        case .error: return LHTheme.danger
        case .warning: return LHTheme.warning
        case .info: return finding.code == .noProblemDetected ? LHTheme.success : LHTheme.secondaryText
        }
    }
    private var severityLabel: String {
        switch finding.severity {
        case .error: return "Problème"
        case .warning: return "Avertissement"
        case .info: return "Information"
        }
    }
}
#endif
