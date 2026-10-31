#if os(macOS)
import AppKit
import SwiftUI

// MARK: - Lists

/// The lists as small cards: what they hold and how they act. A card opens its editor in a sheet;
/// when there is none yet, the catalog of starters is one tap from a ready list.
@MainActor struct BlockingListsSection: View {
    @ObservedObject var controller: BlockingController
    let now: Date
    @Binding var editing: UUID?

    var body: some View {
        GoalongSection(title: "Listes", subtitle: controller.lists.isEmpty ? "Ce que vous voulez couper. Choisissez un point de départ, vous pourrez tout modifier." : nil) {
            if !controller.lists.isEmpty {
                Button { create(from: nil) } label: { Label("Nouvelle liste", systemImage: "plus") }
                    .buttonStyle(LHQuietButtonStyle())
                    .accessibilityIdentifier("blocking-new-list")
            }
        } content: {
            if controller.lists.isEmpty {
                BlockingFlow(spacing: 8) {
                    ForEach(controller.suggestions) { suggestion in
                        Button { create(from: suggestion) } label: { Label(suggestion.title, systemImage: suggestion.symbol) }
                            .accessibilityIdentifier("blocking-suggestion-\(suggestion.id)")
                    }
                    Button { create(from: nil) } label: { Label("Liste vide", systemImage: "plus") }
                        .buttonStyle(LHQuietButtonStyle())
                }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 10)], alignment: .leading, spacing: 10) {
                    ForEach(controller.lists) { list in card(list) }
                }
            }
        }
    }

    private func create(from suggestion: BlockSuggestion?) {
        let list = BlockList(name: suggestion?.title ?? (controller.lists.isEmpty ? "Ma liste" : "Nouvelle liste"),
                             sites: suggestion?.sites.map { BlockSiteRule(pattern: $0) } ?? [],
                             apps: suggestion?.apps ?? [])
        controller.save(list)
        editing = list.id
    }

    private func card(_ list: BlockList) -> some View {
        let locked = list.program.isLocked(at: now)
            || controller.activeBlocks.contains { $0.lock == .locked && $0.listIDs.contains(list.id) }
        return Button { editing = list.id } label: {
            VStack(alignment: .leading, spacing: 10) {
                BlockingIconCluster(lists: [list], size: 20, limit: 5)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(list.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        if locked {
                            Image(systemName: "lock.fill").font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(LHTheme.secondaryText).accessibilityLabel("Verrouillée")
                        }
                    }
                    Text(Self.contents(list)).font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText).lineLimit(1)
                    Text(Self.behaviour(list)).font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText).lineLimit(1)
                }
            }
            .padding(14).frame(maxWidth: .infinity, minHeight: 84, alignment: .topLeading)
            .background(GoalongSurface(corner: LHTheme.cardRadius, fill: LHTheme.cardBackground))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("blocking-list-\(list.name)")
        .accessibilityHint("Modifier la liste")
    }

    static func contents(_ list: BlockList) -> String {
        let sites = list.sites.count, apps = list.apps.count
        let words = list.keywords?.count ?? 0
        let parts = [sites > 0 ? (sites == 1 ? "1 site" : "\(sites) sites") : nil,
                     apps > 0 ? (apps == 1 ? "1 app" : "\(apps) apps") : nil,
                     words > 0 ? (words == 1 ? "1 mot-clé" : "\(words) mots-clés") : nil].compactMap { $0 }
        if list.mode == .allowOnly { return parts.isEmpty ? "Tout bloqué" : "Tout sauf " + parts.joined(separator: " et ") }
        return parts.isEmpty ? "Vide" : parts.joined(separator: ", ")
    }

    static func behaviour(_ list: BlockList) -> String {
        var parts = [list.effectiveAction == .slowDown ? "Ralentit de \(list.delaySeconds) s" : "Bloque l’accès"]
        if let quota = list.quotaMinutesPerDay { parts.append("\(BlockingFormat.duration(minutes: quota)) libres/jour") }
        if let breaks = list.breaks { parts.append("\(breaks.count) pause\(breaks.count > 1 ? "s" : "")") }
        return parts.joined(separator: ", ")
    }
}

/// Edits a list in a sheet; every change is saved at once, and a lock only lets it get stricter.
/// What the list holds and what it does are visible; the rarer settings are folded.
@MainActor struct BlockListEditor: View {
    @ObservedObject var controller: BlockingController
    let list: BlockList
    let now: Date
    var onDone: () -> Void = {}
    @State private var newSite = ""
    @State private var siteError: String?
    @State private var newException = ""
    @State private var newKeyword = ""
    @State private var addingException = false
    @State private var addingKeyword = false
    @State private var ruleError: String?
    @State private var reasonDraft: String
    @State private var nameDraft: String
    @State private var nameError: String?
    @State private var pickingTrigger = false
    @State private var pickingApp = false
    @State private var confirmingDelete = false
    @State private var lockingProgram = false
    @State private var moreOpen: Bool

