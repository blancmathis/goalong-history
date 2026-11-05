import AppleScreenTime
#if os(macOS)
    import Foundation
    import LocalHistoryCore

    /// T-048 C2: an old Goalong installer (August 2026) kept whole `.app` copies in `LocalHistory/app-backups/`.
    /// LaunchServices and Spotlight register every `.app` with our bundle id, so these copies stay candidates for
    /// "Goalong History" next to the installed app. Once per Mac, each copy becomes a `.zip` beside it and the
    /// `.app` is removed: no `.app` left on disk means nothing for LaunchServices to register again, and its
    /// stale record points to a missing bundle. No subprocess (`ditto`, `lsregister`): the app's process
    /// execution stays the fixed list of the security manifest; `NSFileCoordinator` writes the zip.
    enum AppBackupArchiver {
        static let doneKey = "didArchiveAppBackupsV1"
        static let folderName = "app-backups"

        struct Outcome: Equatable {
            var archived: [String] = []
            var failed: [String] = []
        }

        /// The release's own backups folder. Goalong Dev never reads the real data root.
        static var releaseFolder: URL {
            GoalongBuildChannel.realDataRoot.appendingPathComponent(folderName, isDirectory: true)
        }

        /// Our `.app` copies in `folder`: real directories (no symlink) whose bundle id is the release's.
        static func copies(in folder: URL, fileManager: FileManager = .default) -> [URL] {
            let names = (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []
            return names.sorted().compactMap { name -> URL? in
                guard name.hasSuffix(".app") else { return nil }
                let url = folder.appendingPathComponent(name, isDirectory: true)
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values?.isDirectory == true, values?.isSymbolicLink != true,
                    Bundle(url: url)?.bundleIdentifier == GoalongBundleIdentity.release
                else { return nil }
                return url
            }
        }

        /// Zips each copy to `<name>.zip`, checks the zip, then removes the `.app`. A copy whose zip fails stays.
        static func archive(folder: URL, fileManager: FileManager = .default) -> Outcome {
            var outcome = Outcome()
            for app in copies(in: folder, fileManager: fileManager) {
                let zip = folder.appendingPathComponent(app.lastPathComponent + ".zip")
                do {
                    if !fileManager.fileExists(atPath: zip.path) { try writeZip(of: app, to: zip, fileManager: fileManager) }
                    let size = (try? zip.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                    guard size > 0 else { throw CocoaError(.fileWriteUnknown) }
                    try fileManager.removeItem(at: app)
                    outcome.archived.append(app.lastPathComponent)
                } catch {
                    outcome.failed.append(app.lastPathComponent)
                }
            }
            return outcome
        }

        /// Once per Mac (release only), off the main thread. Marked done even on a failure: never a retry loop.
        static func runOnce(defaults: UserDefaults = GoalongDefaults.standard, folder: URL = releaseFolder) {
            guard !GoalongBuildChannel.current.isDevelopment, !defaults.bool(forKey: doneKey) else { return }
            defaults.set(true, forKey: doneKey)
            DispatchQueue.global(qos: .utility).async {
                let outcome = archive(folder: folder)
                guard !outcome.archived.isEmpty || !outcome.failed.isEmpty else { return }
                Diagnostics.write(
                    "App backups archived as zip: archived=\(outcome.archived.count) failed=\(outcome.failed.count)")
            }
        }

        private static func writeZip(of app: URL, to zip: URL, fileManager: FileManager) throws {
            var coordinationError: NSError?
            var copyError: Error?
            NSFileCoordinator().coordinate(readingItemAt: app, options: .forUploading, error: &coordinationError) { temporary in
                do { try fileManager.copyItem(at: temporary, to: zip) } catch { copyError = error }
            }
            if let error = coordinationError ?? copyError {
                try? fileManager.removeItem(at: zip)
                throw error
            }
        }
    }
#endif
