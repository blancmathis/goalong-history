#if os(macOS)
import AppKit
import SwiftUI

/// The human's next action and agenda stay separate from work running in parallel.
@MainActor struct ConcentrationDayView: View {
    @ObservedObject var controller: ConcentrationController
    let now: Date
    let onReview: () -> Void
    @State private var editingTask: FocusDayTaskRequest?
    @State private var editingAgenda = false
    @State private var editingProcess: FocusDayProcessRequest?
    @State private var answering: FocusAgentProcess?
    @State private var completedOpen = false
    @State private var error: String?

    private var plan: FocusPlan { controller.plan }
    private var processes: [FocusAgentProcess] { plan.processes ?? [] }
    private var waiting: [FocusAgentProcess] { FocusDayPlanner.waitingProcesses(plan: plan) }
    private var currentSlot: FocusAgendaSlot? { FocusDayPlanner.currentSlot(plan: plan, at: now) }
    private var nextSlot: FocusAgendaSlot? { FocusDayPlanner.nextSlot(plan: plan, at: now) }
    private var currentItem: FocusPlanItem? {
        if let id = controller.currentSession?.planItemId { return plan.items.first { $0.id == id } }
        if let slot = currentSlot { return FocusDayPlanner.task(for: slot, in: plan) }
        if let slot = nextSlot { return FocusDayPlanner.task(for: slot, in: plan) }
        return plan.items.first { $0.status == .open }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            dayHeader
            if let error { GoalongNote(error, tone: .warning, onDismiss: { self.error = nil }) }
            if controller.settings.usePlanContext == true { FocusDayPlanContextNotice() }
            currentAction
            if let agenda = plan.agenda, !agenda.slots.isEmpty { agendaList(agenda) }
            taskList
            if !processes.isEmpty { parallelSection }
        }
        .accessibilityIdentifier("concentration-guided-day")
        .sheet(item: $editingTask) { request in
            FocusDayTaskEditor(controller: controller, plan: plan, item: request.item, isNew: request.isNew,
                               blocked: request.blocked)
                .goalongControls()
        }
        .sheet(isPresented: $editingAgenda) {
            FocusDayAgendaEditor(controller: controller, plan: plan).goalongControls()
        }
        .sheet(item: $editingProcess) { request in
            FocusDayProcessEditor(controller: controller, plan: plan, process: request.process, isNew: request.isNew)
                .goalongControls()
        }
        .sheet(item: $answering) { process in
            FocusDayAnswerSheet(controller: controller, process: process).goalongControls()
        }
    }

    private var dayHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Votre journée").font(.system(size: 22, weight: .semibold))
                if let intention = FocusDayUI.clean(plan.intention) {
                    Text(intention).font(.system(size: 13)).foregroundStyle(LHTheme.secondaryText)
                } else {
                    Text(processes.isEmpty ? "L’action à suivre, puis la suite." : "Votre attention ici. Les processus avancent en parallèle.")
                        .font(.system(size: 13)).foregroundStyle(LHTheme.secondaryText)
                }
            }
            Spacer(minLength: 8)
            Button("Agenda") { editingAgenda = true }.buttonStyle(LHSecondaryButtonStyle())
                .accessibilityIdentifier("concentration-edit-agenda")
            if !plan.items.isEmpty {
                Button("Bilan", action: onReview).buttonStyle(LHQuietButtonStyle())
                    .accessibilityIdentifier("concentration-open-review")
            }
        }
    }

    @ViewBuilder private var currentAction: some View {
        if let item = currentItem, controller.currentSession?.planItemId == item.id,
           (currentSlot ?? nextSlot)?.itemID != item.id {
            standaloneTaskCard(item)
        } else if let slot = currentSlot ?? nextSlot {
            FocusDayCurrentCard(
                eyebrow: currentSlot == nil ? "À suivre · \(FocusDayUI.time(slot.startMinute))" : "Maintenant",
                title: slot.title, item: FocusDayPlanner.task(for: slot, in: plan),
                active: slot.state == .active, hasSession: controller.currentSession != nil,
                next: nextDescription(after: slot), fixed: slot.fixed,
                onStart: { perform { try controller.startAgendaSlot(slot.id) } },
                onFinish: { perform { try controller.finishAgendaSlot(slot.id) } },
                onShift: { perform { try controller.shiftAgendaSlot(slot.id, minutes: 15) } },
                onBlocked: { if let item = FocusDayPlanner.task(for: slot, in: plan) { edit(item, blocked: true) } },
                onContext: { openContext(FocusDayPlanner.task(for: slot, in: plan)?.contextURL) })
        } else if let item = currentItem {
            standaloneTaskCard(item)
        } else if controller.currentSession == nil {
            VStack(alignment: .leading, spacing: 12) {
                Text(plan.items.isEmpty ? "Que voulez-vous faire avancer ?" : "Les actions prévues sont terminées.")
                    .font(.system(size: 17, weight: .semibold))
                Text("Notez un résultat utile et la première action concrète. Le reste peut se préciser ensuite.")
                    .font(.system(size: 13)).foregroundStyle(LHTheme.secondaryText)
                Button("Ajouter une action") { addTask() }.buttonStyle(LHPrimaryButtonStyle())
                    .disabled(plan.items.count >= FocusPlan.maximumItems)
            }.padding(.vertical, 4)
        }
    }

    private func standaloneTaskCard(_ item: FocusPlanItem) -> some View {
        FocusDayCurrentCard(
            eyebrow: controller.currentSession?.planItemId == item.id ? "Maintenant" : "Prochaine action",
            title: item.title, item: item, active: controller.currentSession?.planItemId == item.id,
            hasSession: controller.currentSession != nil, next: nil, fixed: false,
            onStart: { perform { try controller.startPlannedItem(item.id) } },
            onFinish: nil, onShift: nil, onBlocked: { edit(item, blocked: true) },
            onContext: { openContext(item.contextURL) })
    }

    private func nextDescription(after slot: FocusAgendaSlot) -> String? {
        guard let next = nextSlot, next.id != slot.id else { return nil }
        return "Ensuite · \(FocusDayUI.time(next.startMinute)) · \(next.title)"
    }

    private func agendaList(_ agenda: FocusAgenda) -> some View {
        GoalongSection(title: "Agenda", subtitle: agenda.guided ? "Les rappels suivent le planning." : "Activez les rappels dans les réglages de l’agenda.") {
            Menu {
                Button("Modifier les horaires") { editingAgenda = true }
                Button("Replacer la suite") { perform { try controller.reflowDayPlan() } }
                if plan.previousAgenda != nil {
                    Button("Annuler le dernier ajustement") { perform { try controller.undoDayAdjustment() } }
                }
            } label: { Image(systemName: "ellipsis").frame(width: 28, height: 24) }
                .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Actions de l’agenda")
        } content: {
            LHCard(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(agenda.slots.sorted { $0.startMinute < $1.startMinute }) { slot in
                        FocusDayAgendaRow(slot: slot, current: currentSlot?.id == slot.id,
                                          onSelect: { perform { try controller.startAgendaSlot(slot.id) } },
                                          onFinish: { perform { try controller.finishAgendaSlot(slot.id) } },
                                          onShift: { perform { try controller.shiftAgendaSlot(slot.id, minutes: 15) } },
                                          canStart: controller.currentSession == nil)
                        if slot.id != agenda.slots.sorted(by: { $0.startMinute < $1.startMinute }).last?.id {
                            GoalongRowDivider(inset: 16)
                        }
                    }
                }
            }
        }
    }

    private var taskList: some View {
        GoalongSection(title: processes.isEmpty ? "Actions du jour" : "Votre attention", subtitle: nil) {
            Button { addTask() } label: { Label("Ajouter", systemImage: "plus") }
                .buttonStyle(LHQuietButtonStyle()).disabled(plan.items.count >= FocusPlan.maximumItems)
                .accessibilityIdentifier("concentration-add-day-task")
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                if !plan.items.filter({ $0.status == .open }).isEmpty {
                    LHCard(padding: 0) {
                        VStack(spacing: 0) {
                            ForEach(plan.items.filter { $0.status == .open }) { item in
                                taskRow(item)
                                if item.id != plan.items.last(where: { $0.status == .open })?.id {
                                    GoalongRowDivider(inset: 16)
                                }
                            }
                        }
                    }
                }
                if plan.items.contains(where: { $0.status != .open }) {
                    DisclosureGroup("Actions terminées ou reportées", isExpanded: $completedOpen) {
                        VStack(spacing: 6) {
                            ForEach(plan.items.filter { $0.status != .open }) { item in taskRow(item) }
                        }.padding(.top, 8)
                    }.font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                }
                if processes.isEmpty {
                    Button("Suivre aussi des processus en parallèle") { addProcess() }
                        .buttonStyle(LHQuietButtonStyle()).font(.system(size: 12))
                }
            }
        }
    }

    private func taskRow(_ item: FocusPlanItem) -> some View {
        let active = controller.currentSession?.planItemId == item.id
        return HStack(alignment: .center, spacing: 12) {
            Button {
                perform {
                    var updated = plan
                    guard let index = updated.items.firstIndex(where: { $0.id == item.id }) else { return }
                    updated.items[index].status = item.status == .open ? .done : .open
                    updated.items[index].toDay = nil
                    if item.status == .open, var agenda = updated.agenda {
                        for index in agenda.slots.indices where agenda.slots[index].itemID == item.id {
                            agenda.slots[index].state = .done
                        }
                        updated.agenda = agenda
                    }
                    try controller.applyDayPlan(updated, expectedRevision: plan.effectiveRevision, reason: item.status == .open ? "Action terminée" : "Action rouverte")
                }
            } label: {
                Image(systemName: item.status == .done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 17)).frame(width: 24, height: 28)
            }.buttonStyle(.plain).disabled(active)
                .accessibilityLabel(item.status == .open ? "Terminer \(item.title)" : "Rouvrir \(item.title)")
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.system(size: 13, weight: .medium)).foregroundStyle(LHTheme.text)
                if let next = FocusDayUI.clean(item.nextAction), item.status == .open {
                    Text(next).font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText).lineLimit(2)
                }
                let meta = [item.project, item.actionKind?.title, active ? "En cours" : item.status == .moved ? "Reportée" : nil].compactMap { FocusDayUI.clean($0) }.joined(separator: " · ")
                if !meta.isEmpty { Text(meta).font(.system(size: 11)).foregroundStyle(LHTheme.tertiaryText) }
            }
            Spacer(minLength: 8)
            if item.status == .open && !active {
                Button("Commencer") { perform { try controller.startPlannedItem(item.id) } }
                    .buttonStyle(LHQuietButtonStyle()).disabled(controller.currentSession != nil)
            }
            Menu {
                Button("Modifier") { edit(item) }
                if item.status == .open {
                    Button("Ça bloque : préciser le prochain geste") { edit(item, blocked: true) }
                    Button("Reporter à demain") {
                        perform {
                            let tomorrow = try controller.dayAfter(plan.day)
                            try controller.movePlanItem(item.id, day: plan.day, to: tomorrow)
                        }
                    }.disabled(active)
                }
                if item.contextURL != nil { Button("Ouvrir le contexte") { openContext(item.contextURL) } }
                Button("Retirer du plan") {
                    perform {
                        var updated = plan
                        updated.items.removeAll { $0.id == item.id }
                        updated.agenda?.slots.removeAll { $0.itemID == item.id }
                        try controller.applyDayPlan(updated, expectedRevision: plan.effectiveRevision, reason: "Action retirée")
                    }
                }.disabled(active)
            } label: { Image(systemName: "ellipsis").frame(width: 24, height: 28) }
                .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Options de \(item.title)")
        }.padding(14)
    }

    private var parallelSection: some View {
        GoalongSection(title: "En parallèle", subtitle: "Plusieurs processus peuvent avancer pendant votre action.") {
            Button { addProcess() } label: { Label("Ajouter", systemImage: "plus") }
                .buttonStyle(LHQuietButtonStyle()).disabled(processes.count >= FocusPlan.maximumProcesses)
        } content: {
            VStack(alignment: .leading, spacing: 14) {
                if !waiting.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(waiting.count == 1 ? "Une question à débloquer" : "\(waiting.count) questions à débloquer")
                            .font(.system(size: 13, weight: .semibold))
                        ForEach(waitingGroups, id: \.self) { project in
                            VStack(alignment: .leading, spacing: 5) {
                                if project != "Sans projet" || waitingGroups.count > 1 {
                                    Text(project).font(.system(size: 12, weight: .medium)).foregroundStyle(LHTheme.secondaryText)
                                }
                                ForEach(waiting.filter { (FocusDayUI.clean($0.project) ?? "Sans projet") == project }) { process in
                                    questionRow(process)
                                }
                            }
                        }
                    }
                }
                LHCard(padding: 0) {
                    VStack(spacing: 0) {
                        ForEach(processes) { process in
                            processRow(process)
                            if process.id != processes.last?.id { GoalongRowDivider(inset: 16) }
                        }
                    }
                }
            }
        }
    }

    private var waitingGroups: [String] {
        Array(Set(waiting.map { FocusDayUI.clean($0.project) ?? "Sans projet" })).sorted()
    }

    private func questionRow(_ process: FocusAgentProcess) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(process.title).font(.system(size: 13, weight: .medium))
                Text(FocusDayUI.clean(process.question) ?? "Ouvrez le contexte pour voir la question.")
                    .font(.system(size: 13)).foregroundStyle(LHTheme.secondaryText).lineLimit(4)
            }
            Spacer(minLength: 8)
            Button("Répondre") { answering = process }.buttonStyle(LHSecondaryButtonStyle())
        }.padding(.vertical, 10)
    }

    private func processRow(_ process: FocusAgentProcess) -> some View {
        HStack(spacing: 12) {
            Image(systemName: process.status.isFinished ? "checkmark.circle" : process.needsAnswer ? "bubble.left" : "arrow.triangle.branch")
                .foregroundStyle(LHTheme.secondaryText).frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(process.title).font(.system(size: 13, weight: .medium))
                let meta = [process.project, process.agent].compactMap { FocusDayUI.clean($0) }.joined(separator: " · ")
                if !meta.isEmpty { Text(meta).font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText) }
            }
            Spacer(minLength: 8)
            Text(process.status == .waitingForYou && !process.needsAnswer ? "Réponse prête · à reprendre" : process.status.title)
                .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText).lineLimit(2)
            Menu {
                if process.status == .waitingForYou {
                    Button(process.needsAnswer ? "Répondre" : "Modifier la réponse") { answering = process }
                }
                if process.contextURL != nil { Button("Ouvrir le contexte") { openContext(process.contextURL) } }
                Button("Modifier le suivi") { editingProcess = FocusDayProcessRequest(process: process, isNew: false) }
            } label: { Image(systemName: "ellipsis").frame(width: 24, height: 28) }
                .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Options de \(process.title)")
        }.padding(14)
    }

    private func addTask() {
        editingTask = FocusDayTaskRequest(item: FocusPlanItem(title: "", project: nil, estimateMinutes: nil), isNew: true)
    }
    private func edit(_ item: FocusPlanItem, blocked: Bool = false) {
        editingTask = FocusDayTaskRequest(item: item, isNew: false, blocked: blocked)
    }
    private func addProcess() { editingProcess = FocusDayProcessRequest(process: FocusAgentProcess(title: ""), isNew: true) }
    private func perform(_ action: () throws -> Void) {
        do { try action(); error = nil } catch { self.error = FocusDayUI.message(error) }
    }
    private func openContext(_ value: String?) {
        guard let value, let url = URL(string: value) else { return }
        if !GoalongWorkspaceOpenPolicy.open(url, purpose: .plannedContext) {
            error = "Ce lien n’est pas pris en charge. Utilisez une adresse HTTPS ou l’adresse locale de Context Room."
        }
    }
}

