#if os(macOS)
import AppKit
import SwiftUI

/// Functional, system controls only. Design owns replacement of this file.
@MainActor struct ConcentrationPlaceholder: View {
    @ObservedObject private var runtime = ConcentrationRuntime.shared
    @State private var intent = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Concentration")
            if let c = runtime.controller {
                Text(c.menuBarText)
                TextField("Je fais : …", text: $intent)
                HStack {
                    Button("25 min") { perform { try c.startSession(intent: intent, mode: FocusMode()) } }
                    Button("Pomodoro") { perform { var m = FocusMode(); m.kind = .pomodoro; try c.startSession(intent: intent, mode: m) } }
                    Button("Passer") { perform { try c.skipPhase() } }.disabled(c.currentSession == nil)
                    Button("Arrêter") { perform { try c.stopSession() } }.disabled(c.currentSession == nil)
                }
                ForEach(c.plan.items) { item in Text(item.title) }
                if let error = c.error { Text(error) }
            } else { Text(runtime.error ?? "Module désactivé") }
        }.padding()
    }
    private func perform(_ action: () throws -> Void) { do { try action() } catch { runtime.controller?.error = String(describing: error) } }
}
@MainActor struct ConcentrationActivityMarksPlaceholder: View {
    var day: Date
    @ObservedObject private var runtime = ConcentrationRuntime.shared
    var body: some View {
        let marks = runtime.controller?.limitMarks.filter { Calendar.current.isDate($0.at, inSameDayAs: day) } ?? []
        if !marks.isEmpty {
          VStack(alignment: .leading) {
            ForEach(Array(marks.enumerated()), id: \.offset) { _, mark in
                Text("\(mark.kind == "endOfDay" ? "Fin de journée" : mark.kind == "weekly" ? "Limite de la semaine" : "Limite du jour") — \(mark.at.formatted(date: .omitted, time: .shortened))\(mark.usesActiveTime ? " · temps actif, sans définition du travail" : "")")
            }
          }
        }
    }
}
@MainActor final class ConcentrationPlaceholderPanel {
    private class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
    }
    private var panel: NSPanel?
    func show(_ content: FocusPanel, controller: ConcentrationController) {
        let visible = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1000, height: 700)
        let frame = CGRect(x: visible.midX - 210, y: visible.maxY - 220, width: 420, height: 200)
        let p = panel ?? Panel(contentRect: frame, styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isReleasedWhenClosed = false; p.hidesOnDeactivate = false; p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]; p.level = .floating
        p.contentView = NSHostingView(rootView: ConcentrationPanelPlaceholder(content: content, controller: controller))
        p.setFrame(frame, display: true); p.orderFrontRegardless(); panel = p
    }
    func close() { panel?.close(); panel = nil }
}
private struct ConcentrationPanelPlaceholder: View {
    var content: FocusPanel
    @ObservedObject var controller: ConcentrationController
    @State private var note = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(content.text)
            if content.kind == .sessionReview, let id = content.sessionID {
                Text(controller.sessionFacts.available ? "Actif : \(Int(controller.sessionFacts.activeSeconds / 60)) min · Travail : \(Int(controller.sessionFacts.workSeconds / 60)) min · Hors travail : \(Int(controller.sessionFacts.otherSeconds / 60)) min · Non classé : \(Int(controller.sessionFacts.unclassifiedSeconds / 60)) min" : "Mesure indisponible")
                Text("\(controller.sessionFacts.appSwitches) changements · plus longue plage : \(Int(controller.sessionFacts.longestStretchSeconds / 60)) min")
                TextField("Note (facultative)", text: $note)
                HStack { answer("Oui", id, .done); answer("En partie", id, .partly); answer("Non", id, .notDone) }
            }
            if content.kind == .morning || content.kind == .evening {
                HStack { Button("Faire maintenant") { controller.promptNow() }; Button("Plus tard") { controller.promptLater() } }
            }
            Button("Fermer") { controller.dismissPanel() }
        }.padding()
    }
    private func answer(_ title: String, _ id: UUID, _ outcome: FocusSession.Outcome) -> some View {
        Button(title) { do { try controller.recordOutcome(sessionID: id, outcome: outcome, note: note.isEmpty ? nil : note) } catch { controller.error = String(describing: error) } }
    }
}
#endif
