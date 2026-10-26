#if os(macOS)
    import Ambiance
    import SwiftUI

    /// The menu bar panel: tracking, today's thread, then the three daily actions
    /// (Concentration, Ambiance, Blocage). See docs/MENUBAR-PANEL-20261011.md.
    struct MenuBarPanelView: View {
        @ObservedObject var model: MenuBarPanelModel
        /// Reports the content's natural height so the popover can animate its own size
        /// instead of jumping while the content animates.
        var onHeightChange: (CGFloat) -> Void = { _ in }

        static let width: CGFloat = 340

        var body: some View {
            VStack(spacing: 0) {
                GoalongDevBanner()
                PanelHeader(model: model)
                PanelDivider()
                TodaySection(model: model)
                PanelDivider()
                FocusSection(model: model)
                PanelDivider()
                AmbianceSection(model: model)
                PanelDivider()
                BlockingSection(model: model)
                PanelFooter(model: model)
            }
            .frame(width: Self.width)
            .fixedSize(horizontal: false, vertical: true)
            .background(GeometryReader { Color.clear.preference(key: PanelHeightKey.self, value: $0.size.height) })
            .onPreferenceChange(PanelHeightKey.self) { onHeightChange($0) }
            // While the popover grows or shrinks, the content stays pinned to the top edge.
            .frame(maxHeight: .infinity, alignment: .top)
            .background(LHTheme.pageBackground)
            .clipped()
            .goalongControls()
        }
    }

    private struct PanelHeightKey: PreferenceKey {
        static var defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
    }

    // MARK: - Shared pieces

    private struct PanelDivider: View {
        var body: some View { Rectangle().fill(LHTheme.separator).frame(height: 1) }
    }

    private struct PanelSection<Trailing: View, Content: View>: View {
        let title: String
        @ViewBuilder var trailing: Trailing
        @ViewBuilder var content: Content

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(LHTheme.secondaryText)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 8)
                    trailing
                }
                content
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    extension PanelSection where Trailing == EmptyView {
        init(title: String, @ViewBuilder content: () -> Content) {
            self.init(title: title, trailing: { EmptyView() }, content: content)
        }
    }

    /// Square 28 pt icon button: raised by default, quiet in the footer.
    private struct PanelIconButton: View {
        let symbol: String
        let label: String
        var quiet = false
        var prominent = false
        let action: () -> Void
        @State private var hovered = false

        var body: some View {
            Button(action: action) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .foregroundStyle(prominent ? LHTheme.onAccent : (quiet ? LHTheme.secondaryText : LHTheme.text))
                    .background(
                        RoundedRectangle(cornerRadius: LHTheme.controlRadius, style: .continuous)
                            .fill(prominent ? (hovered ? LHTheme.actionHover : LHTheme.actionBackground)
                                : quiet ? (hovered ? LHTheme.hoverBackground : .clear)
                                : (hovered ? LHTheme.hoverBackground : LHTheme.elevatedBackground))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: LHTheme.controlRadius, style: .continuous)
                            .strokeBorder(quiet || prominent ? .clear : LHTheme.separator)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovered = $0 }
            .animation(LHTheme.hover, value: hovered)
            .help(label)
            .accessibilityLabel(label)
        }
    }

    private func durationText(_ seconds: TimeInterval) -> String {
        GoalongAnalyticsFormatting.duration(seconds)
    }

    private func clockText(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    // MARK: - Header (tracking)

    private struct PanelHeader: View {
        @ObservedObject var model: MenuBarPanelModel

        private var paused: Bool { if case .paused = model.tracking { return true }; return false }
        private var dotColor: Color {
            switch model.tracking {
            case .active: return LHTheme.success
            case .paused: return LHTheme.warning
            case .attention: return LHTheme.danger
            }
        }

        var body: some View {
            HStack(spacing: 10) {
                Image(nsImage: GoalongBrandAssets.menuBarImage)
                    .renderingMode(.template).resizable().scaledToFit()
                    .frame(width: 18, height: 18).foregroundStyle(LHTheme.text)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(ProductIdentity.displayName).font(.system(size: 13, weight: .semibold))
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Circle().fill(dotColor).frame(width: 6, height: 6)
                        VStack(alignment: .leading, spacing: 1) {
                            VStack(alignment: .leading, spacing: 1) {
                                if let title = model.attentionTitle {
                                    Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(LHTheme.text)
                                        .lineLimit(1).truncationMode(.tail)
                                }
                                Text(model.trackingDetail).font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                                    .lineLimit(model.attentionTitle == nil ? 1 : 3).truncationMode(.tail)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .accessibilityElement(children: .combine)
                            if let fix = model.attentionFix {
                                Button(fix.label) { model.perform(fix) }
                                    .buttonStyle(LHQuietButtonStyle()).font(.system(size: 12, weight: .medium))
                                    .accessibilityIdentifier("menubar-attention-fix")
                            }
                        }
                    }
                    .help(model.attentionTitle.map { "\($0) : \(model.trackingDetail)" } ?? model.trackingDetail)
                }
                Spacer(minLength: 8)
                PanelIconButton(
                    symbol: model.consentOff || model.globalPaused ? "gearshape.fill" : (paused ? "play.fill" : "pause.fill"),
                    label: model.headerActionLabel,
                    prominent: paused,
                    action: model.togglePause
                )
            }
            .padding(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 12))
        }
    }

    // MARK: - Today

    private struct TodaySection: View {
        @ObservedObject var model: MenuBarPanelModel

        var body: some View {
            PanelSection(title: "Aujourd’hui") {
                Button("Voir la journée", action: model.openDay).buttonStyle(LHQuietButtonStyle()).font(.system(size: 12, weight: .medium))
            } content: {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    WorkFigure(seconds: model.workSeconds, known: model.workKnown)
                    Text(model.otherSeconds >= 60
                        ? "de travail, \(durationText(model.otherSeconds)) hors travail" : "de travail")
                        .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText).lineLimit(1)
                }
                MiniDayThread(segments: model.segments, now: model.nowFraction)
                    .padding(.top, 4)
            }
        }
    }

    /// « 3 h 12 »: hours large, minutes one step down, like the app's period figure.
    private struct WorkFigure: View {
        let seconds: TimeInterval
        let known: Bool
        var body: some View {
            // Rounded like the Activity page, so both show the same figure for the same day.
            let minutes = Int((seconds / 60).rounded())
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if !known {
                    Text("—").font(.system(size: 28, weight: .bold)).tracking(-0.6)
                } else if seconds > 0 && seconds < 60 {
                    Text("< 1").font(.system(size: 28, weight: .bold)).tracking(-0.6)
                    Text("min").font(.system(size: 17, weight: .semibold)).tracking(-0.2)
                } else if minutes >= 60 {
                    Text("\(minutes / 60) h").font(.system(size: 28, weight: .bold)).tracking(-0.6)
                    Text(String(format: "%02d", minutes % 60)).font(.system(size: 17, weight: .semibold)).tracking(-0.2)
                } else {
                    Text("\(minutes)").font(.system(size: 28, weight: .bold)).tracking(-0.6)
                    Text("min").font(.system(size: 17, weight: .semibold)).tracking(-0.2)
                }
            }
            .goalongNumericTransition()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(known ? "\(durationText(seconds)) de travail aujourd’hui" : "Temps de travail aujourd’hui : à classer")
        }
    }

    /// The day as one line, 0 h to 24 h, thickened where there was activity. Drawn once on open.
    private struct MiniDayThread: View {
        let segments: [MenuBarPanelModel.DaySegment]
        let now: Double
        @State private var drawn: CGFloat = 0
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        private func color(_ kind: MenuBarPanelModel.DaySegment.Kind) -> Color {
            switch kind {
            case .work: return LHTheme.workData
            case .other: return LHTheme.otherData
            case .unclassified: return LHTheme.unclassifiedData
            }
        }

        var body: some View {
            VStack(spacing: 4) {
                GeometryReader { proxy in
                    let w = proxy.size.width
                    ZStack(alignment: .leading) {
                        Rectangle().fill(LHTheme.separator).frame(height: 1)
                        ForEach(segments) { segment in
                            RoundedRectangle(cornerRadius: LHTheme.markRadius, style: .continuous)
                                .fill(color(segment.kind))
                                .frame(width: max(3, (segment.end - segment.start) * w), height: 8)
                                .offset(x: segment.start * w)
                        }
                        RoundedRectangle(cornerRadius: 1).fill(LHTheme.text)
                            .frame(width: 2, height: 14).offset(x: min(w - 2, now * w))
                    }
                    .frame(width: w, height: 14)
                    .mask(alignment: .leading) { Rectangle().frame(width: w * drawn) }
                }
                .frame(height: 14)
                HStack {
                    ForEach(["0 h", "6 h", "12 h", "18 h", "24 h"], id: \.self) { label in
                        Text(label)
                        if label != "24 h" { Spacer(minLength: 0) }
                    }
                }
                .font(.system(size: 11).monospacedDigit()).foregroundStyle(LHTheme.secondaryText)
                .accessibilityHidden(true)
            }
            .onAppear {
                guard drawn == 0 else { return }
                if reduceMotion { drawn = 1 } else { withAnimation(LHTheme.draw) { drawn = 1 } }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Fil de la journée")
        }
    }

    // MARK: - Concentration

    private struct FocusSection: View {
        @ObservedObject var model: MenuBarPanelModel
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            PanelSection(title: "Concentration") {
                Group {
                    if let run = model.focusRun {
                        FocusRunning(run: run, model: model).transition(.opacity.combined(with: .move(edge: .trailing)))
                    } else if !model.concentrationEnabled {
                        InactiveRow(text: "Séances libres ou Pomodoro, avec blocage.",
                                    action: "Activer dans Réglages", perform: model.openModulesSettings)
                            .transition(.opacity)
                    } else {
                        FocusSetup(model: model).transition(.opacity.combined(with: .move(edge: .leading)))
                    }
                }
                .animation(reduceMotion ? nil : LHTheme.settle, value: model.focusRun == nil)
            }
        }
    }

    private struct FocusSetup: View {
        @ObservedObject var model: MenuBarPanelModel
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                GoalongSegmentedControl("Type de séance", selection: $model.focusKind,
                                        options: MenuBarPanelModel.FocusKind.allCases, fills: true) {
                    $0 == .pomodoro ? "Pomodoro" : "Libre"
                }
                if model.focusKind == .pomodoro {
                    HStack(spacing: 6) {
                        ForEach(model.focusMinuteChoices, id: \.self) { minutes in
                            ChoiceChip(title: "\(minutes) min", selected: model.focusMinutes == minutes) {
                                model.focusMinutes = minutes
                            }
                        }
                    }
                }
                Button(action: model.startFocus) {
                    Label("Commencer", systemImage: "play.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(LHPrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(!model.focusAvailable)
                if !model.focusAvailable, let reason = model.focusUnavailableReason {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(reason).font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        if let fix = model.focusUnavailableFix {
                            Spacer(minLength: 8)
                            Button(fix.label) { model.perform(fix) }
                                .buttonStyle(LHQuietButtonStyle()).font(.system(size: 12, weight: .medium))
                                .accessibilityIdentifier("menubar-focus-fix")
                        }
                    }
                }
            }
            .animation(reduceMotion ? nil : LHTheme.settle, value: model.focusKind)
        }
    }

    private struct FocusRunning: View {
        let run: MenuBarPanelModel.FocusRun
        @ObservedObject var model: MenuBarPanelModel

        private var meta: String {
            var parts: [String] = []
            if let cycle = run.cycle, let cycles = run.cycles { parts.append("Cycle \(cycle) sur \(cycles)") }
            if let next = run.nextBreak, !run.isPaused { parts.append("pause à \(GoalongUIFormat.time(next))") }
            if run.isPaused { parts.append("en pause") }
            return parts.joined(separator: ", ")
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 12) {
                    Text(clockText(run.remaining ?? run.elapsed))
                        .font(.system(size: 34, weight: .bold).monospacedDigit()).tracking(-1)
                        .goalongNumericTransition()
                        .opacity(run.isPaused ? 0.55 : 1)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(run.phaseTitle).font(.system(size: 13, weight: .semibold))
                        if !meta.isEmpty {
                            Text(meta).font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText).lineLimit(2)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                if let progress = run.progress {
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(LHTheme.separator).frame(height: 1)
                            Capsule().fill(LHTheme.workData)
                                .frame(width: max(4, proxy.size.width * min(1, max(0, progress))), height: 4)
                        }
                        .frame(maxHeight: .infinity)
                    }
                    .frame(height: 4)
                    .animation(.linear(duration: 1), value: progress)
                    .accessibilityHidden(true)
                }
                HStack(spacing: 8) {
                    if let cycle = run.cycle, let cycles = run.cycles {
                        HStack(spacing: 4) {
                            ForEach(1...max(1, cycles), id: \.self) { index in
                                Capsule().fill(index <= cycle ? LHTheme.workData : LHTheme.separator).frame(width: 14, height: 4)
                            }
                        }
                        .accessibilityHidden(true)
                    }
                    Spacer(minLength: 8)
                    Button("Arrêter", action: model.stopFocus)
                        .buttonStyle(LHSecondaryButtonStyle()).controlSize(.small)
                }
            }
        }
    }

    private struct ChoiceChip: View {
        let title: String
        let selected: Bool
        let action: () -> Void
        @State private var hovered = false

        var body: some View {
            Button(action: action) {
                Text(title)
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .lineLimit(1)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: LHTheme.controlRadius, style: .continuous)
                            .fill(hovered ? LHTheme.hoverBackground : LHTheme.elevatedBackground)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: LHTheme.controlRadius, style: .continuous)
                            .strokeBorder(selected ? LHTheme.accent : LHTheme.separator, lineWidth: selected ? 2 : 1)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovered = $0 }
            .animation(LHTheme.hover, value: hovered)
            .accessibilityAddTraits(selected ? .isSelected : [])
        }
    }

    // MARK: - Ambiance

    private struct AmbianceSection: View {
        @ObservedObject var model: MenuBarPanelModel
        @State private var expanded = false
        @State private var tab: MenuBarPanelModel.AmbianceTab = .focus
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        private func kind(of tab: MenuBarPanelModel.AmbianceTab) -> AmbianceSource.Kind {
            switch tab { case .focus: return .focus; case .relax: return .relax; case .texture: return .texture; case .ownFile: return .ownFile }
        }

        private func tabTitle(_ tab: MenuBarPanelModel.AmbianceTab) -> String {
            kind(of: tab).displayName
        }

        private func kindTitle(_ kind: AmbianceSource.Kind) -> String {
            kind.displayName
        }

        private var tabs: [MenuBarPanelModel.AmbianceTab] {
            MenuBarPanelModel.AmbianceTab.allCases.filter { t in model.ambianceSources.contains { $0.kind == kind(of: t) } }
        }

        private var showsGrid: Bool { expanded || model.ambiancePlaying }

        var body: some View {
            PanelSection(title: "Ambiance") {
                if model.ambianceEnabled {
                    Button(showsGrid ? "Réduire" : "Choisir un son") {
                        withAnimation(reduceMotion ? nil : LHTheme.settle) { expanded.toggle() }
                    }
                    .buttonStyle(LHQuietButtonStyle()).font(.system(size: 12, weight: .medium))
                    .opacity(model.ambiancePlaying ? 0 : 1)
                    .disabled(model.ambiancePlaying)
                }
            } content: {
                if !model.ambianceEnabled {
                    InactiveRow(text: "Musique générative pour travailler ou se reposer.",
                                action: "Activer dans Réglages", perform: model.enableAmbiance)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        player
                        volume
                        if let error = model.ambianceError {
                            Text(error).font(.system(size: 12)).foregroundStyle(LHTheme.danger)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if showsGrid { grid.transition(.opacity) }
                    }
                    .padding(EdgeInsets(top: 10, leading: 12, bottom: 12, trailing: 12))
                    .background(RoundedRectangle(cornerRadius: LHTheme.cardRadius, style: .continuous).fill(LHTheme.cardBackground))
                    .overlay(RoundedRectangle(cornerRadius: LHTheme.cardRadius, style: .continuous).strokeBorder(LHTheme.separator))
                    .animation(reduceMotion ? nil : LHTheme.settle, value: showsGrid)
                    .onAppear { if let current = model.ambianceCurrent { tab = tabFor(current.kind) } }
                }
            }
        }

        private func tabFor(_ kind: AmbianceSource.Kind) -> MenuBarPanelModel.AmbianceTab {
            switch kind { case .focus: return .focus; case .relax: return .relax; case .texture: return .texture; case .ownFile: return .ownFile }
        }

        private var player: some View {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: LHTheme.controlRadius, style: .continuous).fill(LHTheme.fieldBackground)
                    RoundedRectangle(cornerRadius: LHTheme.controlRadius, style: .continuous).strokeBorder(LHTheme.separator)
                    if let current = model.ambianceCurrent {
                        AmbianceWave(seed: current.id, character: AmbianceWaveCharacter(current),
                                     look: model.ambianceLoading ? .waiting : (model.ambiancePlaying ? .active : .idle))
                            .padding(.horizontal, 6).padding(.vertical, 10)
                    }
                }
                .frame(width: 40, height: 40)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.ambianceCurrent?.title ?? "Aucun son choisi")
                        .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: 4)
                if model.ambiancePlaying {
                    PanelIconButton(symbol: "forward.fill", label: "Son suivant", quiet: true, action: model.playNext)
                }
                Button(action: model.togglePlay) {
                    Image(systemName: model.ambiancePlaying ? "stop.fill" : "play.fill")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(LHTheme.elevatedBackground))
                        .overlay(Circle().strokeBorder(LHTheme.separator))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(model.ambianceCurrent == nil || model.ambianceLoading)
                .help(model.ambiancePlaying ? "Arrêter" : "Lire")
                .accessibilityLabel(model.ambiancePlaying ? "Arrêter l’Ambiance" : "Lire l’Ambiance")
            }
        }

        private var subtitle: String {
            guard let current = model.ambianceCurrent else { return "Choisissez un son ci-dessous" }
            if model.ambianceLoading { return "\(kindTitle(current.kind)), chargement…" }
            return model.ambiancePlaying ? "\(kindTitle(current.kind)), en cours" : "\(kindTitle(current.kind)), écouté en dernier"
        }

        private var volume: some View {
            HStack(spacing: 8) {
                Image(systemName: "speaker.fill").font(.system(size: 10))
                Slider(value: $model.ambianceVolume, in: 0...1)
                    .controlSize(.small)
                    .tint(LHTheme.secondaryText)
                    .accessibilityLabel("Volume de l’Ambiance")
                Image(systemName: "speaker.wave.2.fill").font(.system(size: 10))
            }
            .foregroundStyle(LHTheme.secondaryText)
        }

        private var grid: some View {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 2) {
                    ForEach(tabs, id: \.self) { t in
                        Button { tab = t } label: {
                            Text(tabTitle(t)).font(.system(size: 12, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
                                .foregroundStyle(tab == t ? LHTheme.text : LHTheme.secondaryText)
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(tab == t ? LHTheme.elevatedBackground : .clear))
                                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(tab == t ? LHTheme.separator : .clear))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(tab == t ? .isSelected : [])
                    }
                }
                let sources = model.ambianceSources.filter { $0.kind == kind(of: tab) }
                if sources.isEmpty {
                    Text("Aucun son ici pour l’instant.").font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                } else {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                        ForEach(sources) { source in
                            SoundTile(source: source, selected: source.id == model.ambianceCurrent?.id && model.ambiancePlaying) {
                                model.play(source)
                            }
                        }
                    }
                }
            }
        }
    }

    private struct SoundTile: View {
        let source: AmbianceSource
        let selected: Bool
        let action: () -> Void
        @State private var hovered = false

        var body: some View {
            Button(action: action) {
                HStack(spacing: 4) {
                    Text(source.title).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 0)
                    if !source.isAvailable { Image(systemName: "arrow.down.circle").font(.system(size: 10)) }
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(source.isAvailable ? LHTheme.text : LHTheme.secondaryText)
                .padding(.horizontal, 8).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: LHTheme.controlRadius, style: .continuous)
                    .fill(hovered ? LHTheme.hoverBackground : LHTheme.elevatedBackground))
                .overlay(RoundedRectangle(cornerRadius: LHTheme.controlRadius, style: .continuous)
                    .strokeBorder(selected ? LHTheme.accent : LHTheme.separator, lineWidth: selected ? 2 : 1))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!source.isAvailable)
            .onHover { hovered = $0 }
            .animation(LHTheme.hover, value: hovered)
            .help(source.isAvailable ? source.title : "\(source.title) : à télécharger dans Ambiance")
            .accessibilityAddTraits(selected ? .isSelected : [])
        }
    }

    // MARK: - Blocage

    private struct BlockingSection: View {
        @ObservedObject var model: MenuBarPanelModel

        var body: some View {
            PanelSection(title: "Blocage") {
                if !model.blockingEnabled {
                    InactiveRow(text: "Bloquez les sites et apps qui vous distraient.",
                                action: "Activer dans Réglages", perform: model.openModulesSettings)
                } else if model.blockLists.isEmpty {
                    InactiveRow(text: "Aucune liste pour l’instant.", action: "Créer une liste", perform: model.openApp)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(model.blockLists.enumerated()), id: \.element.id) { index, list in
                            if index > 0 { Rectangle().fill(LHTheme.separator).frame(height: 1).padding(.leading, 24) }
                            BlockRow(list: list, model: model)
                        }
                    }
                }
            }
        }
    }

    private struct BlockRow: View {
        let list: MenuBarPanelModel.BlockList
        @ObservedObject var model: MenuBarPanelModel

        var body: some View {
            HStack(spacing: 10) {
                Image(systemName: list.isLocked ? "lock.fill" : "shield")
                    .font(.system(size: 12))
                    .foregroundStyle(list.isLocked || list.isActive ? LHTheme.text : LHTheme.secondaryText)
                    .frame(width: 14)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(list.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Text(list.detail).font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: 8)
                if list.isLocked {
                    Button("Arrêter…") { model.requestStopBlocking(list.id) }
                        .buttonStyle(LHQuietButtonStyle()).font(.system(size: 12, weight: .medium))
                        .accessibilityLabel("Demander l’arrêt de \(list.title)")
                } else {
                    Toggle("Bloquer \(list.title)", isOn: Binding(get: { list.isActive }, set: { model.setBlockList(list.id, active: $0) }))
                        .toggleStyle(GoalongSwitchStyle(layout: .switchOnly))
                        .controlSize(.small)
                        .help(list.isActive ? "Arrêter ce blocage" : "Bloquer jusqu’à minuit")
                }
            }
            .frame(minHeight: 40)
            .padding(.vertical, 2)
        }
    }

    private struct InactiveRow: View {
        let text: String
        let action: String
        let perform: () -> Void

        var body: some View {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(text).font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button(action, action: perform).buttonStyle(LHQuietButtonStyle()).font(.system(size: 12, weight: .medium))
            }
        }
    }

    // MARK: - Footer

    private struct PanelFooter: View {
        @ObservedObject var model: MenuBarPanelModel
        @State private var hovered = false

        var body: some View {
            HStack(spacing: 4) {
                Button(action: model.openApp) {
                    HStack(spacing: 6) {
                        Text("Ouvrir \(ProductIdentity.displayName)").font(.system(size: 13, weight: .medium))
                        Text("⌘O").font(.system(size: 11)).foregroundStyle(LHTheme.secondaryText)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8).frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: LHTheme.controlRadius, style: .continuous)
                        .fill(hovered ? LHTheme.hoverBackground : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut("o", modifiers: .command)
                .onHover { hovered = $0 }
                PanelIconButton(symbol: "gearshape", label: "Réglages", quiet: true, action: model.openSettings)
                PanelIconButton(symbol: "ellipsis", label: "Plus d’options", quiet: true, action: model.showClassicMenu)
            }
            .padding(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
            .overlay(alignment: .top) { Rectangle().fill(LHTheme.separator).frame(height: 1) }
        }
    }
#endif
