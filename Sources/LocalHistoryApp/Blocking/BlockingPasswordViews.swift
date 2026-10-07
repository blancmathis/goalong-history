#if os(macOS)
import SwiftUI

extension BlockLock {
    /// Weakest first: the order the member reads them in.
    static let ordered: [BlockLock] = [.free, .typing, .password, .locked]

    var title: String {
        switch self {
        case .free: return "Libre"
        case .typing: return "Difficile"
        case .password: return "Mot de passe"
        case .locked: return "Verrouillé"
        }
    }

    var symbol: String {
        switch self {
        case .free: return "lock.open"
        case .typing: return "lock"
        case .password: return "key.fill"
        case .locked: return "lock.fill"
        }
    }
}

/// How hard a block is to stop. « Mot de passe » needs the blocking password first: the picker
/// offers to set it right there, so the choice never ends on a refusal.
@MainActor struct BlockingLockPicker: View {
    @ObservedObject var controller: BlockingController
    @Binding var lock: BlockLock
    /// Locks below this one cannot be chosen (a locked program can only get stricter).
    var minimum: BlockLock = .free
    @State private var settingPassword = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GoalongSegmentedControl("Arrêt", selection: Binding(get: { lock }, set: { lock = stronger($0, minimum) }),
                                    options: BlockLock.ordered.filter { $0.strength >= minimum.strength }) { $0.title }
            BlockingLockExplainer(lock: lock)
            if lock == .password, !controller.hasPassword {
                HStack(spacing: 10) {
                    Text("Pas encore de mot de passe.")
                        .font(.system(size: 12)).foregroundStyle(LHTheme.warning).fixedSize()
                    Button("Le choisir…") { settingPassword = true }
                        .buttonStyle(LHQuietButtonStyle()).fixedSize()
                        .accessibilityIdentifier("blocking-password-set")
                }
            }
        }
        .sheet(isPresented: $settingPassword) {
            BlockingPasswordSheet(controller: controller, purpose: .create) { settingPassword = false }
                .goalongControls()
        }
    }
}

private func stronger(_ a: BlockLock, _ b: BlockLock) -> BlockLock { a.strength >= b.strength ? a : b }

/// Every use of the blocking password: choose it, unlock one block, change or remove it.
@MainActor struct BlockingPasswordSheet: View {
    enum Purpose: Equatable {
        case create
        /// Stops an active block, cancels a scheduled one or skips one program range.
        case unlock(UUID, what: String)
        case change
        case remove
    }

    @ObservedObject var controller: BlockingController
    let purpose: Purpose
    var onClose: () -> Void
    @State private var old = ""
    @State private var new = ""
    @State private var again = ""
    @State private var message: String?
    @FocusState private var focused: Bool