    init(controller: BlockingController, list: BlockList, now: Date, onDone: @escaping () -> Void = {}) {
        self.controller = controller
        self.list = list
        self.now = now
        self.onDone = onDone
        _moreOpen = State(initialValue: list.mode == .allowOnly || list.quotaMinutesPerDay != nil || list.breaks != nil)
        _reasonDraft = State(initialValue: list.reason ?? "")
        _nameDraft = State(initialValue: list.name)
    }

    private var stricterOnly: Bool { controller.isStricterOnly(list.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 12) {
                BlockingIconCluster(lists: [list], size: 22, limit: 4)
                // A draft: erasing the name to retype it saves nothing until return or close.
                TextField("Nom de la liste", text: $nameDraft)
                // 14 pt semibold text is 17 pt high: 8 + 17 + 9 fills the 34 pt field.
                .textFieldStyle(GoalongFieldStyle(textFont: .semibold14))
                .onSubmit(saveName)
                .onDisappear(perform: saveName)
                .onChange(of: nameDraft) { value in
                    if value.count > 40 { nameDraft = String(value.prefix(40)) }
                    nameError = nil
                }
                .accessibilityIdentifier("blocking-list-name")
            }
            if let nameError {
                Text(nameError).font(.system(size: 12)).foregroundStyle(LHTheme.warning)
                    .accessibilityIdentifier("blocking-list-name-error")
            }
            TextField("Pourquoi ? ex. Finir le mémoire avant vendredi", text: $reasonDraft)
                .textFieldStyle(GoalongFieldStyle())
                .onSubmit(saveReason)
                .onDisappear(perform: saveReason)
                .onChange(of: reasonDraft) { value in
                    if value.count > 140 { reasonDraft = String(value.prefix(140)) }
                }
                .accessibilityIdentifier("blocking-list-reason")
                .accessibilityHint("Affiché sur l’écran de blocage")
            if stricterOnly {
                GoalongNote(lockNote, symbol: "lock.fill", tone: .neutral)
            }
            if let error = controller.error {
                BlockingNoteButton(note: GoalongNote(error, tone: .warning), hint: "Fermer l’erreur") { controller.error = nil }
            }
            part(list.mode == .block ? "Sites" : "Sites permis") {
                VStack(alignment: .leading, spacing: 10) {
                    BlockingFlow(spacing: 6) {
                        ForEach(list.sites) { site in
                            BlockingItemChip(item: .site(site.pattern), removable: canRemove) {
                                var next = list; next.sites.removeAll { $0 == site }; controller.save(next)
                            }
                        }
                        TextField("Ajouter un site, ex. youtube.com", text: $newSite)
                            .textFieldStyle(GoalongFieldStyle()).controlSize(.small).frame(width: 220)
                            .onSubmit(addSite)
                            .onChange(of: newSite) { _ in siteError = nil }
                            .disabled(!canAdd)
                            .accessibilityIdentifier("blocking-add-site")
                    }
                    if let siteError {
                        Text(siteError).font(.system(size: 12)).foregroundStyle(LHTheme.warning)
                    }
                    if list.mode == .block {
                        suggestionRow
                        exceptionRow
                    }
                    keywordRow
                    if let ruleError {
                        Text(ruleError).font(.system(size: 12)).foregroundStyle(LHTheme.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            part(list.mode == .block ? "Apps" : "Apps permises") {
                BlockingFlow(spacing: 6) {
                    ForEach(list.apps) { app in
                        BlockingItemChip(item: .app(app), removable: canRemove) {
                            var next = list; next.apps.removeAll { $0 == app }; controller.save(next)
                        }
                    }
                    Button { pickingApp = true } label: { Label("Ajouter une app", systemImage: "plus") }
                        .buttonStyle(LHQuietButtonStyle())
                        .disabled(!canAdd)
                        .popover(isPresented: $pickingApp) {
                            BlockingAppPicker(excluded: Set(list.apps.map(\.bundleIdentifier))) { app in
                                var next = list; next.apps.append(app); controller.save(next)
                            }
                        }
                        .accessibilityIdentifier("blocking-add-app")
                }
                triggerRow.padding(.top, 4)
            }
            part("Quand on l’ouvre") {
                VStack(alignment: .leading, spacing: 12) {
                    GoalongSegmentedControl("Action", selection: Binding(get: { list.effectiveAction }, set: { action in
                        var next = list; next.action = action == .block ? nil : .slowDown; controller.save(next)
                    }), options: [BlockList.Action.block, .slowDown]) {
                        $0 == .block ? "Bloquer" : "Ralentir"
                    }
                    .disabled(stricterOnly && list.effectiveAction == .block)
                    .accessibilityIdentifier("blocking-list-action")
                    BlockingActionPicture(list: list)
                    if list.effectiveAction == .slowDown {
                        HStack(spacing: 16) {
                            Stepper(value: Binding(get: { list.delaySeconds }, set: { value in
                                var next = list; next.slowDownSeconds = value; controller.save(next)
                            }), in: (stricterOnly ? list.delaySeconds : 3)...60) {
                                Text("Attendre \(list.delaySeconds) s").monospacedDigit()
                            }.fixedSize()
                            Stepper(value: Binding(get: { list.allowanceMinutes }, set: { value in
                                var next = list; next.continueMinutes = value; controller.save(next)
                            }), in: 1...(stricterOnly ? list.allowanceMinutes : 60)) {
                                Text("Puis libre \(list.allowanceMinutes) min").monospacedDigit()
                            }.fixedSize()
                        }
                        if let counts = frictionLine {
                            Text(counts).font(.system(size: 12).monospacedDigit()).foregroundStyle(LHTheme.secondaryText)
                                .accessibilityIdentifier("blocking-friction-counts")
                        }
                    }
                }
            }
            GoalongDisclosureGroup("Plus de réglages", isExpanded: $moreOpen) {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 10) {
                        GoalongSegmentedControl("Mode", selection: Binding(get: { list.mode }, set: { mode in
                            var next = list; next.mode = mode; controller.save(next)
                        }), options: BlockList.Mode.allCases) {
                            $0 == .block ? "Bloquer ces éléments" : "Tout bloquer sauf"
                        }
                        .disabled(stricterOnly)
                        BlockingModePicture(mode: list.mode, slowed: list.effectiveAction == .slowDown)
                    }
                    limitRow(on: list.quotaMinutesPerDay != nil, title: "Laisser du temps chaque jour",
                             detail: list.effectiveAction == .slowDown
                                 ? "Ralenti jusqu’à ce temps, puis bloqué."
                                 : "Ouvert jusqu’à ce temps, puis bloqué.") { on in
                        var next = list; next.quotaMinutesPerDay = on ? 30 : nil; controller.save(next)
                    } value: {
                        if let quota = list.quotaMinutesPerDay {
                            Stepper(value: Binding(get: { quota }, set: { value in
                                var next = list; next.quotaMinutesPerDay = value; controller.save(next)
                            }), in: Self.quotaRange(current: quota, stricterOnly: stricterOnly), step: 5) {
                                Text("\(BlockingFormat.duration(minutes: quota)) par jour").monospacedDigit()
                            }.fixedSize()
                        }
                    }
                    if list.quotaMinutesPerDay != nil {
                        limitRow(on: list.earn != nil, title: "Gagner du temps en travaillant",
                                 detail: earnDetail) { on in
                            ruleError = message(controller.setEarn(on ? BlockEarn() : nil, for: list.id))
                        }
                        value: { EmptyView() }
                        .accessibilityIdentifier("blocking-list-earn")
                    }
                    limitRow(on: list.breaks != nil, title: "Autoriser des pauses",
                             detail: "Choisies à l’avance, possibles même verrouillé.") { on in
                        var next = list; next.breaks = on ? BlockBreaks(count: 3, minutes: 5) : nil; controller.save(next)
                    } value: {
                        if let breaks = list.breaks {
                            HStack(spacing: 6) {
                                Stepper(value: Binding(get: { breaks.count }, set: { value in
                                    var next = list; next.breaks?.count = value; controller.save(next)
                                }), in: Self.breakCountRange(current: breaks.count, stricterOnly: stricterOnly)) { Text("\(breaks.count) ×").monospacedDigit() }.fixedSize()
                                Stepper(value: Binding(get: { breaks.minutes }, set: { value in
                                    var next = list; next.breaks?.minutes = value; controller.save(next)
                                }), in: Self.breakMinutesRange(current: breaks.minutes, stricterOnly: stricterOnly)) { Text("\(breaks.minutes) min").monospacedDigit() }.fixedSize()
                            }
                        }
                    }
                }
                .padding(.top, 12)
            }
            .accessibilityIdentifier("blocking-list-more")
            Rectangle().fill(LHTheme.separator).frame(height: 1)
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(programLine).font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                    if !list.program.ranges.isEmpty {
                        Button(list.program.isLocked(at: now) ? "Prolonger le verrou…" : "Verrouiller le programme…") { lockingProgram = true }
                            .buttonStyle(LHQuietButtonStyle())
                            .popover(isPresented: $lockingProgram) {
                                BlockingProgramLock(current: list.program.lockedUntil, now: now,
                                                    consent: controller.guardNeedsConsent) { date in
                                    controller.lockProgram(listID: list.id, until: date)
                                    lockingProgram = false
                                }
                            }
                            .accessibilityIdentifier("blocking-lock-program")
                    }
                }
                Spacer()
                if !stricterOnly {
                    Button("Supprimer", role: .destructive) { confirmingDelete = true }
                        .buttonStyle(LHQuietButtonStyle())
                }
                Button("Terminé", action: onDone)
                    .buttonStyle(LHPrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .font(.system(size: 13))
        .alert("Supprimer « \(list.name) » ?", isPresented: $confirmingDelete) {
            Button("Annuler", role: .cancel) {}
            Button("Supprimer", role: .destructive) { controller.delete(list.id); onDone() }
        } message: { Text("Son programme s’arrête aussi.") }
    }

    private var programLine: String {
        guard let first = list.program.ranges.first else { return "Pas de programme. Glissez sur la semaine, ou utilisez le bouton + d’un jour, pour en créer un." }
        let more = list.program.ranges.count > 1 ? " et \(list.program.ranges.count - 1) autre\(list.program.ranges.count > 2 ? "s" : "")" : ""
        return "Programme : \(BlockingFormat.weekdays(first.weekdays)) \(BlockingFormat.range(first))\(more)"
    }

    /// Today's « Ralentir » counts for this list, as facts.
    private var frictionLine: String? {
        let usage = controller.frictionCounts(day: BlockingController.dayKey(now))
        let shown = usage.slowDownShown?[list.id] ?? 0
        guard shown > 0 else { return nil }
        let renounced = usage.renounced?[list.id] ?? 0, continued = usage.continued?[list.id] ?? 0
        return "Aujourd’hui : ralenti \(shown) fois, \(renounced) renoncement\(renounced > 1 ? "s" : ""), continué \(continued) fois."
    }

    /// Under a lock, removing from « Tout bloquer sauf » is stricter; adding to it is not.
    private var canRemove: Bool { !stricterOnly || list.mode == .allowOnly }
    private var canAdd: Bool { !stricterOnly || list.mode == .block }

    private var lockNote: String {
        if let until = list.program.lockedUntil, until > now {
            return "Programme verrouillé jusqu’au \(BlockingFormat.day(until)). La liste peut seulement devenir plus stricte."
        }
        return "Un blocage en cours utilise cette liste. Elle peut seulement devenir plus stricte jusqu’à son arrêt."
    }

    private var suggestionRow: some View {
        let present = Set(list.sites.map(\.pattern))
        // A suggestion already named by the list (« Vidéo » in Vidéo) is not offered again.
        let options = controller.suggestions.filter { !Set($0.sites).isSubset(of: present) && $0.title != list.name }
        return Group {
            if !options.isEmpty {
                BlockingFlow(spacing: 6) {
                    Text("Ajouter").font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText).frame(height: 22)
                    ForEach(options) { suggestion in
                        Button("+ \(suggestion.title)") {
                            var next = list
                            for site in suggestion.sites where !present.contains(site) { next.sites.append(BlockSiteRule(pattern: site)) }
                            for app in suggestion.apps where !next.apps.contains(app) { next.apps.append(app) }
                            controller.save(next)
                        }
                        .buttonStyle(LHQuietButtonStyle()).font(.system(size: 12))
                        .disabled(!canAdd)
                    }
                }
            }
        }
    }

    /// « Sauf » : pages a blocked site keeps open. Only for « Bloquer ces éléments »; under a lock they can only go.
    private var exceptionRow: some View {
        let exceptions = list.exceptions ?? []
        return ruleRow(label: "Sauf", symbol: "checkmark.circle", empty: "Autoriser une page…",
                       detail: "Une page qui reste ouverte, ex. reddit.com/r/swift. Le reste du site reste bloqué.",
                       items: exceptions.map(\.pattern), adding: $addingException, text: $newException,
                       placeholder: "ex. youtube.com/@cours", canAdd: !stricterOnly, canRemove: true,
                       identifier: "exception") { value in
            ruleError = message(controller.addException(value, to: list.id), input: value, kind: "une adresse de page")
        } remove: { pattern in
            ruleError = message(controller.removeException(BlockSiteRule(pattern: pattern), from: list.id))
        }
    }

    /// « Mots-clés » : any page whose address or tab title holds the word. Under a lock they can only be added.
    private var keywordRow: some View {
        ruleRow(label: "Mots-clés", symbol: "textformat", empty: "Bloquer des mots…",
                detail: "Bloque toute page dont l’adresse ou le titre contient ce mot. Mot entier, accents ignorés.",
                items: list.keywords ?? [], adding: $addingKeyword, text: $newKeyword,
                placeholder: "ex. match en direct", canAdd: (list.keywords?.count ?? 0) < 50, canRemove: !stricterOnly,
                identifier: "keyword") { value in
            ruleError = message(controller.addKeyword(value, to: list.id), input: value, kind: "un mot-clé de 2 à 40 caractères")
        } remove: { keyword in
            ruleError = message(controller.removeKeyword(keyword, from: list.id))
        }
    }

    private func saveReason() {
        let trimmed = reasonDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != (list.reason ?? "") else { return }
        ruleError = message(controller.setReason(trimmed, for: list.id))
    }

    private var earnDetail: String {
        let earn = list.earn ?? BlockEarn()
        var line = "Chaque séance de Concentration terminée : +\(earn.rewardMinutes) min toutes les \(earn.workMinutes) min, jusqu’à \(earn.capMinutes) min par jour."
        if let earned = controller.earnedMinutesToday[list.id], earned >= 1 { line += " Aujourd’hui : +\(Int(earned)) min." }
        return line
    }

    /// « Démarrer seule » : the list runs while one of these apps is open. Under a lock they can only be added.
    private var triggerRow: some View {
        let apps = list.triggers?.apps ?? []
        return Group {
            if apps.isEmpty {
                Button { pickingTrigger = true } label: { Label("Démarrer quand j’ouvre une app…", systemImage: "app.badge") }
                    .buttonStyle(LHQuietButtonStyle()).font(.system(size: 12))
                    .accessibilityIdentifier("blocking-open-trigger")
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    BlockingFlow(spacing: 6) {
                        Text("Démarre avec").font(.system(size: 12, weight: .medium)).foregroundStyle(LHTheme.secondaryText)
                            .frame(height: 26)
                        ForEach(apps) { app in
                            BlockingItemChip(item: .app(app), removable: !stricterOnly) {
                                ruleError = message(controller.removeAppTrigger(app, from: list.id))
                            }
                        }
                        Button { pickingTrigger = true } label: { Image(systemName: "plus").frame(height: 26) }
                            .buttonStyle(LHQuietButtonStyle()).accessibilityLabel("Ajouter une app déclencheuse")
                    }
                    Text(list.mode == .block
                         ? "La liste bloque tant qu’une de ces apps est ouverte. « Arrêter » la coupe jusqu’à leur prochaine ouverture."
                         : "Tout est bloqué sauf la liste tant qu’une de ces apps est ouverte. Elles doivent faire partie des apps permises.")
                        .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .popover(isPresented: $pickingTrigger) {
            BlockingAppPicker(excluded: Set(apps.map(\.bundleIdentifier) + (list.mode == .block ? list.apps.map(\.bundleIdentifier) : []))) { app in
                ruleError = message(controller.addAppTrigger(app, to: list.id))
            }
        }
    }

    private func message(_ check: BlockingEditCheck, input: String? = nil, kind: String = "") -> String? {
        Self.refusalMessage(check, input: input, kind: kind)
    }

    /// Only a malformed entry is rewritten with the typed text; a lock or file refusal keeps its own reason.
    static func refusalMessage(_ check: BlockingEditCheck, input: String? = nil, kind: String = "") -> String? {
        guard case .refused(let reason) = check else { return nil }
        let malformed = ["Chaque mot-clé doit contenir de 2 à 40 caractères.", "Adresse d’exception invalide."]
        if let input, malformed.contains(reason) { return "« \(input) » n’est pas \(kind)." }
        return reason
    }

    /// Under a lock a stepper stops at the current value: the controller would refuse any rise.
    static func quotaRange(current: Int, stricterOnly: Bool) -> ClosedRange<Int> { 5...(stricterOnly ? max(5, current) : 720) }
    static func breakCountRange(current: Int, stricterOnly: Bool) -> ClosedRange<Int> { 1...(stricterOnly ? max(1, current) : 12) }
    static func breakMinutesRange(current: Int, stricterOnly: Bool) -> ClosedRange<Int> { 1...(stricterOnly ? max(1, current) : 30) }

    private func saveName() {
        let entry = Self.commitName(nameDraft, of: list, controller: controller)
        nameDraft = entry.text; nameError = entry.error
    }

    /// The field then shows the stored name: `list` is the snapshot from before the save,
    /// so writing it back would undo a trimmed name at the next return or close.
    static func commitName(_ draft: String, of list: BlockList, controller: BlockingController) -> SiteEntry {
        guard draft != list.name else { return SiteEntry(text: draft) }
        let error = controller.rename(list.id, to: draft)
        return SiteEntry(text: controller.list(list.id)?.name ?? list.name, error: error)
    }

    /// A folded row: a quiet button while empty, then chips and a field.
    private func ruleRow(label: String, symbol: String, empty: String, detail: String, items: [String],
                         adding: Binding<Bool>, text: Binding<String>, placeholder: String,
                         canAdd: Bool, canRemove: Bool, identifier: String,
                         add: @escaping (String) -> Void, remove: @escaping (String) -> Void) -> some View {
        Group {
            if items.isEmpty && !adding.wrappedValue {
                Button { adding.wrappedValue = true } label: { Label(empty, systemImage: symbol) }
                    .buttonStyle(LHQuietButtonStyle()).font(.system(size: 12))
                    .disabled(!canAdd)
                    .accessibilityIdentifier("blocking-open-\(identifier)")
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    BlockingFlow(spacing: 6) {
                        Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(LHTheme.secondaryText)
                            .frame(height: 26)
                        ForEach(items, id: \.self) { item in
                            BlockingItemChip(item: .symbol(symbol), label: item, removable: canRemove) { remove(item) }
                        }
                        if canAdd {
                            TextField(placeholder, text: text)
                                .textFieldStyle(GoalongFieldStyle()).controlSize(.small).frame(width: 200)
                                .onSubmit {
                                    let value = text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
                                    guard !value.isEmpty else { return }
                                    add(value)
                                    if ruleError == nil { text.wrappedValue = "" }
                                }
                                .accessibilityIdentifier("blocking-add-\(identifier)")
                        }
                    }
                    Text(detail).font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func addSite() {
        let entry = Self.addSite(newSite, to: list, controller: controller)
        newSite = entry.text; siteError = entry.error
    }

    struct SiteEntry: Equatable { var text: String; var error: String? }

    /// The typed text stays in the field when the site is refused, with the reason next to it.
    static func addSite(_ input: String, to list: BlockList, controller: BlockingController) -> SiteEntry {
        guard let pattern = BlockingRules.normalizeSite(input) else {
            return SiteEntry(text: input, error: input.isEmpty ? nil : "« \(input) » n’est pas une adresse de site.")
        }
        guard !list.sites.contains(where: { $0.pattern == pattern }) else { return SiteEntry(text: "") }
        var next = list; next.sites.append(BlockSiteRule(pattern: pattern))
        if let refusal = controller.save(next) { return SiteEntry(text: input, error: refusal) }
        return SiteEntry(text: "")
    }

    private func part<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(LHTheme.secondaryText)
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }

    private func limitRow<Value: View>(on: Bool, title: String, detail: String, toggle: @escaping (Bool) -> Void,
                                       @ViewBuilder value: () -> Value) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            value()
            Toggle(title, isOn: Binding(get: { on }, set: toggle))
                .toggleStyle(.goalongSwitchOnly).fixedSize()
                .disabled(stricterOnly && !on)
        }
    }
}

/// The list editor as a sheet: scrolls when the list is long.
@MainActor struct BlockListSheet: View {
    @ObservedObject var controller: BlockingController
    let listID: UUID
    let now: Date
    var onDone: () -> Void

    /// The sheet's title: a locked list says why it can only get stricter.
    nonisolated static func title(locked: Bool) -> String { locked ? "Liste verrouillée" : "Modifier la liste" }

    var body: some View {
        Group {
            if let list = controller.list(listID) {
                VStack(spacing: 0) {
                    HStack {
                        Text(Self.title(locked: controller.isStricterOnly(listID)))
                            .font(.system(size: 15, weight: .semibold)).foregroundStyle(LHTheme.text)
                            .accessibilityAddTraits(.isHeader)
                        Spacer()
                        Button("Fermer", action: onDone).buttonStyle(LHQuietButtonStyle())
                            .accessibilityIdentifier("blocking-list-close")
                    }
                    .padding(.horizontal, 28).padding(.top, 20).padding(.bottom, 4)
                    ScrollView {
                        BlockListEditor(controller: controller, list: list, now: now, onDone: onDone).padding(28)
                    }
                }
            } else {
                Color.clear.onAppear(perform: onDone)
            }
        }
        .frame(width: 600).frame(minHeight: 420, idealHeight: 640, maxHeight: 760)
        .background(LHTheme.pageBackground)
        .background(Button("") { onDone() }.keyboardShortcut(.cancelAction).opacity(0).frame(width: 0, height: 0).accessibilityHidden(true))
    }
}

/// What the mode does, drawn: four tiles, the blocked ones struck through.
struct BlockingModePicture: View {
    let mode: BlockList.Mode
    var slowed = false
    var body: some View {
        let verb = slowed ? "ralenti" : "bloqué"
        return HStack(spacing: 10) {
            HStack(spacing: 4) {
                ForEach(0..<5) { index in
                    let listed = index < 2
                    let blocked = mode == .block ? listed : !listed
                    ZStack {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(listed ? LHTheme.controlBackground : LHTheme.insetBackground)
                            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .strokeBorder(listed ? LHTheme.controlBorder : LHTheme.separator))
                        if blocked {
                            Path { path in path.move(to: CGPoint(x: 4, y: 14)); path.addLine(to: CGPoint(x: 14, y: 4)) }
                                .stroke(LHTheme.text, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                        }
                    }
                    .frame(width: 18, height: 18)
                }
            }
            Text(mode == .block ? "Ce qui est dans la liste est \(verb). Le reste est libre."
                                : "Tout est \(verb), sauf ce qui est dans la liste. Goalong et le Finder restent ouverts.")
                .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(mode == .block ? "Mode : la liste est \(slowed ? "ralentie" : "bloquée")" : "Mode : tout est \(verb) sauf la liste")
    }
}

/// What happens when something on the list opens, drawn: struck at once, or a wait then a choice.
struct BlockingActionPicture: View {
    let list: BlockList
    /// An app is asked to quit, never force-quit: one that asks to save is hidden instead.
    static let blockText = "Bloqué tout de suite : le site est couvert, l’app est priée de quitter. Si elle demande d’enregistrer, elle est masquée, jamais forcée : rien n’est perdu."
    var body: some View {
        HStack(spacing: 10) {
            ZStack(alignment: .leading) {
                if list.effectiveAction == .block {
                    // A « no entry » sign, not a box: it must not read as a checkbox or a close button.
                    Image(systemName: "nosign").font(.system(size: 14, weight: .semibold)).foregroundStyle(LHTheme.text)
                        .frame(width: 18, height: 18)
                } else {
                    HStack(spacing: 4) {
                        tile
                        ZStack(alignment: .leading) {
                            Capsule().fill(LHTheme.text.opacity(0.16)).frame(width: 40, height: 4)
                            Capsule().fill(LHTheme.text).frame(width: 26, height: 4)
                            Circle().fill(LHTheme.accent).frame(width: 8, height: 8).offset(x: 22)
                        }
                    }
                }
            }
            .frame(width: list.effectiveAction == .block ? 18 : 66, alignment: .leading)
            Text(list.effectiveAction == .block
                 ? Self.blockText
                 : "Attendre \(list.delaySeconds) s, puis renoncer ou continuer \(list.allowanceMinutes) min. Une app est masquée, jamais fermée.")
                .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(list.effectiveAction == .block ? "Action : bloquer" : "Action : ralentir de \(list.delaySeconds) secondes")
    }

    private var tile: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous).fill(LHTheme.controlBackground)
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(LHTheme.controlBorder))
            .frame(width: 18, height: 18)
    }
}

struct BlockingProgramLock: View {
    let current: Date?
    let now: Date
    /// Shows `GuardConsent.text` while the guard was never registered.
    var consent = false
    var onLock: (Date) -> Void
    @State private var until: Date

    init(current: Date?, now: Date, consent: Bool = false, onLock: @escaping (Date) -> Void) {
        self.current = current
        self.now = now
        self.consent = consent
        self.onLock = onLock
        _until = State(initialValue: Self.initialUntil(current: current, now: now))
    }

    /// The button only acts when it moves the end of the lock later.
    static func extends(until: Date, current: Date?) -> Bool {
        BlockingWallClock.endOfDay(until) > (current ?? .distantPast)
    }

    /// Two weeks from now, never before the lock in place: the button must name the real end.
    static func initialUntil(current: Date?, now: Date, calendar: Calendar = .current) -> Date {
        max(current ?? now, calendar.date(byAdding: .day, value: 14, to: now) ?? now)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Verrouiller le programme").font(LHTheme.cardTitleFont)
            Text("Jusqu’à cette date, la liste et son programme peuvent seulement devenir plus stricts. Les plages programmées ne peuvent pas être arrêtées.")
                .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText).fixedSize(horizontal: false, vertical: true)
            if consent {
                Text(GuardConsent.text)
                    .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText).fixedSize(horizontal: false, vertical: true)
            }
            DatePicker("Jusqu’au", selection: $until, in: max(now, current ?? now)..., displayedComponents: .date)
                .goalongDateField(label: "Jusqu’au")
            HStack {
                Spacer()
                Button("Verrouiller jusqu’au \(BlockingFormat.day(until))") { onLock(BlockingWallClock.endOfDay(until)) }
                    .disabled(!Self.extends(until: until, current: current))
            }
        }
        .padding(18).frame(width: 340)
        .goalongControls()
    }
}

