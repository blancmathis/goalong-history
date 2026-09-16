#if os(macOS)
import SwiftUI
import Foundation
import AppKit
import UniformTypeIdentifiers

/// One vocabulary and one binding for onboarding, settings and the applied summary.
enum RecordingSignal: String, CaseIterable, Identifiable {
    case clicks, scrolling, typing, shortcuts, windowTitles, interfaceLabels, browserURLs
    var id: String { rawValue }
    var title: String {
        switch self {
        case .clicks: return "Clics"
        case .scrolling: return "Défilement"
        case .typing: return "Activité de frappe"
        case .shortcuts: return "Raccourcis"
        case .windowTitles: return "Titres des fenêtres"
        case .interfaceLabels: return "Libellés des boutons"
        case .browserURLs: return "Adresses des pages"
        }
    }
    var detail: String {
        switch self {
        case .clicks: return "Position et cible du clic. Les libellés dépendent des options choisies."
        case .scrolling: return "Direction et nombre de défilements. Aucune capture d’écran."
        case .typing: return "Nombre et durée des frappes. Aucun caractère ni touche précise."
        case .shortcuts: return "Utilisation de raccourcis, sans les combinaisons exactes."
        case .windowTitles: return "Peut révéler des noms de documents et des informations personnelles."
        case .interfaceLabels: return "Peut contenir des informations personnelles affichées dans les boutons et champs."
        case .browserURLs: return "Peut révéler les pages visitées, même lorsque les paramètres sont masqués."
        }
    }
    var keyPath: WritableKeyPath<DashboardSettingsDraft, Bool> {
        switch self {
        case .clicks: return \.captureClicks
        case .scrolling: return \.captureScroll
        case .typing: return \.captureKeyboardActivity
        case .shortcuts: return \.captureShortcuts
        case .windowTitles: return \.captureWindowTitles
        case .interfaceLabels: return \.captureElementLabels
        case .browserURLs: return \.captureURLs
        }
    }
}

struct RecordingChoicesView: View {
    @Binding var draft: DashboardSettingsDraft
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("Applications et durées").font(.system(size: 14, weight: .medium)); Spacer(); Text("Base").font(.system(size: 12)).foregroundStyle(.secondary) }
            Divider()
            signalGroup("Interactions", signals: [.clicks, .scrolling, .typing, .shortcuts])
            Divider()
            signalGroup("Titres et adresses", signals: [.windowTitles, .interfaceLabels, .browserURLs])
            if (!draft.excludedDomainsText.isEmpty || !draft.includedDomainsText.isEmpty) && !draft.captureURLs {
                Label("Les filtres web peuvent bloquer le navigateur. Vérifiez Apps et sites.", systemImage: "info.circle")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }
    private func signalGroup(_ title: String, signals: [RecordingSignal]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            Grid(horizontalSpacing: 22, verticalSpacing: 10) {
                ForEach(0..<((signals.count + 1) / 2), id: \.self) { row in
                    GridRow {
                        ForEach(Array(signals[(row * 2)..<min(row * 2 + 2, signals.count)])) { signal in
                            HStack(spacing: 8) {
                                Text(signal.title).font(.system(size: 14))
                                GoalongHelpButton(text: signal.detail)
                                Spacer(minLength: 8)
                                Toggle(signal.title, isOn: Binding(get: { draft[keyPath: signal.keyPath] }, set: { draft[keyPath: signal.keyPath] = $0 }))
                                    .labelsHidden().toggleStyle(.switch)
                                    .accessibilityIdentifier("recording-\(signal.rawValue)")
                            }.frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
                        }
                    }
                }
            }
        }
    }
}

enum PrivacyScopeInput {
    static func domains(_ text: String) throws -> [String] {
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard lines.count <= 512 else { throw invalid("Use at most 512 domains per list.") }
        var output: [String] = []
        for line in lines {
            let raw = line.hasPrefix("*.") ? String(line.dropFirst(2)) : line
            let candidate = raw.contains("://") ? raw : "https://" + raw
            guard let url = URLComponents(string: candidate),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  url.user == nil, url.password == nil,
                  let host = url.url?.host?.lowercased(), !host.isEmpty, host.utf8.count <= 253,
                  !host.contains(where: { $0.isWhitespace }),
                  host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({
                      !$0.isEmpty && $0.count <= 63 && !$0.hasPrefix("-") && !$0.hasSuffix("-")
                      && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
                  }) else { throw invalid("Use a domain or website URL on each line, such as example.com. Invalid entry: \(line.prefix(100))") }
            if !output.contains(host) { output.append(host) }
        }
        return output
    }
    static func invalid(_ message: String) -> NSError {
        NSError(domain: "GoalongPrivacyChoices", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

extension DashboardSettingsDraft {
    func validatePrivacyRules() throws {
        _ = try PrivacyScopeInput.domains(excludedDomainsText)
        _ = try PrivacyScopeInput.domains(includedDomainsText)
        for text in [excludedApplicationsText, includedApplicationsText] {
            let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            guard lines.count <= 512, lines.allSatisfy({ $0.utf8.count <= 256 && !$0.contains(where: { $0.isWhitespace }) }) else {
                throw PrivacyScopeInput.invalid("Use one application bundle identifier per line, without spaces; at most 512 entries.")
            }
        }
    }
    var recordingSummary: String {
        let enabled = RecordingSignal.allCases.filter { self[keyPath: $0.keyPath] }.map(\.title)
        return enabled.isEmpty ? "Baseline app activity; optional detail fields off." : "Baseline app activity, plus: " + enabled.joined(separator: ", ") + "."
    }
}
/// Native app selection avoids requiring people to discover bundle identifiers.
struct ApplicationScopePickerButton: View {
    @Binding var text: String
    @State private var error: String?
    var body: some View {
        Button("Choisir des applications…", action: chooseApplications)
            .buttonStyle(.bordered)
            .help("Choose applications without opening them. Their identifiers are added to this unsaved recording scope.")
            .alert("Application could not be added", isPresented: Binding(
                get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
    }
    private func chooseApplications() {
        let panel = NSOpenPanel()
        panel.title = "Choisir des applications"
        panel.prompt = "Ajouter"
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.applicationBundle]
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK else { return }
            let identifiers = panel.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }
            guard identifiers.count == panel.urls.count else {
                error = "One selected app does not expose a bundle identifier. No rule was changed."
                return
            }
            var lines = text.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            for identifier in identifiers where !lines.contains(identifier) { lines.append(identifier) }
            text = lines.joined(separator: "\n")
        }
        if let window = NSApplication.shared.keyWindow { panel.beginSheetModal(for: window, completionHandler: completion) }
        else { panel.begin(completionHandler: completion) }
    }
}
#endif
