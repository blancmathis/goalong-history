#if os(macOS)
import Ambiance
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The whole module on one page: what plays, the pieces to choose from, the member's own
/// music and the downloaded sounds. Nothing plays until the member presses a piece.
@MainActor struct AmbiancePage: View {
    @ObservedObject var model: DashboardViewModel
    @ObservedObject private var modules = GoalongModuleStore.shared

    var body: some View {
        if modules.isEnabled(.ambiance), let controller = model.ambianceModule.controller {
            AmbianceLivePage(controller: controller, settings: model.ambianceModule.settings)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("Ambiance").goalongPageTitle()
                Text("Le module est désactivé. Activez-le dans Réglages › Modules.")
                    .font(.system(size: 13)).foregroundStyle(LHTheme.secondaryText)
            }
            .padding(.horizontal, LHTheme.pageInset).padding(.top, 28)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(LHTheme.pageBackground)
        }
    }
}

@MainActor private struct AmbianceLivePage: View {
    @ObservedObject var controller: AmbianceController
    let settings: AmbianceSettings

    var body: some View {
        AmbiancePageContent(
            sources: controller.sources, packs: controller.packs, state: controller.state,
            lastSource: settings.lastSource,
            volume: Binding(get: { controller.volume }, set: { controller.volume = $0 }),
            actions: AmbianceActions(
                play: { source in settings.lastSource = source.id; controller.play(source) },
                stop: { controller.stop() },
                download: { controller.download($0) },
                cancel: { controller.cancelDownload($0) },
                remove: { controller.remove($0) },
                addFiles: { controller.addOwnFiles($0) },
                removeFile: { controller.removeOwnFile($0) }
            )
        )
        .onAppear { controller.refresh() }
    }
}

struct AmbianceActions {
    var play: (AmbianceSource) -> Void
    var stop: () -> Void
    var download: (String) -> Void
    var cancel: (String) -> Void
    var remove: (String) -> Void
    var addFiles: ([URL]) -> Void
    var removeFile: (AmbianceSource) -> Void
}