// MARK: - Chips, icons, layout

enum BlockingItem: Hashable {
    case site(String)
    case app(BlockAppRule)
    /// A thing without an icon of its own.
    case symbol(String)
}

/// The icons of what a list holds: apps first, then sites, overlapping a little.
struct BlockingIconCluster: View {
    let lists: [BlockList]
    var size: CGFloat = 22
    var limit = 5
    /// Size of the « +N » count; nil keeps half the icon size, 10 pt at least.
    var overflowFont: CGFloat?

    /// Each app or host once, in list order: several rules can share a host and lists can share an app.
    static func items(for lists: [BlockList]) -> [BlockingItem] {
        var seen = Set<BlockingItem>()
        return lists.flatMap { list in list.apps.map(BlockingItem.app) + list.sites.map { .site($0.host) } }
            .filter { seen.insert($0).inserted }
    }

    var body: some View {
        let items = Self.items(for: lists)
        if items.isEmpty {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .strokeBorder(LHTheme.controlBorder, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        } else {
            BlockingIconStack(items: Array(items.prefix(limit)), size: size, overflow: max(0, items.count - limit), overflowFont: overflowFont)
        }
    }
}

struct BlockingIconStack: View {
    let items: [BlockingItem]
    var size: CGFloat = 22
    var overflow = 0
    var overflowFont: CGFloat?

