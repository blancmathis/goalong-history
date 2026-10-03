#if os(macOS)
import Foundation
import SwiftUI
import AgentActivity
import LocalHistoryCore

/// Sources read beside the observations of one day. None of them adds to active time.
struct GoalongActivityLanes {
    var code: GoalongCodeDay?
    /// Every source with its state and one action, listed in « Couverture et sources ».
    var sources: [GoalongSourceRow] = []
    var openCodeSettings: () -> Void = {}
    var chooseProjects: () -> Void = {}
}

extension GoalongSourceRow.State {
    init(_ status: GoalongDeveloperLaneStatus) {
        switch status {
        case .disabled: self = .off
        case .permissionDenied: self = .needsPermission
        case .unsupported: self = .unavailable
        case .noData: self = .noData
        case .partial: self = .partial
        case .ready: self = .ready
        case .failed: self = .failed
        }
    }
}

// MARK: - Intervals

enum GoalongIntervals {
    static func merged(_ intervals: [DateInterval]) -> [DateInterval] {
        var result: [DateInterval] = []
        for interval in intervals.filter({ $0.duration > 0 }).sorted(by: { $0.start < $1.start }) {
            if let last = result.last, interval.start <= last.end {
                result[result.count - 1] = DateInterval(start: last.start, end: max(last.end, interval.end))
            } else {
                result.append(interval)
            }
        }
        return result
    }

    /// Seconds of `intervals` outside `cover`; overlapping intervals count once.
    static func seconds(_ intervals: [DateInterval], outside cover: [DateInterval]) -> TimeInterval {
        let cover = merged(cover)
        return merged(intervals).reduce(0) { total, interval in
            let covered = cover.reduce(0.0) { sum, part in
                sum + max(0, min(part.end, interval.end).timeIntervalSince(max(part.start, interval.start)))
            }
            return total + max(0, interval.duration - covered)
        }
    }

    /// When the user was on the Mac: active time, masked time included.
    static func presence(_ day: GoalongLocalAnalytics.Day) -> [DateInterval] {
        day.segments.filter { ($0.kind.isActive || $0.kind == .concealed) && $0.end > $0.start }
            .map { DateInterval(start: $0.start, end: $0.end) }
    }
}

// MARK: - Rows on the axis of the day

enum GoalongLaneMark { case solid, faint, outlined, tick }

/// Rows of one day on the axis of « Le fil »: the user's own thread, then each source.
struct GoalongLaneMatrix: View {
    struct Row: Identifiable {
        let id: String
        let label: String
        /// The user's own observations, drawn as the thread itself.
        var segments: [GoalongLocalAnalytics.Segment] = []
        var solid: [DateInterval] = []
        var faint: [DateInterval] = []
        var outlined: [DateInterval] = []
        var ticks: [Date] = []
    }

    static let solidColor = LHTheme.text.opacity(0.55)
    static let faintColor = LHTheme.text.opacity(0.14)

    let rows: [Row]
    let range: ClosedRange<Date>
    var summary: String
    var labelWidth: CGFloat = 128

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(rows) { row in
                HStack(spacing: 12) {
                    Text(row.label).font(.system(size: 12))
                        .foregroundStyle(row.segments.isEmpty ? LHTheme.secondaryText : LHTheme.text)
                        .lineLimit(1).truncationMode(.middle)
                        .frame(width: labelWidth, alignment: .leading)
                        .help(row.label)
                    ZStack {
                        Rectangle().fill(LHTheme.tertiaryText.opacity(0.35)).frame(height: 1)
                        if !row.segments.isEmpty {
                            GoalongThreadBand(segments: row.segments, lower: range.lowerBound,
                                              upper: range.upperBound, thickness: 10)
                        }
                        Canvas { context, size in draw(row, in: context, size: size) }
                    }
                    .frame(height: 20)
                }
            }
            HStack(spacing: 12) {
                Color.clear.frame(width: labelWidth, height: 1)
                GoalongThreadAxis(marks: marks)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Rubans de la journée")
        .accessibilityValue(summary)
    }

