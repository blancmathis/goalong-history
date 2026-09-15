#if os(macOS)
    import AppKit
    import Foundation
    import SwiftUI

    /// Recovery never changes TCC, code signatures, saved consent, or recording choices.
    /// LaunchServices relaunches only this exact bundle; the new process waits for
    /// the old one to flush and exit before opening any history stores.
    enum PermissionRecovery {
        static let parentArgument = "--permission-recovery-parent"
        static let parentLaunchArgument = "--permission-recovery-parent-launched"

        enum ParentState: Equatable { case notRequested, ready, waiting, invalid }

        static func parentState(arguments: [String], currentPID: Int32, bundleURL: URL,
                                lookup: (Int32) -> (URL, Date?)?) -> ParentState {
            guard let index = arguments.firstIndex(of: parentArgument) else { return .notRequested }
            guard arguments.indices.contains(index + 1),
                  let pid = Int32(arguments[index + 1]), pid > 1, pid != currentPID,
                  let launchIndex = arguments.firstIndex(of: parentLaunchArgument),
                  arguments.indices.contains(launchIndex + 1),
                  let launched = TimeInterval(arguments[launchIndex + 1]), launched.isFinite else { return .invalid }
            guard let (parentURL, launchDate) = lookup(pid) else { return .ready }
            guard parentURL.standardizedFileURL == bundleURL.standardizedFileURL,
                  let launchDate,
                  abs(launchDate.timeIntervalSince1970 - launched) < 0.01 else { return .invalid }
            return .waiting
        }

        @MainActor static func launchWhenParentHasExited(_ start: @escaping () -> Void) {
            let deadline = Date().addingTimeInterval(20)
            func check() {
                let state = parentState(arguments: CommandLine.arguments,
                                        currentPID: ProcessInfo.processInfo.processIdentifier,
                                        bundleURL: Bundle.main.bundleURL) { pid in
                    guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated,
                          let url = app.bundleURL else { return nil }
                    return (url, app.launchDate)
                }
                switch state {
                case .notRequested, .ready: start()
                case .waiting where Date() < deadline:
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { check() }
                case .waiting, .invalid:
                    // Never kill a process or open the same stores concurrently.
                    NSApplication.shared.terminate(nil)
                }
            }
            check()
        }

        @MainActor static func restart(completion: @escaping (String?) -> Void) {
            let bundle = Bundle.main
            guard bundle.bundleURL.pathExtension == "app",
                  bundle.bundleIdentifier == "ai.goalong.localhistory",
                  let launched = NSRunningApplication.current.launchDate else {
                completion("Quit Goalong History, then reopen the installed app from Applications.")
                return
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.createsNewApplicationInstance = true
            configuration.arguments = [parentArgument, String(ProcessInfo.processInfo.processIdentifier),
                                       parentLaunchArgument, String(launched.timeIntervalSince1970)]
            NSWorkspace.shared.openApplication(at: bundle.bundleURL, configuration: configuration) { app, error in
                DispatchQueue.main.async {
                    guard error == nil, let app,
                          app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
                        completion("Goalong could not restart. Quit it, reopen the installed app, then check access again.")
                        return
                    }
                    completion(nil)
                    NSApplication.shared.terminate(nil)
                }
            }
        }
    }

    struct PermissionRecoveryView: View {
        let status: SourceAccessStatus
        var expandOnFailure = false
        @State private var expanded = false
        @State private var restarting = false
        @State private var restartError: String?

        var body: some View {
            DisclosureGroup("Already enabled in System Settings?", isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("A macOS switch can still refer to an older build after an update. Turning it off and on may not replace that entry.")
                    Text("Remove only Goalong History from this permission list with −, then use + to add the exact app shown below and enable it. Do not reset permissions for other apps.")
                    Text(Bundle.main.bundleURL.path).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    Text("Restart Goalong History after granting access, then enable this source again. Your history, saved recording settings, exclusions, and sharing choices are kept. Save pending settings changes before restarting. Restarting never enables a source by itself.")
                    HStack(spacing: 12) {
                        Button("Show this app in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                        }
                        Button(restarting ? "Restarting…" : "Restart Goalong History") {
                            restarting = true
                            restartError = nil
                            PermissionRecovery.restart { message in
                                restartError = message
                                if message != nil { restarting = false }
                            }
                        }.disabled(restarting)
                    }.buttonStyle(.bordered)
                    if let restartError { Text(restartError).foregroundStyle(.secondary) }
                }
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
            }
            .font(.system(size: 12, weight: .medium))
            .onAppear { if expandOnFailure { expanded = true } }
            .onChange(of: expandOnFailure) { if $0 { expanded = true } }
        }
    }
#endif