@MainActor private struct FocusDayPlanContextNotice: View {
    @ObservedObject private var monitor = JevMonitor.shared
    var body: some View {
        if let notice = monitor.planActionNotice {
            Text(notice).font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct FocusDayTaskRequest: Identifiable {
    var id: UUID { item.id }
    var item: FocusPlanItem
    var isNew: Bool
    var blocked = false
}
private struct FocusDayProcessRequest: Identifiable {
    var id: UUID { process.id }
    var process: FocusAgentProcess
    var isNew: Bool
}

private struct FocusDayCurrentCard: View {
    let eyebrow: String
    let title: String
    let item: FocusPlanItem?
    let active: Bool
    let hasSession: Bool
    let next: String?
    let fixed: Bool
    let onStart: () -> Void
    let onFinish: (() -> Void)?
    let onShift: (() -> Void)?
    let onBlocked: () -> Void
    let onContext: () -> Void

    var body: some View {
        LHCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Text(eyebrow).font(.system(size: 12, weight: .semibold)).foregroundStyle(LHTheme.secondaryText)
                    if fixed { Label("Repère fixe", systemImage: "pin").font(.system(size: 11)).foregroundStyle(LHTheme.tertiaryText) }
                    Spacer(minLength: 8)
                    if let project = FocusDayUI.clean(item?.project) {
                        Text(project).font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                    }
                }
                Text(title).font(.system(size: 22, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                if let action = FocusDayUI.clean(item?.nextAction) {
                    Text(action).font(.system(size: 15)).fixedSize(horizontal: false, vertical: true)
                }
                if let done = FocusDayUI.clean(item?.doneWhen) {
                    Text("Fini quand : \(done)").font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                }
                HStack(spacing: 10) {
                    if active {
                        if let onFinish {
                            Button("C’est fait", action: onFinish).buttonStyle(LHPrimaryButtonStyle())
                                .accessibilityIdentifier("concentration-finish-current-slot")
                        } else {
                            Text("Séance en cours").font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                        }
                    } else {
                        Button("Commencer", action: onStart).buttonStyle(LHPrimaryButtonStyle())
                            .disabled(hasSession).accessibilityIdentifier("concentration-start-current-action")
                    }
                    if let onShift, !fixed {
                        Button(active ? "Ajouter 15 min au créneau" : "Décaler de 15 min", action: onShift)
                            .buttonStyle(LHSecondaryButtonStyle())
                            .help("Ajuste l’agenda. Le minuteur et les blocages de la séance conservent leur durée.")
                    }
                    if item != nil { Button("Ça bloque", action: onBlocked).buttonStyle(LHQuietButtonStyle()) }
                    Spacer(minLength: 4)
                    if item?.contextURL != nil {
                        Button(action: onContext) { Label("Contexte", systemImage: "arrow.up.right") }
                            .buttonStyle(LHQuietButtonStyle())
                    }
                }
                if let next {
                    Text(next).font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                        .padding(.top, 3).accessibilityIdentifier("concentration-next-action")
                }
            }
        }
    }
}

private struct FocusDayAgendaRow: View {
    let slot: FocusAgendaSlot
    let current: Bool
    let onSelect: () -> Void
    let onFinish: () -> Void
    let onShift: () -> Void
    let canStart: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(FocusDayUI.time(slot.startMinute)).font(.system(size: 13, weight: .medium).monospacedDigit())
                Text(FocusDayUI.time(slot.endMinute)).font(.system(size: 11).monospacedDigit()).foregroundStyle(LHTheme.secondaryText)
            }.frame(width: 44, alignment: .leading)
            Rectangle().fill(current ? LHTheme.text : LHTheme.separator).frame(width: current ? 3 : 1, height: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(slot.title).font(.system(size: 13, weight: current ? .semibold : .regular))
                    .foregroundStyle(slot.state.isFinished ? LHTheme.secondaryText : LHTheme.text)
                HStack(spacing: 7) {
                    Text(slot.state.title)
                    if slot.fixed { Label("Fixe", systemImage: "pin") }
                }.font(.system(size: 11)).foregroundStyle(LHTheme.secondaryText)
            }
            Spacer(minLength: 8)
            if !slot.state.isFinished {
                Menu {
                    if slot.state != .active { Button("Commencer", action: onSelect).disabled(!canStart) }
                    Button("C’est fait", action: onFinish)
                    if !slot.fixed { Button(slot.state == .active ? "Ajouter 15 min au créneau" : "Décaler de 15 min", action: onShift) }
                } label: { Image(systemName: "ellipsis").frame(width: 24, height: 28) }
                    .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Options de \(slot.title)")
            }
        }.padding(.horizontal, 16).padding(.vertical, 12)
    }
}