    private func draw(_ row: Row, in context: GraphicsContext, size: CGSize) {
        let lower = range.lowerBound, span = max(1, range.upperBound.timeIntervalSince(lower))
        func x(_ date: Date) -> CGFloat { CGFloat(max(0, min(1, date.timeIntervalSince(lower) / span))) * size.width }
        func rect(_ interval: DateInterval, height: CGFloat) -> CGRect? {
            let x0 = x(interval.start), x1 = x(interval.end)
            guard interval.end > lower, interval.start < range.upperBound else { return nil }
            return CGRect(x: x0, y: (size.height - height) / 2, width: max(1.5, x1 - x0), height: height)
        }
        for interval in GoalongIntervals.merged(row.faint) {
            if let r = rect(interval, height: 10) {
                context.fill(Path(roundedRect: r, cornerRadius: min(2, r.width / 2)), with: .color(Self.faintColor))
            }
        }
        for interval in GoalongIntervals.merged(row.outlined) {
            if let r = rect(interval, height: 10)?.insetBy(dx: 0.5, dy: 0.5) {
                context.stroke(Path(roundedRect: r, cornerRadius: min(2, r.width / 2)), with: .color(Self.solidColor), lineWidth: 1)
            }
        }
        for interval in GoalongIntervals.merged(row.solid) {
            if let r = rect(interval, height: 10) {
                context.fill(Path(roundedRect: r, cornerRadius: min(2, r.width / 2)), with: .color(Self.solidColor))
            }
        }
        for tick in row.ticks where range.contains(tick) {
            context.fill(Path(CGRect(x: x(tick) - 0.75, y: 2, width: 1.5, height: size.height - 4)), with: .color(LHTheme.text))
        }
    }

    private var marks: [(label: String, position: CGFloat)] {
        let span = range.upperBound.timeIntervalSince(range.lowerBound)
        guard span > 0 else { return [] }
        let hours = span / 3600, stride = hours > 16 ? 4 : hours > 8 ? 2 : 1
        var result: [(String, CGFloat)] = []
        var cursor = range.lowerBound
        while cursor <= range.upperBound, result.count < 26 {
            result.append((GoalongSummaryFormat.hour(cursor), CGFloat(cursor.timeIntervalSince(range.lowerBound) / span)))
            guard let next = Calendar.current.date(byAdding: .hour, value: stride, to: cursor) else { break }
            cursor = next
        }
        return result
    }

    /// The thread's range for this day, widened to the whole hours that hold `marks`.
    static func range(day: GoalongLocalAnalytics.Day, marks: [Date], calendar: Calendar = .current) -> ClosedRange<Date> {
        let base = GoalongActivityPresentation.chartRange(day, fullDay: false, calendar: calendar)
        let dayStart = calendar.startOfDay(for: day.date)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86400)
        let inside = marks.filter { $0 >= dayStart && $0 <= dayEnd }
        guard let first = inside.min(), let last = inside.max() else { return base }
        let observed = day.segments.contains { $0.kind != .unobserved && $0.end > $0.start }
        var lower = observed ? min(base.lowerBound, first) : first
        var upper = observed ? max(base.upperBound, last) : last
        lower = max(dayStart, calendar.dateInterval(of: .hour, for: lower)?.start ?? lower)
        upper = calendar.dateInterval(of: .hour, for: upper.addingTimeInterval(-0.001))?.end ?? upper
        upper = min(dayEnd, max(upper, lower.addingTimeInterval(3 * 3600)))
        return lower...max(lower.addingTimeInterval(1), upper)
    }
}

struct GoalongLaneLegend: View {
    let items: [(mark: GoalongLaneMark, title: String)]

    var body: some View {
        HStack(spacing: 16) {
            ForEach(items.indices, id: \.self) { index in
                HStack(spacing: 6) {
                    swatch(items[index].mark)
                    Text(items[index].title)
                }
            }
        }
        .font(.system(size: 11)).foregroundStyle(LHTheme.secondaryText)
        .accessibilityHidden(true)
    }

