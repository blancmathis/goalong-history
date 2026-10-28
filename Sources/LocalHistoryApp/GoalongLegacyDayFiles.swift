#if os(macOS)
    import Darwin
    import Foundation
    import LocalHistoryCore
    import LocalHistoryQueryCLI

    /// Before T-045 H7 the day note, call and developer files followed the system calendar
    /// (Buddhist « 2569-10-28 », Japanese « 0008-10-28 »): retention and history clears, which compare
    /// Gregorian keys, kept or erased the wrong days. Renames them once to the Gregorian key of the same day,
    /// also for a user already back on the Gregorian calendar (H9). Gregorian names are left alone, so a second
    /// pass changes nothing. When the Gregorian file of that day exists, the old one is merged into it, old lines
    /// first; the Gregorian file is only ever replaced by a superset of itself.
    enum GoalongLegacyDayFiles {
        private struct Note: Codable { let version: Int; let day: String; let text: String }
        static let folders = [("notes", ".json"), ("calls", ".jsonl"), ("developer", ".jsonl")]
        static let noteBytes = 4096, dayFileBytes = 2_097_152
        /// Goalong wrote no day file before this day: a legacy name read under a calendar the user may have left
        /// (Buddhist, Japanese) is only trusted when it lands between it and today.
        static let firstPossibleDay = "2024-01-01"

        static func gregorianKey(_ stem: String, calendar: Calendar, now: Date) -> String? {
            if let key = GoalongFocusCalendar.gregorianKey(fromLegacy: stem, calendar: calendar, now: now) { return key }
            for identifier in [Calendar.Identifier.buddhist, .japanese] where identifier != calendar.identifier {
                var former = Calendar(identifier: identifier); former.timeZone = calendar.timeZone
                if let key = GoalongFocusCalendar.gregorianKey(fromLegacy: stem, calendar: former, now: now), key >= firstPossibleDay { return key }
            }
            return nil
        }

        static func migrate(root: URL, calendar: Calendar = .current, now: Date = Date()) {
            for (folder, suffix) in folders {
                let directory = root.appendingPathComponent(folder, isDirectory: true)
                guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { continue }
                for name in names.sorted() where name.hasSuffix(suffix) {
                    guard let key = gregorianKey(String(name.dropLast(suffix.count)), calendar: calendar, now: now) else { continue }
                    let source = directory.appendingPathComponent(name, isDirectory: false)
                    let target = directory.appendingPathComponent(key + suffix, isDirectory: false)
                    guard (try? FileManager.default.attributesOfItem(atPath: source.path)[.type] as? FileAttributeType) == .typeRegular
                    else { continue }
                    if folder == "notes" {
                        // The note names its own day: rewrite it under the new key, then drop the old file.
                        guard let bytes = try? GoalongSystemSourceFiles.read(root: root, folder: folder, name: name, maximumBytes: noteBytes),
                              let note = try? JSONDecoder().decode(Note.self, from: bytes) else { continue }
                        var text = note.text
                        if (try? FileManager.default.attributesOfItem(atPath: target.path)) != nil {
                            // Both fit in one note, or the old one stays: notes are never retention-purged and a full clear erases it.
                            guard let current = try? GoalongSystemSourceFiles.read(root: root, folder: folder, name: key + suffix, maximumBytes: noteBytes),
                                  let newer = try? JSONDecoder().decode(Note.self, from: current) else { continue }
                            text = newer.text == note.text || newer.text.hasPrefix(note.text + "\n") ? newer.text : note.text + "\n" + newer.text
                            guard text.count <= GoalongDayNoteStore.maximumCharacters else { continue }
                        }
                        guard let data = try? JSONEncoder().encode(Note(version: note.version, day: key, text: text)),
                              (try? GoalongSystemSourceFiles.write(data, root: root, folder: folder, name: key + suffix, maximumBytes: noteBytes)) != nil
                        else { continue }
                        try? GoalongSystemSourceFiles.remove(root: root, folder: folder, name: name)
                    } else if renamex_np(source.path, target.path, UInt32(RENAME_EXCL)) != 0, errno == EEXIST {
                        merge(root: root, folder: folder, legacy: name, into: key + suffix)
                    }
                }
            }
        }

        /// Old lines, then the Gregorian file, through one atomic replace; the old file goes only after.
        /// A second pass finds the old lines already inside and only drops the old file.
        private static func merge(root: URL, folder: String, legacy: String, into name: String) {
            guard var old = try? GoalongSystemSourceFiles.read(root: root, folder: folder, name: legacy, maximumBytes: dayFileBytes),
                  let newer = try? GoalongSystemSourceFiles.read(root: root, folder: folder, name: name, maximumBytes: dayFileBytes)
            else { return }
            if !old.isEmpty, old.last != 10 { old.append(10) }
            if !old.isEmpty, newer.range(of: old) == nil {
                guard old.count + newer.count <= dayFileBytes,
                      (try? GoalongSystemSourceFiles.write(old + newer, root: root, folder: folder, name: name, maximumBytes: dayFileBytes)) != nil
                else { return }
            }
            try? GoalongSystemSourceFiles.remove(root: root, folder: folder, name: legacy)
        }
    }
#endif