@MainActor private struct FocusDayTaskEditor: View {
    @ObservedObject var controller: ConcentrationController
    @State private var plan: FocusPlan
    let isNew: Bool
    let blocked: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var item: FocusPlanItem
    @State private var detailsOpen = false
    @State private var error: String?

    init(controller: ConcentrationController, plan: FocusPlan, item: FocusPlanItem, isNew: Bool, blocked: Bool) {
        self.controller = controller; self.isNew = isNew; self.blocked = blocked
        _plan = State(initialValue: plan)
        _item = State(initialValue: item)
    }

    var body: some View {
        FocusDaySheet(title: blocked ? "Le prochain geste" : isNew ? "Ajouter une action" : "Modifier l’action",
                      error: error, onCancel: { dismiss() }, onSave: save) {
            if blocked {
                Text("La tâche peut rester difficile. Précisez un geste utile que vous pouvez commencer maintenant, puis ajustez la suite si nécessaire.")
                    .font(.system(size: 13)).foregroundStyle(LHTheme.secondaryText)
            }
            GoalongFormField(title: "Résultat à faire avancer") {
                TextField("Ex. Publier la vidéo de présentation", text: $item.title).textFieldStyle(GoalongFieldStyle())
            }
            GoalongFormField(title: "Prochaine action", detail: "Le geste concret à suivre quand vous commencez.") {
                TextField("Ex. Enregistrer une première prise de l’introduction", text: optional(\.nextAction))
                    .textFieldStyle(GoalongFieldStyle())
            }
            DisclosureGroup("Précisions facultatives", isExpanded: $detailsOpen) {
                VStack(alignment: .leading, spacing: 14) {
                    GoalongFormField(title: "Fini quand") {
                        TextField("Un résultat observable", text: optional(\.doneWhen)).textFieldStyle(GoalongFieldStyle())
                    }
                    HStack(alignment: .top, spacing: 14) {
                        GoalongFormField(title: "Projet") {
                            TextField("Facultatif", text: optional(\.project)).textFieldStyle(GoalongFieldStyle())
                        }
                        GoalongFormField(title: "Type d’action") {
                            Picker("Type d’action", selection: Binding(get: { item.actionKind ?? .work }, set: { item.actionKind = $0 })) {
                                ForEach(FocusActionKind.allCases, id: \.rawValue) { kind in Text(kind.title).tag(kind) }
                            }.labelsHidden()
                        }
                    }
                    GoalongFormField(title: "Lien de contexte") {
                        TextField("Documentation, projet ou conversation", text: optional(\.contextURL)).textFieldStyle(GoalongFieldStyle())
                    }
                    HStack {
                        Toggle("Prévoir une durée", isOn: Binding(get: { item.estimateMinutes != nil }, set: { item.estimateMinutes = $0 ? 25 : nil }))
                        if item.estimateMinutes != nil {
                            Stepper("\(item.estimateMinutes ?? 25) min", value: Binding(get: { item.estimateMinutes ?? 25 }, set: { item.estimateMinutes = $0 }), in: 5...600, step: 5)
                                .frame(width: 160)
                        }
                    }
                }.padding(.top, 12)
            }.font(.system(size: 13))
        }
    }

