#if os(macOS)
import AppKit
import Foundation
import LocalHistoryQueryCLI
import SwiftUI

/// Explicit user-driven export. No background sync or remote auth tokens enter Goalong settings.
struct GoalongWebsiteConnectionCard: View {
    @State private var showsConnection = false

    var body: some View {
        LHCard {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "person.2.crop.square.stack")
                    .font(.title2).foregroundStyle(LHTheme.accent)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Goalong website").font(.headline)
                    Text("Envoi dans votre compte. Les règles de partage configurées sur le site s’appliquent aux dates et champs autorisés.")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Optional · Explicit sends · Unverified submissions")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button("Connect website") { showsConnection = true }
                    .buttonStyle(.bordered)
            }
        }
        .sheet(isPresented: $showsConnection) { GoalongWebsiteConnectionSheet() }
    }
}

private struct GoalongWebsiteConnectionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var windowHost = GoalongWebsiteWindowHost()
    @AppStorage("goalong.website.origin") private var origin = ""
    // Only the user's chosen file path is remembered. The token itself stays in that file.
    @AppStorage("goalong.website.tokenFilePath") private var tokenFilePath = ""
    @State private var date = Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
    @State private var includeApps = false
    @State private var includeHourly = false
    @State private var includeWebsites = false
    @State private var includeRecap = false
    @State private var structuredReport = false
    @State private var payload: Data?
    @State private var devices: [(id: String, name: String)] = []
    @State private var excludedDevices: Set<String> = []
    @State private var previewSummary = ""
    @State private var status: String?
    @State private var error: String?
    @State private var busy = false
    @State private var showsExactData = false
    @State private var showsTokenPath = false
    @State private var tokenPathInput = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Connect to your Goalong account").font(.title2.weight(.semibold))
                    Text("Envoi dans votre compte. Les règles de partage configurées sur le site s’appliquent aux dates et champs autorisés.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.disabled(busy)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("1. Your website account").font(.headline)
                        TextField("Website origin, for example https://your-goalong-host", text: $origin)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Goalong website HTTPS origin")
                        Text("Create an upload-only token in the website’s Sources page and choose its downloaded file here. If needed, Goalong offers ‘Protéger ce fichier’ to restrict access to your account. Its file stays on your Mac; the token authorizes explicit sends to your chosen website and can be revoked there.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Button("Choose token file…", action: chooseTokenFile)
                            if !tokenFilePath.isEmpty {
                                Text(URL(fileURLWithPath: tokenFilePath).lastPathComponent)
                                    .font(.caption).lineLimit(1).truncationMode(.middle)
                                Button("Forget file") { tokenFilePath = ""; status = nil }
                                    .buttonStyle(.borderless)
                            }
                        }
                        DisclosureGroup("Autre méthode : coller le chemin du fichier", isExpanded: $showsTokenPath) {
                            VStack(alignment: .leading, spacing: 8) {
                                TextField("~/Downloads/goalong-token.txt", text: $tokenPathInput)
                                    .textFieldStyle(.roundedBorder)
                                    .accessibilityLabel("Chemin local du fichier de connexion")
                                Text("Collez le chemin du fichier téléchargé, pas la clé. Seul ce fichier sera lu ; la même protection et la même validation s’appliquent.")
                                    .font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Button("Valider ce fichier", action: validateTokenPath)
                                    .disabled(tokenPathInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                            .padding(.top, 6)
                        }
                        Button("Open website Sources", action: openWebsite)
                            .buttonStyle(.borderless)
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 10) {
                        Text("2. Choose your data").font(.headline)
                        DatePicker("Saved day", selection: $date, in: ...Date(), displayedComponents: .date)
                        Text("Device names and screen-time totals are included. Source permissions must still be enabled in Goalong. Nothing is collected or analyzed during export.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Toggle("Application names and durations", isOn: $includeApps)
                        Toggle("Hourly breakdown, when recorded", isOn: $includeHourly)
                        Toggle("Website domains observed on this Mac", isOn: $includeWebsites)
                        Toggle("Saved analysis summary", isOn: $includeRecap)
                        Toggle("Structured report for productivity", isOn: $structuredReport)
                        if structuredReport {
                            Text("The same selected durations become an editable report. Applications are not automatically considered productive: qualify their context on the website, or let your chosen agent prepare the report before importing it. Raw events and conversations stay outside this export.")
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if !devices.isEmpty {
                            VStack(alignment: .leading, spacing: 7) {
                                Text("Devices from the saved day").font(.subheadline.weight(.medium))
                                ForEach(devices, id: \.id) { device in
                                    Toggle(device.name, isOn: Binding(
                                        get: { !excludedDevices.contains(device.id) },
                                        set: { enabled in
                                            if enabled { excludedDevices.remove(device.id) }
                                            else { excludedDevices.insert(device.id) }
                                            invalidatePreview()
                                        }
                                    ))
                                }
                            }
                        }
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 10) {
                        Text("3. Review before sending").font(.headline)
                        Button(payload == nil ? "Prepare offline preview" : "Refresh offline preview", action: preparePreview)
                            .buttonStyle(.bordered)
                        if let payload {
                            Text(previewSummary).font(.subheadline)
                            DisclosureGroup("Review exact data", isExpanded: $showsExactData) {
                                ScrollView([.horizontal, .vertical]) {
                                    Text(String(decoding: payload, as: UTF8.self))
                                        .font(.system(.caption, design: .monospaced))
                                        .textSelection(.enabled).padding(10)
                                }
                                .frame(height: 230)
                                .background(LHTheme.pageBackground, in: RoundedRectangle(cornerRadius: 8))
                            }
                            Text("No raw conversations, captured text, local paths or verification badge are sent. Device/app totals and observed website time are separate measures.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let status {
                            Label(status, systemImage: "checkmark.circle")
                                .font(.subheadline).foregroundStyle(LHTheme.success)
                                .textSelection(.enabled)
                        }
                        if let error {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .font(.subheadline).foregroundStyle(LHTheme.warning)
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(24)
                .disabled(busy)
            }
            Divider()
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Text("Sharing audiences stay under your control on the website.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Send reviewed data", action: sendReviewedData)
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || payload == nil || tokenFilePath.isEmpty || origin.isEmpty)
            }
            .padding(20)
        }
        .frame(width: 660, height: 760)
        .background(GoalongWebsiteWindowReader(host: windowHost).frame(width: 0, height: 0))
        .interactiveDismissDisabled(busy)
        .onChange(of: date) { _ in devices = []; excludedDevices = []; invalidatePreview() }
        .onChange(of: includeApps) { _ in invalidatePreview() }
        .onChange(of: includeHourly) { _ in invalidatePreview() }
        .onChange(of: includeWebsites) { _ in invalidatePreview() }
        .onChange(of: includeRecap) { _ in invalidatePreview() }
        .onChange(of: structuredReport) { _ in invalidatePreview() }
        .onChange(of: origin) { _ in status = nil }
    }

    private func invalidatePreview() { payload = nil; status = nil; error = nil }

    private func chooseTokenFile() {
        guard let window = windowHost.window else {
            error = "Reopen the website connection window before choosing a token file."
            return
        }
        let panel = NSOpenPanel()
        panel.title = "Choose your Goalong upload-only token file"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = true
        panel.resolvesAliases = false
        panel.treatsFilePackagesAsDirectories = false
        // A nested runModal loop inside SwiftUI's connection sheet can stall selection,
        // cancellation and accessibility. Return to the normal event loop immediately.
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let file = panel.url else { return }
            DispatchQueue.main.async { reviewSelectedTokenFile(file, in: window) }
        }
    }

    private func reviewSelectedTokenFile(_ file: URL, in window: NSWindow) {
        do {
            let reviewed = try GoalongSiteSubmission.reviewTokenFile(file: file)
            if reviewed.requiresProtection {
                let confirmation = NSAlert()
                confirmation.messageText = "Protéger ce fichier ?"
                confirmation.informativeText = "Goalong limitera l’accès à « \(file.lastPathComponent) » à votre compte macOS (permissions 0600), puis le sélectionnera pour la connexion. Seul ce fichier sera modifié. Son contenu ne sera pas envoyé."
                confirmation.alertStyle = .informational
                confirmation.addButton(withTitle: "Protéger ce fichier")
                confirmation.addButton(withTitle: "Annuler")
                confirmation.beginSheetModal(for: window) { response in
                    guard response == .alertFirstButtonReturn else { return }
                    do {
                        try GoalongSiteSubmission.protectTokenFile(file: file, reviewed: reviewed)
                        selectTokenFile(file)
                    } catch { self.error = String(describing: error) }
                }
                return
            }
            selectTokenFile(file)
        } catch { self.error = String(describing: error) }
    }

    private func validateTokenPath() {
        guard let window = windowHost.window else {
            error = "Reopen the website connection window before choosing a token file."
            return
        }
        do {
            let file = try GoalongSiteSubmission.tokenFileURL(path: tokenPathInput)
            reviewSelectedTokenFile(file, in: window)
        } catch { self.error = String(describing: error) }
    }

    private func selectTokenFile(_ file: URL) {
        do {
            _ = try GoalongSiteSubmission.readToken(file: file)
            tokenFilePath = file.path
            tokenPathInput = ""
            showsTokenPath = false
            error = nil
            status = nil
        } catch { self.error = String(describing: error) }
    }

    private func openWebsite() {
        do {
            let endpoint = try GoalongSiteSubmission.endpoint(origin: origin.trimmingCharacters(in: .whitespacesAndNewlines))
            var parts = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
            parts.path = "/goalong.dc.html"
            parts.fragment = "sources"
            if let url = parts.url, !GoalongWorkspaceOpenPolicy.open(url, purpose: .goalongWebsite) {
                error = "The configured website could not be opened. Check its origin and try again."
            }
        } catch { self.error = String(describing: error) }
    }

    private func preparePreview() {
        let selected = devices.filter { !excludedDevices.contains($0.id) }.map(\.id)
        guard devices.isEmpty || !selected.isEmpty else { error = "Select at least one device."; return }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        let day = formatter.string(from: date)
        let root = AppPaths.applicationSupportDirectory
        let options = GoalongSiteExportOptions(deviceIDs: selected, includeApplications: includeApps,
            includeHourly: includeHourly, includeWebsites: includeWebsites, includeRecap: includeRecap, structuredReport: structuredReport)
        busy = true
        invalidatePreview()
        Task { @MainActor in
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try GoalongQueryCLI.siteExportPayload(rootDirectory: root, day: day, options: options)
                }.value
                let object = try JSONSerialization.jsonObject(with: result) as? [String: Any]
                let value = (object?["days"] as? [[String: Any]])?.first
                let telemetry = value?["telemetry"] as? [String: Any]
                let rows = telemetry?["devices"] as? [[String: Any]] ?? []
                if devices.isEmpty {
                    devices = rows.compactMap { row in
                        guard let id = row["id"] as? String, let name = row["name"] as? String else { return nil }
                        return (id: id, name: name)
                    }
                }
                let applications = rows.reduce(0) { $0 + (($1["apps"] as? [Any])?.count ?? 0) }
                previewSummary = "\(day) · \(rows.count) devices · \(applications) application rows · \(result.count) bytes. Review the exact fields below."
                payload = result
            } catch { self.error = String(describing: error) }
            busy = false
        }
    }

    private func sendReviewedData() {
        guard let reviewedPayload = payload else { return }
        let target = origin.trimmingCharacters(in: .whitespacesAndNewlines)
        let tokenFile = URL(fileURLWithPath: tokenFilePath)
        busy = true
        error = nil
        status = nil
        Task { @MainActor in
            do {
                let receipt = try await Task.detached(priority: .userInitiated) {
                    try GoalongSiteSubmission.send(payload: reviewedPayload, origin: target, tokenFile: tokenFile)
                }.value
                let result = try JSONSerialization.jsonObject(with: receipt) as? [String: Any] ?? [:]
                status = "Received: \(result["imported"] ?? 0) new, \(result["updated"] ?? 0) updated, \(result["skipped"] ?? 0) unchanged. Unverified. Your website sharing rules apply."
                payload = nil
            } catch { self.error = String(describing: error) }
            busy = false
        }
    }
}

/// SwiftUI sheets do not reliably appear as NSApp.keyWindow/mainWindow. Capture the
/// NSWindow that actually owns this sheet's view, without retaining the window or view.
private final class GoalongWebsiteWindowHost: ObservableObject {
    weak var window: NSWindow?
}

private struct GoalongWebsiteWindowReader: NSViewRepresentable {
    let host: GoalongWebsiteWindowHost

    final class ProbeView: NSView {
        weak var host: GoalongWebsiteWindowHost?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            host?.window = window
        }
    }

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.host = host
        return view
    }

    func updateNSView(_ view: ProbeView, context: Context) {
        view.host = host
        host.window = view.window
    }

    static func dismantleNSView(_ view: ProbeView, coordinator: ()) {
        if view.host?.window === view.window { view.host?.window = nil }
        view.host = nil
    }
}
#endif