    var body: some View {
        HStack(spacing: max(2, size * 0.14)) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in icon(item) }
            if overflow > 0 {
                Text("+\(overflow)").font(.system(size: overflowFont ?? max(10, size * 0.5), weight: .medium).monospacedDigit())
                    .foregroundStyle(LHTheme.secondaryText).fixedSize().padding(.leading, 2)
            }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder private func icon(_ item: BlockingItem) -> some View {
        switch item {
        case .site(let host): BlockingSiteTile(host: host, size: size)
        case .symbol(let name):
            let shape = RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            Image(systemName: name).font(.system(size: size * 0.45, weight: .medium)).foregroundStyle(LHTheme.secondaryText)
                .frame(width: size, height: size)
                .background(shape.fill(LHTheme.insetBackground)).overlay(shape.strokeBorder(LHTheme.separator))
        case .app(let app): AppIconView(bundleIdentifier: app.bundleIdentifier, appName: app.name, size: size)
        }
    }
}

/// A site has no icon offline: its monogram (`WebsiteIconView`), the same shape as an app icon.
struct BlockingSiteTile: View {
    let host: String
    var size: CGFloat = 22
    var body: some View { WebsiteIconView(host: host, size: size) }
}

/// One site or app in a list: icon, name, and a remove cross when removing is allowed.
struct BlockingItemChip: View {
    let item: BlockingItem
    /// Shown instead of the item's own name, e.g. a keyword next to its symbol.
    var label: String? = nil
    var removable = true
    var onRemove: () -> Void = {}