    private func optional(_ path: WritableKeyPath<FocusPlanItem, String?>) -> Binding<String> {
        Binding(get: { item[keyPath: path] ?? "" }, set: { item[keyPath: path] = $0.isEmpty ? nil : $0 })
    }
    private func save() {
        item.title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        item.nextAction = FocusDayUI.clean(item.nextAction); item.doneWhen = FocusDayUI.clean(item.doneWhen)
        item.project = FocusDayUI.clean(item.project); item.contextURL = FocusDayUI.clean(item.contextURL)
        guard item.valid else { error = "Vérifiez le titre, les textes et le lien de contexte."; return }
        var updated = plan
        if isNew { updated.items.append(item) }
        else if let index = updated.items.firstIndex(where: { $0.id == item.id }) { updated.items[index] = item }
        do {
            try controller.applyDayPlan(updated, expectedRevision: plan.effectiveRevision, reason: isNew ? "Action ajoutée" : "Action précisée")
            dismiss()
        } catch { self.error = FocusDayUI.message(error) }
    }
}

@MainActor private struct FocusDayAgendaEditor: View {
    @ObservedObject var controller: ConcentrationController
    @State private var plan: FocusPlan
    @Environment(\.dismiss) private var dismiss
    @State private var agenda: FocusAgenda
    @State private var repeatAnchors = false
    @State private var optionsOpen = false
    @State private var error: String?

