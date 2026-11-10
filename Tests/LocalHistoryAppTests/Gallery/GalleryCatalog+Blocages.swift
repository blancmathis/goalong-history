#if os(macOS)
import Foundation
import SwiftUI
@testable import LocalHistoryApp
@testable import LocalHistoryCore

/// The one page « Blocages » and its rule editor (docs/spec-blocages-20261110.md), on the gallery clock.
/// The lists, the sessions and the red screen come from the fixtures of their old pages.
extension GalleryCatalog {
    static var blocagesEntries: [GalleryEntry] {
        let F = GalleryFixtures.self
        func page(_ id: String, height: CGFloat, themes: [GalleryTheme] = GalleryTheme.standard,
                  _ make: @escaping @MainActor (GalleryContext) throws -> BlocagesPageContent) -> GalleryEntry {
            panel(id, width: 900, height: height, themes: themes, clock: .injected) { ctx in AnyView(try make(ctx)) }
        }
        /// The real editor, without the height limit of its sheet, so the capture shows the whole form.
        func sheet(_ id: String, _ make: @escaping @MainActor (GalleryContext) throws -> BlockRuleEditor) -> GalleryEntry {
            panel(id, width: BlockRuleEditor.width, clock: .injected) { ctx in AnyView(try make(ctx)) }
        }
        @MainActor func rule(_ blocking: BlockingController, _ braise: BraiseController?) throws -> BlockRule {
            guard let rule = BlockRules.current(blocking: blocking, braise: braise, now: F.sunday).first else {
                throw CocoaError(.coderValueNotFound)
            }
            return rule
        }
        return [
            // A new member: no list, no rule, the red screen never used, Concentration off.
            page("blocages/vide", height: 1_000, themes: GalleryTheme.withContrast) { _ in
                BlocagesPageContent(blocking: F.blockingEmpty(), braise: nil, focus: nil, now: F.blockingNow)
            },
            // Every module off: the page still says what each part is and how to turn it on.
            page("blocages/modules-coupes", height: 900) { _ in
                BlocagesPageContent(blocking: nil, braise: nil, focus: nil, now: F.blockingNow)
            },
            // At rest on Sunday: the rules by the clock, the red screen on by hand, the sessions folded.
            page("blocages/regles", height: 1_600, themes: GalleryTheme.withContrast) { ctx in
                BlocagesPageContent(blocking: F.blockingIdle(), braise: try braise(ctx),
                                    focus: try GalleryConcentrationFixtures().empty(), now: F.sunday, measures: [],
                                    sessionDraft: FocusComposerDraft())
            },
            // Monday 15:10: a locked block runs and the weekday rule runs under it.
            page("blocages/blocage-en-cours", height: 1_600) { _ in
                BlocagesPageContent(blocking: F.blockingActive(), braise: nil, focus: nil, now: F.blockingNow)
            },
            page("blocages/mot-de-passe", height: 1_600) { _ in
                BlocagesPageContent(blocking: F.blockingGuarded(), braise: nil, focus: nil, now: F.blockingNow)
            },
            page("blocages/seance-en-cours", height: 1_600) { _ in
                let fixtures = GalleryConcentrationFixtures()
                return BlocagesPageContent(blocking: fixtures.blocking, braise: nil, focus: try fixtures.pomodoro(),
                                           now: GalleryConcentrationFixtures.now, measures: [], sessionDraft: FocusComposerDraft())
            },
            // The dépliants open: the plan of the day, the protection and the red screen by hand.
            page("blocages/depliants", height: 3_000) { ctx in
                let fixtures = GalleryConcentrationFixtures()
                let planned = try fixtures.planned()
                return BlocagesPageContent(blocking: fixtures.blocking, braise: try braise(ctx), focus: planned.controller,
                                           now: GalleryConcentrationFixtures.now, measures: planned.measures,
                                           sessionDraft: FocusComposerDraft(), open: [.plan, .protection, .redSafety])
            },
            sheet("blocages/editeur-maintenant") { ctx in
                BlockRuleEditor(subject: .new, blocking: F.blockingIdle(), braise: try braise(ctx), focus: nil,
                                now: F.sunday, maxHeight: 4_000, sessionDraft: FocusComposerDraft(), onClose: {})
            },
            sheet("blocages/editeur-seance") { _ in
                let fixtures = GalleryConcentrationFixtures()
                var draft = FocusComposerDraft()
                draft.kind = .pomodoro; draft.cycles = 4
                draft.intent = "Relire les épreuves"; draft.blockListIds = [GalleryConcentrationFixtures.socialID]
                return BlockRuleEditor(subject: .session(draft), blocking: fixtures.blocking, braise: nil, focus: try fixtures.empty(),
                                       now: GalleryConcentrationFixtures.now, maxHeight: 4_000, sessionDraft: FocusComposerDraft(), onClose: {})
            },
            sheet("blocages/editeur-horaire") { ctx in
                BlockRuleEditor(subject: .new, blocking: F.blockingIdle(), braise: try braise(ctx), focus: nil,
                                now: F.sunday, trigger: .schedule, maxHeight: 4_000, sessionDraft: FocusComposerDraft(), onClose: {})
            },
            // The red screen was never used: the rule can still be written, the screen part says how to prepare it.
            sheet("blocages/editeur-horaire-sans-ecran-rouge") { _ in
                BlockRuleEditor(subject: .new, blocking: F.blockingIdle(), braise: nil, focus: nil,
                                now: F.sunday, trigger: .schedule, maxHeight: 4_000, sessionDraft: FocusComposerDraft(), onClose: {})
            },
            sheet("blocages/editeur-regle") { ctx in
                let blocking = F.blockingIdle(), red = try braise(ctx)
                return BlockRuleEditor(subject: .rule(try rule(blocking, red)), blocking: blocking, braise: red,
                                       focus: nil, now: F.sunday, maxHeight: 4_000, sessionDraft: FocusComposerDraft(), onClose: {})
            },
            // Monday 15:10, inside the hours of a locked rule: the editor says what the protection refuses.
            sheet("blocages/editeur-regle-verrouillee") { _ in
                var social = F.socialList
                social.program = BlockProgram(ranges: [BlockProgramRange(weekdays: Set(1...5), startMinute: 14 * 60, endMinute: 18 * 60,
                                                                         lock: .locked)])
                var document = BlockingDocument()
                document.lists = [social, F.videoList, F.focusList]
                let now = F.blockingNow
                let blocking = BlockingController(document: document, clock: { now }, continuous: { now.timeIntervalSince1970 },
                                                  runningApps: F.noApps)
                guard let rule = BlockRules.current(blocking: blocking, braise: nil, now: now).first(where: { $0.lock == .locked }) else {
                    throw CocoaError(.coderValueNotFound)
                }
                return BlockRuleEditor(subject: .rule(rule), blocking: blocking, braise: nil, focus: nil, now: now, maxHeight: 4_000,
                                       sessionDraft: FocusComposerDraft(), onClose: {})
            },
            // The Jev rule to set up: no key, history on and a work definition (the former « surveillance/a-configurer »).
            sheet("blocages/editeur-jev") { _ in
                try GalleryFixtureHome.install(.recordingOn)
                try JevWorkContextStore.shared.save("Atlas : préparer le lancement de l’app mobile.",
                    applications: "Xcode, Terminal et GitHub pour Atlas.", content: "Documentation Swift.",
                    procrastination: "youtube.com, Messages")
                return BlockRuleEditor(subject: .jev, blocking: F.blockingIdle(), braise: nil, focus: nil, now: F.sunday,
                                       maxHeight: 4_000, sessionDraft: FocusComposerDraft(), onClose: {})
            },
        ]
    }
}
#endif
