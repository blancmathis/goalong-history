#if os(macOS)
import SwiftUI

/// The week as seven threads, Monday to Sunday on one 0–24 h scale, like Activité's weave, and the
/// one place where programs are edited: drag on a day to draw a range, click a range to change it.
/// A range is solid when its program is locked, quieter when free, outlined when it slows down.
/// The present is the lime point on today's thread.
@MainActor struct BlockingWeekEditor: View {
    @ObservedObject var controller: BlockingController
    let now: Date
    @State private var dragging: (day: Int, start: Int, end: Int)?
    @State private var editing: BlockingRangeDraft?

    private static let rowHeight: CGFloat = 26
    private static let laneHeight: CGFloat = 18
    private static let label: CGFloat = 34
    private static let gap: CGFloat = 10
    private static let spacing: CGFloat = 4

    fileprivate struct Span: Hashable {
        var listID: UUID
        var rangeID: UUID
        var start: Int
        var end: Int
        var locked: Bool
        var lock: BlockLock
        var slowed: Bool
        var name: String
        var lane = 0
    }

    private var today: Int { BlockingSchedule.isoWeekday(now) }
    private var nowMinute: Int {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: now)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    /// Per day, the ranges that touch it, each on the first lane where it does not overlap another.
    private var spans: [Int: [Span]] {
        var result: [Int: [Span]] = [:]
        for list in controller.lists {
            let locked = list.program.isLocked(at: now)
            let slowed = list.effectiveAction == .slowDown
            for range in list.program.ranges {
                func add(_ day: Int, _ start: Int, _ end: Int) {
                    result[day, default: []].append(Span(listID: list.id, rangeID: range.id, start: start, end: end,
                                                         locked: locked, lock: locked ? .locked : range.effectiveLock,
                                                         slowed: slowed, name: list.name))
                }
                for day in range.weekdays {
                    if range.crossesMidnight {
                        add(day, range.startMinute, 1_440)
                        if range.endMinute > 0 { add(day % 7 + 1, 0, range.endMinute) }
                    } else {
                        add(day, range.startMinute, range.endMinute)
                    }
                }
            }
        }
        for (day, items) in result {
            var lanes: [Int] = []
            result[day] = items.sorted { ($0.start, $0.end) < ($1.start, $1.end) }.map { span in
                var span = span
                if let free = lanes.firstIndex(where: { $0 <= span.start }) {
                    span.lane = free; lanes[free] = span.end
                } else {
                    span.lane = lanes.count; lanes.append(span.end)
                }
                return span
            }
        }
        return result
    }