    init(controller: ConcentrationController, plan: FocusPlan) {
        self.controller = controller
        _plan = State(initialValue: plan)
        _agenda = State(initialValue: plan.agenda ?? FocusAgenda(timeZoneID: TimeZone.current.identifier))
        _repeatAnchors = State(initialValue: controller.settings.agendaTemplate != nil)
    }

    var body: some View {
        FocusDaySheet(title: "Préparer la journée", error: error, width: 720, onCancel: { dismiss() }, onSave: save) {
            Text("Des actions pour votre attention, des repères fixes pour les repas et la fin de journée. Les processus parallèles ne prennent pas un créneau chacun.")
                .font(.system(size: 13)).foregroundStyle(LHTheme.secondaryText)
            Toggle("Me rappeler l’action à suivre", isOn: $agenda.guided)
            if agenda.slots.isEmpty {
                Text("Ajoutez les actions et les repères dont vous avez besoin.")
                    .font(.system(size: 13)).foregroundStyle(LHTheme.secondaryText).padding(.vertical, 8)
            } else {
                ScrollView {
                    VStack(spacing: 14) {
                        ForEach($agenda.slots) { $slot in
                            let slotID = slot.id
                            FocusDaySlotEditor(slot: $slot, items: plan.items, removable: slot.state != .active) {
                                agenda.slots.removeAll { $0.id == slotID }
                            }
                        }
                    }.padding(.trailing, 6)
                }.frame(maxHeight: 310)
            }
            HStack(spacing: 10) {
                Menu("Ajouter une action") {
                    ForEach(plan.items.filter { $0.status == .open }) { item in
                        Button(item.title) { append(item: item) }
                    }
                }.disabled(plan.items.allSatisfy { $0.status != .open } || agenda.slots.count >= FocusAgenda.maximumSlots)
                Button("Ajouter un repère") { append(item: nil) }
                    .buttonStyle(LHSecondaryButtonStyle()).disabled(agenda.slots.count >= FocusAgenda.maximumSlots)
            }
            DisclosureGroup("Ajustements et répétition", isExpanded: $optionsOpen) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 18) {
                        GoalongFormField(title: "Début de la plage de travail") { FocusDayTimeField(minute: $agenda.startMinute) }
                        GoalongFormField(title: "Fin de la plage de travail") { FocusDayTimeField(minute: $agenda.endMinute, allowsMidnight: true) }
                        GoalongFormField(title: "Marge entre les actions") {
                            Stepper("\(agenda.bufferMinutes) min", value: $agenda.bufferMinutes, in: 0...60, step: 5)
                        }
                    }
                    Toggle("Replacer les actions souples après un changement", isOn: $agenda.autoAdjust)
                    VStack(alignment: .leading, spacing: 5) {
                        Toggle("Donner à Jev l’action en cours", isOn: planContextBinding)
                        Text("Si vous avez déjà consenti au service Jev, seuls le titre et la première action de la séance choisie lui seront transmis. Les questions des agents et la documentation restent exclues.")
                            .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                        Text("Si l’action ne tient pas entière dans l’envoi, elle sera omise et Goalong vous l’indiquera.")
                            .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                    }
                    Toggle("Réutiliser les repères sans action liée les prochains jours", isOn: $repeatAnchors)
                    Text("Les repères fixes et la fin de journée restent en place. Un créneau qui ne tient plus sera indiqué « À replacer ».")
                        .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                    if controller.settings.agendaTemplate != nil {
                        Button("Ne plus répéter les repères") {
                            do { try controller.updateAgendaTemplate(nil); repeatAnchors = false }
                            catch { self.error = FocusDayUI.message(error) }
                        }.buttonStyle(LHQuietButtonStyle()).font(.system(size: 12))
                    }
                }.padding(.top, 12)
            }.font(.system(size: 13))
        }
    }

    private var planContextBinding: Binding<Bool> {
        Binding(get: { controller.settings.usePlanContext == true }, set: { enabled in
            var settings = controller.settings
            settings.usePlanContext = enabled
            do { try controller.updateSettings(settings) }
            catch { self.error = FocusDayUI.message(error) }
        })
    }

    private func append(item: FocusPlanItem?) {
        let start = min(1380, max(agenda.startMinute, agenda.slots.map(\.endMinute).max() ?? agenda.startMinute))
        agenda.slots.append(FocusAgendaSlot(itemID: item?.id, title: item?.title ?? "Nouveau repère",
                                           startMinute: start, endMinute: min(1440, start + (item?.estimateMinutes ?? 30)),
                                           fixed: item == nil))
    }
    private func save() {
        guard agenda.valid(forDay: plan.day, items: plan.items) else {
            error = "Vérifiez les titres, les horaires et la plage de travail. L’heure de fin doit suivre l’heure de début."
            return
        }
        var updated = plan; updated.agenda = agenda
        do {
            try controller.applyDayPlan(updated, expectedRevision: plan.effectiveRevision, reason: "Agenda préparé")
            plan = controller.plan
            if repeatAnchors { try controller.updateAgendaTemplate(agenda) }
            else if controller.settings.agendaTemplate != nil { try controller.updateAgendaTemplate(nil) }
            dismiss()
        } catch { self.error = FocusDayUI.message(error) }
    }
}