    /// Long enough that it is not guessed, short enough that a friend types it without a fuss.
    static let minimumLength = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(LHTheme.sheetTitleFont).tracking(-0.4)
                Text(subtitle).font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if purpose == .create { handOver }
            VStack(alignment: .leading, spacing: 10) {
                if needsOld {
                    SecureField(purpose == .change ? "Mot de passe actuel" : "Mot de passe de blocage", text: $old)
                        .textFieldStyle(GoalongFieldStyle()).focused($focused)
                        .accessibilityIdentifier("blocking-password-field")
                }
                if needsNew {
                    SecureField(purpose == .change ? "Nouveau mot de passe" : "Mot de passe", text: $new)
                        .textFieldStyle(GoalongFieldStyle())
                        .accessibilityIdentifier("blocking-password-new")
                    SecureField("Retapez-le", text: $again)
                        .textFieldStyle(GoalongFieldStyle())
                        .accessibilityIdentifier("blocking-password-again")
                }
            }
            if let message {
                GoalongNote(message, tone: .warning).accessibilityIdentifier("blocking-password-message")
            }
            HStack {
                Spacer()
                Button(cancelTitle) { clear(); onClose() }.keyboardShortcut(.cancelAction)
                Button(actionTitle, action: submit)
                    .buttonStyle(LHPrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(!ready)
                    .accessibilityIdentifier("blocking-password-submit")
            }
        }
        .font(.system(size: 13))
        .padding(28).frame(width: 480)
        .background(LHTheme.pageBackground)
        .onAppear { focused = true }
    }

    /// The point of the password: someone else keeps it.
    private var handOver: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array([
                ("person.2", "Demandez à un proche de le taper, sans vous le montrer."),
                ("key", "Il le garde. Sans lui, un blocage « Mot de passe » va jusqu’à sa fin."),
                ("arrow.counterclockwise", "Oublié ? Le blocage finit à son heure. Goalong ne peut pas le retrouver."),
            ].enumerated()), id: \.offset) { _, line in
                Label(line.1, systemImage: line.0)
                    .font(.system(size: 12)).foregroundStyle(LHTheme.text)
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(LHTheme.insetBackground, in: RoundedRectangle(cornerRadius: LHTheme.controlRadius, style: .continuous))
    }

    private var title: String {
        switch purpose {
        case .create: return "Mot de passe de blocage"
        case .unlock: return "Débloquer avec le mot de passe"
        case .change: return "Changer le mot de passe"
        case .remove: return "Supprimer le mot de passe"
        }
    }

    private var subtitle: String {
        switch purpose {
        case .create:
            return "Un seul mot de passe pour tous les blocages « Mot de passe ». Il faut le taper pour les arrêter, alléger leurs listes, couper le module ou quitter Goalong."
        case .unlock(_, let what): return what
        case .change: return "Possible seulement quand aucun blocage « Mot de passe » n’est actif ou prévu."
        case .remove: return "Possible seulement quand aucun blocage « Mot de passe » n’est actif ou prévu."
        }
    }

    private var actionTitle: String {
        switch purpose {
        case .create: return "Enregistrer"
        case .unlock: return "Débloquer"
        case .change: return "Changer"
        case .remove: return "Supprimer"
        }
    }

    private var cancelTitle: String {
        if case .unlock = purpose { return "Garder le blocage" }
        return "Annuler"
    }

    private var needsOld: Bool { purpose != .create }
    private var needsNew: Bool { purpose == .create || purpose == .change }

    private var ready: Bool {
        (!needsOld || !old.isEmpty) && (!needsNew || new.count >= Self.minimumLength)
    }

    private func submit() {
        if needsNew {
            guard new == again else { message = "Les deux mots de passe sont différents."; return }
        }
        let result: BlockingPasswordResult
        switch purpose {
        case .create: result = controller.setPassword(new) ? .ok : .refused(reason: controller.error ?? "Mot de passe refusé.")
        case .unlock(let id, _): result = controller.unlockWithPassword(old, blockID: id)
        case .change: result = controller.changePassword(old: old, new: new)
        case .remove: result = controller.removePassword(old: old)
        }
        switch result {
        case .ok:
            controller.error = nil
            clear(); onClose()
        case .wrong(let remaining):
            old = ""
            message = remaining > 0
                ? "Mot de passe incorrect. Encore \(remaining) essai\(remaining > 1 ? "s" : "") avant une attente."
                : "Mot de passe incorrect."
        case .wait(let until):
            old = ""
            message = "Trop d’essais. Réessayez \(BlockingFormat.moment(until))."
        case .refused(let reason):
            controller.error = nil
            message = reason
        }
    }

    private func clear() { old = ""; new = ""; again = "" }
}

/// One-time blocks set for later, under the state: each can be cancelled at the price of its lock.
@MainActor struct BlockingScheduledList: View {
    @ObservedObject var controller: BlockingController
    let now: Date
    var onTyping: (BlockSession) -> Void
    var onPassword: (BlockSession) -> Void

    var body: some View {
        let upcoming = controller.scheduledBlocks.filter { $0.start > now }
        if !upcoming.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text("Programmés une fois").font(.system(size: 12, weight: .medium))
                    .foregroundStyle(LHTheme.secondaryText).padding(.bottom, 6)
                ForEach(upcoming) { session in
                    if session.id != upcoming.first?.id { GoalongRowDivider() }
                    row(session)
                }
            }
            .accessibilityIdentifier("blocking-scheduled")
        }
    }

    private func row(_ session: BlockSession) -> some View {
        let lists = session.listIDs.compactMap(controller.list)
        return HStack(spacing: 12) {
            BlockingIconCluster(lists: lists, size: 18, limit: 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(lists.map(\.name).joined(separator: ", ")).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text("\(BlockingFormat.moment(session.start, now: now)) → \(BlockingFormat.time(session.end))")
                    .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
            }
            Spacer(minLength: 12)
            Label(session.lock.title, systemImage: session.lock.symbol)
                .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
            switch session.lock {
            case .free: Button("Annuler") { controller.cancelScheduled(id: session.id) }
            case .typing: Button("Annuler…") { onTyping(session) }
            case .password: Button("Annuler…") { onPassword(session) }
            case .locked: EmptyView()
            }
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .contain)
    }
}
#endif