    var body: some View {
        let spans = self.spans
        let heights = (1...7).map { day in
            CGFloat(max(1, (spans[day]?.map(\.lane).max() ?? 0) + 1)) * Self.laneHeight + Self.rowHeight - Self.laneHeight
        }
        VStack(alignment: .leading, spacing: Self.spacing) {
            ForEach(1...7, id: \.self) { day in
                HStack(spacing: Self.gap) {
                    Text(BlockingFormat.weekdayShort[day - 1])
                        .font(.system(size: 12, weight: day == today ? .semibold : .regular))
                        .foregroundStyle(day == today ? LHTheme.text : LHTheme.secondaryText)
                        .frame(width: Self.label, alignment: .leading)
                    GeometryReader { proxy in
                        dayRow(day, spans: spans[day] ?? [], width: proxy.size.width, height: heights[day - 1],
                               top: heights.prefix(day - 1).reduce(0, +) + CGFloat(day - 1) * Self.spacing)
                    }
                    .frame(height: heights[day - 1])
                }
            }
            HStack(spacing: Self.gap) {
                Color.clear.frame(width: Self.label, height: 1)
                GeometryReader { proxy in
                    ForEach([0, 6, 12, 18, 24], id: \.self) { hour in
                        Text("\(hour) h").font(.system(size: 11).monospacedDigit()).foregroundStyle(LHTheme.tertiaryText)
                            .fixedSize()
                            .position(x: min(max(10, proxy.size.width * CGFloat(hour) / 24), proxy.size.width - 12), y: 7)
                    }
                }
                .frame(height: 14)
            }
            HStack(spacing: 16) {
                legend(Capsule().fill(LHTheme.text), "Verrouillé")
                legend(Capsule().fill(LHTheme.text.opacity(0.42)), "Libre")
                legend(Capsule().strokeBorder(LHTheme.text.opacity(0.7), lineWidth: 1.5), "Ralenti")
                HStack(spacing: 6) {
                    Circle().fill(LHTheme.accent).frame(width: 8, height: 8)
                    Text("Maintenant")
                }
            }
            .font(.system(size: 11)).foregroundStyle(LHTheme.secondaryText)
            .padding(.leading, Self.label + Self.gap).padding(.top, 6)
        }
        .coordinateSpace(name: "blocking-week")
        .popover(item: $editing, attachmentAnchor: .rect(.rect(editing?.anchor ?? .zero)), arrowEdge: .bottom) { draft in
            BlockingRangePopover(controller: controller, draft: draft, now: now) { editing = nil }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityIdentifier("blocking-week")
    }

    private func dayRow(_ day: Int, spans: [Span], width: CGFloat, height: CGFloat, top: CGFloat) -> some View {
        let origin = Self.label + Self.gap
        func x(_ minute: Int) -> CGFloat { width * CGFloat(minute) / 1_440 }
        func minute(_ x: CGFloat) -> Int { min(1_440, max(0, Int((x / max(1, width) * 1_440 / 15).rounded()) * 15)) }
        return ZStack(alignment: .topLeading) {
            Rectangle().fill(LHTheme.tertiaryText.opacity(0.45)).frame(height: 1)
                .offset(y: Self.laneHeight / 2 + (Self.rowHeight - Self.laneHeight) / 2)
            ForEach(spans, id: \.self) { span in
                spanView(span, width: max(Self.laneHeight, x(span.end) - x(span.start)))
                    .offset(x: x(span.start), y: (Self.rowHeight - Self.laneHeight) / 2 + CGFloat(span.lane) * Self.laneHeight)
                    .onTapGesture {
                        guard let list = controller.list(span.listID),
                              let range = list.program.ranges.first(where: { $0.id == span.rangeID }) else { return }
                        editing = BlockingRangeDraft(existing: span.rangeID, listIDs: [list.id], days: range.weekdays,
                                                     start: range.startMinute, end: range.endMinute, lock: range.effectiveLock,
                                                     anchor: CGRect(x: origin + x(span.start), y: top, width: x(span.end) - x(span.start), height: Self.rowHeight))
                    }
            }
            if let dragging, dragging.day == day {
                let low = min(dragging.start, dragging.end), high = max(dragging.start, dragging.end)
                Capsule().fill(LHTheme.accent.opacity(0.25))
                    .overlay(Capsule().strokeBorder(LHTheme.accent, lineWidth: 1.5))
                    .frame(width: max(Self.laneHeight, x(high) - x(low)), height: Self.laneHeight)
                    .overlay(alignment: .top) {
                        Text("\(BlockingFormat.minuteOfDay(low)) → \(high == 1_440 ? "24:00" : BlockingFormat.minuteOfDay(high))")
                            .font(.system(size: 11, weight: .medium).monospacedDigit()).fixedSize()
                            .offset(y: -16)
                    }
                    .offset(x: x(low), y: (Self.rowHeight - Self.laneHeight) / 2)
                    .allowsHitTesting(false)
            }
            if day == today {
                Circle().fill(LHTheme.accent)
                    .overlay(Circle().strokeBorder(LHTheme.pageBackground, lineWidth: 2))
                    .frame(width: 12, height: 12)
                    .offset(x: x(nowMinute) - 6, y: Self.rowHeight / 2 - 6)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    dragging = (day, minute(value.startLocation.x), minute(value.location.x))
                }
                .onEnded { value in
                    var start = minute(value.startLocation.x), end = minute(value.location.x)
                    if end < start { swap(&start, &end) }
                    // A click without a drag draws one hour from there.
                    if end - start < 15 { start = min(start, 1_380); end = start + 60 }
                    dragging = nil
                    guard !controller.lists.isEmpty else { return }
                    editing = BlockingRangeDraft(existing: nil, listIDs: [controller.lists[0].id], days: [day],
                                                 start: start, end: end == 1_440 ? 1_440 : end,
                                                 anchor: CGRect(x: origin + x(start), y: top, width: x(end) - x(start), height: Self.rowHeight))
                }
        )
        .help("Glissez pour programmer un blocage")
    }

    private func spanView(_ span: Span, width: CGFloat) -> some View {
        let ink = LHTheme.text.opacity(span.slowed ? 1 : (span.lock.protectsLists ? 1 : 0.42))
        return ZStack(alignment: .leading) {
            if span.slowed {
                Capsule().fill(LHTheme.pageBackground)
                Capsule().strokeBorder(LHTheme.text.opacity(span.locked ? 1 : 0.55), lineWidth: 1.5)
            } else {
                // Opaque even when quiet: the day's thread must not show through.
                Capsule().fill(LHTheme.pageBackground)
                Capsule().fill(ink)
            }
            if width > CGFloat(span.name.count) * 6.5 + 26 {
                HStack(spacing: 4) {
                    if span.lock != .free { Image(systemName: span.lock.symbol).font(.system(size: 8, weight: .bold)) }
                    Text(span.name).font(.system(size: 10.5, weight: .semibold)).lineLimit(1)
                }
                .foregroundStyle(span.slowed || !span.locked ? LHTheme.text : LHTheme.pageBackground)
                .padding(.horizontal, 9)
            }
        }
        .frame(width: width, height: Self.laneHeight - 3)
        .padding(.vertical, 1.5)
        .contentShape(Capsule())
        .help("\(span.name) · \(BlockingFormat.minuteOfDay(span.start)) → \(span.end == 1_440 ? "24:00" : BlockingFormat.minuteOfDay(span.end))")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(span.name), \(BlockingFormat.minuteOfDay(span.start)) à \(BlockingFormat.minuteOfDay(span.end % 1_440))")
        .accessibilityAddTraits(.isButton)
    }

    private func legend(_ mark: some View, _ text: String) -> some View {
        HStack(spacing: 6) {
            mark.frame(width: 18, height: 7)
            Text(text)
        }
    }

    private var accessibilitySummary: String {
        let parts = controller.lists.flatMap { list in
            list.program.ranges.map { "\(list.name) : \(BlockingFormat.weekdays($0.weekdays)), \(BlockingFormat.range($0))" }
        }
        return parts.isEmpty ? "Semaine sans programme" : "Semaine : " + parts.joined(separator: " ; ")
    }
}

/// A range being drawn or changed in the week.
struct BlockingRangeDraft: Identifiable {
    var id = UUID()
    /// The range changed, or nil for a new one.
    var existing: UUID?
    var listIDs: Set<UUID>
    var days: Set<Int>
    var start: Int
    var end: Int
    var lock: BlockLock = .free
    var anchor: CGRect = .zero
}

/// Which lists, which days, from when to when. A new range is added to every chosen list.
@MainActor struct BlockingRangePopover: View {
    @ObservedObject var controller: BlockingController
    let now: Date
    var onClose: () -> Void
    @State private var draft: BlockingRangeDraft
    @State private var start: Date
    @State private var end: Date