    var body: some View {
        HStack(spacing: 6) {
            BlockingIconStack(items: [item], size: 16)
            Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1)
            if removable {
                Button(action: onRemove) {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(LHTheme.secondaryText)
                        .frame(width: 16, height: 16).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Retirer \(title)")
            }
        }
        .padding(.leading, 6).padding(.trailing, removable ? 4 : 9).frame(height: 26)
        .background(GoalongSurface(corner: LHTheme.controlRadius - 1, fill: LHTheme.controlBackground, highlighted: true))
        .accessibilityElement(children: .contain)
    }

    private var title: String {
        if let label { return label }
        switch item {
        case .site(let pattern): return pattern
        case .app(let app): return app.name
        case .symbol(let name): return name
        }
    }
}

/// A list to include in « Bloquer maintenant »: selected = lime outline and a check.
struct BlockingListChip: View {
    let list: BlockList
    let selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                BlockingIconCluster(lists: [list], size: 16, limit: 3)
                Text(list.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Image(systemName: selected ? "checkmark" : "plus").font(.system(size: 10, weight: .bold))
                    .foregroundStyle(selected ? LHTheme.accent : LHTheme.tertiaryText)
            }
            .padding(.horizontal, 10).frame(height: 32)
            .background {
                let shape = RoundedRectangle(cornerRadius: LHTheme.controlRadius, style: .continuous)
                shape.fill(selected ? LHTheme.selectionBackground : LHTheme.controlBackground)
                    .overlay(shape.strokeBorder(selected ? LHTheme.accent : LHTheme.controlBorder, lineWidth: selected ? 1.5 : 1))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("blocking-pick-\(list.name)")
    }
}

/// Installed apps, searchable, with their icons.
@MainActor struct BlockingAppPicker: View {
    let excluded: Set<String>
    /// Given by a test or the gallery: shown as is, and no scan of the installed apps.
    private let fixedApps: [BlockAppRule]?
    var onPick: (BlockAppRule) -> Void
    @State private var apps: [BlockAppRule]
    @State private var search = ""