    @ViewBuilder private func swatch(_ mark: GoalongLaneMark) -> some View {
        switch mark {
        case .solid: RoundedRectangle(cornerRadius: 2).fill(GoalongLaneMatrix.solidColor).frame(width: 14, height: 7)
        case .faint: RoundedRectangle(cornerRadius: 2).fill(GoalongLaneMatrix.faintColor).frame(width: 14, height: 7)
        case .outlined: RoundedRectangle(cornerRadius: 2).strokeBorder(GoalongLaneMatrix.solidColor, lineWidth: 1).frame(width: 14, height: 7)
        case .tick: Rectangle().fill(LHTheme.text).frame(width: 1.5, height: 11)
        }
    }
}

// MARK: - Agents et code

/// « Agents et code » for one day: what development tools did, per project.
struct GoalongCodeDay: Equatable {
    struct Project: Identifiable, Equatable {
        let id: String
        var name: String
        /// T3 Code requests and the turns it ran.
        var requests = 0
        var running: [DateInterval] = []
        var parallel = 0
        /// Captured conversations of other agents: a count and their first-to-last spans.
        var conversations = 0
        var providers: [String] = []
        var spans: [DateInterval] = []
        var commits: [Date] = []
        var otherGitActions = 0
        /// Distinct files per five-minute window, summed over the windows.
        var fileChanges = 0
        var partial = false

        var runningSeconds: TimeInterval { GoalongDeveloperIntervals.unionSeconds(running) }
        var weight: Int { requests + conversations + commits.count + otherGitActions + fileChanges }
    }

    var projects: [Project] = []
    var unassignedConversations = 0
    /// Commits and file changes need « Activité de développement » and chosen projects.
    var followsProjects = false
    var followedProjects = 0

    var running: [DateInterval] { projects.flatMap(\.running) }
    var runningSeconds: TimeInterval { GoalongDeveloperIntervals.unionSeconds(running) }
    var requests: Int { projects.reduce(0) { $0 + $1.requests } }
    var commits: Int { projects.reduce(0) { $0 + $1.commits.count } }
    var fileChanges: Int { projects.reduce(0) { $0 + $1.fileChanges } }
    var conversations: Int { projects.reduce(0) { $0 + $1.conversations } + unassignedConversations }

    /// The key figure of the view, for its entry in « Explorer la journée ».
    var caption: String {
        guard !projects.isEmpty else {
            return unassignedConversations > 0
                ? Self.count(unassignedConversations, "conversation d’agent", "conversations d’agents") + " sans projet"
                : "Aucune activité de développement"
        }
        var parts = [Self.count(projects.count, "projet", "projets")]
        if requests > 0 { parts.append(Self.count(requests, "demande à T3", "demandes à T3")) }
        if commits > 0 { parts.append(Self.count(commits, "commit", "commits")) }
        else if fileChanges > 0 { parts.append(Self.count(fileChanges, "modification de fichier", "modifications de fichiers")) }
        else if conversations > 0 { parts.append(Self.count(conversations, "conversation", "conversations")) }
        return parts.joined(separator: " · ")
    }

    static func facts(_ project: Project) -> String {
        var parts: [String] = []
        if project.requests > 0 {
            parts.append(count(project.requests, "demande à T3", "demandes à T3"))
            if project.parallel > 1 { parts.append("jusqu’à \(project.parallel) tours en même temps") }
        }
        if project.conversations > 0 {
            let who = project.providers.filter { $0 != "T3 Code" }.joined(separator: ", ")
            parts.append(count(project.conversations, "conversation", "conversations") + (who.isEmpty ? "" : " \(who)"))
        }
        if !project.commits.isEmpty { parts.append(count(project.commits.count, "commit", "commits")) }
        if project.otherGitActions > 0 { parts.append(count(project.otherGitActions, "autre action Git", "autres actions Git")) }
        if project.fileChanges > 0 { parts.append(count(project.fileChanges, "modification de fichier", "modifications de fichiers")) }
        if project.partial { parts.append("données partielles") }
        return parts.joined(separator: " · ")
    }

