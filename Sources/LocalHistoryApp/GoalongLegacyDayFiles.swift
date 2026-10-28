#if os(macOS)
    import Darwin
    import Foundation
    import LocalHistoryCore
    import LocalHistoryQueryCLI

    /// Before T-045 H7 the day note, call and developer files followed the system calendar
    /// (Buddhist « 2569-10-28 », Japanese « 0008-10-28 »): retention and history clears, which compare
    /// Gregorian keys, kept or erased the wrong days. Renames them once to the Gregorian key of the same day.
    /// Gregorian names are left alone, so a second pass changes nothing; an existing Gregorian file is never replaced.
    enum GoalongLegacyDayFiles {
        private struct Note: Codable { let version: Int; let day: String; let text: String }
        static let folders = [("notes", ".json"), ("calls", ".jsonl"), ("developer", ".jsonl")]

        static func migrate(root: URL, calendar: Calendar = .current, now: Date = Date()) {
            guard calendar.identifier != .gregorian else { return }
            for (folder, suffix) in folders {
                let directory = root.appendingPathComponent(folder, isDirectory: true)
                guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { continue }
                for name in names.sorted() where name.hasSuffix(suffix) {
                    guard let key = GoalongFocusCalendar.gregorianKey(
                        fromLegacy: String(name.dropLast(suffix.count)), calendar: calendar, now: now)
                    else { continue }
                    let source = directory.appendingPathComponent(name, isDirectory: false)
                    let target = directory.appendingPathComponent(key + suffix, isDirectory: false)
                    guard (try? FileManager.default.attributesOfItem(atPath: source.path)[.type] as? FileAttributeType) == .typeRegular
                    else { continue }
                    if folder == "notes" {
                        // The note names its own day: rewrite it under the new key, then drop the old file.
                        guard let bytes = try? GoalongSystemSourceFiles.read(root: root, folder: folder, name: name, maximumBytes: 4096),
                              let note = try? JSONDecoder().decode(Note.self, from: bytes),
                              (try? FileManager.default.attributesOfItem(atPath: target.path)) == nil,
                              let data = try? JSONEncoder().encode(Note(version: note.version, day: key, text: note.text)),
                              (try? GoalongSystemSourceFiles.write(data, root: root, folder: folder, name: key + suffix, maximumBytes: 4096)) != nil
                        else { continue }
                        try? GoalongSystemSourceFiles.remove(root: root, folder: folder, name: name)
                    } else {
                        _ = renamex_np(source.path, target.path, UInt32(RENAME_EXCL))
                    }
                }
            }
        }
    }
#endif