private struct FocusDaySlotEditor: View {
    @Binding var slot: FocusAgendaSlot
    let items: [FocusPlanItem]
    let removable: Bool
    let onRemove: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                TextField("Action ou repère", text: $slot.title).textFieldStyle(GoalongFieldStyle())
                if removable {
                    Button(action: onRemove) { Image(systemName: "xmark").frame(width: 24, height: 24) }
                        .buttonStyle(LHQuietButtonStyle()).accessibilityLabel("Retirer \(slot.title)")
                }
            }
            HStack(spacing: 12) {
                FocusDayTimeField(minute: $slot.startMinute).frame(width: 82)
                Text("à").foregroundStyle(LHTheme.secondaryText)
                FocusDayTimeField(minute: $slot.endMinute, allowsMidnight: true).frame(width: 82)
                Toggle("Fixe", isOn: $slot.fixed)
                Spacer(minLength: 6)
                if let id = slot.itemID, let item = items.first(where: { $0.id == id }) {
                    Text(item.project ?? "Action liée").font(.system(size: 11)).foregroundStyle(LHTheme.secondaryText)
                }
                if slot.state == .active { Text("En cours").font(.system(size: 11)).foregroundStyle(LHTheme.secondaryText) }
            }.font(.system(size: 12))
        }
    }
}