    static func count(_ value: Int, _ one: String, _ many: String) -> String {
        "\(value.formatted(.number.locale(Locale(identifier: "fr_FR"))))\u{00A0}\(value > 1 ? many : one)"
    }
}

extension GoalongCodeDay {
    init(_ value: GoalongDeveloperDay) {
        var rows: [String: Project] = [:]
        func update(_ project: GoalongDeveloperProject, _ change: (inout Project) -> Void) {
            var row = rows[project.id] ?? Project(id: project.id, name: project.name)
            change(&row)
            rows[project.id] = row
        }
        for group in value.agents.projects {
            update(group.project) { row in
                row.conversations = group.sessions
                row.providers = group.providers.sorted()
                row.spans = group.documentIntervals
                row.partial = row.partial || group.partial
                if let t3 = group.t3 {
                    row.requests = t3.requests; row.running = t3.busyIntervals; row.parallel = t3.maximumParallelTurns
                }
            }
        }
        for git in value.git where !git.actions.isEmpty {
            update(git.project) { row in
                row.commits = git.commits
                row.otherGitActions = git.actions.count - git.commits.count
                row.partial = row.partial || git.status == .partial
            }
        }
        let followed = Dictionary(value.selectedProjects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for bucket in value.files.buckets where bucket.modifiedFiles > 0 {
            guard let project = followed[bucket.projectID] else { continue }
            update(project) { $0.fileChanges += bucket.modifiedFiles }
        }
        projects = rows.values.filter { $0.weight > 0 }.sorted {
            $0.weight == $1.weight ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : $0.weight > $1.weight
        }
        unassignedConversations = value.agents.unassignedSessions
        followsProjects = value.developerStatus != .disabled
        followedProjects = value.selectedProjects.count
    }
}

/// « Agents et code »: per project, what development tools did that day. Never active time.
struct GoalongCodeSection: View {
    let code: GoalongCodeDay
    let day: GoalongLocalAnalytics.Day
    var isPreview = false
    var onSettings: () -> Void = {}
    var onProjects: () -> Void = {}

    private static let shownProjects = 6