/// Values in, actions out, so renders and tests can show every state.
struct AmbiancePageContent: View {
    let sources: [AmbianceSource]
    let packs: [AmbiancePackState]
    let state: AmbianceController.State
    var lastSource: String?
    @Binding var volume: Double
    let actions: AmbianceActions

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LHTheme.sectionSpacing) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Ambiance").goalongPageTitle()
                    Text("Une musique sans paroles qui ne se répète jamais, pour travailler ou souffler.")
                        .font(.system(size: 13)).foregroundStyle(LHTheme.secondaryText)
                }
                VStack(alignment: .leading, spacing: 12) {
                    if pack("orchestra")?.status == .installed, let current {
                        AmbiancePlayer(source: current, state: state, volume: $volume, actions: actions)
                    } else if let orchestra = pack("orchestra") {
                        AmbianceOrchestraSetup(pack: orchestra, pieces: pieces.count, actions: actions)
                    }
                    if case .error(let message) = state {
                        GoalongNote(message, symbol: "exclamationmark.triangle", tone: .warning)
                            .accessibilityIdentifier("ambiance-error")
                    }
                }
                tiles("Concentration", subtitle: "Pour travailler.", kind: .focus)
                tiles("Détente", subtitle: "Pour souffler.", kind: .relax)
                textures
                ownMusic
                downloaded
                promises
            }
            .font(.system(size: 13))
            .frame(maxWidth: LHTheme.readableWidth, alignment: .leading)
            .padding(.horizontal, LHTheme.pageInset).padding(.top, 28).padding(.bottom, 48)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(LHTheme.pageBackground)
        .accessibilityIdentifier("ambiance-page")
    }

    // MARK: State

    private var playingID: String? {
        if case .playing(let source) = state { return source.id }
        return nil
    }

    private var pieces: [AmbianceSource] { sources.filter { $0.kind == .focus || $0.kind == .relax } }

    /// The piece that plays, else the last one played, else the first focus piece.
    private var current: AmbianceSource? {
        if case .playing(let source) = state { return source }
        return sources.first { $0.id == lastSource && $0.isAvailable } ?? sources.first { $0.kind == .focus }
    }

    private func pack(_ id: String) -> AmbiancePackState? { packs.first { $0.id == id } }

    private func toggle(_ source: AmbianceSource) {
        if playingID == source.id { actions.stop() } else { actions.play(source) }
    }

    // MARK: Sections

    private func tiles(_ title: String, subtitle: String, kind: AmbianceSource.Kind) -> some View {
        let items = sources.filter { $0.kind == kind }
        // Full rows only: eight pieces sit in fours, five in fives.
        let columns = items.count.isMultiple(of: 5) ? 5 : 4
        return GoalongSection(title: title, subtitle: subtitle) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: columns),
                      alignment: .leading, spacing: 12) {
                ForEach(items) { source in
                    AmbianceTile(source: source, playing: playingID == source.id,
                                 current: current?.id == source.id && source.isAvailable) { toggle(source) }
                }
            }
        }
    }

    @ViewBuilder private var textures: some View {
        let items = sources.filter { $0.kind == .texture }
        if !items.isEmpty {
            tiles("Textures", subtitle: "Des sons continus, sans mélodie.", kind: .texture)
        } else if let pack = pack("textures") {
            GoalongSection(title: "Textures", subtitle: "Des sons continus, sans mélodie.") {
                VStack(alignment: .leading, spacing: 12) {
                    LHCard(padding: 0) {
                        AmbiancePackRow(pack: pack, title: "Pluie, marée, bruits doux", seed: "rain",
                                        character: .rain, actions: actions)
                    }
                    if case .failed(let message) = pack.status {
                        GoalongNote(message, symbol: "exclamationmark.triangle", tone: .warning)
                    }
                }
            }
        }
    }

    private var ownMusic: some View {
        let files = sources.filter { $0.kind == .ownFile }
        return GoalongSection(title: "Ma musique", subtitle: "Lue là où elle est, jamais copiée.", trailing: {
            Button("Ajouter…") { chooseFiles() }
                .buttonStyle(LHQuietButtonStyle())
                .accessibilityIdentifier("ambiance-add-files")
        }) {
            if files.isEmpty {
                Text("Ajoutez des fichiers audio ou un dossier.")
                    .font(.system(size: 13)).foregroundStyle(LHTheme.tertiaryText)
            } else {
                LHCard(padding: 0) {
                    VStack(spacing: 0) {
                        ForEach(files) { file in
                            AmbianceFileRow(source: file, playing: playingID == file.id,
                                            onPlay: { toggle(file) }, onRemove: { actions.removeFile(file) })
                            if file.id != files.last?.id { GoalongRowDivider() }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var downloaded: some View {
        let kept = packs.filter { $0.status == .installed }
        if !kept.isEmpty {
            GoalongDisclosureGroup {
                LHCard(padding: 0) {
                    VStack(spacing: 0) {
                        ForEach(kept) { pack in
                            HStack(spacing: 12) {
                                Text(pack.title).font(.system(size: 13, weight: .medium))
                                Spacer(minLength: 12)
                                Text(Self.megabytes(pack.bytes)).font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                                    .monospacedDigit()
                                Button("Supprimer", role: .destructive) { actions.remove(pack.id) }
                                    .accessibilityIdentifier("ambiance-remove-\(pack.id)")
                            }
                            .padding(.horizontal, LHTheme.cardInset).frame(minHeight: 52)
                            if pack.id != kept.last?.id { GoalongRowDivider() }
                        }
                    }
                }
                .padding(.top, 8)
            } label: {
                HStack(spacing: 8) {
                    Text("Sons téléchargés").font(.system(size: 13, weight: .medium))
                    Text(Self.megabytes(kept.reduce(0) { $0 + $1.bytes }))
                        .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText).monospacedDigit()
                }
            }
        }
    }

    /// The module's promises, as facts rather than a paragraph.
    private var promises: some View {
        HStack(alignment: .top, spacing: 24) {
            fact("hand.tap", "Rien ne joue sans vous")
            fact("mic.slash", "Goalong n’écoute jamais")
            fact("arrow.down.circle", "Sons téléchargés à la demande")
        }
        .accessibilityElement(children: .combine)
    }

    private func fact(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(LHTheme.tertiaryText)
            Text(text).font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
        }
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.audio]
        panel.prompt = "Ajouter"
        panel.message = "Choisissez des fichiers audio ou un dossier. Goalong les lit là où ils sont."
        guard panel.runModal() == .OK else { return }
        actions.addFiles(panel.urls)
    }

    static func megabytes(_ bytes: Int64) -> String { "\(Int((Double(bytes) / 1_000_000).rounded())) Mo" }

    static func kindLabel(_ kind: AmbianceSource.Kind) -> String {
        switch kind {
        case .focus: return "Concentration"
        case .relax: return "Détente"
        case .texture: return "Texture"
        case .ownFile: return "Ma musique"
        }
    }
}

// MARK: - Player

/// What plays, its line, the volume and the one main action of the page.
private struct AmbiancePlayer: View {
    let source: AmbianceSource
    let state: AmbianceController.State
    @Binding var volume: Double
    let actions: AmbianceActions

    private var playing: Bool { if case .playing = state { return true } else { return false } }

    var body: some View {
        LHCard(padding: 20) {
            VStack(alignment: .leading, spacing: 18) {
                AmbianceWave(seed: source.id, character: AmbianceWaveCharacter(source),
                             look: playing ? .active : .idle, lineWidth: 2)
                    .frame(height: 64)
                    .id(source.id)
                HStack(alignment: .center, spacing: 20) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(source.title).font(LHTheme.sheetTitleFont).tracking(-0.4).lineLimit(1)
                        Text(playing ? "En cours · \(AmbiancePageContent.kindLabel(source.kind))"
                                     : AmbiancePageContent.kindLabel(source.kind))
                            .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                    }
                    .accessibilityElement(children: .combine)
                    Spacer(minLength: 12)
                    HStack(spacing: 8) {
                        Image(systemName: "speaker.fill").font(.system(size: 11)).foregroundStyle(LHTheme.tertiaryText)
                        Slider(value: $volume, in: 0...1).controlSize(.small).frame(width: 120)
                            .accessibilityLabel("Volume")
                            .accessibilityIdentifier("ambiance-volume")
                        Image(systemName: "speaker.wave.3.fill").font(.system(size: 11)).foregroundStyle(LHTheme.tertiaryText)
                    }
                    .accessibilityElement(children: .contain)
                    mainButton
                }
            }
        }
    }

    @ViewBuilder private var mainButton: some View {
        if state == .loading {
            Button {} label: {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Préparation…") }
            }
            .buttonStyle(LHPrimaryButtonStyle()).disabled(true)
        } else {
            Button {
                if playing { actions.stop() } else { actions.play(source) }
            } label: {
                Label(playing ? "Arrêter" : "Écouter", systemImage: playing ? "stop.fill" : "play.fill")
            }
            .buttonStyle(LHPrimaryButtonStyle())
            .accessibilityIdentifier("ambiance-play")
        }
    }
}

