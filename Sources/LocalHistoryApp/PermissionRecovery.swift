#if os(macOS)
import AppKit
import Foundation
import LocalHistoryCore
import SwiftUI

extension SourceAccessStatus {
    var privacyPermissionTitle: String? {
        switch self {
        case .accessibility: return "Accessibility"
        case .inputMonitoring: return "Input Monitoring"
        case .fullDiskAccess: return "Full Disk Access"
        case .ready, .screenTimeSetup, .unavailable: return nil
        }
    }
}

/// A failed return from Settings is a recovery hint, not proof that the checkbox
/// is off or that TCC is corrupt. Never infer a grant from the user's button click.
struct SourceAccessRecoveryState: Equatable {
    private(set) var requestedStatus: SourceAccessStatus?
    private(set) var recoveryStatus: SourceAccessStatus?

    mutating func requested(_ status: SourceAccessStatus) {
        requestedStatus = status.privacyPermissionTitle == nil ? nil : status
        if recoveryStatus != status { recoveryStatus = nil }
    }

    mutating func checked(_ status: SourceAccessStatus) {
        if status == .ready {
            self = SourceAccessRecoveryState()
        } else {
            recoveryStatus = status == requestedStatus && status.privacyPermissionTitle != nil
                ? status : nil
        }
    }
}

/// macOS access and the person's source choice are separate state. An unsuccessful
/// access check may block a view, but must never revoke or rewrite saved consent.
/// Only an explicitly requested activation may prepare and enable a new source.
enum SourceAccessConsentPolicy {
    static func apply(
        _ status: SourceAccessStatus,
        capability: GoalongCapability,
        surface: GoalongConsentSurface,
        allowEnable: Bool,
        store: GoalongCapabilityConsentStore,
        prepare: () throws -> Void
    ) -> SourceAccessStatus {
        guard status == .ready, allowEnable, !store.isEnabled(capability) else { return status }
        do { try prepare() }
        catch { return .unavailable("Settings could not be saved: \(error.localizedDescription)") }
        guard store.set(capability, enabled: true, surface: surface) else {
            return .unavailable("Your choice could not be saved. Nothing has been enabled. Try again.")
        }
        return .ready
    }
}

extension GoalongWorkspaceOpenPolicy {
    /// Select only the bundle of this running process. Do not search by display
    /// name: an older copy, a mounted DMG or a development build may share it.
    static var runningApplicationURL: URL? {
        let url = Bundle.main.bundleURL.standardizedFileURL
        guard url.isFileURL, url.pathExtension == "app",
              (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
        return url
    }

    @discardableResult
    static func revealRunningApplication() -> Bool {
        guard let url = runningApplicationURL else { return false }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        return true
    }
}

/// The same recovery is available for Accessibility, Input Monitoring and FDA.
/// It never modifies TCC, code signatures, quarantine, or the consent registry.
struct PermissionRecoveryPanel: View {
    let status: SourceAccessStatus
    var afterSettingsCheck = false
    var beforeQuit: () -> Void = {}
    @State private var expanded = false
    @State private var confirmQuit = false
    @State private var identity: CaptureBuildIdentity?

    var body: some View {
        if let permission = status.privacyPermissionTitle {
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("macOS has not made \(permission) available to this running app. A checked entry in System Settings is not proof that this process can use it.")
                    Text("First quit Goalong completely and reopen it. Closing its window is not enough: it can remain running in the menu bar.")
                    Text("If access is still refused, remove only Goalong’s entry with the − button in Privacy & Security → \(permission). Add the exact app shown below with +, enable it, then quit and reopen Goalong. Repeatedly toggling an old entry may not refresh its signing identity.")
                    if let url = GoalongWorkspaceOpenPolicy.runningApplicationURL {
                        Text(url.path)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        if let identity {
                            Text("Running version: \(identity.displayVersion ?? "development") · build \(identity.buildNumber ?? "unknown")")
                                .font(.system(size: 11))
                            if identity.signatureKind == .adHoc || identity.signatureKind == .unsigned {
                                Text("This Community/development build has no stable Apple signing identity. An app update can require macOS permissions to be granted again. The update signature does not replace an Apple code-signing identity.")
                                    .foregroundStyle(LHTheme.warning)
                            }
                        }
                        HStack(spacing: 10) {
                            Button("Show this app in Finder") {
                                _ = GoalongWorkspaceOpenPolicy.revealRunningApplication()
                            }
                            Button("Quit Goalong…") { confirmQuit = true }
                        }
                    } else {
                        Text("Run the installed Goalong History.app from Applications, not a standalone executable, to grant access to the intended application.")
                    }
                    Text("Your history and source choices are kept. Goalong will verify access again; this guide does not grant permission or disable any macOS protection.")
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
            } label: {
                Text(afterSettingsCheck ? "Still blocked after enabling access?" : "Already enabled in System Settings?")
                    .font(.system(size: 12, weight: .medium))
            }
            .onAppear {
                identity = BuildIdentityReader.current()
                if afterSettingsCheck { expanded = true }
            }
            .onChange(of: afterSettingsCheck) { if $0 { expanded = true } }
            .alert("Quit Goalong to reload macOS access?", isPresented: $confirmQuit) {
                Button("Cancel", role: .cancel) {}
                Button("Quit Goalong") {
                    beforeQuit()
                    _ = GoalongWorkspaceOpenPolicy.revealRunningApplication()
                    NSApplication.shared.terminate(nil)
                }
            } message: {
                Text("Goalong will stop recording and close normally. Reopen the app selected in Finder, then check access again. Local history and settings are not deleted.")
            }
        }
    }
}
#endif