    init(excluded: Set<String>, apps: [BlockAppRule]? = nil, onPick: @escaping (BlockAppRule) -> Void) {
        self.excluded = excluded; fixedApps = apps; self.onPick = onPick
        _apps = State(initialValue: apps ?? [])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GoalongSearchField("Rechercher une app…", text: $search, accessibilityLabel: "Rechercher une app")
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(apps.filter { !excluded.contains($0.bundleIdentifier) && (search.isEmpty || $0.name.localizedStandardContains(search)) }) { app in
                        Button { onPick(app) } label: {
                            HStack(spacing: 10) {
                                AppIconView(bundleIdentifier: app.bundleIdentifier, appName: app.name, size: 22)
                                Text(app.name).font(.system(size: 13))
                                Spacer()
                            }
                            .padding(.horizontal, 8).frame(height: 32).contentShape(Rectangle())
                        }
                        .buttonStyle(LHNavigationButtonStyle(cornerRadius: 6))
                    }
                }
            }
            .frame(height: 300)
        }
        .padding(14).frame(width: 300)
        .task { if fixedApps == nil { apps = await BlockingController.installedApps() } }
        .goalongControls()
    }
}

/// Lays chips out in lines, wrapping at the available width.
struct BlockingFlow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { y += line + spacing; x = 0; line = 0 }
            x += size.width + spacing; line = max(line, size.height); widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { y += line + spacing; x = bounds.minX; line = 0 }
            view.place(at: CGPoint(x: x, y: y + (line > 0 ? 0 : 0)), proposal: ProposedViewSize(size))
            x += size.width + spacing; line = max(line, size.height)
        }
    }
}
#endif