    var body: some View {
        let shown = Array(code.projects.prefix(Self.shownProjects))
        GoalongSection(title: "Agents et code", subtitle: lead) {
            VStack(alignment: .leading, spacing: 20) {
                if code.projects.isEmpty {
                    Text(code.unassignedConversations > 0
                         ? "Des conversations d’agents ont eu lieu, sans projet reconnu."
                         : "Aucune activité de développement observée ce jour-là.")
                        .font(.system(size: 13)).foregroundStyle(LHTheme.secondaryText)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        GoalongLaneLegend(items: legend(shown))
                        GoalongLaneMatrix(rows: rows(shown), range: range(shown), summary: code.caption)
                    }
                    VStack(spacing: 0) {
                        ForEach(Array(code.projects.enumerated()), id: \.element.id) { index, project in
                            if index > 0 { Divider().padding(.leading, 6) }
                            projectRow(project)
                        }
                    }
                }
                if let note = followNote {
                    HStack(alignment: .center, spacing: 12) {
                        GoalongNote(note.text)
                        Button(note.action, action: code.followsProjects ? onProjects : onSettings)
                            .buttonStyle(LHQuietButtonStyle()).font(.system(size: 13))
                            .disabled(isPreview)
                    }
                }
                Text("Un tour T3 compte du début à la fin de son exécution ; les tours qui se chevauchent comptent une fois. Les conversations des autres agents sont comptées, sans durée fiable. Commits et fichiers modifiés viennent des seuls projets suivis. Goalong ne lit ni les messages, ni le code, ni les messages de commit.")
                    .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityIdentifier("activity-code")
    }

    /// The answer first: how long the agents ran, and how much of it without the user.
    private var lead: String {
        let running = code.runningSeconds
        if running >= 60 {
            let projects = code.projects.filter { $0.runningSeconds > 0 }.count
            let away = GoalongIntervals.seconds(code.running, outside: GoalongIntervals.presence(day))
            var text = "T3 Code a exécuté des tours pendant \(GoalongAnalyticsFormatting.duration(running)) sur \(GoalongCodeDay.count(projects, "projet", "projets"))"
            if away >= 300 { text += ", dont \(GoalongAnalyticsFormatting.duration(away)) sans activité de votre part sur ce Mac" }
            return text + ". Ce temps ne s’ajoute jamais à votre temps actif."
        }
        guard !code.projects.isEmpty else { return "Ce que vos outils de développement ont fait ce jour-là." }
        var facts: [String] = []
        if code.commits > 0 { facts.append(GoalongCodeDay.count(code.commits, "commit", "commits")) }
        if code.fileChanges > 0 { facts.append(GoalongCodeDay.count(code.fileChanges, "modification de fichier", "modifications de fichiers")) }
        if code.conversations > 0 { facts.append(GoalongCodeDay.count(code.conversations, "conversation d’agent", "conversations d’agents")) }
        let list = facts.count > 1 ? facts.dropLast().joined(separator: ", ") + " et " + facts[facts.count - 1] : facts.joined()
        return "\(GoalongCodeDay.count(code.projects.count, "projet actif", "projets actifs")) ce jour-là" + (list.isEmpty ? "." : " : \(list).")
    }

    private var followNote: (text: String, action: String)? {
        if !code.followsProjects {
            return ("Pour voir aussi les commits et les fichiers modifiés de vos projets, activez « Activité de développement ».", "Réglages…")
        }
        if code.followedProjects == 0 {
            return ("Aucun projet suivi : choisissez vos projets pour voir leurs commits et leurs fichiers modifiés.", "Choisir les projets…")
        }
        return nil
    }

    private func legend(_ shown: [GoalongCodeDay.Project]) -> [(mark: GoalongLaneMark, title: String)] {
        var items: [(mark: GoalongLaneMark, title: String)] = []
        if shown.contains(where: { !$0.running.isEmpty }) { items.append((.solid, "Tour T3 en cours")) }
        if shown.contains(where: { !$0.spans.isEmpty }) { items.append((.faint, "Conversation d’agent, du premier au dernier message")) }
        if shown.contains(where: { !$0.commits.isEmpty }) { items.append((.tick, "Commit")) }
        return items
    }

    private func rows(_ shown: [GoalongCodeDay.Project]) -> [GoalongLaneMatrix.Row] {
        var rows: [GoalongLaneMatrix.Row] = []
        if day.segments.contains(where: { $0.kind.isActive }) {
            rows.append(.init(id: "you", label: "Vous", segments: day.segments))
        }
        for project in shown {
            rows.append(.init(id: project.id, label: project.name, solid: project.running, faint: project.spans, ticks: project.commits))
        }
        return rows
    }

    private func range(_ shown: [GoalongCodeDay.Project]) -> ClosedRange<Date> {
        let marks = shown.flatMap { project in
            project.running.flatMap { [$0.start, $0.end] } + project.spans.flatMap { [$0.start, $0.end] } + project.commits
        }
        return GoalongLaneMatrix.range(day: day, marks: marks)
    }

    private func projectRow(_ project: GoalongCodeDay.Project) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(project.name).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Text(GoalongCodeDay.facts(project)).font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if project.runningSeconds >= 60 {
                Text(GoalongAnalyticsFormatting.duration(project.runningSeconds))
                    .font(.system(size: 13, weight: .semibold)).monospacedDigit()
                    .help("Tours T3 en cours, comptés une fois quand ils se chevauchent")
            }
        }
        .padding(.vertical, 9).padding(.horizontal, 6)
        .accessibilityElement(children: .combine)
    }
}
#endif
