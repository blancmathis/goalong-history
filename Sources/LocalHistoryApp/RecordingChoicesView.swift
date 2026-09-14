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
        case .clicks: return "Clicks"
        case .scrolling: return "Scrolling"
        case .typing: return "Typing activity"
        case .shortcuts: return "Shortcut activity"
        case .windowTitles: return "Window titles"
        case .interfaceLabels: return "Interface labels"
        case .browserURLs: return "Browser URLs"
        }
    }
    var detail: String {
        switch self {
        case .clicks: return "Click position and target; labels depend on your choices below."
        case .scrolling: return "Grouped direction and event counts, not page screenshots."
        case .typing: return "Counts and duration only; no characters or exact keys."
        case .shortcuts: return "Generic shortcut activity, not the exact key combination."
        case .windowTitles: return "May reveal document names, page titles or personal information."
        case .interfaceLabels: return "May contain personal information visible in accessible controls."
        case .browserURLs: return "May reveal visited pages and URL paths, even when query values are redacted."
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
        VStack(alignment: .leading, spacing: 14) {
            Text("When Computer History is enabled, the app timeline records application identity, timing and non-text interface metadata. These additional details are optional.")
                .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12)], spacing: 12) {
                ForEach(RecordingSignal.allCases) { signal in
                    Toggle(isOn: Binding(get: { draft[keyPath: signal.keyPath] },
                                         set: { draft[keyPath: signal.keyPath] = $0 })) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(signal.title).font(.system(size: 13, weight: .medium))
                            Text(signal.detail).font(.system(size: 12)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .toggleStyle(.switch).controlSize(.small)
                    .accessibilityIdentifier("recording-\(signal.rawValue)")
                    .accessibilityLabel(signal.title).accessibilityHint(signal.detail)
                    .padding(13).frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 11))
                }
            }
            Button("Turn off optional detail fields") {
                for signal in RecordingSignal.allCases { draft[keyPath: signal.keyPath] = false }
                draft.capturePrivateBrowsing = false
                draft.redactAllURLQueryValues = true
            }.buttonStyle(.bordered)
            if (!draft.excludedDomainsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !draft.includedDomainsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) && !draft.captureURLs {
                Label("With website rules and Browser URLs off, browser activity is excluded: Goalong cannot verify which domain is allowed without inspecting addresses.", systemImage: "info.circle")
                    .font(.system(size: 12)).foregroundStyle(LHTheme.warning).fixedSize(horizontal: false, vertical: true)
            }
            Text("Turning a detail off affects future recording; it does not erase details already stored or sent.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
        Button("Choose apps…", action: chooseApplications)
            .buttonStyle(.bordered)
            .help("Choose applications without opening them. Their identifiers are added to this unsaved recording scope.")
            .alert("Application could not be added", isPresented: Binding(
                get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
    }
    private func chooseApplications() {
        let panel = NSOpenPanel()
        panel.title = "Choose apps for this recording rule"
        panel.prompt = "Add to rule"
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