/// Before the first piece: the orchestra's sounds come down once, drawn on the line itself.
private struct AmbianceOrchestraSetup: View {
    let pack: AmbiancePackState
    let pieces: Int
    let actions: AmbianceActions

    var body: some View {
        let size = AmbiancePageContent.megabytes(pack.bytes)
        LHCard(padding: 20) {
            VStack(alignment: .leading, spacing: 18) {
                AmbianceWave(seed: "ambre", character: .focus, look: look, lineWidth: 2).frame(height: 64)
                HStack(alignment: .center, spacing: 20) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Téléchargez l’orchestre").font(LHTheme.sheetTitleFont).tracking(-0.4)
                        Group {
                            if case .downloading(let fraction) = pack.status {
                                Text("\(Int((fraction * 100).rounded())) % de \(size)")
                            } else {
                                Text("\(size), une seule fois. Les \(pieces) morceaux en ont besoin.")
                            }
                        }
                        .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText).monospacedDigit()
                    }
                    Spacer(minLength: 12)
                    if case .downloading = pack.status {
                        Button("Annuler") { actions.cancel(pack.id) }.buttonStyle(LHQuietButtonStyle())
                            .accessibilityIdentifier("ambiance-cancel-\(pack.id)")
                    } else {
                        Button { actions.download(pack.id) } label: {
                            Label(pack.status == .notInstalled ? "Télécharger" : "Réessayer", systemImage: "arrow.down")
                        }
                        .buttonStyle(LHPrimaryButtonStyle())
                        .accessibilityIdentifier("ambiance-download-\(pack.id)")
                    }
                }
            }
        }
        if case .failed(let message) = pack.status {
            GoalongNote(message, symbol: "exclamationmark.triangle", tone: .warning)
        }
    }

    private var look: AmbianceWave.Look {
        if case .downloading(let fraction) = pack.status { return .progress(fraction) }
        return .waiting
    }
}

// MARK: - Rows and tiles

