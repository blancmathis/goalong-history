import AppKit
import Combine

#if os(macOS)
    /// What a bare key does in the dashboard window (T-052, lot 2a, points 2 and 3).
    enum DashboardKeyCommand: Equatable {
        case previousDay, nextDay, today, back
    }

    /// What the window shows at the moment of the key. Built from the real window, decided by a pure function.
    struct DashboardKeyContext: Equatable {
        var section: DashboardSection
        var textHasFocus = false
        /// Lot 2b: a non-text AppKit control (segment, slider, date picker, pop-up) holds the focus and keeps ←/→/T.
        var controlHasFocus = false
        /// A sheet, an alert, a modal or a popover is in front.
        var layerAbove = false
        /// A visible search field holds text.
        var searchFilled = false
        var welcomeShown = false
    }

    extension DashboardSection {
        /// Lot 2a (4): the one table of the sidebar's shortcuts, read by the View menu and by the row tooltips.
        /// ⌘1 to ⌘4 follow the sidebar order (Ambiance only when its module is on); ⌘, is the macOS key for Réglages.
        var sidebarShortcutKey: String? {
            switch self {
            case .overview: return "1"
            case .history: return "2"
            case .blocking: return "3"
            case .ambiance: return "4"
            case .settings: return ","
            default: return nil
            }
        }

        var sidebarShortcutLabel: String? { sidebarShortcutKey.map { "⌘" + $0 } }

        /// « Activité (⌘1) ».
        var sidebarTooltip: String { sidebarShortcutLabel.map { "\(simpleTitle) (\($0))" } ?? simpleTitle }
    }

    enum DashboardKeyboard {
    /// Pure decision. A key with ⌘, ⌥, ⌃ or ⇧, or a repeat, is never ours (menus own those).
    static func dashboardKeyCommand(keyCode: UInt16, characters: String?, modifiers: NSEvent.ModifierFlags,
                                    isRepeat: Bool, context: DashboardKeyContext) -> DashboardKeyCommand? {
        guard modifiers.intersection([.command, .option, .control, .shift]).isEmpty, !isRepeat,
              !context.layerAbove, !context.welcomeShown else { return nil }
        let typing = context.textHasFocus || context.controlHasFocus
        let dayPage = context.section == .overview || context.section == .analytics || context.section == .history
        switch keyCode {
        case 123: return dayPage && !typing ? .previousDay : nil
        case 124: return dayPage && !typing ? .nextDay : nil
        case 53:
            return context.section.isSecondary && !context.textHasFocus && !context.searchFilled ? .back : nil
        default:
            if characters?.lowercased() == "t", dayPage, !typing { return .today }
            return nil
        }
    }

    /// Finds the search field of the page on screen: the highest visible, editable field whose prompt starts with « Rechercher ».
    @MainActor static func searchFields(in window: NSWindow) -> [NSTextField] {
        var found: [NSTextField] = []
        func walk(_ view: NSView) {
            if view.isHiddenOrHasHiddenAncestor { return }
            if let field = view as? NSTextField, field.isEditable,
               field.placeholderString?.hasPrefix("Rechercher") == true
                || field.placeholderAttributedString?.string.hasPrefix("Rechercher") == true {
                found.append(field)
            }
            view.subviews.forEach(walk)
        }
        if let root = window.contentView?.superview ?? window.contentView { walk(root) }
        return found.sorted { $0.convert($0.bounds, to: nil).maxY > $1.convert($1.bounds, to: nil).maxY }
    }

    /// Lot 2a (4): ⌘F gives the search field of the page the keyboard focus. False when the page has none.
    @MainActor @discardableResult static func focusSearchField(in window: NSWindow) -> Bool {
        guard window.attachedSheet == nil, let field = searchFields(in: window).first else { return false }
        return window.makeFirstResponder(field)
    }

    /// Reads the real window: focus, sheets, popovers and the search fields.
    @MainActor static func dashboardKeyContext(window: NSWindow, section: DashboardSection, welcomeShown: Bool) -> DashboardKeyContext {
        let responder = window.firstResponder
        let editing = (responder as? NSText)?.isEditable == true || responder is NSTextInputClient && responder is NSTextField
        let control = focusedNonTextControl(responder)
        let layer = window.attachedSheet != nil || NSApp.modalWindow != nil
            || (window.childWindows?.contains(where: { $0.isVisible }) ?? false)
        let filled = searchFields(in: window).contains { !$0.stringValue.isEmpty }
        return DashboardKeyContext(section: section, textHasFocus: editing, controlHasFocus: control, layerAbove: layer, searchFilled: filled,
                                   welcomeShown: welcomeShown)
    }

    /// Lot 2b: the focused view is, or sits inside, an AppKit control that is not a text field.
    static func focusedNonTextControl(_ responder: NSResponder?) -> Bool {
        var view = responder as? NSView
        while let current = view {
            if current is NSTextField || current is NSText { return false }
            if current is NSControl { return true }
            view = current.superview
        }
        return false
    }

    }

    /// One local key monitor for the dashboard window. Consumes the key only when it did something.
    @MainActor final class DashboardKeyRouter {
        private weak var window: NSWindow?
        private weak var model: DashboardViewModel?
        private var monitor: Any?

        init(window: NSWindow, model: DashboardViewModel) {
            self.window = window
            self.model = model
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, event.window === self.window else { return event }
                return self.handle(event) ? nil : event
            }
        }

        func remove() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }

        /// True when the key was ours and was carried out.
        func handle(_ event: NSEvent) -> Bool {
            guard let window, let model else { return false }
            let navigation = model.keyboardNavigation
            let context = DashboardKeyboard.dashboardKeyContext(
                window: window, section: navigation.selectedSection, welcomeShown: navigation.showWelcome)
            guard let command = DashboardKeyboard.dashboardKeyCommand(
                keyCode: event.keyCode, characters: event.charactersIgnoringModifiers, modifiers: event.modifierFlags,
                isRepeat: event.isARepeat, context: context) else { return false }
            perform(command, model: model)
            return true
        }

        func perform(_ command: DashboardKeyCommand, model: DashboardViewModel) {
            let navigation = model.keyboardNavigation
            switch command {
            case .back:
                model.returnFromSecondaryPage()
            case .previousDay, .nextDay, .today:
                if navigation.selectedSection == .history {
                    switch command {
                    case .today: model.selectDay(model.now())
                    default:
                        let direction = command == .previousDay ? -1 : 1
                        if let day = DateSelectionControl.steppedDay(from: navigation.selectedDay, by: direction, now: model.now()) {
                            model.selectDay(day)
                        }
                    }
                } else {
                    navigation.dayKeys.send(command)
                }
            }
        }
    }
#endif