private struct FocusDayTimeField: View {
    @Binding var minute: Int
    var allowsMidnight = false
    @State private var text = ""
    @State private var invalid = false

    var body: some View {
        TextField("08:00", text: Binding(get: { text }, set: { value in
            text = value
            if let value = FocusDayUI.minute(value), value < 1440 || allowsMidnight {
                minute = value; invalid = false
            } else { invalid = true; minute = -1 }
        }))
        .textFieldStyle(GoalongFieldStyle())
        .font(.system(size: 13).monospacedDigit())
        .foregroundStyle(invalid ? LHTheme.warning : LHTheme.text)
        .onAppear { text = FocusDayUI.time(minute) }
        .onChange(of: minute) { value in
            if !invalid && FocusDayUI.minute(text) != value { text = FocusDayUI.time(value); invalid = false }
        }
        .accessibilityLabel("Heure, au format heures et minutes")
    }
}

@MainActor private struct FocusDayProcessEditor: View {
    @ObservedObject var controller: ConcentrationController
    @State private var plan: FocusPlan
    let isNew: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var process: FocusAgentProcess
    @State private var error: String?
    init(controller: ConcentrationController, plan: FocusPlan, process: FocusAgentProcess, isNew: Bool) {
        self.controller = controller; self.isNew = isNew
        _plan = State(initialValue: plan)
        _process = State(initialValue: process)
    }
    var body: some View {
        FocusDaySheet(title: isNew ? "Suivre un processus" : "Modifier le suivi", error: error, onCancel: { dismiss() }, onSave: save) {
            Text("Le suivi décrit un travail lancé dans son outil. Il ne lance pas un agent à votre place.")
                .font(.system(size: 13)).foregroundStyle(LHTheme.secondaryText)
            GoalongFormField(title: "Travail attendu") {
                TextField("Ex. Implémenter l’export vidéo", text: $process.title).textFieldStyle(GoalongFieldStyle())
            }
            HStack(spacing: 14) {
                GoalongFormField(title: "Projet") { TextField("Facultatif", text: optional(\.project)).textFieldStyle(GoalongFieldStyle()) }
                GoalongFormField(title: "Agent ou responsable") { TextField("Facultatif", text: optional(\.agent)).textFieldStyle(GoalongFieldStyle()) }
            }
            GoalongFormField(title: "État") {
                Picker("État", selection: $process.status) {
                    ForEach(FocusAgentProcess.Status.allCases, id: \.rawValue) { status in Text(status.title).tag(status) }
                }.labelsHidden()
            }
            if process.status == .waitingForYou {
                GoalongFormField(title: "Question à débloquer") {
                    TextField("Ce qu’il faut décider", text: optional(\.question)).textFieldStyle(GoalongFieldStyle())
                }
            }
            GoalongFormField(title: "Lien de contexte") {
                TextField("Conversation, projet ou documentation", text: optional(\.contextURL)).textFieldStyle(GoalongFieldStyle())
            }
        }
    }
    private func optional(_ path: WritableKeyPath<FocusAgentProcess, String?>) -> Binding<String> {
        Binding(get: { process[keyPath: path] ?? "" }, set: { process[keyPath: path] = $0.isEmpty ? nil : $0 })
    }
    private func save() {
        process.title = process.title.trimmingCharacters(in: .whitespacesAndNewlines)
        process.project = FocusDayUI.clean(process.project); process.agent = FocusDayUI.clean(process.agent)
        process.question = FocusDayUI.clean(process.question); process.contextURL = FocusDayUI.clean(process.contextURL)
        process.updatedAt = GoalongToday.now
        guard process.valid else { error = "Vérifiez le titre, la question et le lien de contexte."; return }
        var updated = plan
        var processes = updated.processes ?? []
        if isNew { processes.append(process) }
        else if let index = processes.firstIndex(where: { $0.id == process.id }) { processes[index] = process }
        updated.processes = processes
        do {
            try controller.applyDayPlan(updated, expectedRevision: plan.effectiveRevision, reason: isNew ? "Processus ajouté" : "Suivi du processus modifié")
            dismiss()
        } catch { self.error = FocusDayUI.message(error) }
    }
}