    init(controller: BlockingController, draft: BlockingRangeDraft, now: Date, onClose: @escaping () -> Void) {
        self.controller = controller
        self.now = now
        self.onClose = onClose
        _draft = State(initialValue: draft)
        let midnight = Calendar.current.startOfDay(for: now)
        _start = State(initialValue: midnight.addingTimeInterval(TimeInterval(draft.start * 60)))
        _end = State(initialValue: midnight.addingTimeInterval(TimeInterval(draft.end % 1_440 * 60)))
    }

    private var list: BlockList? { draft.existing == nil ? nil : draft.listIDs.first.flatMap(controller.list) }
    private var locked: Bool { list?.program.isLocked(at: now) ?? false }
    /// While the program is locked, a range's lock can only rise.
    private var minimumLock: BlockLock {
        guard locked, let existing = draft.existing,
              let range = list?.program.ranges.first(where: { $0.id == existing }) else { return .free }
        return range.effectiveLock
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(list?.name ?? "Programmer un blocage").font(LHTheme.cardTitleFont)
            if draft.existing == nil {
                BlockingFlow(spacing: 6) {
                    ForEach(controller.lists) { list in
                        BlockingListChip(list: list, selected: draft.listIDs.contains(list.id)) {
                            if draft.listIDs.contains(list.id) { draft.listIDs.remove(list.id) } else { draft.listIDs.insert(list.id) }
                        }
                    }
                    BlockingNewListChip { draft.listIDs.insert($0) }
                }
            }
            HStack(spacing: 3) {
                ForEach(1...7, id: \.self) { day in
                    let on = draft.days.contains(day)
                    Button {
                        if on { draft.days.remove(day) } else { draft.days.insert(day) }
                    } label: {
                        Text(BlockingFormat.weekdayLetters[day - 1]).font(.system(size: 12, weight: .semibold))
                            .frame(width: 26, height: 26)
                            .foregroundStyle(on ? LHTheme.onAccent : LHTheme.secondaryText)
                            .background(on ? LHTheme.actionBackground : LHTheme.insetBackground,
                                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(BlockingFormat.weekdayShort[day - 1])
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
                Spacer(minLength: 10)
                HStack(spacing: 12) {
                    Button("Lun–ven") { draft.days = Set(1...5) }.buttonStyle(LHQuietButtonStyle())
                    Button("Tous") { draft.days = Set(1...7) }.buttonStyle(LHQuietButtonStyle())
                }
            }
            HStack(spacing: 12) {
                DatePicker("De", selection: $start, displayedComponents: .hourAndMinute).fixedSize()
                    .environment(\.locale, Locale(identifier: "fr_FR"))
                DatePicker("à", selection: $end, displayedComponents: .hourAndMinute).fixedSize()
                    .environment(\.locale, Locale(identifier: "fr_FR"))
                if minutes(end) <= minutes(start), minutes(end) != 0 {
                    Text("le lendemain").font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Arrêt").font(.system(size: 12, weight: .medium)).foregroundStyle(LHTheme.secondaryText)
                BlockingLockPicker(controller: controller, lock: $draft.lock, minimum: minimumLock)
            }
            if locked {
                GoalongNote("Programme verrouillé : la plage peut seulement s’allonger ou se durcir.", symbol: "lock.fill")
            }
            if let error = controller.error {
                GoalongNote(error, tone: .warning)
            }
            HStack {
                if draft.existing != nil, !locked {
                    Button("Retirer", role: .destructive) { remove() }.buttonStyle(LHQuietButtonStyle())
                }
                Spacer()
                Button("Annuler", action: onClose).keyboardShortcut(.cancelAction)
                Button(draft.existing == nil ? "Programmer" : "Enregistrer", action: save)
                    .buttonStyle(LHPrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.days.isEmpty || draft.listIDs.isEmpty || minutes(start) == minutes(end)
                              || (draft.lock == .password && !controller.hasPassword))
                    .accessibilityIdentifier("blocking-range-save")
            }
        }
        .font(.system(size: 13))
        .padding(18).frame(width: 440)
        .goalongControls()
    }

    private func minutes(_ date: Date) -> Int {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    private func range(id: UUID = UUID()) -> BlockProgramRange {
        BlockProgramRange(id: id, weekdays: draft.days, startMinute: minutes(start),
                          endMinute: minutes(end) == 0 ? 1_440 : minutes(end), lock: draft.lock == .free ? nil : draft.lock)
    }

    private func save() {
        if let existing = draft.existing, var next = list,
           let index = next.program.ranges.firstIndex(where: { $0.id == existing }) {
            next.program.ranges[index] = range(id: existing)
            controller.save(next)
        } else {
            for id in controller.lists.map(\.id) where draft.listIDs.contains(id) {
                guard var next = controller.list(id) else { continue }
                next.program.ranges.append(range())
                controller.save(next)
            }
        }
        onClose()
    }

    private func remove() {
        guard let existing = draft.existing, var next = list else { return }
        next.program.ranges.removeAll { $0.id == existing }
        controller.save(next)
        onClose()
    }
}
#endif