private struct AmbianceTile: View {
    let source: AmbianceSource
    let playing: Bool
    let current: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                AmbianceWave(seed: source.id, character: AmbianceWaveCharacter(source),
                             look: !source.isAvailable ? .waiting : playing ? .active : .idle)
                    .frame(height: 28)
                HStack(spacing: 6) {
                    Text(source.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .foregroundStyle(source.isAvailable ? LHTheme.text : LHTheme.tertiaryText)
                    Spacer(minLength: 0)
                    if playing {
                        Image(systemName: "speaker.wave.2.fill").font(.system(size: 11)).foregroundStyle(LHTheme.accent)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background, in: RoundedRectangle(cornerRadius: LHTheme.cardRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: LHTheme.cardRadius, style: .continuous)
                .strokeBorder(current ? LHTheme.accent : LHTheme.separator, lineWidth: current ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: LHTheme.cardRadius, style: .continuous))
        }
        .buttonStyle(AmbiancePressStyle())
        .disabled(!source.isAvailable)
        .onHover { hovering = $0 && source.isAvailable }
        .animation(LHTheme.hover, value: hovering)
        .accessibilityLabel("\(source.title), \(AmbiancePageContent.kindLabel(source.kind))")
        .accessibilityValue(playing ? "En cours" : source.isAvailable ? "" : "À télécharger")
        .accessibilityHint(playing ? "Arrêter" : "Écouter")
        .accessibilityIdentifier("ambiance-source-\(source.id)")
    }

    private var background: Color {
        if playing { return LHTheme.selectionBackground }
        if hovering { return LHTheme.hoverBackground }
        return LHTheme.cardBackground
    }
}

private struct AmbianceFileRow: View {
    let source: AmbianceSource
    let playing: Bool
    let onPlay: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onPlay) {
                HStack(spacing: 12) {
                    Image(systemName: playing ? "speaker.wave.2.fill" : "music.note")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(playing ? LHTheme.accent : LHTheme.secondaryText)
                        .frame(width: 22)
                    Text(source.title).font(.system(size: 13, weight: playing ? .semibold : .regular))
                        .lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(source.isAvailable ? LHTheme.text : LHTheme.tertiaryText)
                    if !source.isAvailable {
                        Text("Introuvable").font(.system(size: 12)).foregroundStyle(LHTheme.warning)
                    }
                    Spacer(minLength: 12)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!source.isAvailable)
            .accessibilityLabel(source.title)
            .accessibilityValue(playing ? "En cours" : source.isAvailable ? "" : "Introuvable")
            .accessibilityIdentifier("ambiance-file-\(source.id)")
            Button(action: onRemove) {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(LHTheme.tertiaryText)
                    .frame(width: 28, height: 28).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Retirer \(source.title)")
        }
        .padding(.horizontal, LHTheme.cardInset).frame(minHeight: 44)
    }
}

/// A pack not on this Mac yet: its line fills while it downloads.
private struct AmbiancePackRow: View {
    let pack: AmbiancePackState
    let title: String
    let seed: String
    let character: AmbianceWaveCharacter
    let actions: AmbianceActions

    var body: some View {
        let size = AmbiancePageContent.megabytes(pack.bytes)
        HStack(spacing: 16) {
            AmbianceWave(seed: seed, character: character, look: look).frame(width: 96, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Group {
                    if case .downloading(let fraction) = pack.status {
                        Text("\(Int((fraction * 100).rounded())) % de \(size)")
                    } else {
                        Text("\(size), une seule fois.")
                    }
                }
                .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText).monospacedDigit()
            }
            Spacer(minLength: 12)
            if case .downloading = pack.status {
                Button("Annuler") { actions.cancel(pack.id) }.buttonStyle(LHQuietButtonStyle())
                    .accessibilityIdentifier("ambiance-cancel-\(pack.id)")
            } else {
                Button(pack.status == .notInstalled ? "Télécharger" : "Réessayer") { actions.download(pack.id) }
                    .accessibilityIdentifier("ambiance-download-\(pack.id)")
            }
        }
        .padding(.horizontal, LHTheme.cardInset).frame(minHeight: 60)
    }

    private var look: AmbianceWave.Look {
        if case .downloading(let fraction) = pack.status { return .progress(fraction) }
        return .waiting
    }
}

private struct AmbiancePressStyle: ButtonStyle {
    @Environment(\.goalongReduceMotion) private var reduceMotion
    @Environment(\.isFocused) private var isFocused

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .overlay(RoundedRectangle(cornerRadius: LHTheme.cardRadius + 3, style: .continuous)
                .stroke(LHTheme.accent, lineWidth: 2).padding(-3).opacity(isFocused ? 1 : 0))
            .animation(reduceMotion ? nil : LHTheme.press, value: configuration.isPressed)
    }
}
#endif