@MainActor private struct FocusDayAnswerSheet: View {
    @ObservedObject var controller: ConcentrationController
    let process: FocusAgentProcess
    @Environment(\.dismiss) private var dismiss
    @State private var answer: String
    @State private var error: String?
    init(controller: ConcentrationController, process: FocusAgentProcess) {
        self.controller = controller; self.process = process
        _answer = State(initialValue: process.answer ?? "")
    }
    var body: some View {
        FocusDaySheet(title: process.title, error: error, saveTitle: "Enregistrer la réponse", onCancel: { dismiss() }, onSave: save) {
            Text(process.question ?? "Quelle décision faut-il transmettre ?").font(.system(size: 15))
            GoalongTextArea(text: $answer, placeholder: "Votre réponse ou la décision à suivre", minHeight: 100)
            Text("La réponse sera disponible dans Goalong. Le processus restera en attente jusqu’à ce que l’agent confirme sa reprise.")
                .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
            if let context = process.contextURL, let url = URL(string: context) {
                Button("Ouvrir le contexte") {
                    if !GoalongWorkspaceOpenPolicy.open(url, purpose: .plannedContext) { error = "Ce lien n’est pas pris en charge. Utilisez une adresse HTTPS ou l’adresse locale de Context Room." }
                }.buttonStyle(LHQuietButtonStyle())
            }
        }
    }
    private func save() {
        guard let clean = FocusDayUI.clean(answer) else { error = "Écrivez une réponse avant de l’enregistrer."; return }
        guard let latest = controller.plan.processes?.first(where: { $0.id == process.id }),
              latest.status == .waitingForYou, latest.question == process.question, latest.answer == process.answer else {
            error = "Cette question a changé. Fermez cette fenêtre et rouvrez-la avant de répondre."
            return
        }
        do { try controller.answerProcess(process.id, answer: clean); dismiss() }
        catch { self.error = FocusDayUI.message(error) }
    }
}

private struct FocusDaySheet<Content: View>: View {
    let title: String
    let error: String?
    var width: CGFloat = 600
    var saveTitle = "Enregistrer"
    let onCancel: () -> Void
    let onSave: () -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title).font(LHTheme.sheetTitleFont)
            content()
            if let error { GoalongNote(error, tone: .warning) }
            HStack {
                Spacer()
                Button("Annuler", action: onCancel).buttonStyle(LHSecondaryButtonStyle()).keyboardShortcut(.cancelAction)
                Button(saveTitle, action: onSave).buttonStyle(LHPrimaryButtonStyle()).keyboardShortcut(.defaultAction)
            }.padding(.top, 4)
        }.padding(28).frame(width: width).background(LHTheme.pageBackground)
    }
}

enum FocusDayUI {
    static func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let result = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return result.isEmpty ? nil : result
    }
    static func time(_ minute: Int) -> String { String(format: "%02d:%02d", minute / 60, minute % 60) }
    static func minute(_ value: String) -> Int? {
        let parts = value.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0...24).contains(hour), (0...59).contains(minute), hour != 24 || minute == 0 else { return nil }
        return hour * 60 + minute
    }
    static func message(_ error: Error) -> String {
        if let failure = error as? FocusFailure, failure == .conflict || failure == .requestConflict {
            return "Le plan a changé depuis l’ouverture. Fermez cet éditeur puis rouvrez-le pour retrouver la dernière version."
        }
        return FocusUIError.message(error)
    }
}
#endif
